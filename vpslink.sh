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
                if mode_a_placeholder; then
                    :
                fi
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

mode_a_placeholder() {
    dim "A mode is not implemented in this milestone yet."
    dim "It will start a temporary one-off iperf3 server and print the port."
    return 0
}

run_mode_b() {
    dim "B mode is not implemented in this milestone yet."
    dim "It will ask for the A address and port, then run the full test sequence."
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
