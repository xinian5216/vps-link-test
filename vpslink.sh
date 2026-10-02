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
            printf '  %-8s present\n' "$cmd"
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
    main_menu

    info "Bye."
}

# Only auto-run when executed, so the file can also be sourced for testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
