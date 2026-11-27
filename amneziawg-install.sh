#!/bin/bash

# AmneziaWG server installer
# https://github.com/romikb/amneziawg-install

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'
# Derived during NEW setup from the last two octets of the public IPv4.
WGIP=""
SCRIPT_VERSION="1.2-debian13"

AMNEZIAWG_DIR="/etc/amnezia/amneziawg"

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

function setupError() {
    local status="$1" line="$2"
    trap - ERR
    echo "Installation stopped at line ${line} (exit ${status})." >&2
    echo "Kernel: $(uname -r). Review the error above; setup was not marked successful." >&2
    if command -v dkms >/dev/null 2>&1; then
        dkms status >&2 || true
        echo "DKMS build logs: /var/lib/dkms/amneziawg/*/*/*/log/make.log or /var/lib/dkms/amneziawg/*/build/make.log" >&2
    fi
    exit "$status"
}

function validIPv4() {
    local address="$1" octet
    local -a octets
    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

function publicIPv4() {
    validIPv4 "$1" || return 1
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    a=$((10#$a)); b=$((10#$b))
    # Reject local/private, shared NAT, loopback, link-local and multicast.
    (( a > 0 && a < 224 && a != 10 && a != 127 )) || return 1
    (( a != 172 || b < 16 || b > 31 )) || return 1
    (( a != 192 || b != 168 )) || return 1
    (( a != 169 || b != 254 )) || return 1
    (( a != 100 || b < 64 || b > 127 )) || return 1
    (( a != 198 || (b != 18 && b != 19) )) || return 1
}

function detectPublicIPv4() {
    local address url
    # Select the default route's source, not the first address of a VPN/LAN.
    address=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}')
    if publicIPv4 "$address"; then
        printf '%s\n' "$address"
        return 0
    fi
    # A server behind NAT needs its external address. Never use a proxy here.
    for url in https://api.ipify.org https://ipv4.icanhazip.com; do
        address=$(curl -4 -fsS --noproxy '*' --connect-timeout 3 --max-time 8 "$url" 2>/dev/null) || continue
        address=${address//$'\r'/}
        if publicIPv4 "$address"; then
            printf '%s\n' "$address"
            return 0
        fi
    done
    return 1
}

function deriveWGIP() {
    validIPv4 "$1" || return 1
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    WGIP="10.$((10#$c)).$((10#$d)).1"
}

function ipv4Number() {
    validIPv4 "$1" || return 1
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    printf '%u\n' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

function checkNetworkConflicts() {
    local address prefix rest route_num vpn_num mask route_list
    [[ "$SERVER_PUB_NIC" =~ ^[a-zA-Z0-9_.-]{1,15}$ ]] || fail "Invalid public interface name."
    [[ "$SERVER_AWG_NIC" =~ ^[a-zA-Z0-9_]{1,15}$ ]] || fail "Invalid VPN interface name."
    ip link show dev "$SERVER_PUB_NIC" >/dev/null || fail "Public interface does not exist."
    if ip link show dev "$SERVER_AWG_NIC" >/dev/null 2>&1; then
        fail "Interface ${SERVER_AWG_NIC} already exists; refusing to replace it."
    fi
    validIPv4 "$SERVER_AWG_IPV4" || fail "Invalid VPN IPv4."
    vpn_num=$(ipv4Number "$SERVER_AWG_IPV4")
    (( (vpn_num & 255) > 0 && (vpn_num & 255) < 255 )) || fail "VPN address must be a host address in /24."
    route_list=$(ip -4 route show table all) || fail "Cannot inspect IPv4 routes."
    while read -r address rest; do
        # Include connected routes, policy routes and host routes, but not default.
        case "$address" in
            local|broadcast|unicast|throw|unreachable|blackhole|prohibit)
                read -r address rest <<< "$rest" ;;
        esac
        [[ "$address" == default || -z "$address" ]] && continue
        prefix=32
        if [[ "$address" == */* ]]; then prefix=${address#*/}; address=${address%/*}; fi
        validIPv4 "$address" || continue
        [[ "$prefix" =~ ^[0-9]+$ ]] || continue
        (( prefix > 0 && prefix <= 32 )) || continue
        # Compare the common prefix: overlapping /8, /24 and /32 all matter.
        (( prefix > 24 )) && prefix=24
        mask=$(( (0xFFFFFFFF << (32-prefix)) & 0xFFFFFFFF ))
        route_num=$(ipv4Number "$address")
        if (( (vpn_num & mask) == (route_num & mask) )); then
            fail "VPN /24 overlaps route ${address}/${prefix}. Choose another VPN IPv4 in advanced settings. No VPN routes were changed."
        fi
    done <<< "$route_list"
    local listeners
    listeners=$(ss -H -lun "sport = :${SERVER_PORT}") || fail "Cannot inspect UDP ports."
    [[ -z "$listeners" ]] || fail "UDP port ${SERVER_PORT} is already in use."
}

function rollbackSetup() {
    local result="$1"
    trap - EXIT
    if [[ "$result" != 0 && "${SETUP_NETWORK_STARTED:-n}" == y ]]; then
        echo "Setup failed; removing this setup's interface/rules and restoring forwarding settings." >&2
        systemctl stop "awg-quick@${SERVER_AWG_NIC}" >/dev/null 2>&1 || true
        if [[ "$USE_NFTABLES" == y && -f "${AMNEZIAWG_DIR}/nft.sh" ]]; then
            bash "${AMNEZIAWG_DIR}/nft.sh" down "$SERVER_PORT" "$SERVER_PUB_NIC" "$SERVER_AWG_NIC" >/dev/null 2>&1 || true
        fi
        sysctl -q -w "net.ipv4.ip_forward=${SETUP_OLD_FORWARD4}" || true
        if [[ "$USE_IPV6" == y ]]; then sysctl -q -w "net.ipv6.conf.all.forwarding=${SETUP_OLD_FORWARD6}" || true; fi
        if [[ -f "${AMNEZIAWG_DIR}/sysctl.before-setup" ]]; then
            cp -p "${AMNEZIAWG_DIR}/sysctl.before-setup" /etc/sysctl.d/awg.conf || true
        else
            rm -f /etc/sysctl.d/awg.conf
        fi
        echo "VPN settings retained in ${AMNEZIAWG_DIR}; retry with: bash aw.sh --repair" >&2
    fi
    return 0
}

function enableForwarding() {
    SETUP_OLD_FORWARD4=$(sysctl -n net.ipv4.ip_forward)
    if [[ "$USE_IPV6" == y ]]; then SETUP_OLD_FORWARD6=$(sysctl -n net.ipv6.conf.all.forwarding); fi
    if [[ -f /etc/sysctl.d/awg.conf ]]; then
        cp -p /etc/sysctl.d/awg.conf "${AMNEZIAWG_DIR}/sysctl.before-setup"
    else
        rm -f "${AMNEZIAWG_DIR}/sysctl.before-setup"
    fi
    SETUP_NETWORK_STARTED=y
    printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/awg.conf
    if [[ "$USE_IPV6" == y ]]; then printf 'net.ipv6.conf.all.forwarding = 1\n' >> /etc/sysctl.d/awg.conf; fi
    sysctl -p /etc/sysctl.d/awg.conf
}

function ensureKernelHeaders() {
    local kernel header_package meta
    kernel=$(uname -r)
    header_package="linux-headers-${kernel}"
    if [[ ! -f "/lib/modules/${kernel}/build/Makefile" ]]; then
        if ! apt-get install -y "$header_package"; then
            echo "Headers for the RUNNING kernel ${kernel} are unavailable." >&2
            echo "Installing headers for another kernel does not fix DKMS for this kernel." >&2
            if [[ "$OS" == debian ]]; then
                case "$kernel" in
                    *-cloud-amd64) meta=cloud-amd64 ;;
                    *-amd64) meta=amd64 ;;
                    *-cloud-arm64) meta=cloud-arm64 ;;
                    *-arm64) meta=arm64 ;;
                    *) meta="" ;;
                esac
                if [[ -n "$meta" ]]; then
                    echo "For a standard Debian kernel, run:" >&2
                    echo "  apt-get install linux-image-${meta} linux-headers-${meta}" >&2
                    echo "Then reboot into that kernel and run this script again." >&2
                else
                    echo "Install matching headers from your kernel/VPS provider, or boot a standard Debian kernel." >&2
                fi
            fi
            exit 1
        fi
    fi
    [[ -f "/lib/modules/${kernel}/build/Makefile" ]] || fail "Kernel headers are incomplete: /lib/modules/${kernel}/build/Makefile"
}

function verifyAmneziaWG() {
    command -v awg >/dev/null || fail "awg was not installed."
    command -v awg-quick >/dev/null || fail "awg-quick was not installed."
    if [[ "$OS" == debian || "$OS" == ubuntu ]]; then
        dkms autoinstall -k "$(uname -r)"
        depmod -a "$(uname -r)"
    fi
    if ! modprobe amneziawg; then
        echo "The AmneziaWG kernel module could not be loaded. Check DKMS and Secure Boot:" >&2
        echo "  dkms status" >&2
        echo "  journalctl -k -n 80 --no-pager" >&2
        fail "Module load failed; no new VPN configuration has been generated."
    fi
}

function startAmneziaWG() {
    systemctl daemon-reload
    if ! systemctl restart "awg-quick@${SERVER_AWG_NIC}"; then
        journalctl -u "awg-quick@${SERVER_AWG_NIC}" -n 60 --no-pager >&2 || true
        fail "AmneziaWG did not start. Check the error above (including protocol/tool/module compatibility)."
    fi
    systemctl is-active --quiet "awg-quick@${SERVER_AWG_NIC}" || fail "AmneziaWG service is inactive."
    awg show "${SERVER_AWG_NIC}" >/dev/null || fail "AmneziaWG interface is missing."
    systemctl enable "awg-quick@${SERVER_AWG_NIC}"
}

function isRoot() {
    if [ "${EUID}" -ne 0 ]; then
        echo "You need to run this script as root"
        exit 1
    fi
}

function checkVirt() {
    if [ "$(systemd-detect-virt)" == "openvz" ]; then
        echo "OpenVZ is not supported"
        exit 1
    fi

    if [ "$(systemd-detect-virt)" == "lxc" ]; then
        echo "LXC is not supported (yet)."
        echo "WireGuard can technically run in an LXC container,"
        echo "but the kernel module has to be installed on the host,"
        echo "the container has to be run with some specific parameters"
        echo "and only the tools need to be installed in the container."
        exit 1
    fi
}

function checkOS() {
    source /etc/os-release

    OS="${ID}"

    case "$OS" in
    "debian" | "raspbian")
        MAJOR_VERSION=$(echo "$VERSION_ID" | cut -d'.' -f1)
        if [[ ! "$MAJOR_VERSION" =~ ^[0-9]+$ || "$MAJOR_VERSION" -lt 12 ]]; then
            echo "Your version of Debian ($VERSION_ID) is not supported. Please use Debian 12 Bookworm or later."
            exit 1
        fi
        OS="debian" #overwrite if raspbian
        ;;
    "ubuntu")
        MAJOR_VERSION=$(echo "$VERSION_ID" | cut -d'.' -f1)
        if [[ ! "$MAJOR_VERSION" =~ ^[0-9]+$ || "$MAJOR_VERSION" -lt 22 ]]; then
            echo "Your version of Ubuntu ($VERSION_ID) is not supported. Please use Ubuntu 22.04 or later."
            exit 1
        fi
        ;;
    "fedora")
        MAJOR_VERSION=$(echo "$VERSION_ID" | cut -d'.' -f1)
        if [[ ! "$MAJOR_VERSION" =~ ^[0-9]+$ || "$MAJOR_VERSION" -lt 43 ]]; then
            echo "Your version of Fedora ($VERSION_ID) is not supported. Please use Fedora 43 or later."
            exit 1
        fi
        ;;
    "centos" | "almalinux" | "rocky" | "rhel")
        MAJOR_VERSION=$(echo "$VERSION_ID" | cut -d'.' -f1)
        if [[ ! "$MAJOR_VERSION" =~ ^[0-9]+$ || "$MAJOR_VERSION" -lt 9 ]]; then
            echo "Your version of $OS ($VERSION_ID) is not supported. Please use $OS 9 or later."
            exit 1
        fi
        ;;
    *)
        echo "Looks like you are not running this installer on a Debian, Ubuntu, Fedora, CentOS, AlmaLinux, Rocky Linux or RHEL system."
        exit 1
        ;;
    esac
}

function getHomeDirForClient() {
    local CLIENT_NAME=$1

    if [ -z "${CLIENT_NAME}" ]; then
        echo "Error: getHomeDirForClient() requires a client name as argument"
        exit 1
    fi

    # Home directory of the user, where the client configuration will be written
    if [ -e "/home/${CLIENT_NAME}" ]; then
        # if $1 is a user name
        HOME_DIR="/home/${CLIENT_NAME}"
    elif [ "${SUDO_USER}" ]; then
        # if not, use SUDO_USER
        if [ "${SUDO_USER}" == "root" ]; then
            # If running sudo as root
            HOME_DIR="/root"
        else
            HOME_DIR="/home/${SUDO_USER}"
        fi
    else
        # if not SUDO_USER, use /root
        HOME_DIR="/root"
    fi

    echo "$HOME_DIR"
}

function getDirForClientConfig() {
    if [[ ${STORE_CLIENT} == 'y' ]]; then
        CONFIG_DIR=${AMNEZIAWG_DIR}
    else
        CONFIG_DIR=$(getHomeDirForClient $1)
    fi
    echo "$CONFIG_DIR"
}

function initialCheck() {
    isRoot
    checkVirt
    checkOS
}

function readJminAndJmax() {
    SERVER_AWG_JMIN=0
    SERVER_AWG_JMAX=0
    until [[ ${SERVER_AWG_JMIN} =~ ^[0-9]+$ ]] && (( ${SERVER_AWG_JMIN} >= 1 )) && (( ${SERVER_AWG_JMIN} <= 1280 )); do
        read -rp "Server AmneziaWG Jmin [1-1280]: " -e -i 40 SERVER_AWG_JMIN || fail "Input closed; rerun the script from an interactive terminal."
    done
    until [[ ${SERVER_AWG_JMAX} =~ ^[0-9]+$ ]] && (( ${SERVER_AWG_JMAX} >= 1 )) && (( ${SERVER_AWG_JMAX} <= 1280 )); do
        read -rp "Server AmneziaWG Jmax [1-1280]: " -e -i 70 SERVER_AWG_JMAX || fail "Input closed; rerun the script from an interactive terminal."
    done
}

function generateSParams() {
    if [[ "${AWG_VERSION}" == "3.1" ]]; then
        RANDOM_AWG_S1=$(shuf -i12-150 -n1)
        RANDOM_AWG_S2=${RANDOM_AWG_S1}
        RANDOM_AWG_S3=${RANDOM_AWG_S1}
        RANDOM_AWG_S4=${RANDOM_AWG_S1}
    elif [[ "${AWG_VERSION}" == "2.0" ]]; then
        RANDOM_AWG_S1=$(shuf -i15-150 -n1)
        RANDOM_AWG_S2=$(shuf -i15-150 -n1)
        RANDOM_AWG_S3=$(shuf -i15-150 -n1)
        RANDOM_AWG_S4=$(shuf -i15-150 -n1)
    else
        RANDOM_AWG_S1=$(shuf -i15-150 -n1)
        RANDOM_AWG_S2=$(shuf -i15-150 -n1)
        RANDOM_AWG_S3=""
        RANDOM_AWG_S4=""
    fi
}

function readSParams() {
    SERVER_AWG_S1=0
    SERVER_AWG_S2=0
    local min_s=15
    local default_s2=${RANDOM_AWG_S2}
    local default_s3=${RANDOM_AWG_S3}
    local default_s4=${RANDOM_AWG_S4}
    if [[ "${AWG_VERSION}" == "3.1" ]]; then
        min_s=12
        if [[ "${SERVER_AWG_RANDOM_TRAILERS}" == "y" ]]; then
            default_s2=${RANDOM_AWG_S1}
            default_s3=${RANDOM_AWG_S1}
            default_s4=${RANDOM_AWG_S1}
        fi
    fi
    until [[ ${SERVER_AWG_S1} =~ ^[0-9]+$ ]] && (( SERVER_AWG_S1 >= min_s && SERVER_AWG_S1 <= 150 )); do
        read -rp "Server AmneziaWG S1 [${min_s}-150]: " -e -i ${RANDOM_AWG_S1} SERVER_AWG_S1 || fail "Input closed; rerun the script from an interactive terminal."
    done
    if [[ "${AWG_VERSION}" == "3.1" && "${SERVER_AWG_RANDOM_TRAILERS}" == "y" ]]; then
        default_s2=${SERVER_AWG_S1}
        default_s3=${SERVER_AWG_S1}
        default_s4=${SERVER_AWG_S1}
    fi
    until [[ ${SERVER_AWG_S2} =~ ^[0-9]+$ ]] && (( SERVER_AWG_S2 >= min_s && SERVER_AWG_S2 <= 150 )); do
        read -rp "Server AmneziaWG S2 [${min_s}-150]: " -e -i ${default_s2} SERVER_AWG_S2 || fail "Input closed; rerun the script from an interactive terminal."
    done
    if [[ "${AWG_VERSION}" != "1.0" ]]; then
        SERVER_AWG_S3=0
        SERVER_AWG_S4=0
        until [[ ${SERVER_AWG_S3} =~ ^[0-9]+$ ]] && (( SERVER_AWG_S3 >= min_s && SERVER_AWG_S3 <= 150 )); do
            read -rp "Server AmneziaWG S3 [${min_s}-150]: " -e -i ${default_s3} SERVER_AWG_S3 || fail "Input closed; rerun the script from an interactive terminal."
        done
        until [[ ${SERVER_AWG_S4} =~ ^[0-9]+$ ]] && (( SERVER_AWG_S4 >= min_s && SERVER_AWG_S4 <= 150 )); do
            read -rp "Server AmneziaWG S4 [${min_s}-150]: " -e -i ${default_s4} SERVER_AWG_S4 || fail "Input closed; rerun the script from an interactive terminal."
        done
    fi
}

function validateHValue() {
    local val="$1"
    local min_val="$2"
    local max_val=4294967295

    if [[ "$val" =~ ^[0-9]+$ ]]; then
        if (( val >= min_val && val <= max_val )); then
            echo "$val $val"
            return 0
        fi
    elif [[ "$val" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local low="${BASH_REMATCH[1]}"
        local high="${BASH_REMATCH[2]}"
        if (( low >= min_val && high <= max_val && low <= high )); then
            echo "$low $high"
            return 0
        fi
    fi
    return 1
}

function checkHOverlap() {
    local -a h_vals=("$1" "$2" "$3" "$4")
    local -a lows=()
    local -a highs=()
    local min_val="${5:-1}"

    for i in 0 1 2 3; do
        local res
        res=$(validateHValue "${h_vals[$i]}" "$min_val") || return 1
        read -r l h <<< "$res"
        lows[$i]="$l"
        highs[$i]="$h"
    done

    for ((i = 0; i < 4; i++)); do
        for ((j = i + 1; j < 4; j++)); do
            if (( lows[i] <= highs[j] && highs[i] >= lows[j] )); then
                return 2
            fi
        done
    done
    return 0
}

function generateH1AndH2AndH3AndH4() {
    if [[ "${AWG_VERSION}" == "3.1" ]]; then
        RANDOM_AWG_H1=1
        RANDOM_AWG_H2=2
        RANDOM_AWG_H3=3
        RANDOM_AWG_H4=4
    else
        RANDOM_AWG_H1=$(shuf -i5-2147483647 -n1)
        RANDOM_AWG_H2=$(shuf -i5-2147483647 -n1)
        RANDOM_AWG_H3=$(shuf -i5-2147483647 -n1)
        RANDOM_AWG_H4=$(shuf -i5-2147483647 -n1)
    fi
}

function readH1AndH2AndH3AndH4() {
    local min_h=5
    if [[ "${AWG_VERSION}" == "3.1" ]]; then
        min_h=1
    fi

    echo ""
    echo "H1-H4 obfuscation: enter single numbers or ranges (e.g. 100-200) without overlap."
    while true; do
        SERVER_AWG_H1=""
        SERVER_AWG_H2=""
        SERVER_AWG_H3=""
        SERVER_AWG_H4=""

        until [[ -n "${SERVER_AWG_H1}" ]] && validateHValue "${SERVER_AWG_H1}" "${min_h}" >/dev/null; do
            read -rp "Server AmneziaWG H1 [${min_h}-4294967295]: " -e -i "${RANDOM_AWG_H1}" SERVER_AWG_H1 || fail "Input closed; rerun the script from an interactive terminal."
        done
        until [[ -n "${SERVER_AWG_H2}" ]] && validateHValue "${SERVER_AWG_H2}" "${min_h}" >/dev/null; do
            read -rp "Server AmneziaWG H2 [${min_h}-4294967295]: " -e -i "${RANDOM_AWG_H2}" SERVER_AWG_H2 || fail "Input closed; rerun the script from an interactive terminal."
        done
        until [[ -n "${SERVER_AWG_H3}" ]] && validateHValue "${SERVER_AWG_H3}" "${min_h}" >/dev/null; do
            read -rp "Server AmneziaWG H3 [${min_h}-4294967295]: " -e -i "${RANDOM_AWG_H3}" SERVER_AWG_H3 || fail "Input closed; rerun the script from an interactive terminal."
        done
        until [[ -n "${SERVER_AWG_H4}" ]] && validateHValue "${SERVER_AWG_H4}" "${min_h}" >/dev/null; do
            read -rp "Server AmneziaWG H4 [${min_h}-4294967295]: " -e -i "${RANDOM_AWG_H4}" SERVER_AWG_H4 || fail "Input closed; rerun the script from an interactive terminal."
        done

        local overlap_code=0
        checkHOverlap "${SERVER_AWG_H1}" "${SERVER_AWG_H2}" "${SERVER_AWG_H3}" "${SERVER_AWG_H4}" "${min_h}" || overlap_code=$?

        if [[ "${overlap_code}" -eq 0 ]]; then
            break
        elif [[ "${overlap_code}" -eq 2 ]]; then
            echo "AmneziaWG requires H1, H2, H3 and H4 values or ranges not to overlap. Please re-enter."
        else
            echo "AmneziaWG requires valid H parameters within [${min_h}-4294967295]. Please re-enter."
        fi
    done
}

function validateIParam() {
    local val="$1"
    [[ -z "$val" ]] && return 1
    local remaining="$val"
    local tag_regex="^(<[bB] +0[xX]([0-9a-fA-F]{2})+>|<[rR] +[1-9][0-9]*>|<[rR][dD] +[1-9][0-9]*>|<[rR][cC] +[1-9][0-9]*>|<[tT]>)"
    while [[ -n "$remaining" ]]; do
        if [[ "$remaining" =~ $tag_regex ]]; then
            local matched="${BASH_REMATCH[0]}"
            remaining="${remaining:${#matched}}"
        else
            return 1
        fi
    done
    return 0
}

function readIParams() {
    SERVER_AWG_I1=""
    SERVER_AWG_I2=""
    SERVER_AWG_I3=""
    SERVER_AWG_I4=""
    SERVER_AWG_I5=""

    echo ""
    echo "Custom Protocol Signature (CPS) decoy packets (I1-I5):"
    echo "Packets sent before handshake to mimic legitimate protocols (e.g. QUIC, DNS)."
    echo "Supported tags:"
    echo "  <b 0xHEX>  - static hex bytes (even number of hex digits, e.g. <b 0xd100000001>)"
    echo "  <r SIZE>   - random bytes (e.g. <r 64>)"
    echo "  <rd SIZE>  - random digits 0-9 (e.g. <rd 10>)"
    echo "  <rc SIZE>  - random chars a-zA-Z (e.g. <rc 8>)"
    echo "  <t>        - 4-byte UNIX timestamp"
    echo "Leave empty (press Enter) to skip or finish the sequence."

    local i
    for i in 1 2 3 4 5; do
        local input=""
        while true; do
            read -rp "AmneziaWG I${i} [optional, Enter to finish]: " -e input || fail "Input closed; rerun the script from an interactive terminal."
            input=$(echo "${input}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            if [[ -z "${input}" ]]; then
                return 0
            fi
            if validateIParam "${input}"; then
                case "${i}" in
                    1) SERVER_AWG_I1="${input}" ;;
                    2) SERVER_AWG_I2="${input}" ;;
                    3) SERVER_AWG_I3="${input}" ;;
                    4) SERVER_AWG_I4="${input}" ;;
                    5) SERVER_AWG_I5="${input}" ;;
                esac
                break
            else
                echo "Invalid syntax for I${i}! Allowed tags: <b 0xHEX>, <r SIZE>, <rd SIZE>, <rc SIZE>, <t>."
                echo "Example: <b 0xd100000001><rc 8><t><r 50> or <r 64>. Press Enter without input to finish."
            fi
        done
    done
}

function installQuestions() {
    echo "AmneziaWG server installer (https://github.com/romikb/amneziawg-install)"
    echo ""
    echo "I need to ask you a few questions before starting the setup."
    echo "You can keep the default options and just press enter if you are ok with them."
    echo ""

    # Reset interactive variables
    SERVER_PUB_IP=""
    SERVER_PORT=""
    DNS_CHOICE=""
    AWG_VERSION=""
    AWG_VERSION_CHOICE=""
    SERVER_AWG_MTU=""
    SERVER_AWG_HPK=""
    SERVER_AWG_CPA=""
    SERVER_AWG_RANDOM_TRAILERS=""
    SERVER_AWG_DISABLE_COOKIES=""
    SERVER_AWG_I1=""
    SERVER_AWG_I2=""
    SERVER_AWG_I3=""
    SERVER_AWG_I4=""
    SERVER_AWG_I5=""
    SERVER_AWG_S3=""
    SERVER_AWG_S4=""
    ADVANCED_SETTINGS=""
    USE_IPV6=""
    SERVER_PUB_NIC=""
    SERVER_AWG_NIC=""
    SERVER_AWG_IPV4=""
    SERVER_AWG_IPV6=""
    STORE_CLIENT=""
    USE_NFTABLES=""
    ALLOWED_IPS=""
    KEEPALIVE=""

    # Public endpoint remains editable; the IPv4 is also used to derive WGIP.
    local detected_ipv4 real_ipv4
    detected_ipv4=$(detectPublicIPv4) || detected_ipv4=""
    SERVER_PUB_IP="$detected_ipv4"
    if [[ -z "$SERVER_PUB_IP" ]]; then
        SERVER_PUB_IP=$(ip -6 addr show scope global | awk '/inet6/ {sub(/\/.*/, "", $2); print $2; exit}')
    fi
    while true; do
        read -rp "Public IPv4 or IPv6 address or domain: " -e -i "$SERVER_PUB_IP" SERVER_PUB_IP || fail "Input closed."
        SERVER_PUB_IP=${SERVER_PUB_IP#[}
        SERVER_PUB_IP=${SERVER_PUB_IP%]}
        if [[ -n "$SERVER_PUB_IP" && "$SERVER_PUB_IP" =~ ^[a-zA-Z0-9.:_-]+$ ]]; then
            break
        fi
        echo "Invalid public endpoint. Enter an IP address or hostname."
    done
    if publicIPv4 "$SERVER_PUB_IP"; then
        real_ipv4="$SERVER_PUB_IP"
    else
        real_ipv4="$detected_ipv4"
    fi
    until publicIPv4 "$real_ipv4"; do
        read -rp "Real public IPv4 for subnet calculation (10.xx.yy.1): " real_ipv4 || fail "Public IPv4 is required."
    done
    deriveWGIP "$real_ipv4" || fail "Cannot calculate WGIP."
    echo "Public IPv4: ${real_ipv4}; default VPN address: ${WGIP}/24"

    # Generate random number within private ports range
    RANDOM_PORT=$(shuf -i49152-65535 -n1)
    until [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] && [ "${SERVER_PORT}" -ge 1 ] && [ "${SERVER_PORT}" -le 65535 ]; do
        read -rp "Server AmneziaWG port [1-65535]: " -e -i "${RANDOM_PORT}" SERVER_PORT || fail "Input closed; rerun the script from an interactive terminal."
    done

    # Select DNS resolver
    echo ""
    echo "Select a DNS resolver for the clients:"
    echo "   1) Cloudflare (1.1.1.1, 1.0.0.1) [Recommended]"
    echo "   2) AdGuard DNS (blocks ads and trackers)"
    echo "   3) Google DNS (8.8.8.8, 8.8.4.4)"
    echo "   4) Custom DNS"
    until [[ ${DNS_CHOICE} =~ ^[1-4]$ ]]; do
        read -rp "DNS resolver [1-4]: " -e -i 1 DNS_CHOICE || fail "Input closed; rerun the script from an interactive terminal."
    done
    case "${DNS_CHOICE}" in
    1)
        CLIENT_IPV4_DNS_1="1.1.1.1"
        CLIENT_IPV4_DNS_2="1.0.0.1"
        CLIENT_IPV6_DNS_1="2606:4700:4700::1111"
        CLIENT_IPV6_DNS_2="2606:4700:4700::1001"
        ;;
    2)
        CLIENT_IPV4_DNS_1="94.140.14.14"
        CLIENT_IPV4_DNS_2="94.140.15.15"
        CLIENT_IPV6_DNS_1="2a10:50c0::ad1:ff"
        CLIENT_IPV6_DNS_2="2a10:50c0::ad2:ff"
        ;;
    3)
        CLIENT_IPV4_DNS_1="8.8.8.8"
        CLIENT_IPV4_DNS_2="8.8.4.4"
        CLIENT_IPV6_DNS_1="2001:4860:4860::8888"
        CLIENT_IPV6_DNS_2="2001:4860:4860::8844"
        ;;
    4)
        until [[ ${CLIENT_IPV4_DNS_1} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
            read -rp "First IPv4 DNS resolver to use for the clients: " -e -i 1.1.1.1 CLIENT_IPV4_DNS_1 || fail "Input closed; rerun the script from an interactive terminal."
        done
        until [[ ${CLIENT_IPV4_DNS_2} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
            read -rp "Second IPv4 DNS resolver to use for the clients (optional): " -e -i 1.0.0.1 CLIENT_IPV4_DNS_2 || fail "Input closed; rerun the script from an interactive terminal."
        done
        ;;
    esac

    # Select AmneziaWG protocol version
    echo ""
    echo "Select AmneziaWG protocol version:"
    echo "   1) AmneziaWG 3.1 (Recommended / Maximum anti-DPI protection) [Default]"
    echo "   2) AmneziaWG 2.0 (Compatibility with KeeneticOS / OpenWrt / routers)"
    echo "   3) AmneziaWG 1.0 (Legacy)"
    until [[ ${AWG_VERSION_CHOICE} =~ ^[1-3]$ ]]; do
        read -rp "Protocol version [1-3]: " -e -i 1 AWG_VERSION_CHOICE || fail "Input closed; rerun the script from an interactive terminal."
    done
    case "${AWG_VERSION_CHOICE}" in
    1) AWG_VERSION="3.1" ;;
    2) AWG_VERSION="2.0" ;;
    3) AWG_VERSION="1.0" ;;
    esac

    # Advanced settings toggle
    echo ""
    until [[ ${ADVANCED_SETTINGS} =~ ^[yn]$ ]]; do
        read -rp "Customize advanced settings (IPv6, interface, firewall, obfuscation)? [y/n]: " -e -i n ADVANCED_SETTINGS || fail "Input closed; rerun the script from an interactive terminal."
        ADVANCED_SETTINGS=${ADVANCED_SETTINGS,,}
    done

    # Detect public interface
    SERVER_NIC="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"
    if [[ -z ${SERVER_NIC} ]]; then
        SERVER_NIC="$(ip -6 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"
    fi

    [[ -n "$SERVER_NIC" ]] || fail "No default network interface found."

    # Pre-generate base obfuscation parameters
    RANDOM_AWG_JC=$(shuf -i4-8 -n1)
    generateSParams
    while (( ${RANDOM_AWG_S1} + 56 == ${RANDOM_AWG_S2} )); do
        generateSParams
    done
    generateH1AndH2AndH3AndH4
    if [[ "${AWG_VERSION}" != "3.1" ]]; then
        while ! checkHOverlap "${RANDOM_AWG_H1}" "${RANDOM_AWG_H2}" "${RANDOM_AWG_H3}" "${RANDOM_AWG_H4}" "5" >/dev/null 2>&1; do
            generateH1AndH2AndH3AndH4
        done
    fi

    if [[ ${ADVANCED_SETTINGS} == 'y' ]]; then
        echo ""
        echo "--- Advanced configuration ---"

        DEFAULT_MTU=1360
        if [[ "${AWG_VERSION}" != "3.1" ]]; then
            DEFAULT_MTU=1420
        fi
        until [[ ${SERVER_AWG_MTU} =~ ^[0-9]+$ ]] && (( SERVER_AWG_MTU >= 576 && SERVER_AWG_MTU <= 1500 )); do
            read -rp "AmneziaWG MTU [576-1500]: " -e -i "${DEFAULT_MTU}" SERVER_AWG_MTU || fail "Input closed; rerun the script from an interactive terminal."
        done

        until [[ ${USE_IPV6} =~ ^[yn]$ ]]; do
            read -rp "Do you want to use IPv6? [y/n]: " -e -i n USE_IPV6 || fail "Input closed; rerun the script from an interactive terminal."
            USE_IPV6=${USE_IPV6,,}
        done

        until [[ ${SERVER_PUB_NIC} =~ ^[a-zA-Z0-9_]+$ ]]; do
            read -rp "Public interface: " -e -i "${SERVER_NIC}" SERVER_PUB_NIC || fail "Input closed; rerun the script from an interactive terminal."
        done

        until [[ ${SERVER_AWG_NIC} =~ ^[a-zA-Z0-9_]+$ && ${#SERVER_AWG_NIC} -lt 16 ]]; do
            read -rp "AmneziaWG interface name: " -e -i awg0 SERVER_AWG_NIC || fail "Input closed; rerun the script from an interactive terminal."
        done

        until validIPv4 "$SERVER_AWG_IPV4" && [[ "${SERVER_AWG_IPV4##*.}" != 0 && "${SERVER_AWG_IPV4##*.}" != 255 ]]; do
            read -rp "Server AmneziaWG IPv4: " -e -i ${WGIP} SERVER_AWG_IPV4 || fail "Input closed; rerun the script from an interactive terminal."
        done

        if [[ ${USE_IPV6} == 'y' ]]; then
            until [[ ${SERVER_AWG_IPV6} =~ ^([a-f0-9]{1,4}:){3,4}: ]]; do
                read -rp "Server AmneziaWG IPv6: " -e -i fd42:42:42::1 SERVER_AWG_IPV6 || fail "Input closed; rerun the script from an interactive terminal."
            done

            if [[ ${DNS_CHOICE} == '4' ]]; then
                until [[ ${CLIENT_IPV6_DNS_1} =~ ^([a-f0-9]{1,4}:){3,4}: ]]; do
                    read -rp "First IPv6 DNS resolver to use for the clients: " -e -i 2606:4700:4700::1111 CLIENT_IPV6_DNS_1 || fail "Input closed; rerun the script from an interactive terminal."
                done

                until [[ ${CLIENT_IPV6_DNS_2} =~ ^([a-f0-9]{1,4}:){3,4}: ]]; do
                    read -rp "Second IPv6 DNS resolver to use for the clients (optional): " -e -i 2606:4700:4700::1001 CLIENT_IPV6_DNS_2 || fail "Input closed; rerun the script from an interactive terminal."
                done
            fi
        fi

        until [[ ${STORE_CLIENT} =~ ^[yn]$ ]]; do
            read -rp "Store client config file at ${AMNEZIAWG_DIR}? [y/n]: " -e -i y STORE_CLIENT || fail "Input closed; rerun the script from an interactive terminal."
            STORE_CLIENT=${STORE_CLIENT,,}
        done

        until [[ ${USE_NFTABLES} =~ ^[yn]$ ]]; do
            read -rp "Use nftables instead of iptables? [y/n]: " -e -i y USE_NFTABLES || fail "Input closed; rerun the script from an interactive terminal."
            USE_NFTABLES=${USE_NFTABLES,,}
        done

        POSSIBLE_ALLOWED_IPS="0.0.0.0/0"
        if [[ ${USE_IPV6} == 'y' ]]; then
            POSSIBLE_ALLOWED_IPS="${POSSIBLE_ALLOWED_IPS}, ::/0"
        fi
        until [[ ${ALLOWED_IPS} =~ ^.+$ ]]; do
            read -rp "Allowed IPs list for generated clients (leave default to route everything): " -e -i "$POSSIBLE_ALLOWED_IPS" ALLOWED_IPS || fail "Input closed; rerun the script from an interactive terminal."
        if [[ ${ALLOWED_IPS} == "" ]]; then
            ALLOWED_IPS="$POSSIBLE_ALLOWED_IPS"
        fi
        done

        # Keepalive interval
        until [[ ${KEEPALIVE} =~ ^[0-9]+$ ]] && [ "${KEEPALIVE}" -ge 0 ] && [ "${KEEPALIVE}" -le 65535 ]; do
            read -rp "Keepalive interval [0-65535]: " -e -i 0 KEEPALIVE || fail "Input closed; rerun the script from an interactive terminal."
        done

        # Jc
        until [[ ${SERVER_AWG_JC} =~ ^[0-9]+$ ]] && (( ${SERVER_AWG_JC} >= 1 )) && (( ${SERVER_AWG_JC} <= 128 )); do
            read -rp "Server AmneziaWG Jc [1-128]: " -e -i ${RANDOM_AWG_JC} SERVER_AWG_JC || fail "Input closed; rerun the script from an interactive terminal."
        done

        # Jmin && Jmax
        readJminAndJmax
        until [ "${SERVER_AWG_JMIN}" -le "${SERVER_AWG_JMAX}" ]; do
            echo "AmneziaWG requires Jmin <= Jmax"
            readJminAndJmax
        done

        if [[ "${AWG_VERSION}" == "3.1" ]]; then
            echo ""
            echo "HeaderProtectionKey encrypts packet headers using ChaCha20 (AmneziaWG 3.1+)."
            echo "Leave 'auto' to automatically generate via 'awg genkey' during installation,"
            echo "or provide a custom 32-byte Base64 key."
            until [[ "${SERVER_AWG_HPK}" == "auto" || "${SERVER_AWG_HPK}" =~ ^[A-Za-z0-9+/]{43}=$ || "${SERVER_AWG_HPK}" =~ ^[A-Za-z0-9+/]{44}$ ]]; do
                read -rp "HeaderProtectionKey [auto or 32-byte base64]: " -e -i auto SERVER_AWG_HPK || fail "Input closed; rerun the script from an interactive terminal."
            done

            until [[ "${SERVER_AWG_CPA}" =~ ^[0-9]+(-[0-9]+)?$ ]]; do
                read -rp "ContentPaddingAddition [e.g. 16-64]: " -e -i "16-64" SERVER_AWG_CPA || fail "Input closed; rerun the script from an interactive terminal."
            done

            echo ""
            echo "RandomTrailers appends random-length padding to packets to disrupt size profiling (AmneziaWG 3.1+)."
            until [[ ${SERVER_AWG_RANDOM_TRAILERS} =~ ^[yn]$ ]]; do
                read -rp "Enable RandomTrailers? [y/n]: " -e -i y SERVER_AWG_RANDOM_TRAILERS || fail "Input closed; rerun the script from an interactive terminal."
                SERVER_AWG_RANDOM_TRAILERS=${SERVER_AWG_RANDOM_TRAILERS,,}
            done

            echo ""
            echo "DisableCookies disables handshake cookie replies to evade active DPI probing (AmneziaWG 3.1+)."
            until [[ ${SERVER_AWG_DISABLE_COOKIES} =~ ^[yn]$ ]]; do
                read -rp "Enable DisableCookies? [y/n]: " -e -i y SERVER_AWG_DISABLE_COOKIES || fail "Input closed; rerun the script from an interactive terminal."
                SERVER_AWG_DISABLE_COOKIES=${SERVER_AWG_DISABLE_COOKIES,,}
            done
        else
            SERVER_AWG_HPK=""
            SERVER_AWG_CPA=""
            SERVER_AWG_RANDOM_TRAILERS="n"
            SERVER_AWG_DISABLE_COOKIES="n"
        fi

        if [[ "${AWG_VERSION}" == "1.0" ]]; then
            SERVER_AWG_S3=""
            SERVER_AWG_S4=""
        fi

        # S1 && S2 (and S3 && S4 for AWG 2.0 and 3.1)
        if [[ "${AWG_VERSION}" == "3.1" && "${SERVER_AWG_RANDOM_TRAILERS}" == "y" ]]; then
            echo ""
            echo "Note: When RandomTrailers is enabled, AmneziaWG recommends setting S1 = S2 = S3 = S4."
        fi
        readSParams
        while (( ${SERVER_AWG_S1} + 56 == ${SERVER_AWG_S2} )); do
            echo "AmneziaWG requires S1 + 56 <> S2"
            readSParams
        done

        # H1 && H2 && H3 && H4 (supports uint32 and intervals min-max)
        readH1AndH2AndH3AndH4

        # I1-I5 Custom Protocol Signature (CPS) for AWG 3.1 and 2.0
        if [[ "${AWG_VERSION}" != "1.0" ]]; then
            readIParams
        else
            SERVER_AWG_I1=""
            SERVER_AWG_I2=""
            SERVER_AWG_I3=""
            SERVER_AWG_I4=""
            SERVER_AWG_I5=""
        fi
    else
        # Standard mode automatic defaults
        USE_IPV6="n"
        SERVER_PUB_NIC="${SERVER_NIC}"
        SERVER_AWG_NIC="awg0"
        SERVER_AWG_IPV4="${WGIP}"
        STORE_CLIENT="y"
        USE_NFTABLES="y"
        ALLOWED_IPS="0.0.0.0/0"
        KEEPALIVE=0
        SERVER_AWG_JC=${RANDOM_AWG_JC}
        SERVER_AWG_JMIN=40
        SERVER_AWG_JMAX=70

        if [[ "${AWG_VERSION}" == "3.1" ]]; then
            SERVER_AWG_MTU=1360
            SERVER_AWG_HPK="auto"
            SERVER_AWG_CPA="16-64"
            SERVER_AWG_RANDOM_TRAILERS="y"
            SERVER_AWG_DISABLE_COOKIES="y"
            SERVER_AWG_S1=${RANDOM_AWG_S1}
            SERVER_AWG_S2=${RANDOM_AWG_S1}
            SERVER_AWG_S3=${RANDOM_AWG_S1}
            SERVER_AWG_S4=${RANDOM_AWG_S1}
            SERVER_AWG_H1=1
            SERVER_AWG_H2=2
            SERVER_AWG_H3=3
            SERVER_AWG_H4=4
        elif [[ "${AWG_VERSION}" == "2.0" ]]; then
            SERVER_AWG_MTU=1420
            SERVER_AWG_HPK=""
            SERVER_AWG_CPA=""
            SERVER_AWG_RANDOM_TRAILERS="n"
            SERVER_AWG_DISABLE_COOKIES="n"
            SERVER_AWG_S1=${RANDOM_AWG_S1}
            SERVER_AWG_S2=${RANDOM_AWG_S2}
            SERVER_AWG_S3=${RANDOM_AWG_S3}
            SERVER_AWG_S4=${RANDOM_AWG_S4}
            SERVER_AWG_H1=${RANDOM_AWG_H1}
            SERVER_AWG_H2=${RANDOM_AWG_H2}
            SERVER_AWG_H3=${RANDOM_AWG_H3}
            SERVER_AWG_H4=${RANDOM_AWG_H4}
        else
            SERVER_AWG_MTU=1420
            SERVER_AWG_HPK=""
            SERVER_AWG_CPA=""
            SERVER_AWG_RANDOM_TRAILERS="n"
            SERVER_AWG_DISABLE_COOKIES="n"
            SERVER_AWG_S1=${RANDOM_AWG_S1}
            SERVER_AWG_S2=${RANDOM_AWG_S2}
            SERVER_AWG_S3=""
            SERVER_AWG_S4=""
            SERVER_AWG_H1=${RANDOM_AWG_H1}
            SERVER_AWG_H2=${RANDOM_AWG_H2}
            SERVER_AWG_H3=${RANDOM_AWG_H3}
            SERVER_AWG_H4=${RANDOM_AWG_H4}
        fi
        SERVER_AWG_I1=""
        SERVER_AWG_I2=""
        SERVER_AWG_I3=""
        SERVER_AWG_I4=""
        SERVER_AWG_I5=""
    fi

    echo ""
    echo "Okay, that was all I needed. Ready to setup your AmneziaWG server now."
}

function installPackages() {
    if [[ ${USE_NFTABLES} == 'y' ]]; then NF_PACKAGE="nftables"; else NF_PACKAGE="iptables"; fi

    # Install AmneziaWG tools and module
    if [[ ${OS} == 'ubuntu' ]]; then
        apt-get update -o APT::Update::Error-Mode=any
        apt-get install -y software-properties-common ca-certificates curl gnupg dkms build-essential kmod iproute2
        ensureKernelHeaders
        add-apt-repository -y ppa:amnezia/ppa
        apt-get update -o APT::Update::Error-Mode=any
        apt-get install -y amneziawg-dkms amneziawg-tools qrencode "${NF_PACKAGE}"
    elif [[ ${OS} == 'debian' ]]; then
        apt-get update -o APT::Update::Error-Mode=any
        apt-get install -y ca-certificates curl gnupg dkms build-essential kmod iproute2
        ensureKernelHeaders

        MAJOR_VERSION=$(echo "$VERSION_ID" | cut -d'.' -f1)
        case "$MAJOR_VERSION" in
            12) UBUNTU_SUITE="jammy" ;;
            *)  UBUNTU_SUITE="noble" ;;
        esac

        install -d -m 755 /etc/apt/keyrings
        local key_file key_fingerprint
        key_file=$(mktemp)
        curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
            "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828" -o "$key_file"
        key_fingerprint=$(gpg --batch --show-keys --with-colons "$key_file" | awk -F: '$1=="fpr" {print $10; exit}')
        [[ "$key_fingerprint" == 75C9DD72C799870E310542E24166F2C257290828 ]] || fail "Unexpected Amnezia PPA key fingerprint."
        gpg --batch --dearmor --yes -o /etc/apt/keyrings/amneziawg-keyring.gpg "$key_file"
        rm -f "$key_file"
        chmod 644 /etc/apt/keyrings/amneziawg-keyring.gpg
        echo "Types: deb deb-src
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: ${UBUNTU_SUITE}
Components: main
Signed-By: /etc/apt/keyrings/amneziawg-keyring.gpg
" > "/etc/apt/sources.list.d/amneziawg.sources"
        chmod 644 /etc/apt/sources.list.d/amneziawg.sources
        apt-get update -o APT::Update::Error-Mode=any
        apt-get install -y amneziawg-dkms amneziawg-tools qrencode "${NF_PACKAGE}"
    elif [[ ${OS} == 'fedora' ]]; then
        dnf copr enable -y tigro/amneziawg
        dnf install -y amneziawg-kmod amneziawg-tools qrencode bc ${NF_PACKAGE}
    elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]] || [[ ${OS} == 'rhel' ]]; then
        dnf install -y dnf-plugins-core 2>/dev/null || true
        dnf config-manager --set-enabled crb 2>/dev/null || dnf config-manager enable crb 2>/dev/null || crb enable 2>/dev/null || true
        dnf install -y epel-release
        dnf copr enable -y tigro/amneziawg
        if [[ ${MAJOR_VERSION} -ge 10 ]]; then
            echo -e "\n${ORANGE}WARNING: Detected Enterprise Linux 10 (${OS} ${VERSION_ID}).${NC}"
            echo -e "${ORANGE}EL 10 package availability and build success depend on the Copr repository author and official kernel source compatibility.${NC}"
            echo -e "${ORANGE}Building kernel module via DKMS (amneziawg-dkms)...${NC}\n"
            dnf install -y amneziawg-dkms amneziawg-tools qrencode ${NF_PACKAGE}
        else
            dnf install -y kmod-amneziawg amneziawg-tools qrencode ${NF_PACKAGE}
        fi
    fi

    verifyAmneziaWG
}

