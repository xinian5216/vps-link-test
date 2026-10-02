#!/usr/bin/env bash
#
# vpslink.sh - Lightweight VPS <-> VPS network link test.
#
# Two Linux VPS run this same script. One picks A mode (temporary iperf3
# server), the other picks B mode (runs the tests) and prints a compact,
# readable report.
#
# Deliberately small and accurate. Not a benchmark suite, not a monitoring
# platform, not a Web UI. Test, report, exit.
#
# Production safety rules baked into this file:
#   * this script only ever touches files and PIDs it created itself
#   * it never restarts services, reboots, or edits system configuration
#   * it never modifies firewall rules or software sources
#   * it never upgrades or removes pre-existing packages
#   * every wait has a hard deadline
#
# Usage:
#   bash vpslink.sh [--help|--version|--no-color]

VPSLINK_VERSION="0.1.0"

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------

SUPPORTED_DISTROS="Debian, Ubuntu, AlmaLinux, Rocky Linux, CentOS Stream"

DISTRO_ID=""
DISTRO_NAME="unknown"
DISTRO_VERSION="unknown"
PKG_FAMILY=""          # "debian" | "rhel" | ""
PKG_MANAGER=""         # "apt" | "dnf" | "yum" | ""
DISTRO_SUPPORTED=0

# Runtime scratch directory (owned by this run only).
WORKDIR=""
WORKDIR_MARKER=""

# Addresses reported by the menu.
PUBLIC_IPV4="unavailable"
PUBLIC_IPV6="unavailable"

# PID of the iperf3 one-off server started by this script (empty = none).
IPERF3_PID=""

# ---------------------------------------------------------------------------
# Dependency bookkeeping
# ---------------------------------------------------------------------------

# Commands the script needs in order to run the full test sequence.
REQUIRED_COMMANDS=(curl ping iperf3 mtr jq ss timeout)

# Commands that were already on the system when this run started.
PREEXISTING_COMMANDS=()
# Commands that this run made available by installing a package.
INSTALLED_BY_RUN_COMMANDS=()
# Commands that are still missing after the install attempt.
MISSING_COMMANDS=()
# Packages installed by this run (never anything that existed before).
INSTALLED_PACKAGES=()

# Record of what was there before we touched anything. Used so the optional
# "remove what I added" step can never delete pre-existing software.
DEPS_RECORDED=0

# Palette, filled in by init_colors().
C_RESET=""
C_BOLD=""
C_DIM=""
C_RED=""
C_GREEN=""
C_YELLOW=""
C_BLUE=""
C_CYAN=""

# ---------------------------------------------------------------------------
# Locale
#
# Every tool output we parse must be in English, otherwise the packet-loss /
# RTT summary line cannot be parsed reliably. Set it once, globally.
# ---------------------------------------------------------------------------
export LC_ALL=C
export LANG=C

# ---------------------------------------------------------------------------
# Colour handling
# ---------------------------------------------------------------------------

init_colors() {
    if [[ -n "${NO_COLOR:-}" || -n "${VPSLINK_NO_COLOR:-}" ]] \
       || [[ ! -t 1 ]] || [[ -z "${TERM:-}" || "${TERM:-}" == "dumb" ]]; then
        return 0
    fi

    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
}

# ---------------------------------------------------------------------------
# Small output helpers
# ---------------------------------------------------------------------------

info()  { printf '%s\n' "$*"; }
warn()  { printf '%s%s%s\n' "${C_YELLOW}" "$*" "${C_RESET}"; }
fail()  { printf '%s%s%s\n' "${C_RED}" "$*" "${C_RESET}"; }
ok()    { printf '%s%s%s\n' "${C_GREEN}" "$*" "${C_RESET}"; }
dim()   { printf '%s%s%s\n' "${C_DIM}" "$*" "${C_RESET}"; }
rule()  { printf '%s\n' "----------------------------------------"; }

# Prints "$1" or "unavailable" when empty.
val_or_unavailable() {
    if [[ -n "$1" ]]; then
        printf '%s\n' "$1"
    else
        printf '%s\n' "unavailable"
    fi
}

# ---------------------------------------------------------------------------
# Scratch directory + cleanup
# ---------------------------------------------------------------------------

init_workdir() {
    local base="${TMPDIR:-/tmp}"
    base="${base%/}"
    [[ -d "$base" ]] || base="/tmp"

    WORKDIR="$(mktemp -d "${base}/vps-link-test-XXXXXXXX" 2>/dev/null)" || return 1
    WORKDIR_MARKER="${WORKDIR}/.vpslink-owned"
    : >"$WORKDIR_MARKER" 2>/dev/null || return 1
    return 0
}

# Terminates only the iperf3 process this script started (never a
# blanket pkill/killall, which could take down an unrelated service).
stop_iperf3_server() {
    if [[ -n "$IPERF3_PID" ]] && kill -0 "$IPERF3_PID" 2>/dev/null; then
        kill "$IPERF3_PID" 2>/dev/null || true
        # Give it a moment to exit on its own, then make sure it is gone.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$IPERF3_PID" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$IPERF3_PID" 2>/dev/null; then
            kill -9 "$IPERF3_PID" 2>/dev/null || true
        fi
        wait "$IPERF3_PID" 2>/dev/null || true
    fi
    IPERF3_PID=""
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM

    stop_iperf3_server

    # Only delete a directory this run actually created and marked.
    if [[ -n "$WORKDIR" && -n "$WORKDIR_MARKER" && -f "$WORKDIR_MARKER" ]]; then
        rm -rf -- "$WORKDIR" 2>/dev/null || true
    fi
    WORKDIR=""
    WORKDIR_MARKER=""

    return "$rc"
}

install_traps() {
    trap cleanup EXIT INT TERM
}

# ---------------------------------------------------------------------------
# Distribution detection
# ---------------------------------------------------------------------------