function installAmneziaWG() {
    # Restrict fail-fast to setup; management uses grep exit 1 for empty lists.
    set -Ee
    trap 'setupError "$?" "$LINENO"' ERR
    trap 'rollbackSetup "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    umask 077
    if [[ "$OS" == debian || "$OS" == ubuntu ]]; then
        apt-get update -o APT::Update::Error-Mode=any
        apt-get install -y ca-certificates curl iproute2
    fi
    installQuestions
    checkNetworkConflicts
    installPackages
    install -d -m 700 "$AMNEZIAWG_DIR"
    # Preserve remnants from an earlier failed setup before writing new keys.
    if [[ -e "${AMNEZIAWG_DIR}/${SERVER_AWG_NIC}.conf" || -e "${AMNEZIAWG_DIR}/params.pending" ]]; then
        local previous_dir
        previous_dir=$(mktemp -d "${AMNEZIAWG_DIR}/before-setup.XXXXXX")
        local previous_file
        for previous_file in "${SERVER_AWG_NIC}.conf" params.pending nft.sh; do
            if [[ -f "${AMNEZIAWG_DIR}/${previous_file}" ]]; then
                cp -p "${AMNEZIAWG_DIR}/${previous_file}" "$previous_dir/"
            fi
        done
        echo "Previous incomplete configuration saved to ${previous_dir}"
    fi

    SERVER_AWG_CONF="${AMNEZIAWG_DIR}/${SERVER_AWG_NIC}.conf"

    # Deferred generation of HeaderProtectionKey for AWG 3.1
    if [[ "${AWG_VERSION}" == "3.1" ]]; then
        if [[ -z "${SERVER_AWG_HPK}" || "${SERVER_AWG_HPK}" == "auto" ]]; then
            SERVER_AWG_HPK=$(awg genkey)
        fi
    fi

    SERVER_PRIV_KEY=$(awg genkey)
    SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | awg pubkey)

    # Shell-escape every value: params is sourced when managing/recovering setup.
    local param
    for param in AWG_VERSION SERVER_AWG_IPV4 SERVER_AWG_IPV6 SERVER_AWG_MTU SERVER_AWG_HPK SERVER_AWG_CPA SERVER_AWG_RANDOM_TRAILERS SERVER_AWG_DISABLE_COOKIES SERVER_AWG_I1 SERVER_AWG_I2 SERVER_AWG_I3 SERVER_AWG_I4 SERVER_AWG_I5 SERVER_PUB_IP SERVER_PUB_NIC SERVER_AWG_NIC SERVER_PORT SERVER_PRIV_KEY SERVER_PUB_KEY CLIENT_IPV4_DNS_1 CLIENT_IPV4_DNS_2 CLIENT_IPV6_DNS_1 CLIENT_IPV6_DNS_2 STORE_CLIENT USE_IPV6 USE_NFTABLES ALLOWED_IPS KEEPALIVE SERVER_AWG_JC SERVER_AWG_JMIN SERVER_AWG_JMAX SERVER_AWG_S1 SERVER_AWG_S2 SERVER_AWG_S3 SERVER_AWG_S4 SERVER_AWG_H1 SERVER_AWG_H2 SERVER_AWG_H3 SERVER_AWG_H4; do
        printf '%s=%q\n' "$param" "${!param}"
    done > "${AMNEZIAWG_DIR}/params.pending"

    # Add server interface
    SERVER_ADDRESS="${SERVER_AWG_IPV4}/24"

    if [[ "$USE_IPV6" = 'y' ]]; then
        SERVER_ADDRESS="${SERVER_ADDRESS}, ${SERVER_AWG_IPV6}/64"
    fi

    echo "[Interface]
Address = ${SERVER_ADDRESS}
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
MTU = ${SERVER_AWG_MTU}
Jc = ${SERVER_AWG_JC}
Jmin = ${SERVER_AWG_JMIN}
Jmax = ${SERVER_AWG_JMAX}
S1 = ${SERVER_AWG_S1}
S2 = ${SERVER_AWG_S2}" >"${SERVER_AWG_CONF}"

    if [[ "${AWG_VERSION}" == "3.1" ]]; then
        echo "S3 = ${SERVER_AWG_S3}
S4 = ${SERVER_AWG_S4}
H1 = ${SERVER_AWG_H1}
H2 = ${SERVER_AWG_H2}
H3 = ${SERVER_AWG_H3}
H4 = ${SERVER_AWG_H4}
HeaderProtectionKey = ${SERVER_AWG_HPK}
ContentPaddingAddition = ${SERVER_AWG_CPA}" >>"${SERVER_AWG_CONF}"
    elif [[ "${AWG_VERSION}" == "2.0" ]]; then
        echo "S3 = ${SERVER_AWG_S3}
S4 = ${SERVER_AWG_S4}
H1 = ${SERVER_AWG_H1}
H2 = ${SERVER_AWG_H2}
H3 = ${SERVER_AWG_H3}
H4 = ${SERVER_AWG_H4}" >>"${SERVER_AWG_CONF}"
    else
        echo "H1 = ${SERVER_AWG_H1}