detect_distro() {
    local fields="" os_id="" os_like="" os_name="" os_version_id=""

    if [[ -r /etc/os-release ]]; then
        # Sourced inside a subshell so nothing leaks into the current shell.
        # shellcheck source=/dev/null
        fields="$(
            . /etc/os-release >/dev/null 2>&1
            printf '%s|%s|%s|%s' "${ID:-}" "${ID_LIKE:-}" "${NAME:-}" "${VERSION_ID:-}"
        )"
        IFS='|' read -r os_id os_like os_name os_version_id <<<"$fields"
    fi

    DISTRO_ID="$os_id"
    DISTRO_NAME="${os_name:-unknown}"
    DISTRO_VERSION="${os_version_id:-unknown}"
    [[ -n "$DISTRO_NAME" ]] || DISTRO_NAME="unknown"
    [[ -n "$DISTRO_VERSION" ]] || DISTRO_VERSION="unknown"

    # "ID" first, then "ID_LIKE" so common derivatives (Linux Mint, Oracle
    # Linux, ...) map onto one of the supported families.
    case " ${os_id} ${os_like} " in
        *" debian "*|*" ubuntu "*|*" linuxmint "*)
            PKG_FAMILY="debian"
            ;;
        *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*)
            PKG_FAMILY="rhel"
            ;;
        *)
            PKG_FAMILY=""
            ;;
    esac

    if [[ -z "$PKG_FAMILY" ]]; then
        DISTRO_SUPPORTED=0
        return 1
    fi

    if [[ "$PKG_FAMILY" == "debian" ]] && command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    fi

    if [[ -z "$PKG_MANAGER" ]]; then
        DISTRO_SUPPORTED=0
        return 1
    fi

    DISTRO_SUPPORTED=1
    return 0
}

reject_unsupported_distro() {
    fail "Unsupported operating system."
    info ""
    info "  Detected : ${DISTRO_NAME} ${DISTRO_VERSION} (id: ${DISTRO_ID:-unknown})"
    info "  Supported: ${SUPPORTED_DISTROS}"
    info ""
    info "No packages were installed and nothing was changed."
    info "Exiting. Open an issue if you want this distribution added."
}

# ---------------------------------------------------------------------------
# Privilege helper
#
# Everything the package manager does needs root. sudo -n is used so the
# script can never hang on an interactive password prompt.
# ---------------------------------------------------------------------------

run_privileged() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -n "$@"
    else
        fail "This action needs root privileges, but sudo is not available."
        info "Re-run as root, for example: sudo bash vpslink.sh"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Dependency management
#
# Rules enforced here:
#   * detect what is missing, install only that
#   * never run any form of upgrade / autoremove
#   * never touch software sources
#   * never replace a package that is already installed
#   * remember exactly what this run added, so the optional removal step can
#     only ever remove packages that did not exist before
# ---------------------------------------------------------------------------

# Maps a command to the package that provides it on this distribution family.
dep_package_for() {
    local cmd="$1"
    case "$cmd" in
        curl)
            printf 'curl\n'
            ;;
        ping)
            if [[ "$PKG_FAMILY" == "debian" ]]; then
                printf 'iputils-ping\n'
            else
                printf 'iputils\n'
            fi
            ;;
        iperf3)
            printf 'iperf3\n'
            ;;
        mtr)
            printf 'mtr\n'
            ;;
        jq)
            printf 'jq\n'
            ;;
        ss)
            if [[ "$PKG_FAMILY" == "debian" ]]; then
                printf 'iproute2\n'
            else
                printf 'iproute\n'
            fi
            ;;
        timeout)
            printf 'coreutils\n'
            ;;
        *)
            return 1
            ;;
    esac
}

# Is this package already installed on the system?
package_installed() {
    local pkg="$1"
    case "$PKG_MANAGER" in
        apt)
            dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null \
                | grep -q "install ok installed"
            ;;
        dnf|yum)
            rpm -q "$pkg" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

detect_dependencies() {
    MISSING_COMMANDS=()
    local cmd
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            MISSING_COMMANDS+=("$cmd")
        fi
    done
    return 0
}

# Snapshots the current state. Must be called before anything is installed.
record_pre_existing_dependencies() {
    PREEXISTING_COMMANDS=()
    local cmd
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            PREEXISTING_COMMANDS+=("$cmd")
        fi
    done
    DEPS_RECORDED=1
}

command_origin() {
    # "pre-existing" | "this run" | "missing"
    local cmd="$1" known
    for known in "${PREEXISTING_COMMANDS[@]}"; do
        [[ "$known" == "$cmd" ]] && { printf 'pre-existing'; return 0; }
    done
    for known in "${INSTALLED_BY_RUN_COMMANDS[@]}"; do
        [[ "$known" == "$cmd" ]] && { printf 'this run'; return 0; }
    done
    printf 'missing'
    return 0
}

pkg_install() {
    # NOTE: no "upgrade", no "dist-upgrade", no "update" of packages, no
    # "autoremove", and no change of sources.list anywhere in this file.
    case "$PKG_MANAGER" in
        apt)
            run_privileged env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y "$@"
            ;;
        dnf)
            run_privileged dnf install -y "$@"
            ;;
        yum)
            run_privileged yum install -y "$@"
            ;;
        *)
            fail "No usable package manager (apt/dnf/yum) was found."
            return 1
            ;;
    esac
}