H2 = ${SERVER_AWG_H2}
H3 = ${SERVER_AWG_H3}
H4 = ${SERVER_AWG_H4}" >>"${SERVER_AWG_CONF}"
    fi

    # Append parameters only if they differ from configuration defaults
    if [[ "${SERVER_AWG_RANDOM_TRAILERS}" == "y" ]]; then
        echo "RandomTrailers = on" >>"${SERVER_AWG_CONF}"
    fi

    if [[ "${SERVER_AWG_DISABLE_COOKIES}" == "y" ]]; then
        echo "DisableCookies = on" >>"${SERVER_AWG_CONF}"
    fi

    if systemctl is-active --quiet firewalld 2>/dev/null || pgrep -x firewalld >/dev/null 2>&1; then
        echo "PostUp = firewall-cmd --zone=public --add-interface=${SERVER_AWG_NIC}
PostUp = firewall-cmd --zone=public --add-port=${SERVER_PORT}/udp" >>"${SERVER_AWG_CONF}"

        echo "PostUp = firewall-cmd --direct --add-rule ipv4 filter FORWARD 0 -i ${SERVER_PUB_NIC} -o ${SERVER_AWG_NIC} -j ACCEPT
PostUp = firewall-cmd --direct --add-rule ipv4 filter FORWARD 0 -i ${SERVER_AWG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostUp = firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s ${SERVER_AWG_IPV4%.*}.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = firewall-cmd --direct --remove-rule ipv4 nat POSTROUTING 0 -s ${SERVER_AWG_IPV4%.*}.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = firewall-cmd --direct --remove-rule ipv4 filter FORWARD 0 -i ${SERVER_AWG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostDown = firewall-cmd --direct --remove-rule ipv4 filter FORWARD 0 -i ${SERVER_PUB_NIC} -o ${SERVER_AWG_NIC} -j ACCEPT" >>"${SERVER_AWG_CONF}"

        if [[ "$USE_IPV6" = 'y' ]]; then
            echo "PostUp = firewall-cmd --direct --add-rule ipv6 filter FORWARD 0 -i ${SERVER_PUB_NIC} -o ${SERVER_AWG_NIC} -j ACCEPT
PostUp = firewall-cmd --direct --add-rule ipv6 filter FORWARD 0 -i ${SERVER_AWG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostUp = firewall-cmd --direct --add-rule ipv6 nat POSTROUTING 0 -s ${SERVER_AWG_IPV6%::*}::/64 -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = firewall-cmd --direct --remove-rule ipv6 nat POSTROUTING 0 -s ${SERVER_AWG_IPV6%::*}::/64 -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = firewall-cmd --direct --remove-rule ipv6 filter FORWARD 0 -i ${SERVER_AWG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
PostDown = firewall-cmd --direct --remove-rule ipv6 filter FORWARD 0 -i ${SERVER_PUB_NIC} -o ${SERVER_AWG_NIC} -j ACCEPT" >>"${SERVER_AWG_CONF}"
        fi

        echo "PostDown = firewall-cmd --zone=public --remove-port=${SERVER_PORT}/udp
PostDown = firewall-cmd --zone=public --remove-interface=${SERVER_AWG_NIC}" >>"${SERVER_AWG_CONF}"
    elif [[ ${USE_NFTABLES} == 'y' ]]; then
        NFTABLES_SCRIPT_PATH="${AMNEZIAWG_DIR}/nft.sh"
        cat << 'EOF' > "${NFTABLES_SCRIPT_PATH}"
#!/bin/bash
set -euo pipefail
ACTION="$1"
PORT="$2"
PUB_NIC="$3"
AWG_NIC="$4"
TABLE_NAME="awg_${AWG_NIC}"
VPN_NET="${5:-}"
VPN_NET6="${6:-}"

if [[ "${ACTION}" == 'up' ]]; then
    [[ "$VPN_NET" =~ ^([0-9]{1,3}\.){3}0/24$ ]] || { echo "Missing VPN subnet" >&2; exit 1; }
    # One transaction; do not flush any other service's tables or policies.
    {
        cat <<RULES
add table inet ${TABLE_NAME}
flush table inet ${TABLE_NAME}
add chain inet ${TABLE_NAME} input { type filter hook input priority filter; policy accept; }
add rule inet ${TABLE_NAME} input udp dport ${PORT} accept
add chain inet ${TABLE_NAME} forward { type filter hook forward priority filter; policy accept; }
add rule inet ${TABLE_NAME} forward iifname "${AWG_NIC}" oifname "${PUB_NIC}" accept
add rule inet ${TABLE_NAME} forward iifname "${PUB_NIC}" oifname "${AWG_NIC}" ct state established,related accept
add chain inet ${TABLE_NAME} postrouting { type nat hook postrouting priority srcnat; policy accept; }
add rule inet ${TABLE_NAME} postrouting ip saddr ${VPN_NET} oifname "${PUB_NIC}" masquerade
RULES
        if [[ -n "$VPN_NET6" ]]; then
            printf 'add rule inet %s postrouting ip6 saddr %s oifname "%s" masquerade\n' "$TABLE_NAME" "$VPN_NET6" "$PUB_NIC"
        fi
    } | nft -f -

    # Also allow in inet filter if an existing firewall table is present
    if nft list table inet filter >/dev/null 2>&1; then
        if nft list chain inet filter input >/dev/null 2>&1; then
            nft insert rule inet filter input udp dport "${PORT}" accept comment "\"${TABLE_NAME}\""
        fi
        if nft list chain inet filter forward >/dev/null 2>&1; then
            nft insert rule inet filter forward iifname "${AWG_NIC}" accept comment "\"${TABLE_NAME}\""
            nft insert rule inet filter forward iifname "${PUB_NIC}" oifname "${AWG_NIC}" accept comment "\"${TABLE_NAME}\""
        fi
    fi
elif [[ "${ACTION}" == 'down' ]]; then
    # Remove rules from inet filter if present
    if nft list table inet filter >/dev/null 2>&1; then
        for chain in input forward; do
            if nft list chain inet filter "${chain}" >/dev/null 2>&1; then
                nft -a list chain inet filter "${chain}" | awk -v marker="$TABLE_NAME" 'index($0, "comment \"" marker "\"") {print $NF}' | while read -r handle; do
                    nft delete rule inet filter "${chain}" handle "${handle}" 2>/dev/null || true
                done
            fi
        done
    fi

    # Atomically delete dedicated table
    nft delete table inet "${TABLE_NAME}" 2>/dev/null || true
fi
EOF
        chmod +x "${NFTABLES_SCRIPT_PATH}"
        local vpn_net6=""
        if [[ "$USE_IPV6" == y ]]; then vpn_net6="${SERVER_AWG_IPV6%::*}::/64"; fi
        echo "PostUp = ${NFTABLES_SCRIPT_PATH} up ${SERVER_PORT} ${SERVER_PUB_NIC} ${SERVER_AWG_NIC} ${SERVER_AWG_IPV4%.*}.0/24 ${vpn_net6}
PreDown = ${NFTABLES_SCRIPT_PATH} down ${SERVER_PORT} ${SERVER_PUB_NIC} ${SERVER_AWG_NIC}" >>"${SERVER_AWG_CONF}"
    else
        echo "PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_AWG_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_AWG_NIC} -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s ${SERVER_AWG_IPV4%.*}.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_AWG_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_AWG_NIC} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${SERVER_AWG_IPV4%.*}.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE" >> "${SERVER_AWG_CONF}"

        if [[ "$USE_IPV6" = 'y' ]]; then
            echo "PostUp = ip6tables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = ip6tables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_AWG_NIC} -j ACCEPT
PostUp = ip6tables -I FORWARD -i ${SERVER_AWG_NIC} -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -s ${SERVER_AWG_IPV6%::*}::/64 -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = ip6tables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = ip6tables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_AWG_NIC} -j ACCEPT
PostDown = ip6tables -D FORWARD -i ${SERVER_AWG_NIC} -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -s ${SERVER_AWG_IPV6%::*}::/64 -o ${SERVER_PUB_NIC} -j MASQUERADE" >> "${SERVER_AWG_CONF}"  
        fi
    fi

    enableForwarding
    chmod 600 "$SERVER_AWG_CONF" "${AMNEZIAWG_DIR}/params.pending"
    startAmneziaWG
    mv -f "${AMNEZIAWG_DIR}/params.pending" "${AMNEZIAWG_DIR}/params"
    SETUP_NETWORK_STARTED=n
    trap - ERR EXIT INT TERM
    set +e

    newClient
    echo -e "${GREEN}If you want to add more clients, you simply need to run this script another time!${NC}"

    # Check if AmneziaWG is running
    systemctl is-active --quiet "awg-quick@${SERVER_AWG_NIC}"
    AWG_RUNNING=$?

    # AmneziaWG might not work if we updated the kernel. Tell the user to reboot
    if [[ ${AWG_RUNNING} -ne 0 ]]; then
        echo -e "\n${RED}WARNING: AmneziaWG does not seem to be running.${NC}"
        echo -e "${ORANGE}You can check if AmneziaWG is running with: systemctl status awg-quick@${SERVER_AWG_NIC}${NC}"
        echo -e "${ORANGE}If you get something like \"Cannot find device ${SERVER_AWG_NIC}\", please reboot!${NC}"
    else # AmneziaWG is running
        echo -e "\n${GREEN}AmneziaWG is running.${NC}"
        echo -e "${GREEN}You can check the status of AmneziaWG with: systemctl status awg-quick@${SERVER_AWG_NIC}\n\n${NC}"
        echo -e "${ORANGE}If you don't have internet connectivity from your client, try to reboot the server.${NC}"
    fi
}

function generateClientConfigFile() {
    local target_file="$1"
    local priv_key="$2"
    local address="$3"
    local psk="$4"
    local dns="$5"
    local endpoint="$6"
    local allowed_ips="$7"
    local keepalive="$8"

    local tmp_file="${target_file}.tmp"
    echo "[Interface]
PrivateKey = ${priv_key}
Address = ${address}
DNS = ${dns}
MTU = ${SERVER_AWG_MTU}
Jc = ${SERVER_AWG_JC}
Jmin = ${SERVER_AWG_JMIN}
Jmax = ${SERVER_AWG_JMAX}
S1 = ${SERVER_AWG_S1}
S2 = ${SERVER_AWG_S2}" > "${tmp_file}"

    if [[ "${AWG_VERSION}" == "3.1" ]]; then
        echo "S3 = ${SERVER_AWG_S3}
S4 = ${SERVER_AWG_S4}
H1 = ${SERVER_AWG_H1}
H2 = ${SERVER_AWG_H2}
H3 = ${SERVER_AWG_H3}
H4 = ${SERVER_AWG_H4}
HeaderProtectionKey = ${SERVER_AWG_HPK}
ContentPaddingAddition = ${SERVER_AWG_CPA}" >> "${tmp_file}"
    elif [[ "${AWG_VERSION}" == "2.0" ]]; then
        echo "S3 = ${SERVER_AWG_S3}
S4 = ${SERVER_AWG_S4}
H1 = ${SERVER_AWG_H1}
H2 = ${SERVER_AWG_H2}
H3 = ${SERVER_AWG_H3}
H4 = ${SERVER_AWG_H4}" >> "${tmp_file}"
    else
        echo "H1 = ${SERVER_AWG_H1}
H2 = ${SERVER_AWG_H2}
H3 = ${SERVER_AWG_H3}
H4 = ${SERVER_AWG_H4}" >> "${tmp_file}"
    fi

    # Append parameters only if they differ from configuration defaults
    if [[ "${SERVER_AWG_RANDOM_TRAILERS}" == "y" ]]; then
        echo "RandomTrailers = on" >> "${tmp_file}"
    fi

    if [[ "${SERVER_AWG_DISABLE_COOKIES}" == "y" ]]; then
        echo "DisableCookies = on" >> "${tmp_file}"
    fi

    local i
    for i in 1 2 3 4 5; do
        local var="SERVER_AWG_I${i}"
        local val="${!var}"
        if [[ -n "${val}" ]]; then
            echo "I${i} = ${val}" >> "${tmp_file}"
        fi
    done

    echo "
[Peer]
PublicKey = ${SERVER_PUB_KEY}" >> "${tmp_file}"

    if [[ -n "${psk}" ]]; then
        echo "PresharedKey = ${psk}" >> "${tmp_file}"
    fi

    echo "Endpoint = ${endpoint}
AllowedIPs = ${allowed_ips}" >> "${tmp_file}"

    if [[ -n "${keepalive}" && "${keepalive}" =~ ^[0-9]+$ && "${keepalive}" -gt 0 ]]; then
        echo "PersistentKeepalive = ${keepalive}" >> "${tmp_file}"
    fi

    mv -f "${tmp_file}" "${target_file}"
    chmod 600 "${target_file}"
    if [[ -n "${SUDO_USER}" && "${SUDO_USER}" != "root" && "${target_file}" == /home/* ]]; then
        chown "${SUDO_USER}:${SUDO_USER}" "${target_file}" 2>/dev/null || true
    fi
}

function regenerateClientConfig() {
    local target_file="$1"
    if [[ ! -f "${target_file}" ]]; then
        return 1
    fi

    local priv_key address psk dns endpoint allowed_ips keepalive
    priv_key=$(grep -m1 -E '^[[:space:]]*PrivateKey[[:space:]]*=' "${target_file}" | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    address=$(grep -m1 -E '^[[:space:]]*Address[[:space:]]*=' "${target_file}" | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    psk=$(grep -m1 -E '^[[:space:]]*PresharedKey[[:space:]]*=' "${target_file}" | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    dns=$(grep -m1 -E '^[[:space:]]*DNS[[:space:]]*=' "${target_file}" | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    endpoint=$(grep -m1 -E '^[[:space:]]*Endpoint[[:space:]]*=' "${target_file}" | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    allowed_ips=$(grep -m1 -E '^[[:space:]]*AllowedIPs[[:space:]]*=' "${target_file}" | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    keepalive=$(grep -m1 -E '^[[:space:]]*PersistentKeepalive[[:space:]]*=' "${target_file}" | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    if [[ -z "${priv_key}" || -z "${address}" ]]; then
        echo -e "${ORANGE}Warning: Could not parse PrivateKey or Address from ${target_file}. Skipping.${NC}" >&2
        return 1
    fi

    if [[ -z "${dns}" ]]; then
        dns="${CLIENT_IPV4_DNS_1}, ${CLIENT_IPV4_DNS_2}"
        if [[ "$USE_IPV6" = 'y' && -n "${CLIENT_IPV6_DNS_1}" ]]; then
            dns="${dns}, ${CLIENT_IPV6_DNS_1}, ${CLIENT_IPV6_DNS_2}"
        fi
    fi

    if [[ -z "${endpoint}" ]]; then
        local ep_ip="${SERVER_PUB_IP}"
        if [[ ${ep_ip} =~ .*:.* ]]; then
            if [[ ${ep_ip} != *"["* ]] || [[ ${ep_ip} != *"]"* ]]; then
                ep_ip="[${ep_ip}]"
            fi
        fi
        endpoint="${ep_ip}:${SERVER_PORT}"
    fi

    allowed_ips="${allowed_ips:-${ALLOWED_IPS}}"
    keepalive="${keepalive:-${KEEPALIVE}}"

    generateClientConfigFile "${target_file}" "${priv_key}" "${address}" "${psk}" "${dns}" "${endpoint}" "${allowed_ips}" "${keepalive}"
}

function newClient() {
    set -Ee
    trap 'setupError "$?" "$LINENO"' ERR
    CLIENT_NAME=""
    CLIENT_EXISTS=""
    IPV4_EXISTS=""
    IPV6_EXISTS=""
    DOT_IP=""
    CLIENT_DOT_IP=""
    CLIENT_DOT_IP6=""

    # If SERVER_PUB_IP is IPv6, add brackets if missing
    if [[ ${SERVER_PUB_IP} =~ .*:.* ]]; then
        if [[ ${SERVER_PUB_IP} != *"["* ]] || [[ ${SERVER_PUB_IP} != *"]"* ]]; then
            SERVER_PUB_IP="[${SERVER_PUB_IP}]"
        fi
    fi
    ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"

    echo ""
    echo "Client configuration"
    echo ""
    echo "The client name must consist of alphanumeric character(s). It may also include underscores or dashes and can't exceed 15 chars."

    until [[ ${CLIENT_NAME} =~ ^[a-zA-Z0-9_-]+$ && ${CLIENT_EXISTS} == '0' && ${#CLIENT_NAME} -lt 16 ]]; do
        read -rp "Client name: " -e CLIENT_NAME || fail "Input closed; rerun the script from an interactive terminal."
        [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]{1,15}$ ]] || { echo "Invalid client name."; continue; }
        CLIENT_EXISTS=$(grep -c -E "^### Client ${CLIENT_NAME}\$" "${SERVER_AWG_CONF}") || true

        if [[ ${CLIENT_EXISTS} != 0 ]]; then
            echo ""
            echo -e "${ORANGE}A client with the specified name was already created, please choose another name.${NC}"
            echo ""
        fi
    done

    IPV4_NET=$(echo "$SERVER_AWG_IPV4" | awk -F '.' '{ print $1"."$2"."$3 }')
    SERVER_LAST_OCTET=$(echo "$SERVER_AWG_IPV4" | awk -F '.' '{ print $4 }')
    DOT_IP=""
    for i in {2..254}; do
        if [[ "$i" == "$SERVER_LAST_OCTET" ]]; then
            continue
        fi
        DOT_EXISTS=$(grep -c -F "${IPV4_NET}.${i}/" "${SERVER_AWG_CONF}") || true
        if [[ ${DOT_EXISTS} == '0' ]]; then
            DOT_IP="$i"
            break
        fi
    done

    if [[ -z "${DOT_IP}" ]]; then
        echo ""
        echo "The subnet configured supports only 253 clients."
        exit 1
    fi

    BASE_IP="${IPV4_NET}"
    until [[ ${IPV4_EXISTS} == '0' ]]; do
        read -rp "Client AmneziaWG IPv4: ${BASE_IP}." -e -i "${DOT_IP}" CLIENT_DOT_IP || fail "Input closed; rerun the script from an interactive terminal."
        CLIENT_DOT_IP="${CLIENT_DOT_IP:-${DOT_IP}}"
        if [[ ! "$CLIENT_DOT_IP" =~ ^[0-9]{1,3}$ ]]; then echo "Enter a host number from 2 to 254."; continue; fi
        CLIENT_DOT_IP=$((10#$CLIENT_DOT_IP))
        if (( CLIENT_DOT_IP < 2 || CLIENT_DOT_IP > 254 || CLIENT_DOT_IP == SERVER_LAST_OCTET )); then
            echo "Invalid client address or server address selected."; continue
        fi
        CLIENT_AWG_IPV4="${BASE_IP}.${CLIENT_DOT_IP}"
        IPV4_EXISTS=$(grep -c -F "$CLIENT_AWG_IPV4/32" "${SERVER_AWG_CONF}") || true

        if [[ ${IPV4_EXISTS} != 0 ]]; then
            echo ""
            echo -e "${ORANGE}A client with the specified IPv4 was already created, please choose another IPv4.${NC}"
            echo ""
        fi
    done

    if [[ ${USE_IPV6} == 'y' ]]; then
        BASE_IP=$(echo "$SERVER_AWG_IPV6" | awk -F '::' '{ print $1 }')
        until [[ ${IPV6_EXISTS} == '0' ]]; do
            read -rp "Client AmneziaWG IPv6: ${BASE_IP}::" -e -i "${DOT_IP}" CLIENT_DOT_IP6 || fail "Input closed; rerun the script from an interactive terminal."
            CLIENT_DOT_IP6="${CLIENT_DOT_IP6:-${DOT_IP}}"
            CLIENT_AWG_IPV6="${BASE_IP}::${CLIENT_DOT_IP6}"
            IPV6_EXISTS=$(grep -c -F "${CLIENT_AWG_IPV6}/128" "${SERVER_AWG_CONF}") || true

            if [[ ${IPV6_EXISTS} != 0 ]]; then
                echo ""
                echo -e "${ORANGE}A client with the specified IPv6 was already created, please choose another IPv6.${NC}"
                echo ""
            fi
        done
    fi

    # Generate key pair for the client
    CLIENT_PRIV_KEY=$(awg genkey)
    CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | awg pubkey)
    CLIENT_PRE_SHARED_KEY=$(awg genpsk)

    CONFIG_DIR=$(getDirForClientConfig "${CLIENT_NAME}")
    CLIENT_CONFIG="${CONFIG_DIR}/${SERVER_AWG_NIC}-client-${CLIENT_NAME}.conf"

    # Create client file and add the server as a peer
    CLIENT_CONFIG_DNS="${CLIENT_IPV4_DNS_1}, ${CLIENT_IPV4_DNS_2}"
    if [[ "$USE_IPV6" = 'y' ]]; then
        CLIENT_CONFIG_DNS="${CLIENT_CONFIG_DNS}, ${CLIENT_IPV6_DNS_1}, ${CLIENT_IPV6_DNS_2}"
    fi

    CLIENT_ADDRESS="${CLIENT_AWG_IPV4}/32"
    if [[ "$USE_IPV6" = 'y' ]]; then
        CLIENT_ADDRESS="${CLIENT_ADDRESS}, ${CLIENT_AWG_IPV6}/128"
    fi

    generateClientConfigFile "${CLIENT_CONFIG}" "${CLIENT_PRIV_KEY}" "${CLIENT_ADDRESS}" "${CLIENT_PRE_SHARED_KEY}" "${CLIENT_CONFIG_DNS}" "${ENDPOINT}" "${ALLOWED_IPS}" "${KEEPALIVE}"

    # Add the client as a peer to the server
    echo -e "\n### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_ADDRESS}" >> "${SERVER_AWG_CONF}"

    if ip link show dev "${SERVER_AWG_NIC}" >/dev/null 2>&1; then
        local stripped_config
        stripped_config=$(mktemp "${AMNEZIAWG_DIR}/.sync.XXXXXX")
        awg-quick strip "$SERVER_AWG_NIC" > "$stripped_config"
        awg syncconf "$SERVER_AWG_NIC" "$stripped_config"
        rm -f "$stripped_config"
    fi

    # Generate QR code if qrencode is installed
    if command -v qrencode &>/dev/null; then
        echo -e "${GREEN}\nHere is your client config file as a QR Code:\n${NC}"
        qrencode -t ansiutf8 -l L <"${CLIENT_CONFIG}"
        echo ""
    fi

    echo -e "${GREEN}Your client config file is in ${CLIENT_CONFIG}${NC}"
    trap - ERR
    set +e
}

function listClients() {
    NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "${SERVER_AWG_CONF}")
    if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
        echo ""
        echo "You have no existing clients!"
        exit 1
    fi

    grep -E "^### Client" "${SERVER_AWG_CONF}" | cut -d ' ' -f 3 | nl -s ') '
}

function revokeClient() {
    NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "${SERVER_AWG_CONF}")
    if [[ ${NUMBER_OF_CLIENTS} == '0' ]]; then
        echo ""
        echo "You have no existing clients!"
        exit 1
    fi

    CLIENT_NUMBER=""
    CLIENT_NAME=""

    echo ""
    echo "Select the existing client you want to revoke"
    grep -E "^### Client" "${SERVER_AWG_CONF}" | cut -d ' ' -f 3 | nl -s ') '
    until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
        if [[ ${CLIENT_NUMBER} == '1' ]]; then
            read -rp "Select one client [1]: " CLIENT_NUMBER || fail "Input closed; rerun the script from an interactive terminal."
        else
            read -rp "Select one client [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER || fail "Input closed; rerun the script from an interactive terminal."
        fi
    done

    # match the selected number to a client name
    CLIENT_NAME=$(grep -E "^### Client" "${SERVER_AWG_CONF}" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)

    # Safely remove [Peer] block matching CLIENT_NAME
    awk -v client="### Client ${CLIENT_NAME}" '
        $0 == client { skip = 1; next }
        skip && /^### Client / { skip = 0 }
        !skip { print }
    ' "${SERVER_AWG_CONF}" > "${SERVER_AWG_CONF}.tmp" && mv "${SERVER_AWG_CONF}.tmp" "${SERVER_AWG_CONF}"

    # remove generated client file
    CONFIG_DIR=$(getDirForClientConfig "${CLIENT_NAME}")
    CLIENT_CONFIG="${CONFIG_DIR}/${SERVER_AWG_NIC}-client-${CLIENT_NAME}.conf"
    rm -f "${CLIENT_CONFIG}"

    # restart AmneziaWG to apply changes
    if ip link show dev "${SERVER_AWG_NIC}" >/dev/null 2>&1; then
        awg syncconf "${SERVER_AWG_NIC}" <(awg-quick strip "${SERVER_AWG_NIC}")
    fi
}

function showClientQR() {
    NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "${SERVER_AWG_CONF}")
    if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
        echo ""
        echo "You have no existing clients!"
        exit 1
    fi

    CLIENT_NUMBER=""
    CLIENT_NAME=""

    echo ""
    echo "Select the client to show QR code"
    grep -E "^### Client" "${SERVER_AWG_CONF}" | cut -d ' ' -f 3 | nl -s ') '
    until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
        if [[ ${CLIENT_NUMBER} == '1' ]]; then
            read -rp "Select one client [1]: " CLIENT_NUMBER || fail "Input closed; rerun the script from an interactive terminal."
        else
            read -rp "Select one client [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER || fail "Input closed; rerun the script from an interactive terminal."
        fi
    done

    # match the selected number to a client name
    CLIENT_NAME=$(grep -E "^### Client" "${SERVER_AWG_CONF}" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)

    # Get the home directory for the client
    CONFIG_DIR=$(getDirForClientConfig "${CLIENT_NAME}")
    CLIENT_CONFIG="${CONFIG_DIR}/${SERVER_AWG_NIC}-client-${CLIENT_NAME}.conf"

    # Check if the client config file exists
    if [[ -f "${CLIENT_CONFIG}" ]]; then
        echo -e "${GREEN}\nHere is your client config file as a QR Code:\n${NC}"
        qrencode -t ansiutf8 -l L <"${CLIENT_CONFIG}"
        echo ""
    else
        echo -e "${RED}Client config file not found!${NC}"
    fi
}

function uninstallAmneziaWG() {
    echo ""
    echo -e "\n${RED}WARNING: This will uninstall AmneziaWG and remove all the configuration files!${NC}"
    echo -e "${ORANGE}Please backup the /etc/amnezia/amneziawg directory if you want to keep your configuration files.\n${NC}"
    read -rp "Do you really want to remove AmneziaWG? [y/n]: " -e REMOVE || fail "Input closed; rerun the script from an interactive terminal."
    REMOVE=${REMOVE:-n}
    if [[ $REMOVE == 'y' ]]; then
        checkOS

        systemctl stop "awg-quick@${SERVER_AWG_NIC}"
        systemctl disable "awg-quick@${SERVER_AWG_NIC}"

        # Disable routing
        rm -f /etc/sysctl.d/awg.conf
        sysctl --system

        # Remove config files
        rm -rf "${AMNEZIAWG_DIR:?}"/*

        if [[ ${USE_NFTABLES} == 'y' ]]; then NF_PACKAGE="nftables"; else NF_PACKAGE="iptables"; fi

        if [[ ${OS} == 'ubuntu' ]]; then
            apt-get remove -y amneziawg amneziawg-tools
            add-apt-repository -ry ppa:amnezia/ppa
            rm -f /etc/apt/sources.list.d/amneziawg.sources /etc/apt/sources.list.d/amneziawg.sources.list
            apt-get update -o APT::Update::Error-Mode=any
        elif [[ ${OS} == 'debian' ]]; then
            apt-get remove -y amneziawg amneziawg-tools
            rm -f /etc/apt/sources.list.d/amneziawg.sources /etc/apt/sources.list.d/amneziawg.sources.list
            rm -f /etc/apt/keyrings/amneziawg-keyring.gpg
            apt-get update -o APT::Update::Error-Mode=any
        elif [[ ${OS} == 'fedora' ]]; then
            dnf remove -y amneziawg-kmod amneziawg-tools
            dnf copr disable -y tigro/amneziawg || true
        elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]] || [[ ${OS} == 'rhel' ]]; then
            dnf remove -y kmod-amneziawg amneziawg-dkms amneziawg-tools
            dnf copr disable -y tigro/amneziawg || true
        fi

        # Check if AmneziaWG is running
        systemctl is-active --quiet "awg-quick@${SERVER_AWG_NIC}"
        AWG_RUNNING=$?

        if [[ ${AWG_RUNNING} -eq 0 ]]; then
            echo "AmneziaWG failed to uninstall properly."
            exit 1
        else
            echo "AmneziaWG uninstalled successfully."
            echo "You can remove the qrencode and ${NF_PACKAGE} packages yourself if you don't need them."
            exit 0
        fi
    else
        echo ""
        echo "Removal aborted!"
    fi
}

function loadParams() {
    # shellcheck disable=SC1090
    source "${1:-${AMNEZIAWG_DIR}/params}"
    SERVER_AWG_CONF="${AMNEZIAWG_DIR}/${SERVER_AWG_NIC}.conf"
    AWG_VERSION="${AWG_VERSION:-1.0}"
    SERVER_AWG_MTU="${SERVER_AWG_MTU:-1420}"
    SERVER_AWG_HPK="${SERVER_AWG_HPK:-}"
    SERVER_AWG_CPA="${SERVER_AWG_CPA:-}"
    SERVER_AWG_S3="${SERVER_AWG_S3:-}"
    SERVER_AWG_S4="${SERVER_AWG_S4:-}"
    SERVER_AWG_RANDOM_TRAILERS="${SERVER_AWG_RANDOM_TRAILERS:-n}"
    SERVER_AWG_DISABLE_COOKIES="${SERVER_AWG_DISABLE_COOKIES:-n}"
    SERVER_AWG_I1="${SERVER_AWG_I1:-}"
    SERVER_AWG_I2="${SERVER_AWG_I2:-}"
    SERVER_AWG_I3="${SERVER_AWG_I3:-}"
    SERVER_AWG_I4="${SERVER_AWG_I4:-}"
    SERVER_AWG_I5="${SERVER_AWG_I5:-}"
}

# Values new_i1..new_i5 are read indirectly with ${!var} below.
# shellcheck disable=SC2034
function editIParams() {
    echo ""
    echo "--- Change parameters: Custom Protocol Signature (I1-I5) ---"
    echo "Current settings:"
    local i
    for i in 1 2 3 4 5; do
        local var="SERVER_AWG_I${i}"
        local val="${!var}"
        if [[ -n "${val}" ]]; then
            echo "  I${i}: ${val}"
        else
            echo "  I${i}: (not set)"
        fi
    done

    echo ""
    echo "Supported tags:"
    echo "  <b 0xHEX>  - static hex bytes (even number of hex digits, e.g. <b 0xd100000001>)"
    echo "  <r SIZE>   - random bytes (e.g. <r 64>)"
    echo "  <rd SIZE>  - random digits 0-9 (e.g. <rd 10>)"
    echo "  <rc SIZE>  - random chars a-zA-Z (e.g. <rc 8>)"
    echo "  <t>        - 4-byte UNIX timestamp"
    echo "Press Enter to keep current value, leave empty to finish/remove, or type 'q' to abort."

    local new_i1=""
    local new_i2=""
    local new_i3=""
    local new_i4=""
    local new_i5=""

    local prev_set=1
    for i in 1 2 3 4 5; do
        if [[ ${prev_set} -eq 0 ]]; then
            break
        fi

        local var_cur="SERVER_AWG_I${i}"
        local cur_val="${!var_cur}"

        while true; do
            local input=""
            read -rp "AmneziaWG I${i} [optional, Enter to keep/finish]: " -e -i "${cur_val}" input || fail "Input closed; rerun the script from an interactive terminal."
            input=$(echo "${input}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

            if [[ "${input}" == "q" || "${input}" == "quit" || "${input}" == "cancel" ]]; then
                echo "Aborted. No parameters were changed."
                return 0
            fi

            if [[ -z "${input}" ]]; then
                prev_set=0
                break
            fi

            if validateIParam "${input}"; then
                case "${i}" in
                    1) new_i1="${input}" ;;
                    2) new_i2="${input}" ;;
                    3) new_i3="${input}" ;;
                    4) new_i4="${input}" ;;
                    5) new_i5="${input}" ;;
                esac
                break
            else
                echo "Invalid syntax for I${i}! Allowed tags: <b 0xHEX>, <r SIZE>, <rd SIZE>, <rc SIZE>, <t>."
                echo "Example: <b 0xd100000001><rc 8><t><r 50> or <r 64>."
            fi
        done
    done

    # Check if anything changed
    local changed=0
    for i in 1 2 3 4 5; do
        local var_old="SERVER_AWG_I${i}"
        local var_new="new_i${i}"
        if [[ "${!var_old}" != "${!var_new}" ]]; then
            changed=1
            break
        fi
    done

    if [[ ${changed} -eq 0 ]]; then
        echo ""
        echo "No parameters were changed."
        return 0
    fi

    echo ""
    echo "Applying new I1-I5 parameters..."

    # 1. Update /etc/amnezia/amneziawg/params
    for i in 1 2 3 4 5; do
        local var="new_i${i}"
        local val="${!var}"
        if grep -q "^SERVER_AWG_I${i}=" "${AMNEZIAWG_DIR}/params"; then
            sed -i "s|^SERVER_AWG_I${i}=.*|SERVER_AWG_I${i}=\"${val}\"|" "${AMNEZIAWG_DIR}/params"
        else
            echo "SERVER_AWG_I${i}=\"${val}\"" >> "${AMNEZIAWG_DIR}/params"
        fi
    done
    loadParams

    # 2. Ensure server config has no I-parameters (they are client-only)
    if [[ -f "${SERVER_AWG_CONF}" ]]; then
        sed -i '/^I[1-5][[:space:]]*=/d' "${SERVER_AWG_CONF}"
    fi

    # 3. Regenerate all client configs
    local client_count=0
    local client_names=""
    if [[ -f "${SERVER_AWG_CONF}" ]]; then
        client_names=$(grep -E "^### Client " "${SERVER_AWG_CONF}" | awk '{print $3}')
    fi

    local client_files=()
    for client in ${client_names}; do
        local cfg_file="${SERVER_AWG_NIC}-client-${client}.conf"
        local expected_dir
        expected_dir=$(getDirForClientConfig "${client}")
        for dir in "${expected_dir}" "${AMNEZIAWG_DIR}" "/root" "/home/${client}"; do
            if [[ -f "${dir}/${cfg_file}" ]]; then
                client_files+=("${dir}/${cfg_file}")
            fi
        done
        for hdir in /home/*; do
            if [[ -d "${hdir}" && -f "${hdir}/${cfg_file}" ]]; then
                client_files+=("${hdir}/${cfg_file}")
            fi
        done
    done

    # Remove duplicates
    local unique_files=()
    if [[ ${#client_files[@]} -gt 0 ]]; then
        while IFS= read -r f; do
            unique_files+=("$f")
        done < <(printf "%s\n" "${client_files[@]}" | sort -u)
    fi

    for cfile in "${unique_files[@]}"; do
        if regenerateClientConfig "${cfile}"; then
            echo "  - Regenerated: ${cfile}"
            client_count=$((client_count + 1))
        fi
    done

    echo ""
    echo -e "${GREEN}Parameters updated successfully!${NC}"
    echo "Updated params in: ${AMNEZIAWG_DIR}/params"
    echo "Regenerated client configurations: ${client_count} file(s)"
    echo ""
    echo -e "${ORANGE}Note: Please update the configuration files or re-scan QR codes on your client devices.${NC}"
}

function changeParameters() {
    if [[ "${AWG_VERSION}" == "1.0" ]]; then
        echo ""
        echo "--- Change parameters ---"
        echo -e "${ORANGE}I1-I5 parameters are only supported in AmneziaWG 2.0 and 3.1.${NC}"
        echo "Current protocol version is 1.0 (Legacy)."
        return 0
    fi

    editIParams
}

function backupSettings() {
    echo ""
    echo "--- Backup AmneziaWG settings ---"

    if [[ ! -f "${SERVER_AWG_CONF}" ]]; then
        echo -e "${RED}Error: Server configuration file not found (${SERVER_AWG_CONF})!${NC}"
        return 1
    fi

    local backup_file
    backup_file="$(pwd)/amneziawg-backup.tar.gz"

    local backup_temp
    backup_temp=$(mktemp -d)
    if [[ ! -d "${backup_temp}" ]]; then
        echo -e "${RED}Error: Failed to create temporary directory for backup.${NC}"
        return 1
    fi

    # 1. Copy params
    cp -f "${AMNEZIAWG_DIR}/params" "${backup_temp}/params"

    # 2. Copy server config
    cp -f "${SERVER_AWG_CONF}" "${backup_temp}/${SERVER_AWG_NIC}.conf"

    # 3. Copy nft.sh if nftables is used or file exists
    if [[ -f "${AMNEZIAWG_DIR}/nft.sh" ]]; then
        cp -f "${AMNEZIAWG_DIR}/nft.sh" "${backup_temp}/nft.sh"
    fi

    # 4. Find and copy client config files (only those registered in server config)
    mkdir -p "${backup_temp}/clients"

    local client_names
    client_names=$(grep -E "^### Client " "${SERVER_AWG_CONF}" | awk '{print $3}')
    for client in ${client_names}; do
        local cfg_file="${SERVER_AWG_NIC}-client-${client}.conf"
        local expected_dir
        expected_dir=$(getDirForClientConfig "${client}")
        if [[ -f "${expected_dir}/${cfg_file}" ]]; then
            cp -f "${expected_dir}/${cfg_file}" "${backup_temp}/clients/"
        elif [[ -f "${AMNEZIAWG_DIR}/${cfg_file}" ]]; then
            cp -f "${AMNEZIAWG_DIR}/${cfg_file}" "${backup_temp}/clients/"
        elif [[ -f "/root/${cfg_file}" ]]; then
            cp -f "/root/${cfg_file}" "${backup_temp}/clients/"
        elif [[ -f "$(pwd)/${cfg_file}" ]]; then
            cp -f "$(pwd)/${cfg_file}" "${backup_temp}/clients/"
        else
            for hdir in /home/*; do
                if [[ -d "${hdir}" && -f "${hdir}/${cfg_file}" ]]; then
                    cp -f "${hdir}/${cfg_file}" "${backup_temp}/clients/"
                    break
                fi
            done
        fi
    done

    local client_count
    client_count=$(find "${backup_temp}/clients" -type f -name "*.conf" 2>/dev/null | wc -l)

    # 5. Create archive
    if tar -czf "${backup_file}" -C "${backup_temp}" .; then
        chmod 600 "${backup_file}"
        if [[ -n "${SUDO_USER}" && "${SUDO_USER}" != "root" ]]; then
            chown "${SUDO_USER}:${SUDO_USER}" "${backup_file}" 2>/dev/null || true
        fi
        echo ""
        echo -e "${GREEN}Backup created successfully!${NC}"
        echo "Archive: ${backup_file}"
        echo "Archive contents:"
        echo "  - params"
        echo "  - ${SERVER_AWG_NIC}.conf"
        [[ -f "${backup_temp}/nft.sh" ]] && echo "  - nft.sh"
        echo "  - Client configs: ${client_count} found and backed up"
    else
        echo -e "${RED}Error: Failed to create archive.${NC}"
        rm -rf "${backup_temp}"
        return 1
    fi

    rm -rf "${backup_temp}"
}

function restoreSettings() {
    echo ""
    echo "--- Restore AmneziaWG settings ---"

    local backup_file
    backup_file="$(pwd)/amneziawg-backup.tar.gz"

    if [[ ! -f "${backup_file}" ]]; then
        echo -e "${RED}Backup archive not found: ${backup_file}${NC}"
        echo "Please make sure 'amneziawg-backup.tar.gz' is located in the current directory ($(pwd))."
        return 1
    fi

    echo "Found backup archive: ${backup_file}"

    # Verify tar.gz archive
    if ! tar -tzf "${backup_file}" >/dev/null 2>&1; then
        echo -e "${RED}Error: The file is not a valid .tar.gz archive.${NC}"
        return 1
    fi

    local restore_temp
    restore_temp=$(mktemp -d)
    if [[ ! -d "${restore_temp}" ]]; then
        echo -e "${RED}Error: Failed to create temporary directory for extraction.${NC}"
        return 1
    fi

    if ! tar -xzf "${backup_file}" -C "${restore_temp}"; then
        echo -e "${RED}Error: Failed to extract archive.${NC}"
        rm -rf "${restore_temp}"
        return 1
    fi

    if [[ ! -f "${restore_temp}/params" ]]; then
        echo -e "${RED}Error: Archive does not contain 'params' file! Restore aborted.${NC}"
        rm -rf "${restore_temp}"
        return 1
    fi

    local restored_nic
    restored_nic=$(grep -E '^SERVER_AWG_NIC=' "${restore_temp}/params" | cut -d '=' -f 2 | tr -d '"'\'' ')
    restored_nic="${restored_nic:-awg0}"

    if [[ ! -f "${restore_temp}/${restored_nic}.conf" ]]; then
        local found_conf
        found_conf=$(find "${restore_temp}" -maxdepth 1 -name "*.conf" ! -name "*-client-*" | head -n 1)
        if [[ -n "${found_conf}" ]]; then
            cp -f "${found_conf}" "${restore_temp}/${restored_nic}.conf"
        else
            echo -e "${RED}Error: Archive does not contain server config (${restored_nic}.conf)! Restore aborted.${NC}"
            rm -rf "${restore_temp}"
            return 1
        fi
    fi

    local restored_store_client
    restored_store_client=$(grep -E '^STORE_CLIENT=' "${restore_temp}/params" | cut -d '=' -f 2 | tr -d '"'\'' ')
    restored_store_client="${restored_store_client:-y}"

    echo ""
    echo -e "${ORANGE}WARNING: Restoring will overwrite current AmneziaWG configuration and client settings.${NC}"
    echo "Restoring server interface: ${restored_nic}"
    echo "Client storage mode (STORE_CLIENT): ${restored_store_client}"
    local confirm_restore=""
    read -rp "Are you sure you want to proceed? [y/n]: " -e confirm_restore || fail "Input closed; rerun the script from an interactive terminal."
    if [[ "${confirm_restore,,}" != "y" ]]; then
        echo "Restore cancelled."
        rm -rf "${restore_temp}"
        return 0
    fi

    # Stop active service
    if [[ -n "${SERVER_AWG_NIC}" ]] && systemctl is-active --quiet "awg-quick@${SERVER_AWG_NIC}" 2>/dev/null; then
        systemctl stop "awg-quick@${SERVER_AWG_NIC}" 2>/dev/null || true
    fi
    if [[ "${restored_nic}" != "${SERVER_AWG_NIC}" ]] && systemctl is-active --quiet "awg-quick@${restored_nic}" 2>/dev/null; then
        systemctl stop "awg-quick@${restored_nic}" 2>/dev/null || true
    fi

    # Ensure AMNEZIAWG_DIR exists
    mkdir -p "${AMNEZIAWG_DIR}"
    chmod 700 "${AMNEZIAWG_DIR}"

    # 1. Restore params
    cp -f "${restore_temp}/params" "${AMNEZIAWG_DIR}/params"
    chmod 600 "${AMNEZIAWG_DIR}/params"
    echo "  - Restored params to ${AMNEZIAWG_DIR}/params"

    # 2. Restore server config
    cp -f "${restore_temp}/${restored_nic}.conf" "${AMNEZIAWG_DIR}/${restored_nic}.conf"
    chmod 600 "${AMNEZIAWG_DIR}/${restored_nic}.conf"
    echo "  - Restored server config to ${AMNEZIAWG_DIR}/${restored_nic}.conf"

    # 3. Restore nft.sh if present
    if [[ -f "${restore_temp}/nft.sh" ]]; then
        cp -f "${restore_temp}/nft.sh" "${AMNEZIAWG_DIR}/nft.sh"
        chmod 755 "${AMNEZIAWG_DIR}/nft.sh"
        echo "  - Restored nftables script to ${AMNEZIAWG_DIR}/nft.sh"
    fi

    # 4. Restore client configs with respect to STORE_CLIENT from backup
    local client_count=0
    while IFS= read -r -d '' client_file; do
        local client_file_base
        client_file_base=$(basename "${client_file}")
        local cname=""
        if [[ "${client_file_base}" =~ ^.*-client-(.+)\.conf$ ]]; then
            cname="${BASH_REMATCH[1]}"
        fi

        local target_dir
        if [[ "${restored_store_client}" == 'y' ]]; then
            target_dir="${AMNEZIAWG_DIR}"
        else
            target_dir=$(getHomeDirForClient "${cname}")
        fi

        mkdir -p "${target_dir}"
        cp -f "${client_file}" "${target_dir}/${client_file_base}"
        chmod 600 "${target_dir}/${client_file_base}"
        if [[ -n "${SUDO_USER}" && "${SUDO_USER}" != "root" && "${target_dir}" == /home/* ]]; then
            chown "${SUDO_USER}:${SUDO_USER}" "${target_dir}/${client_file_base}" 2>/dev/null || true
        fi
        echo "  - Restored client config: ${client_file_base} -> ${target_dir}/"
        client_count=$((client_count + 1))
    done < <(find "${restore_temp}" -type f -name "*-client-*.conf" -print0)

    rm -rf "${restore_temp}"

    # Reload variables from restored params
    loadParams

    # Restart AmneziaWG service
    echo ""
    echo "Restarting AmneziaWG service..."
    systemctl daemon-reload
    systemctl restart "awg-quick@${SERVER_AWG_NIC}" 2>/dev/null || true
    if systemctl is-active --quiet "awg-quick@${SERVER_AWG_NIC}"; then
        echo -e "${GREEN}AmneziaWG (${SERVER_AWG_NIC}) is active and running!${NC}"
    else
        echo -e "${ORANGE}Service restart finished. You can verify status with: systemctl status awg-quick@${SERVER_AWG_NIC}${NC}"
    fi

    echo ""
    echo -e "${GREEN}Restore completed successfully!${NC}"
    echo "Total client configs restored: ${client_count}"
}

function manageMenu() {
    echo "AmneziaWG server installer (https://github.com/romikb/amneziawg-install)"
    echo ""
    echo "It looks like AmneziaWG is already installed."
    echo ""
    echo "What do you want to do?"
    echo "   1) Add a new user"
    echo "   2) List all users"
    echo "   3) Revoke existing user"
    echo "   4) Show client QR code"
    echo "   5) Change parameters"
    echo "   6) Uninstall AmneziaWG"
    echo "   7) Backup settings"
    echo "   8) Restore settings"
    echo "   9) Exit"
    until [[ ${MENU_OPTION} =~ ^[1-9]$ ]]; do
        read -rp "Select an option [1-9]: " MENU_OPTION || fail "Input closed; rerun the script from an interactive terminal."
    done
    case "${MENU_OPTION}" in
    1)
        newClient
        ;;
    2)
        listClients
        ;;
    3)
        revokeClient
        ;;
    4)
        showClientQR
        ;;
    5)
        changeParameters
        ;;
    6)
        uninstallAmneziaWG
        ;;
    7)
        backupSettings
        ;;
    8)
        restoreSettings
        ;;
    9)
        exit 0
        ;;
    esac
}

function repairAmneziaWG() {
    local params_file="${AMNEZIAWG_DIR}/params"
    if [[ ! -f "$params_file" ]]; then params_file="${AMNEZIAWG_DIR}/params.pending"; fi
    [[ -f "$params_file" ]] || fail "No saved params found. Run without --repair for setup."
    loadParams "$params_file"
    [[ -n "$SERVER_AWG_NIC" && -s "$SERVER_AWG_CONF" ]] || fail "Saved server config is missing; restore a backup."
    grep -Eq '^PrivateKey[[:space:]]*=[[:space:]]*[^[:space:]]+' "$SERVER_AWG_CONF" || fail "Saved server private key is empty; restore a valid configuration."
    set -Ee
    trap 'setupError "$?" "$LINENO"' ERR
    trap 'rollbackSetup "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    umask 077
    installPackages
    enableForwarding
    startAmneziaWG
    if [[ "$params_file" == *.pending ]]; then mv -f "$params_file" "${AMNEZIAWG_DIR}/params"; fi
    SETUP_NETWORK_STARTED=n
    trap - ERR EXIT INT TERM
    set +e
    echo "Packages/module checked and service restarted; existing keys, clients and VPN subnet preserved."
}

function main() {
    case "${1:-}" in
        ""|--repair) ;;
        --help|-h)
            echo "AmneziaWG installer ${SCRIPT_VERSION}"
            echo "Usage: bash aw.sh [--repair]"
            echo "Default: install or manage clients. --repair: repair packages/module and restart saved configuration."
            return 0 ;;
        *) fail "Unknown option: $1 (use --help)" ;;
    esac
    initialCheck
    umask 077
    if [[ "${1:-}" == --repair ]]; then
        repairAmneziaWG
    elif [[ -e "${AMNEZIAWG_DIR}/params" ]]; then
        loadParams
        manageMenu
    elif [[ -f "${AMNEZIAWG_DIR}/params.pending" ]]; then
        echo "An incomplete setup was found. Resuming it with the saved keys and subnet."
        repairAmneziaWG
    else
        installAmneziaWG
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