ask_yn() {
    # ask_yn <prompt> <default: y|n>  -> returns 0 for yes, 1 for no
    local prompt="$1" default="${2:-n}" answer=""
    printf '%s' "$prompt"
    if ! read -r answer; then
        printf '\n'
        return 1
    fi
    [[ -n "$answer" ]] || answer="$default"
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

ensure_dependencies() {
    if [[ "$DEPS_RECORDED" -ne 1 ]]; then
        record_pre_existing_dependencies
    fi

    detect_dependencies

    if [[ ${#MISSING_COMMANDS[@]} -eq 0 ]]; then
        ok "All required commands are already present."
        info "Pre-existing: ${PREEXISTING_COMMANDS[*]}"
        return 0
    fi

    warn "Missing commands: ${MISSING_COMMANDS[*]}"
    printf '\n'
    dim  "Only the missing ones will be installed."
    dim  "Already installed software is never replaced or upgraded."
    printf '\n'

    if ! ask_yn "Install the missing dependencies now? [Y/n] " "y"; then
        info "Continuing without installing."
        warn "Tests that need ${MISSING_COMMANDS[*]} will be reported as unavailable."
        return 1
    fi

    local to_install=() skip=() cmd pkg
    for cmd in "${MISSING_COMMANDS[@]}"; do
        if [[ "$cmd" == "timeout" ]]; then
            # Part of coreutils on every supported distribution. If it is
            # missing the system is damaged; do not try to "fix" that.
            skip+=("$cmd (coreutils, cannot be installed safely)")
            continue
        fi
        pkg="$(dep_package_for "$cmd")"
        if package_installed "$pkg"; then
            # The package is present but the command is not. Replacing an
            # existing package is explicitly out of scope, so leave it alone.
            warn "'$cmd' not found, but package '$pkg' is already installed."
            info "Leaving '$pkg' untouched; '$cmd' will be reported as unavailable."
            skip+=("$cmd")
            continue
        fi
        to_install+=("$pkg")
    done

    # De-duplicate while preserving order (one package may cover two commands).
    local -A seen=()
    local unique=()
    for pkg in "${to_install[@]}"; do
        [[ -n "${seen[$pkg]:-}" ]] && continue
        seen["$pkg"]=1
        unique+=("$pkg")
    done
    to_install=("${unique[@]}")

    if [[ ${#to_install[@]} -gt 0 ]]; then
        info "Installing: ${to_install[*]}"
        if ! pkg_install "${to_install[@]}"; then
            warn "First install attempt failed."
            # A missing/empty package index is the usual cause on fresh
            # images. Refresh metadata once and retry, then give up.
            if [[ "$PKG_MANAGER" == "apt" ]] \
               && run_privileged env DEBIAN_FRONTEND=noninteractive \
                    apt-get update -qq; then
                info "Retrying once..."
                if ! pkg_install "${to_install[@]}"; then
                    warn "Install failed for: ${to_install[*]}"
                fi
            fi
        fi
    fi

    detect_dependencies

    if [[ ${#MISSING_COMMANDS[@]} -eq 0 ]]; then
        ok "All required commands are now available."
        INSTALLED_PACKAGES=("${to_install[@]}")
        INSTALLED_BY_RUN_COMMANDS=()
        for cmd in "${REQUIRED_COMMANDS[@]}"; do
            if command -v "$cmd" >/dev/null 2>&1; then
                local was_present=0 known
                for known in "${PREEXISTING_COMMANDS[@]}"; do
                    [[ "$known" == "$cmd" ]] && was_present=1
                done
                [[ "$was_present" -eq 1 ]] || INSTALLED_BY_RUN_COMMANDS+=("$cmd")
            fi
        done
    else
        warn "Still unavailable: ${MISSING_COMMANDS[*]}"
        warn "Tests that need them will be skipped and clearly reported."
    fi

    if [[ ${#skip[@]} -gt 0 ]]; then
        info "Left untouched: ${skip[*]}"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Optional removal of what this run added
#
# Only packages that (a) did not exist before this run and (b) were installed
# by this script are ever offered, and only after an explicit confirmation.
# Removal uses "remove", never "autoremove".
# ---------------------------------------------------------------------------

offer_dependency_removal() {
    [[ ${#INSTALLED_PACKAGES[@]} -gt 0 ]] || return 0

    # Defensive second filter: cross-check against the pre-existing snapshot.
    local removable=() pkg cmd cmd_pkg found
    for pkg in "${INSTALLED_PACKAGES[@]}"; do
        found=0
        for cmd in "${REQUIRED_COMMANDS[@]}"; do
            cmd_pkg="$(dep_package_for "$cmd")" || continue
            if [[ "$cmd_pkg" == "$pkg" ]] && [[ "$(command_origin "$cmd")" == "pre-existing" ]]; then
                found=1
            fi
        done
        [[ "$found" -eq 1 ]] || removable+=("$pkg")
    done

    if [[ ${#removable[@]} -eq 0 ]]; then
        return 0
    fi

    printf '\n'
    warn "Newly installed by this run: ${removable[*]}"
    dim  "Packages that already existed before this run are never touched."

    if ! ask_yn "Remove the newly installed packages? [y/N] " "n"; then
        info "Keeping them."
        return 0
    fi

    case "$PKG_MANAGER" in
        apt)
            run_privileged env DEBIAN_FRONTEND=noninteractive \
                apt-get remove -y "${removable[@]}" || warn "Removal failed."
            ;;
        dnf)
            run_privileged dnf remove -y "${removable[@]}" || warn "Removal failed."
            ;;
        yum)
            run_privileged yum remove -y "${removable[@]}" || warn "Removal failed."
            ;;
    esac

    INSTALLED_PACKAGES=()
    INSTALLED_BY_RUN_COMMANDS=()
    return 0
}

# ---------------------------------------------------------------------------
# Address helpers
# ---------------------------------------------------------------------------

is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6_literal() {
    # A bare IPv6 literal always contains at least one ':' and no dots.
    [[ "$1" == *:* && "$1" != *.* ]]
}

# Local addresses, mainly used for the environment screen and as a visible
# hint when the public-IP lookup services are unreachable.
local_ipv4() {
    ip -o -4 addr show scope global 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | head -n 1
}

local_ipv6() {
    ip -o -6 addr show scope global 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 \
        | grep -v '^fe80:' | head -n 1
}

detect_public_ips() {
    local out=""

    if command -v curl >/dev/null 2>&1; then
        out="$(curl -4 -fsS --connect-timeout 3 --max-time 5 \
               https://api.ipify.org 2>/dev/null | tr -d '[:space:]')"
        if ! is_ipv4 "$out"; then
            out="$(curl -4 -fsS --connect-timeout 3 --max-time 5 \
                   https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]')"
        fi
        if is_ipv4 "$out"; then
            PUBLIC_IPV4="$out"
        fi

        out="$(curl -6 -fsS --connect-timeout 3 --max-time 5 \
               https://api64.ipify.org 2>/dev/null | tr -d '[:space:]')"
        if ! is_ipv6_literal "$out"; then
            out="$(curl -6 -fsS --connect-timeout 3 --max-time 5 \
                   https://ipv6.icanhazip.com 2>/dev/null | tr -d '[:space:]')"
        fi
        if is_ipv6_literal "$out"; then
            PUBLIC_IPV6="$out"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Environment information screen
# ---------------------------------------------------------------------------

show_environment() {
    local cmd missing=()

    printf '%sVPS Link Test v%s - Environment%s\n' "${C_BOLD}" "$VPSLINK_VERSION" "${C_RESET}"
    rule
    printf '  Distribution    %s %s\n' "$DISTRO_NAME" "$DISTRO_VERSION"
    printf '  Distro id       %s\n' "${DISTRO_ID:-unknown}"
    printf '  Kernel          %s\n' "$(uname -r 2>/dev/null || echo unknown)"
    printf '  Architecture    %s\n' "$(uname -m 2>/dev/null || echo unknown)"
    printf '  Package manager %s (%s family)\n' "${PKG_MANAGER:-none}" "${PKG_FAMILY:-unsupported}"
    printf '  Supported distro %s\n' "$([[ "$DISTRO_SUPPORTED" -eq 1 ]] && echo yes || echo no)"
    printf '  Running as      %s\n' "$([[ $EUID -eq 0 ]] && echo root || echo "$(id -un 2>/dev/null) (non-root)")"
    rule

    printf 'Addresses\n'
    printf '  Public IPv4     %s\n' "$PUBLIC_IPV4"
    printf '  Public IPv6     %s\n' "$PUBLIC_IPV6"
    printf '  Local  IPv4     %s\n' "$(val_or_unavailable "$(local_ipv4)")"
    printf '  Local  IPv6     %s\n' "$(val_or_unavailable "$(local_ipv6)")"
    rule

    printf 'Required commands\n'
    for cmd in curl ping iperf3 mtr jq ss timeout; do
        if command -v "$cmd" >/dev/null 2>&1; then
            printf '  %-8s present  (%s)\n' "$cmd" "$(command_origin "$cmd")"
        else
            printf '  %-8s missing\n' "$cmd"
            missing+=("$cmd")
        fi
    done
    rule

    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "All required commands are available."
    else
        warn "Missing: ${missing[*]}"
        info ""
        info "Use the dependency check from the main menu (option 2) to install them."
    fi
    info ""
}

# ---------------------------------------------------------------------------
# Banner + menu
# ---------------------------------------------------------------------------

print_banner() {
    printf '%sVPS Link Test v%s%s\n' "${C_BOLD}" "$VPSLINK_VERSION" "${C_RESET}"
    printf '\n'
    printf '%sIPv4:%s %s\n' "${C_BLUE}" "${C_RESET}" "$PUBLIC_IPV4"
    printf '%sIPv6:%s %s\n' "${C_BLUE}" "${C_RESET}" "$PUBLIC_IPV6"
    printf '\n'
    printf '1. A mode - Wait for another VPS\n'
    printf '2. B mode - Test another VPS\n'
    printf '3. Environment information\n'
    printf '0. Exit\n'
}

press_enter() {
    local _dummy=""
    printf '\nPress Enter to continue... '
    read -r _dummy || true
}

main_menu() {
    local choice=""

    while true; do
        print_banner
        printf '\n%sSelect [0-3]: %s' "${C_CYAN}" "${C_RESET}"
        if ! read -r choice; then
            printf '\n'
            info "No interactive input detected. Exiting."
            return 0
        fi

        case "$choice" in
            1)
                info ""
                run_mode_a
                press_enter
                ;;
            2)
                info ""
                run_mode_b
                press_enter
                ;;
            3)
                info ""
                show_environment
                press_enter
                ;;
            0|q|Q|exit)
                return 0
                ;;
            *)
                warn "Invalid choice: '$choice'"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# A mode - a temporary one-off iperf3 server
#
# Nothing here touches an existing iperf3 instance, an existing listener or any
# firewall. The port is picked from a free high range, and the only process ever
# signalled is the one started below.
#
# iperf3's server, with no explicit --bind, creates an AF_INET6 socket with
# IPV6_V6ONLY=0, i.e. one dual-stack listener that accepts IPv4 and IPv6
# clients alike. If the kernel has no IPv6 support, netannounce() falls back to
# an IPv4 wildcard socket. Either way we verify what actually got bound with
# "ss" before advertising an address, instead of assuming.
# ---------------------------------------------------------------------------

A_PORT_MIN=30000
A_PORT_MAX=50000
A_ROUND_1_TIMEOUT=600        # first session: wait up to ~10 minutes
A_ROUND_2_TIMEOUT=180        # second session: wait up to ~3 minutes

A_LISTEN_IPV4=0
A_LISTEN_IPV6=0

IPERF3_HELP=""

# read_line <prompt> -> prints the answer. The prompt goes to stderr so that
# command substitution captures only the typed value.
read_line() {
    local prompt="$1" line=""
    printf '%s' "$prompt" >&2
    IFS= read -r line || line=""
    printf '%s' "$line"
}

random_port() {
    if command -v shuf >/dev/null 2>&1; then
        shuf -i "${A_PORT_MIN}-${A_PORT_MAX}" -n 1
    else
        # shuf is coreutils; this branch is only a belt-and-braces fallback.
        printf '%s\n' "$(( (RANDOM % (A_PORT_MAX - A_PORT_MIN + 1)) + A_PORT_MIN ))"
    fi
}

# True when something already listens on that TCP or UDP port.
port_in_use() {
    local port="$1" tcp_addrs="" udp_addrs=""

    if command -v ss >/dev/null 2>&1; then
        tcp_addrs="$(ss -tln 2>/dev/null | awk -v p="$port" 'NR>1 && $4 ~ "[:.]"p"$" {print $4}')"
        [[ -n "$tcp_addrs" ]] && return 0
        udp_addrs="$(ss -uln 2>/dev/null | awk -v p="$port" 'NR>1 && $4 ~ "[:.]"p"$" {print $4}')"
        [[ -n "$udp_addrs" ]] && return 0
        return 1
    fi

    # No ss available: probe the loopback port instead of guessing blindly.
    if command -v timeout >/dev/null 2>&1; then
        if timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

find_free_port() {
    local tries=0 port=""
    while [[ $tries -lt 64 ]]; do
        port="$(random_port)"
        if ! port_in_use "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
        tries=$((tries + 1))
    done
    return 1
}

# Which address families did our server actually bind? Decided from "ss", not
# from assumptions, so an IPv4-only or IPv6-only host is reported correctly.
listen_families() {
    local port="$1" addrs=""
    A_LISTEN_IPV4=0
    A_LISTEN_IPV6=0

    command -v ss >/dev/null 2>&1 || return 0
    addrs="$(ss -tln 2>/dev/null | awk -v p="$port" 'NR>1 && $4 ~ "[:.]"p"$" {print $4}')"
    [[ -n "$addrs" ]] || return 0

    # iperf3 -s (no --bind) asks for AF_UNSPEC, which netannounce() turns into
    # an AF_INET6 socket with IPV6_V6ONLY=0. Such a socket shows up in ss as a
    # wildcard and accepts IPv4 clients as well as IPv6 ones, so a wildcard row
    # has to be counted as both families. A concrete [2001:db8::1] row would be
    # a genuine IPv6-only bind and is counted as IPv6 alone.
    if printf '%s\n' "$addrs" | grep -qE '^(\[::\]|\*):'; then
        A_LISTEN_IPV4=1
        A_LISTEN_IPV6=1
        return 0
    fi

    # Concrete rows: IPv6 rows are bracketed, IPv4 rows never are.
    if printf '%s\n' "$addrs" | grep -q '^\['; then
        A_LISTEN_IPV6=1
    fi
    if printf '%s\n' "$addrs" | grep -vq '^\['; then
        A_LISTEN_IPV4=1
    fi
    return 0
}

iperf3_help() {
    if [[ -z "$IPERF3_HELP" ]]; then
        IPERF3_HELP="$(iperf3 -h 2>&1 || true)"
    fi
    printf '%s' "$IPERF3_HELP"
}

iperf3_supports() {
    iperf3_help | grep -q -- "$1"
}

# start_iperf3_server <port> <logfile> <idle-timeout-seconds>
start_iperf3_server() {
    local port="$1" log="$2" idle="$3"
    local args=(-s -1 -p "$port")

    # --idle-timeout makes a one-off server exit by itself when no client shows
    # up; a second line of defence even if this script is SIGKILLed.
    if iperf3_supports -- '--idle-timeout'; then
        args+=(--idle-timeout "$idle")
    fi

    iperf3 "${args[@]}" >"$log" 2>&1 &
    IPERF3_PID=$!

    sleep 1
    if ! kill -0 "$IPERF3_PID" 2>/dev/null; then
        fail "The temporary iperf3 server exited immediately."
        warn "Last lines of its output:"
        tail -n 6 "$log" 2>/dev/null
        IPERF3_PID=""
        return 1
    fi
    return 0
}

# Waits for the single client session this one-off server accepts.
# Hard deadline: never returns later than <timeout_s> seconds plus one.
wait_for_one_off_session() {
    local label="$1" timeout_s="$2" log="$3" waited=0 next_notice=60 rc=0

    info "Waiting for B (${label}) - up to ${timeout_s}s."
    dim  "Ctrl+C stops immediately and removes the listener."

    while kill -0 "$IPERF3_PID" 2>/dev/null; do
        if [[ $waited -ge $timeout_s ]]; then
            warn "No client session within ${timeout_s}s."
            stop_iperf3_server
            return 1
        fi
        if [[ $waited -ge $next_notice ]]; then
            info "  still waiting... ${waited}s elapsed of ${timeout_s}s"
            next_notice=$((waited + 60))
        fi
        sleep 1
        waited=$((waited + 1))
    done

    wait "$IPERF3_PID" 2>/dev/null
    rc=$?
    IPERF3_PID=""

    if [[ $rc -ne 0 ]]; then
        warn "iperf3 server reported an error (exit code ${rc})."
        tail -n 6 "$log" 2>/dev/null
        return 1
    fi
    return 0
}

print_server_summary() {
    local log="$1"
    [[ -s "$log" ]] || return 0
    info "Server side saw:"
    grep -E 'Accepted connection' "$log" 2>/dev/null | tail -n 1
    # The closing "Interval ... Transfer ... Bitrate" line is the measurement.
    grep -E 'sec[[:space:]]+[0-9.]+[[:space:]]+[MKG]Bytes' "$log" 2>/dev/null | tail -n 1
    return 0
}

run_mode_a() {
    if ! command -v iperf3 >/dev/null 2>&1; then
        fail "iperf3 is not available, so A mode cannot start a server."
        info "Re-run this script and accept the dependency installation, or"
        info "install iperf3 yourself, then choose A mode again."
        return 1
    fi

    local addr_v4="$PUBLIC_IPV4" addr_v6="$PUBLIC_IPV6" answer=""

    if [[ "$addr_v4" == "unavailable" ]]; then
        info "The public IPv4 address could not be detected automatically."
        info "(The detection service may simply be unreachable from this VPS.)"
        answer="$(read_line "Enter the IPv4 address B should use, or leave blank to skip: ")"
        [[ -n "$answer" ]] && addr_v4="$answer"
    fi
    if [[ "$addr_v6" == "unavailable" ]]; then
        info "The public IPv6 address could not be detected automatically."
        answer="$(read_line "Enter the IPv6 address B should use, or leave blank to skip: ")"
        [[ -n "$answer" ]] && addr_v6="$answer"
    fi

    if ! A_PORT="$(find_free_port)"; then
        fail "Could not find a free TCP port in ${A_PORT_MIN}-${A_PORT_MAX}."
        info " Something is wrong with this host's port allocation."
        return 1
    fi

    local log1="${WORKDIR}/iperf3-server-1.log"
    local log2="${WORKDIR}/iperf3-server-2.log"

    # ---- first session: B -> A -------------------------------------------
    if ! start_iperf3_server "$A_PORT" "$log1" "$A_ROUND_1_TIMEOUT"; then
        return 1
    fi
    listen_families "$A_PORT"

    printf '\n%sA mode ready%s\n\n' "${C_BOLD}" "${C_RESET}"
    if [[ "$A_LISTEN_IPV4" -eq 1 ]]; then
        printf 'IPv4:\n%s\n\n' "$addr_v4"
    else
        printf 'IPv4:\n%s\n\n' "not available on this server"
    fi
    if [[ "$A_LISTEN_IPV6" -eq 1 ]]; then
        printf 'IPv6:\n%s\n\n' "$addr_v6"
    else
        printf 'IPv6:\n%s\n\n' "not available on this server"
    fi
    printf 'Port:\n%s\n\n' "$A_PORT"

    info "On the other VPS choose 'B mode' and enter the address above plus this port."
    info "Two tests are expected: B -> A first, then A -> B."
    printf '\n'

    if ! wait_for_one_off_session "session 1, B -> A" "$A_ROUND_1_TIMEOUT" "$log1"; then
        return 1
    fi
    print_server_summary "$log1"

    # ---- second session: A -> B, on a fresh one-off server ---------------
    printf '\n'
    info "Session 1 finished. Starting a fresh one-off server for session 2."
    if ! start_iperf3_server "$A_PORT" "$log2" "$A_ROUND_2_TIMEOUT"; then
        return 1
    fi
    if ! wait_for_one_off_session "session 2, A -> B" "$A_ROUND_2_TIMEOUT" "$log2"; then
        warn "Session 2 did not complete; A mode is stopping anyway."
        return 1
    fi
    print_server_summary "$log2"

    printf '\n'
    ok "A mode finished. Both sessions are done."
    return 0
}

# ---------------------------------------------------------------------------
# B mode - drive the tests against the A side
#
# Order is fixed:
#   1. Connectivity preparation
#   2. Ping
#   3. MTR
#   4. TCP throughput B -> A
#   5. TCP throughput A -> B
#   6. Analyze
#   7. Report
#
# A single failing step must never abort the run: every step records a status
# and a human readable reason, and the report prints whatever is available.
#
# The *_STATUS / *_MBPS / ... variables below are the contract with the report
# layer, so they are written here and read there.
# shellcheck disable=SC2034
# ---------------------------------------------------------------------------

PING_COUNT=20
MTR_CYCLES=20
IPERF_DURATION=10
IPERF_OMIT=2

# Resolved target, shared with the report.
RESOLVED_ADDR=""
RESOLVED_FAMILY=""
A_PORT=""

# Ping results.
PING_STATUS="not run"       # ok | loss | filtered | unavailable
PING_LOSS=""
PING_MIN=""
PING_AVG=""
PING_MAX=""
PING_MDEV=""

# MTR results.
MTR_STATUS="not run"        # ok | unavailable | filtered
MTR_HOPS=""
MTR_TARGET_LOSS=""
MTR_MODE=""                 # json | text

# iperf3 results.
IPERF_BA_STATUS="not run"   # ok | error | unavailable
IPERF_BA_MBPS=""
IPERF_BA_RETRANS=""
IPERF_BA_SECONDS=""
IPERF_BA_ERROR=""
IPERF_AB_STATUS="not run"
IPERF_AB_MBPS=""
IPERF_AB_RETRANS=""
IPERF_AB_SECONDS=""
IPERF_AB_ERROR=""

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

# Resolves a target into one address plus the family actually used. If a
# hostname has both A and AAAA records the user picks the protocol.
resolve_target() {
    local host="$1" addr=""
    local -a v4=() v6=() all=()

    if is_ipv4 "$host"; then
        RESOLVED_ADDR="$host"
        RESOLVED_FAMILY="IPv4"
        return 0
    fi
    if is_ipv6_literal "$host"; then
        RESOLVED_ADDR="$host"
        RESOLVED_FAMILY="IPv6"
        return 0
    fi

    if ! command -v getent >/dev/null 2>&1; then
        fail "getent is not available, so hostnames cannot be resolved."
        info "Enter an IPv4 or IPv6 literal instead."
        return 1
    fi

    while IFS= read -r addr; do
        [[ -n "$addr" ]] && all+=("$addr")
    done < <(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u)

    if [[ ${#all[@]} -eq 0 ]]; then
        fail "Could not resolve '${host}'."
        info "Check the spelling, or enter an IP address instead."
        return 1
    fi

    for addr in "${all[@]}"; do
        if is_ipv4 "$addr"; then
            v4+=("$addr")
        elif is_ipv6_literal "$addr"; then
            v6+=("$addr")
        fi
    done

    if [[ ${#v4[@]} -gt 0 && ${#v6[@]} -gt 0 ]]; then
        printf '\n'
        info "'${host}' resolves to both IPv4 and IPv6:"
        info "  1. IPv4  ${v4[0]}"
        info "  2. IPv6  ${v6[0]}"
        local choice=""
        choice="$(read_line "Test over which protocol? [1/2] (default 1): ")"
        case "$choice" in
            2) RESOLVED_ADDR="${v6[0]}"; RESOLVED_FAMILY="IPv6" ;;
            *) RESOLVED_ADDR="${v4[0]}"; RESOLVED_FAMILY="IPv4" ;;
        esac
        return 0
    fi

    if [[ ${#v4[@]} -gt 0 ]]; then
        RESOLVED_ADDR="${v4[0]}"
        RESOLVED_FAMILY="IPv4"
        return 0
    fi
    if [[ ${#v6[@]} -gt 0 ]]; then
        RESOLVED_ADDR="${v6[0]}"
        RESOLVED_FAMILY="IPv6"
        return 0
    fi

    fail "No usable IPv4 or IPv6 address found for '${host}'."
    return 1
}

# ---------------------------------------------------------------------------
# Step 2: Ping
# ---------------------------------------------------------------------------

run_ping_test() {
    local target="$1" family="$2" out="$WORKDIR/ping.txt"
    local summary="" rttline="" vals=""

    PING_STATUS="unavailable"

    if ! command -v ping >/dev/null 2>&1; then
        return 1
    fi

    info "Pinging ${target} ${PING_COUNT} times ..."

    # iputils picks the address family from a literal on modern versions, but
    # older builds need an explicit -6, so try that first and fall back.
    if [[ "$family" == "IPv6" ]]; then
        timeout 40 ping -6 -n -c "$PING_COUNT" -W 2 "$target" >"$out" 2>&1 || true
        [[ -s "$out" ]] || timeout 40 ping -n -c "$PING_COUNT" -W 2 "$target" >"$out" 2>&1 || true
    else
        timeout 40 ping -n -c "$PING_COUNT" -W 2 "$target" >"$out" 2>&1 || true
    fi

    # Without the summary line, ICMP is filtered or the host is unreachable.
    summary="$(grep -E 'packets transmitted' "$out" 2>/dev/null | tail -n 1)"
    if [[ -z "$summary" ]]; then
        PING_STATUS="filtered"
        return 1
    fi

    PING_LOSS="$(printf '%s\n' "$summary" | sed -n 's/.*[^0-9.]\([0-9][0-9.]*\)% packet loss.*/\1/p')"
    [[ -n "$PING_LOSS" ]] || PING_LOSS=""

    rttline="$(grep -E 'min/avg/max/mdev' "$out" 2>/dev/null | tail -n 1)"
    if [[ -n "$rttline" ]]; then
        vals="$(printf '%s\n' "$rttline" | sed -n 's#.*= *\([0-9.]*\)/\([0-9.]*\)/\([0-9.]*\)/\([0-9.]*\).*#\1 \2 \3 \4#p')"
    fi
    if [[ -n "$vals" ]]; then
        read -r PING_MIN PING_AVG PING_MAX PING_MDEV <<<"$vals"
        PING_STATUS="ok"
        return 0
    fi

    # A summary line with no RTT samples means everything was lost.
    PING_STATUS="loss"
    return 0
}

# ---------------------------------------------------------------------------
# Step 3: MTR
# ---------------------------------------------------------------------------

mtr_help() {
    mtr --help 2>&1 || true
}

mtr_json_flag() {
    local help
    help="$(mtr_help)"
    if printf '%s\n' "$help" | grep -q -- '--json'; then
        printf -- '--json'
    elif printf '%s\n' "$help" | grep -q -- ' -j '; then
        printf -- '-j'
    else
        printf ''
    fi
}

# mtr needs raw sockets; a non-root user may be allowed to use them anyway.
# If that fails, try sudo -n exactly once.
mtr_can_use_sudo() {
    [[ $EUID -eq 0 ]] && return 1
    command -v sudo >/dev/null 2>&1 || return 1
    sudo -n true >/dev/null 2>&1
}

# Sets MTR_HOPS and MTR_TARGET_LOSS from whichever report format we got.
# Only the target is treated as a measurement of the link.
extract_mtr_facts() {
    local out="$1" mode="$2" n="" loss=""

    MTR_HOPS=""
    MTR_TARGET_LOSS=""

    if [[ "$mode" == "json" ]] && command -v jq >/dev/null 2>&1; then
        if jq -e '.report.hubs' "$out" >/dev/null 2>&1; then
            n="$(jq -r '.report.hubs | length' "$out" 2>/dev/null)"
            loss="$(jq -r '.report.hubs[-1]["Loss%"] // empty' "$out" 2>/dev/null)"
        fi
    fi
    if [[ -z "$n" ]]; then
        # Plain report: rows start with "<n>.|--"; the last row is the target.
        n="$(awk '/^[[:space:]]*[0-9]+\./ {last=$3; c++} END {print c" "last}' \
             "$out" 2>/dev/null)"
        loss="$(printf '%s\n' "$n" | awk '{print $2}')"
        n="$(printf '%s\n' "$n" | awk '{print $1}')"
        loss="${loss%\%}"
    else
        loss="${loss%\%}"
    fi
    [[ -n "$n" && "$n" != "0" ]] && MTR_HOPS="$n"
    [[ -n "$loss" ]] && MTR_TARGET_LOSS="$loss"
    return 0
}

run_mtr_test() {
    local target="$1" family="$2" out="$WORKDIR/mtr.out"
    local jflag=""

    MTR_STATUS="unavailable"
    MTR_MODE=""

    if ! command -v mtr >/dev/null 2>&1; then
        return 1
    fi

    info "Tracing the route with ${MTR_CYCLES} cycles ..."
    jflag="$(mtr_json_flag)"

    if [[ -n "$jflag" ]]; then
        timeout 60 mtr -r -c "$MTR_CYCLES" "$jflag" "$target" >"$out" 2>&1 || true
        if [[ ! -s "$out" ]] && mtr_can_use_sudo; then
            timeout 60 sudo -n mtr -r -c "$MTR_CYCLES" "$jflag" "$target" >"$out" 2>&1 || true
        fi
        [[ -s "$out" ]] && MTR_MODE="json"
    fi

    if [[ ! -s "$out" ]]; then
        # Missing JSON support must never stop the overall test: fall back to
        # the plain text report.
        if [[ -n "$jflag" ]]; then
            info "JSON output produced nothing, falling back to the plain text report."
        fi
        MTR_MODE="text"
        timeout 60 mtr -r -c "$MTR_CYCLES" "$target" >"$out" 2>&1 || true
        if [[ ! -s "$out" ]] && mtr_can_use_sudo; then
            timeout 60 sudo -n mtr -r -c "$MTR_CYCLES" "$target" >"$out" 2>&1 || true
        fi
    fi

    if [[ ! -s "$out" ]]; then
        MTR_STATUS="filtered"
        return 1
    fi

    MTR_STATUS="ok"
    extract_mtr_facts "$out" "$MTR_MODE"
    return 0
}

# ---------------------------------------------------------------------------
# Steps 4 and 5: iperf3
# ---------------------------------------------------------------------------

iperf3_has_option() {
    iperf3_help | grep -q -- "$1"
}

# Runs one iperf3 test and echoes "<mbps> <retransmits|n/a> <seconds|n/a>".
# On failure it echoes the error message and returns non-zero, so the caller
# can continue with the other direction.
run_iperf3_test() {
    local label="$1" out="$2" reverse="$3"
    local -a args=(-c "$RESOLVED_ADDR" -p "$A_PORT" -t "$IPERF_DURATION")
    local err="" jbps="" retr="" secs="" mbps=""

    if ! command -v iperf3 >/dev/null 2>&1; then
        printf 'iperf3 is not available\n'
        return 1
    fi

    # -O (--omit) is not present in every iperf3 build; degrade instead of fail.
    # Use the short form when it is advertised together with --omit, and fall
    # back to the long form when only that is listed.
    if iperf3_help | grep -qE -- '-O, *--omit'; then
        args+=(-O "$IPERF_OMIT")
    elif iperf3_has_option -- '--omit'; then
        args+=(--omit "$IPERF_OMIT")
    fi
    if [[ "$reverse" == "reverse" ]]; then
        args+=(-R)
    fi
    args+=(-J)

    # Progress goes to stderr: stdout carries only the parsed result, so the
    # caller can capture it with $(...).
    printf '%sMeasuring %s (%ss, single TCP stream) ...%s\n' \
        "$C_DIM" "$label" "$IPERF_DURATION" "$C_RESET" >&2
    timeout 60 iperf3 "${args[@]}" >"$out" 2>&1
    local rc=$?
    [[ -s "$out" ]] || printf 'iperf3: error - exited with code %s and produced no output\n' "$rc" >"$out"

    # A connection failure usually shows up as plain text on stderr, not JSON.
    if ! jq -e . "$out" >/dev/null 2>&1; then
        err="$(grep -E 'iperf3: error|unable to connect|Connection refused|timed out' \
               "$out" 2>/dev/null | head -n 1)"
        [[ -n "$err" ]] || err="iperf3 exited with code ${rc} and produced no JSON"
        printf '%s\n' "$err"
        return 1
    fi

    err="$(jq -r '.error // empty' "$out" 2>/dev/null)"
    if [[ -n "$err" ]]; then
        printf '%s\n' "$err"
        return 1
    fi

    jbps="$(jq -r '
        [ .end.sum.bits_per_second,
          .end.sum_received.bits_per_second,
          .end.sum_sent.bits_per_second ] | map(select(. != null)) | first // empty
    ' "$out" 2>/dev/null)"
    if [[ -z "$jbps" || "$jbps" == "null" ]]; then
        printf 'iperf3: error - no throughput value found in the JSON result\n'
        return 1
    fi

    retr="$(jq -r '
        [ .end.sum_sent.retransmits, .end.sum.retransmits ] | map(select(. != null)) | first // empty
    ' "$out" 2>/dev/null)"
    secs="$(jq -r '.end.sum.seconds // empty' "$out" 2>/dev/null)"

    mbps="$(awk -v b="$jbps" 'BEGIN { printf "%.1f", b / 1000000 }')"
    printf '%s %s %s\n' "$mbps" "${retr:-n/a}" "${secs:-n/a}"
    return 0
}

# ---------------------------------------------------------------------------
# The B mode sequence
# ---------------------------------------------------------------------------

step_header() {
    printf '\n%sStep %s/7  %s%s\n' "${C_BOLD}" "$1" "$2" "${C_RESET}"
}

run_mode_b() {
    local target="" port="" stepout="" rc=0

    printf '\n'
    printf '%sB mode%s\n' "${C_BOLD}" "${C_RESET}"
    rule

    target="$(read_line "Address of the other VPS (IPv4, IPv6 or hostname): ")"
    if [[ -z "$target" ]]; then
        warn "No address given."
        return 1
    fi
    port="$(read_line "Temporary port shown by A mode: ")"
    if ! validate_port "$port"; then
        fail "'${port}' is not a valid TCP port (expected 1-65535)."
        return 1
    fi
    A_PORT="$port"

    step_header 1 "Connectivity preparation"
    if ! resolve_target "$target"; then
        return 1
    fi
    A_PORT="$port"
    info "  Target        ${RESOLVED_ADDR}"
    info "  Protocol      ${RESOLVED_FAMILY}"
    info "  Port          ${A_PORT}"
    local missing=() c
    for c in ping mtr iperf3 jq; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "  Not available : ${missing[*]}"
        info "  Those steps will be reported as unavailable, not fatal."
    else
        info "  Tools         all required commands present"
    fi

    step_header 2 "Ping"
    run_ping_test "$RESOLVED_ADDR" "$RESOLVED_FAMILY"
    case "$PING_STATUS" in
        ok)
            info "  Packet loss   ${PING_LOSS} %"
            info "  Min / avg / max   ${PING_MIN} / ${PING_AVG} / ${PING_MAX} ms"
            info "  RTT variation     ${PING_MDEV} ms"
            ;;
        loss)
            info "  Packet loss   ${PING_LOSS} % (no RTT samples)"
            ;;
        *)
            warn "  Ping          unavailable / filtered"
            ;;
    esac

    step_header 3 "MTR"
    run_mtr_test "$RESOLVED_ADDR" "$RESOLVED_FAMILY"
    case "$MTR_STATUS" in
        ok)
            info "  Report mode   ${MTR_MODE} (${MTR_CYCLES} cycles)"
            info "  Hops          ${MTR_HOPS:-unknown}"
            info "  Target loss   ${MTR_TARGET_LOSS:-unknown} %"
            dim  "  Intermediate hops are not treated as link loss."
            ;;
        filtered)
            warn "  MTR           unavailable / filtered"
            ;;
        *)
            warn "  MTR           unavailable"
            ;;
    esac

    step_header 4 "TCP throughput B -> A"
    rc=0
    stepout="$(run_iperf3_test "B -> A" "${WORKDIR}/iperf3-b-to-a.json" normal)" || rc=1
    if [[ $rc -eq 0 ]]; then
        read -r IPERF_BA_MBPS IPERF_BA_RETRANS IPERF_BA_SECONDS <<<"$stepout"
        IPERF_BA_STATUS="ok"
        info "  Observed TCP throughput   ${IPERF_BA_MBPS} Mbps"
        info "  Retransmits               ${IPERF_BA_RETRANS} in ${IPERF_BA_SECONDS}s"
    else
        IPERF_BA_STATUS="error"
        IPERF_BA_ERROR="$(printf '%s\n' "$stepout" | head -n 1)"
        warn "  B -> A throughput failed: ${IPERF_BA_ERROR}"
        info ""
        info "Possible causes:"
        info "  - Local firewall"
        info "  - Cloud security group"
        info "  - Provider ACL"
        info "  - NAT / CGNAT"
        info "  - Incorrect address or port"
    fi
info "  Status         ${IPERF_BA_STATUS}"

    step_header 5 "TCP throughput A -> B"
    rc=0
    stepout="$(run_iperf3_test "A -> B" "${WORKDIR}/iperf3-a-to-b.json" reverse)" || rc=1
    if [[ $rc -eq 0 ]]; then
        read -r IPERF_AB_MBPS IPERF_AB_RETRANS IPERF_AB_SECONDS <<<"$stepout"
        IPERF_AB_STATUS="ok"
        info "  Observed TCP throughput   ${IPERF_AB_MBPS} Mbps"
        info "  Retransmits               ${IPERF_AB_RETRANS} in ${IPERF_AB_SECONDS}s"
    else
        IPERF_AB_STATUS="error"
        IPERF_AB_ERROR="$(printf '%s\n' "$stepout" | head -n 1)"
        warn "  A -> B throughput failed: ${IPERF_AB_ERROR}"
        info ""
        info "Possible causes:"
        info "  - Local firewall"
        info "  - Cloud security group"
        info "  - Provider ACL"
        info "  - NAT / CGNAT"
        info "  - Incorrect address or port"
    fi
info "  Status         ${IPERF_AB_STATUS}"

    step_header 6 "Analyze"
    info "  Results captured; the parser and report layer come next."

    step_header 7 "Report"
    info "  Raw files for this run are kept in ${WORKDIR}."
    return 0
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
vpslink.sh ${VPSLINK_VERSION} - lightweight VPS <-> VPS link test

Usage:
  bash vpslink.sh [options]

Options:
  -h, --help       Show this help and exit
  -V, --version    Show version and exit
      --no-color   Disable ANSI colours even on a terminal
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -V|--version) printf 'vpslink.sh %s\n' "$VPSLINK_VERSION"; exit 0 ;;
            --no-color) VPSLINK_NO_COLOR=1 ;;
            --) shift; break ;;
            *)
                fail "Unknown option: $1"
                info ""
                usage
                exit 2
                ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"
    init_colors

    if ! init_workdir; then
        fail "Could not create a temporary working directory under ${TMPDIR:-/tmp}."
        exit 1
    fi
    install_traps

    if ! detect_distro; then
        reject_unsupported_distro
        exit 0
    fi

    detect_public_ips
    ensure_dependencies
    main_menu
    offer_dependency_removal

    info "Bye."
}

# Only auto-run when executed, so the file can also be sourced for testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
