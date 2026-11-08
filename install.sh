#!/usr/bin/env bash
# =============================================================================
# OCI Worker - Smart Installer (v2)
# -----------------------------------------------------------------------------
# Friendly interactive installer with the following features:
#   * First-install wizard: JDK / DB / port / systemd / firewall
#   * Upgrade mode (auto-detected): only refresh JAR; does not touch
#     application.yml or the database.
#   * 1Panel / Aapanel friendly: supports "use existing MySQL" branch with
#     connectivity / charset / version / privilege auto-checks.
#   * Atomic config writes with .bak rollback if the new config breaks startup.
#
# This script is an independent installer for OCI Worker.
# It does NOT modify anything outside /opt/oci-worker, /etc/systemd/system,
# /usr/local/bin/ociworker.
#
# Run as root:
#   bash <(curl -fsSL https://github.com/OCIworker/OCIworker/releases/download/installer-latest/install.sh)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants (DO NOT change unless backend code changes accordingly)
# -----------------------------------------------------------------------------
readonly INSTALL_DIR="/opt/oci-worker"
readonly KEYS_DIR="${INSTALL_DIR}/keys"
readonly BACKUP_DIR="${INSTALL_DIR}/backups"
readonly JAR_NAME="oci-worker.jar"
readonly JAR_ASSET="oci-worker-1.0.0.jar"
readonly CONFIG_FILE="${INSTALL_DIR}/application.yml"
readonly SERVICE_NAME="oci-worker"
# 新安装的默认面板端口。早期版本用 8818，与另一个同类项目相同，其漏洞被公开后
# 出现了针对 8818 的定向扫描，本项目用户会被一并波及，故换到冷门端口。
# 升级不会改动既有 application.yml，存量部署仍保持原端口。
readonly DEFAULT_WEB_PORT="6699"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly WEB_THREAD_DROPIN="/etc/systemd/system/${SERVICE_NAME}.service.d/30-platform-web-threads.conf"
readonly LEGACY_TERMINAL_BIN="${INSTALL_DIR}/oci-webssh"
readonly LEGACY_TERMINAL_SERVICE="oci-webssh"
readonly LEGACY_TERMINAL_CONTAINER="webssh"

readonly REPO="OCIworker/OCIworker"
readonly JAR_RELEASE_TAG="latest"
readonly INSTALLER_RELEASE_TAG="installer-latest"
readonly RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"

readonly OCIWORKER_BIN="/usr/local/bin/ociworker"
TMP_DIR="$(mktemp -d -t oci-worker-installer.XXXXXX)" \
    || { printf '[ERROR] 无法创建安装器临时目录\n' >&2; exit 1; }
readonly TMP_DIR
UPGRADE_LOCK_FALLBACK=""

# JDK 21 (Adoptium Temurin)
readonly JDK_VERSION="21.0.12.1+1"
readonly JDK_VERSION_URLENC="21.0.12.1%2B1"
readonly JDK_VERSION_FILE="21.0.12.1_1"
readonly JDK_INSTALL_BASE="/opt/java"

# -----------------------------------------------------------------------------
# Cleanup on exit
# -----------------------------------------------------------------------------
cleanup() {
    if [ -n "${UPGRADE_LOCK_FALLBACK}" ]; then
        rmdir "${UPGRADE_LOCK_FALLBACK}" 2>/dev/null || true
    fi
    rm -rf "${TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_RED="$(tput setaf 1)"; C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"
    C_BLUE="$(tput setaf 4)"; C_CYAN="$(tput setaf 6)"; C_BOLD="$(tput bold)"; C_RESET="$(tput sgr0)"
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

info()    { printf "%s[INFO]%s %s\n" "${C_BLUE}" "${C_RESET}" "$*"; }
ok()      { printf "%s[ OK ]%s %s\n" "${C_GREEN}" "${C_RESET}" "$*"; }
warn()    { printf "%s[WARN]%s %s\n" "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()     { printf "%s[ERR ]%s %s\n" "${C_RED}" "${C_RESET}" "$*" >&2; }
die()     { err "$*"; exit 1; }
section() { printf "\n%s%s== %s ==%s\n" "${C_BOLD}" "${C_CYAN}" "$*" "${C_RESET}"; }

# Read a value with default. Use stderr for the prompt so command substitution works.
ask() {
    local prompt="$1" default="${2:-}" reply
    if [ -n "${default}" ]; then
        printf "%s [%s]: " "${prompt}" "${default}" >&2
    else
        printf "%s: " "${prompt}" >&2
    fi
    IFS= read -r reply </dev/tty || reply=""
    if [ -z "${reply}" ]; then
        printf "%s" "${default}"
    else
        printf "%s" "${reply}"
    fi
}

ask_password() {
    local prompt="$1" reply
    printf "%s: " "${prompt}" >&2
    IFS= read -r -s reply </dev/tty || reply=""
    printf "\n" >&2
    printf "%s" "${reply}"
}

ask_yes_no() {
    # ask_yes_no "prompt" Y|N    -> echoes "y" or "n"
    local prompt="$1" default="${2:-Y}" hint reply
    case "${default}" in
        Y|y) hint="[Y/n]" ;;
        N|n) hint="[y/N]" ;;
        *)   hint="[y/n]" ;;
    esac
    while true; do
        printf "%s %s: " "${prompt}" "${hint}" >&2
        IFS= read -r reply </dev/tty || reply=""
        reply="${reply:-${default}}"
        case "${reply}" in
            Y|y|YES|yes|Yes) printf "y"; return 0 ;;
            N|n|NO|no|No)    printf "n"; return 0 ;;
            *) warn "请输入 y 或 n" ;;
        esac
    done
}

ask_choice() {
    # ask_choice "prompt" default_index "opt1" "opt2" ...
    local prompt="$1" default="$2"; shift 2
    local options=("$@") i reply
    printf "\n%s\n" "${prompt}" >&2
    for i in "${!options[@]}"; do
        printf "  %d) %s\n" "$((i+1))" "${options[$i]}" >&2
    done
    while true; do
        printf "请选择 [%s]: " "${default}" >&2
        IFS= read -r reply </dev/tty || reply=""
        reply="${reply:-${default}}"
        if [[ "${reply}" =~ ^[0-9]+$ ]] && [ "${reply}" -ge 1 ] && [ "${reply}" -le "${#options[@]}" ]; then
            printf "%s" "${reply}"
            return 0
        fi
        warn "请输入 1-${#options[@]} 的数字"
    done
}

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "请以 root 身份运行：sudo bash install.sh"
    fi
}

require_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        die "未检测到 systemd，本脚本只支持基于 systemd 的 Linux（Debian/Ubuntu/CentOS 等）"
    fi
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) die "不支持的 CPU 架构：${arch}（仅支持 amd64 和 arm64）" ;;
    esac
}

# Returns "x64" or "aarch64" for Adoptium download URL
detect_jdk_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *) die "不支持的 CPU 架构" ;;
    esac
}

detect_pkg_mgr() {
    if   command -v apt-get >/dev/null 2>&1; then echo "apt"
    elif command -v dnf     >/dev/null 2>&1; then echo "dnf"
    elif command -v yum     >/dev/null 2>&1; then echo "yum"
    else echo "none"
    fi
}

# Install a list of packages using whatever PM is available.
pkg_install() {
    local pm
    pm="$(detect_pkg_mgr)"
    case "${pm}" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
             DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
        dnf) dnf install -y -q "$@" ;;
        yum) yum install -y -q "$@" ;;
        *)   warn "未识别的包管理器，跳过安装：$*" ;;
    esac
}

ensure_cmd() {
    # ensure_cmd <cmd> [pkg-name]
    local cmd="$1" pkg="${2:-$1}"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        info "未找到 ${cmd}，尝试安装 ${pkg}..."
        pkg_install "${pkg}" || warn "安装 ${pkg} 失败，请手动安装后重试"
    fi
}

docker_service_start() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable docker >/dev/null 2>&1 || true
        systemctl start docker >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service docker start >/dev/null 2>&1 || true
    fi
}

install_docker_engine_apt_distro() {
    warn "改用系统 docker.io 包安装 Docker..."
    rm -f /etc/apt/sources.list.d/ociworker-docker.list
    DEBIAN_FRONTEND=noninteractive apt-get update -qq \
        || warn "apt-get update 失败，将尝试使用现有软件包缓存继续安装 docker.io"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io
}

docker_official_apt_codename_supported() {
    # Known Docker APT channels. Unknown codenames use distro docker.io instead.
    # Debian 11/12/13: bullseye/bookworm/trixie
    # Ubuntu 20.04/22.04/24.04: focal/jammy/noble
    local repo_os="$1" codename="$2"
    case "${repo_os}:${codename}" in
        debian:bullseye|debian:bookworm|debian:trixie) return 0 ;;
        ubuntu:focal|ubuntu:jammy|ubuntu:noble) return 0 ;;
        *) return 1 ;;
    esac
}

install_docker_engine_apt() {
    local os_id="" os_like="" codename="" repo_os="" arch="" docker_list="/etc/apt/sources.list.d/ociworker-docker.list"
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-}"
        os_like="${ID_LIKE:-}"
        codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    fi

    case "${os_id}" in
        ubuntu) repo_os="ubuntu" ;;
        debian) repo_os="debian" ;;
        *)
            if printf '%s' " ${os_like} " | grep -qw "ubuntu"; then
                repo_os="ubuntu"
            elif printf '%s' " ${os_like} " | grep -qw "debian"; then
                repo_os="debian"
            else
                install_docker_engine_apt_distro
                return $?
            fi
            ;;
    esac
    if [ -z "${codename}" ]; then
        install_docker_engine_apt_distro
        return $?
    fi
    if ! docker_official_apt_codename_supported "${repo_os}" "${codename}"; then
        warn "当前 ${repo_os}/${codename} 不在安装器内置 Docker 官方源白名单，改用系统 docker.io 包。"
        install_docker_engine_apt_distro
        return $?
    fi

    info "使用 Docker 官方 ${repo_os}/${codename} APT 源安装 Docker Engine..."
    warn "本项目不需要 docker-model-plugin；为避免部分 Debian/Ubuntu 找不到该可选包，安装器不会安装它。"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq \
        || warn "apt-get update 失败，将继续尝试安装 Docker 必需依赖"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl gnupg; then
        install_docker_engine_apt_distro
        return $?
    fi
    install -m 0755 -d /etc/apt/keyrings
    if ! curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 \
            "https://download.docker.com/linux/${repo_os}/gpg" \
            -o /etc/apt/keyrings/docker.asc; then
        install_docker_engine_apt_distro
        return $?
    fi
    chmod a+r /etc/apt/keyrings/docker.asc
    arch="$(dpkg --print-architecture)"
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
        "${arch}" "${repo_os}" "${codename}" > "${docker_list}"
    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
        install_docker_engine_apt_distro
        return $?
    fi

    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        return 0
    fi

    if command -v docker >/dev/null 2>&1; then
        return 0
    fi
    install_docker_engine_apt_distro
}

install_docker_engine_rpm_distro() {
    local pm="$1"
    warn "改用系统仓库 Docker 包安装..."
    rm -f /etc/yum.repos.d/ociworker-docker.repo
    ${pm} makecache -q >/dev/null 2>&1 || true
    ${pm} install -y -q docker || ${pm} install -y -q moby-engine
}

docker_official_rpm_repo_os() {
    local os_id="$1" os_like="$2"
    case "${os_id}" in
        rhel) echo "rhel"; return 0 ;;
        centos|rocky|almalinux|ol|oraclelinux) echo "centos"; return 0 ;;
        *)
            if printf '%s' " ${os_like} " | grep -Eqw "rhel|centos|fedora"; then
                echo "centos"
                return 0
            fi
            return 1
            ;;
    esac
}

docker_official_rpm_major_supported() {
    local repo_os="$1" major="$2"
    case "${repo_os}:${major}" in
        centos:7|centos:8|centos:9|rhel:8|rhel:9) return 0 ;;
        *) return 1 ;;
    esac
}

install_docker_engine_rpm() {
    local pm="$1" os_id="" os_like="" version_id="" major="" repo_os="" repo_file="/etc/yum.repos.d/ociworker-docker.repo"
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-}"
        os_like="${ID_LIKE:-}"
        version_id="${VERSION_ID:-}"
    fi
    major="${version_id%%.*}"
    if ! repo_os="$(docker_official_rpm_repo_os "${os_id}" "${os_like}")" || [ -z "${major}" ]; then
        install_docker_engine_rpm_distro "${pm}"
        return $?
    fi
    if ! docker_official_rpm_major_supported "${repo_os}" "${major}"; then
        warn "当前 ${os_id:-rpm}/${version_id:-unknown} 不在安装器内置 Docker 官方 RPM 源白名单，改用系统仓库。"
        install_docker_engine_rpm_distro "${pm}"
        return $?
    fi

    info "使用 Docker 官方 ${repo_os}/${major} RPM 源安装 Docker Engine..."
    warn "本项目不需要 docker-model-plugin；安装器只安装 Docker Engine 与 Compose 插件等必要包。"
    ${pm} install -y -q ca-certificates curl || {
        install_docker_engine_rpm_distro "${pm}"
        return $?
    }
    printf '%s\n' \
        '[docker-ce-stable]' \
        'name=Docker CE Stable - $basearch' \
        "baseurl=https://download.docker.com/linux/${repo_os}/${major}/\$basearch/stable" \
        'enabled=1' \
        'gpgcheck=1' \
        "gpgkey=https://download.docker.com/linux/${repo_os}/gpg" \
        > "${repo_file}"
    ${pm} makecache -q >/dev/null 2>&1 || {
        install_docker_engine_rpm_distro "${pm}"
        return $?
    }
    if ${pm} install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        return 0
    fi
    install_docker_engine_rpm_distro "${pm}"
}

install_docker_engine() {
    local pm
    pm="$(detect_pkg_mgr)"
    case "${pm}" in
        apt)
            install_docker_engine_apt \
                || die "Docker 安装失败。Debian/Ubuntu 可手动执行：apt-get update && apt-get install -y docker.io && systemctl enable --now docker"
            ;;
        dnf|yum)
            install_docker_engine_rpm "${pm}" || {
                warn "RPM 官方源和系统仓库均未完成 Docker 安装，最后尝试 Docker 官方便捷脚本兜底..."
                ensure_cmd curl
                curl -fsSL https://get.docker.com | sh \
                    || die "Docker 安装失败。请先手动安装 Docker Engine 后重跑安装器。"
            }
            ;;
        *)
            die "未识别的包管理器，请先手动安装 Docker Engine 后重跑安装器。"
            ;;
    esac
}

ensure_docker_ready() {
    if ! command -v docker >/dev/null 2>&1; then
        info "未检测到 Docker，正在安装..."
        install_docker_engine
    fi

    if ! docker info >/dev/null 2>&1; then
        info "Docker 已安装，正在启动 Docker 服务..."
        docker_service_start
    fi

    if ! docker info >/dev/null 2>&1; then
        warn "检测到 docker 命令，但 Docker 服务仍不可用，尝试重新安装/修复 Docker Engine..."
        install_docker_engine
        docker_service_start
    fi

    if ! docker info >/dev/null 2>&1; then
        die "Docker 服务不可用。请检查：systemctl status docker"
    fi
    ok "Docker 已可用"
}

# -----------------------------------------------------------------------------
# Mode detection
# -----------------------------------------------------------------------------
detect_mode() {
    if [ -f "${CONFIG_FILE}" ] && [ -f "${INSTALL_DIR}/${JAR_NAME}" ]; then
        echo "upgrade"
    else
        echo "install"
    fi
}

# -----------------------------------------------------------------------------
# JDK 21
# -----------------------------------------------------------------------------
java_version_line() {
    local executable="${1:-java}" output
    command -v "${executable}" >/dev/null 2>&1 || return 1
    output="$("${executable}" -version 2>&1)" || return 1
    printf '%s\n' "${output}" | sed -n '1p'
}

java_is_supported() {
    local version
    version="$(java_version_line "$1" | sed -n 's/.*"\([^"]*\)".*/\1/p')"
    [[ "${version}" =~ ^21\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || return 1
    [ "$(printf '%s\n' '21.0.12.1' "${version}" | sort -V | head -n 1)" = '21.0.12.1' ]
}

patch_java_blocklist() {
    local executable="$1" settings java_home target candidate required
    settings="$("${executable}" -XshowSettings:properties -version 2>&1)" || die "无法检查 Java 运行时：${executable}"
    java_home="$(printf '%s\n' "${settings}" | sed -n 's/^[[:space:]]*java.home = //p' | tr -d '\r')"
    [ -n "${java_home}" ] && [ -d "${java_home}/lib/security" ] || die "无法确定 Java 证书黑名单目录"
    target="${java_home}/lib/security/blocked.certs"
    # OS packages may deliberately symlink this file; update its resolved target.
    target="$(readlink -f "${target}")" || die "无法解析 Java 证书黑名单路径"
    required="${TMP_DIR}/blocked.certs.required"
    cat > "${required}" <<'OCI_BLOCKED_CERTS'
Algorithm=SHA-256
0164D7CEAE5BB909C272AF151FF44B1177AE9B47D9424B94F1D9558C30934D19
03DB9E5E79FE6117177F81C11595AF598CB176AF766290DBCEB2C318B32E39A2
08C396C006A21055D00826A5781A5CCFCE2C8D053AB3C197637A4A7A5BB9A650
10E7E5BFDB55CFB78D0C21366654046182087A1960C079682513795665AA0C6B
14E6D2764A4B06701C6CBC376A253775F79C782FBCB6C0EE6F99DE4BA1024ADD
169A0523C5E071AA4E298286DBD4EE0E40C8C06ABB6B0C077D132F001FA19240
1C5E6985ACC09221DBD1A4B7BBC6D3A8C3F8540D19F20763A9537FDD42B4FFE7
1F6BF8A3F2399AF7FD04516C2719C566CBAD51F412738F66D0457E1E6BDE6F2D
21182E577E5106B669322ABE6086FFF6B101E8C83FD2D01DC32D854961AAC832
2A464E4113141352C7962FBD1706ED4B88533EF24D7BBA6CCC5D797FD202F1C4
31C8FD37DB9B56E708B03D1F01848B068C6DA66F36FB5D82C008C6040FA3E133
33C1BCDC6DA52DF950B3B14121127DA1955F7F31F828497A7608986EB2DDCC09
37E866582D43C35D7C17D47794B974F291B3047B868DC123382477F7A08AEFA8
3946901F46B0071E90D78279E82FABABCA177231A704BE72C5B0E8918566EA66
3B88E4B77FC53C45CA216700E39FC0EA7621A0A40FCB268215082E35D2BD5829
3C5456D4219BA2372273867FAC9A07104600391E96C7FDCDE3B4420C0F1F69BF
3E11CF90719F6FB44D94EAC9A156B89BEBE7B8598F28EC58913F2BFCAF91D0C0
423279423B9FC8CB06F1BB7C3B247522B948D5F18939F378ECC901126DE40BFB
42C4ACCD12C4F59597925E1A08A7A90102608543809308D50EC427E118BA1493
432EC25F0D28DE9006D97BF752F17BBB2CD41F669933FCB072D9A1148D0261F3
450F1B421BB05C8609854884559C323319619E8B06B001EA2DCBB74A23AA3BE2
45A883F349AEDFD5F3A649B5498FFB121712BA8B448F3F2A91DBC5A766FCDDBE
4B2460A466F95FD40113BCDCCA2CEB29B3B093921DE45474DA7DF48874C630B1
4CBBF8256BC9888A8007B2F386940A2E394378B0D903CBB3863C5A6394B889CE
4DED6F955374E40B8558A611A9719B2AB69AA6852AC50966EDC4B07DE4D4277C
4FEE0163686ECBD65DB968E7494F55D84B25486D438E9DE558D629D28CD4D176
50E71B08B9AC407B93D50EE90100CB6B6B41C956DC7AA86C5BAA38AE713CFD6A
535D04DFCE027C70BD5F8A9E0AD4F218E9AFDCF5BBCF9B6DE0D81E148E2E3172
558EC6CA13DA9B800FEDC9ACC3C18CA98BB19768F1309B60B5BB89793B3481CB
568FAF38D9F155F624838E2181B1CEB4D8459305EE652B0F810C97C3611BFE19
579480AEA166290BD3C643589E795FC0D0E54E86505D180F1DFF99EFD3199512
585CFE6B7436CBD4E732763A2137D7F49599BA9B1790E688FCEC799C58EB84A6
59CC5FD35A737B84682EDA26AD23F5ADE8AA847D5BEB3B38AB6CD62347925A66
5D8FC3ECDDB4DDB243AEE5C306BCFDE670ADF2D66B193DD3AA2D6B2FB91869BE
5E83124D68D24E8E177E306DF643D5EA99C5A94D6FC34B072F7544A1CABB7C7B
5F1DED4DD590AF74631290CF073B122A2AAC6A1FA479778A0BD43579BD832699
62B7F9868263F72F6911FC78CEAF72C1979158B7368BF648683BB2AA39B02E72
71CB00749B9130FB2707A2664BFF958D0FCC8E161D9674C7450BA0FC2BEAF9D3
7485B51C0ED192878FA1D2F948FB529AE1842CC5086C4B67F7BE5B2039DE9489
75D8853BE99C87678E6C7BF9F684B31454D81DEB1C7F37B9FBC026A268337536
76A45A496031E4DD2D7ED23E8F6FF97DBDEA980BAAC8B0BA94D7EDB551348645
7BA62FEC54E9D040556FCA70A6A88F03761C178FA1F7CB8390A73076849F55A2
84112972B8E59D14560AE7E7119654474AAD119990CF3722BFC1E3B91615E1FD
8A1BD21661C60015065212CC98B1ABB50DFD14C872A208E66BAE890F25C448AF
8F580C6E34CEE7EE57B93BA9C0AC5FAEDD7BF3085F5EE9C6C0175A2555B111D0
8FED925362F62FFF90DD835BE6ADC32B02DEC8DF5E82D83E512F1C977D066E82
912A48745BFF2F14D1798B27858613DE1C0EB03C2BDE630AFD0DDD5251E1EBE1
98B896625C0C230ADEEC3EB2CF6AAD5001ECF9156A68644E82374CE5833BC25B
9E39DE2881273ACC225A149C72BA3E0F51424963669AB633EE1DC7DF5DB067B4
9E7617035CFF537C837E078A7CDC7FD9EB77BCE7DDF3DC6DBD5C50AAFC1F1FA7
9ED8F9B0E8E42A1656B8E1DD18F42BA42DC06FE52686173BA2FC70E756F207DC
9FADCE80D62A959F9930D748488C1E22E821F4E1E4A43584B848C2FC11E04D77
A0ED2032C5249EE1A653F1F88005D9E779E385DF533B5C521137CEE5176CD7FC
A104B1314DF8E02F7DE27DDC287D0961D6E6824AD4DAFC3D11064F24C1B653D5
A4328E058C867AF9CA8D468C388B72C250CE84BDB6BAF7F8C47C9A0B1CB35EEC
A496E23AC0CAB8155FC9B117B97EAE368EFCBB9041AEC8804D5A308D2D01C2D8
A4B72DBD37256324B557B9176F8CBA4310DDFFBCC4609977E2463F3504A716C8
A61FE79B019062DD3C6420BC20EAF64702CC1063C546A084DD0A0BCB915A14A9
A686FEE577C88AB664D0787ECDFFF035F4806F3DE418DC9E4D516324FFF02083
A90132CEA1D4F7185E4F688EFFD16F6AC14DFD78356A807599A5DABBEEF3333E
AB7292F82267333031F512379FDBADA949DFA49D3C046CC8FA7F34117C342986
B7121039CAF13E03E52507F42DB56FA802FF119DA7591ABA8A2E842133DB7C9C
B75104427B6A5BE55033AF50DC0FE3102181BE130E761D487A4E8178C93317DD
B8686723E415534BC0DBD16326F9486F85B0B0799BF6639334E61DAAE67F36CD
C0D1F42B9F4BF7ACC045B7BB5D4805E10737F67B6310CE505248D543D0D5FE07
C5F1531C6331659C75A6411A088A65DAD7518FD91F57B64537A651B6DCD76AE0
C65CBC98295549BA940494A6214B9706E7115E64F3FE269412C5B48AEACB2222
C93F7B1EEF27CFD0F227DFE3F057D63833533890B7230B1821A424BD40848E33
CB6E15165AC802E9B3F993F16C25D41F4E81C21EBDE71AE1B012AC00BF9C7C3F
CD740652E552D93EE64D7C9D1CC25228E466895889CEE25A11C962AB09906978
D0156949F1381943442C6974E9B5B49EF441BB799EF20477B90A89C3F33620CE
D151962D954970501C60079258EBCFA38502E0A9F03CD640322B08C0A3117FE5
D24566BF315F4E597D6E381C87119FB4198F5E9E2607F5F4AB362EF7E2E7672F
D3A936E1A7775A45217C8296A1F22AC5631DCDEC45594099E78EEEBBEDCBA967
D6CEAE5D9E047FAF7D797858D229AC991AD44316D1E2A37A21926D763153593A
D8A50FA0068E9558E6C3BEE18CDB03B7EECBC3C56C1B2336B98AEE11644994B8
DF21016B00FC54F9FE3BC8B039911BB216E9162FAD2FD14D990AB96E951B49BE
E0E740E4B0F8B3548181FF75B5372FAF4C70B99EC995D694ED0FB91B03FF8D21
E7568FE6E12331F4FD7DE61DA4C7559D0F8EB192A218D4741A3BA75184333838
EC30C9C3065A06BB07DC5B1C6B497F370C1CA65C0F30C08E042BA6BCECC78F2C
EF34030C01B13BF42B534072DCC3C75B13C009DC9241119ADA39E2C15E2AFD2E
F5B6F88F75D391A4B1EB336F9E201239FB6B1377DB8CFA7B84736216E5AFFFD7
FBB12938ABD86C125796EDF4162D291028890A7D6C0C1CCA75FD4B95EBFA7A1A
FC02FD48DB92D4DCE6F11679D38354CF750CFC7F584A520EB90BDE80E241F2BD
FD9D5C2DBBD4995AB69B8D50C439D9527B00529199C2FD01B2174EB58F07021F
FDEDB5BDFCB67411513A61AEE5CB5B5D7C52AF06028EFC996CC1B05B1D6CEA2B
OCI_BLOCKED_CERTS
    if [ -f "${target}" ]; then
        grep -qx 'Algorithm=SHA-256' "${target}" || die "Java 黑名单不是 SHA-256 格式，已保留原文件，请人工合并"
        if awk 'NR==FNR {if ($0 !~ /^Algorithm=/) required[$0]=1; next}
            {line=$0; sub(/=.*/, "", line); delete required[line]}
            END {for (key in required) exit 1}' "${required}" "${target}"; then
            ok "Java 证书黑名单已包含 CVE-2026-91403 修复：${target}"
            return
        fi
    fi
    candidate="$(mktemp "${target}.ociworker.XXXXXXXX")" || die "无法写入 Java 证书黑名单，请以系统服务权限执行运行时维护"
    if [ -f "${target}" ]; then
        cp -p "${target}" "${candidate}" || die "证书黑名单复制失败"
        if [ ! -e "${target}.before-cve-2026-91403" ]; then
            cp -p "${target}" "${target}.before-cve-2026-91403" || die "证书黑名单备份失败"
        fi
    else
        printf 'Algorithm=SHA-256\n' > "${candidate}"
        chmod 644 "${candidate}"
    fi
    # Append the upstream entries; preserve every existing/custom Java property.
    printf '\n' >> "${candidate}"
    sed '1d' "${required}" >> "${candidate}"
    mv -f "${candidate}" "${target}" || die "证书黑名单替换失败"
    ok "已合并 CVE-2026-91403 证书黑名单；重启 Java 服务后生效"
}

patch_service_java() {
    local service_exec service_java
    command -v systemctl >/dev/null 2>&1 || return 0
    service_exec="$(systemctl show "${SERVICE_NAME}" -p ExecStart --value 2>/dev/null || true)"
    service_java="$(printf '%s\n' "${service_exec}" | sed -n 's/.*path=\([^ ;]*\).*/\1/p')"
    if [ -n "${service_java}" ] && [ "${service_java}" != /usr/local/bin/java ]; then
        case "${service_java}" in
            */java) patch_java_blocklist "${service_java}" ;;
            *) die "服务使用自定义启动器，请人工检查实际 JVM 后再升级：${service_java}" ;;
        esac
    fi
}

install_jdk21() {
    local executable=/usr/local/bin/java
    if [ ! -x "${executable}" ]; then
        executable="$(command -v java || true)"
    fi
    if [ -n "${executable}" ] && java_is_supported "${executable}"; then
        if [ "${executable}" != /usr/local/bin/java ]; then
            ln -sf "$(readlink -f "${executable}")" /usr/local/bin/java
        fi
        patch_java_blocklist /usr/local/bin/java
        patch_service_java
        ok "Java 运行时及证书黑名单已检查：$(java_version_line /usr/local/bin/java)"
        return
    fi
    info "维护 Java 21 (Adoptium Temurin ${JDK_VERSION})..."
    ensure_cmd curl
    ensure_cmd tar
    ensure_cmd sha256sum
    local jdk_arch tmp digest jdk_dir staging
    jdk_arch="$(detect_jdk_arch)"
    tmp="${TMP_DIR}/jdk21.tar.gz"
    case "${jdk_arch}" in
        aarch64) digest="14be1f35ebdbd1f6e8d57eb911a3ffb74d6d9aa255abc5daf2b1302002cf2cf2" ;;
        x64) digest="2413149700df0f7d440500a84a8f764c535f21e5a5e87d38328b64eec2c5b500" ;;
    esac
    if ! curl -fSL --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 600 \
            -o "${tmp}" \
            "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-${JDK_VERSION_URLENC}/OpenJDK21U-jre_${jdk_arch}_linux_hotspot_${JDK_VERSION_FILE}.tar.gz"; then
        die "Java 下载失败，已保留原运行时"
    fi
    printf '%s  %s\n' "${digest}" "${tmp}" | sha256sum -c - || die "Java 下载校验失败，已保留原运行时"
    # Extract into staging so failures cannot damage an existing/running JVM.
    staging="${TMP_DIR}/java-extracted"
    mkdir -p "${staging}" "${JDK_INSTALL_BASE}"
    tar -xzf "${tmp}" -C "${staging}" || die "Java 解压失败"
    jdk_dir="${staging}/jdk-${JDK_VERSION}-jre"
    [ -x "${jdk_dir}/bin/java" ] && java_is_supported "${jdk_dir}/bin/java" || die "Java 解压后版本验证失败"
    patch_java_blocklist "${jdk_dir}/bin/java"
    local destination="${JDK_INSTALL_BASE}/ociworker-jre-${JDK_VERSION}"
    if [ -e "${destination}" ]; then
        java_is_supported "${destination}/bin/java" || die "已有运行时目录版本无效：${destination}"
        patch_java_blocklist "${destination}/bin/java"
    else
        mv "${jdk_dir}" "${destination}" || die "Java 运行时安装失败"
    fi
    ln -sf "${destination}/bin/java" /usr/local/bin/java
    patch_service_java
    ok "Java 安装及证书黑名单维护完成 ($(java_version_line /usr/local/bin/java))"
}

# -----------------------------------------------------------------------------
# Database wizard
# -----------------------------------------------------------------------------
DB_HOST=""; DB_PORT=""; DB_NAME=""; DB_USER=""; DB_PASS=""

docker_mysql_container_up() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "oci-worker-mysql"
}

# Run mysql inside oci-worker-mysql (avoids host MariaDB client vs MySQL 8 quirks on Debian 13+).
mysql_docker_run() {
    local user="$1" pass="$2" db="$3" sql="$4"
    local args=(-u"${user}" -N -B --connect-timeout=5)
    [ -n "${db}" ] && args+=("${db}")
    local out errf err=""
    errf="$(mktemp)"
    out="$(docker exec -e MYSQL_PWD="${pass}" oci-worker-mysql \
        mysql "${args[@]}" -e "${sql}" 2>"${errf}" || true)"
    if [ -s "${errf}" ]; then
        err="$(tr '\n' ' ' < "${errf}" | sed 's/  */ /g')"
    fi
    rm -f "${errf}"
    out="$(printf '%s' "${out}" | tr -d '\r')"
    if [ -n "${out}" ]; then
        printf '%s' "${out}"
        return 0
    fi
    if [ -n "${err}" ]; then
        printf '%s' "${err}"
    fi
}

mysql_output_is_one() {
    local o="$1"
    o="$(printf '%s' "${o}" | tr -d '\r\n[:space:]')"
    [ "${o}" = "1" ]
}

docker_mysql_logs_final_ready() {
    local logs
    logs="$(docker logs --tail=200 oci-worker-mysql 2>&1 || true)"
    grep -qE 'ready for connections.*port: 3306' <<<"${logs}"
}

# Host mysql: keep stderr separate so MariaDB client WARNING lines do not break parsing.
mysql_host_run() {
    local host="$1" port="$2" user="$3" pass="$4" db="$5" sql="$6"
    local args=(-h"${host}" -P"${port}" -u"${user}" -N -B --connect-timeout=5)
    [ -n "${db}" ] && args+=("${db}")
    local out errf err=""
    errf="$(mktemp)"
    out="$(MYSQL_PWD="${pass}" mysql "${args[@]}" -e "${sql}" 2>"${errf}" || true)"
    if [ -s "${errf}" ]; then
        err="$(tr '\n' ' ' < "${errf}" | sed 's/  */ /g')"
    fi
    rm -f "${errf}"
    if [ -n "${out}" ]; then
        printf '%s' "${out}"
        return 0
    fi
    if [ -n "${err}" ]; then
        printf '%s' "${err}"
    fi
}

mysql_cli_run() {
    # mysql_cli_run <host> <port> <user> <pass> <db_or_empty> <sql>
    # Returns query stdout (or error text if query failed with no stdout).
    local host="$1" port="$2" user="$3" pass="$4" db="$5" sql="$6"
    if [ "${host}" = "127.0.0.1" ] && [ "${port}" = "3306" ] && docker_mysql_container_up; then
        mysql_docker_run "${user}" "${pass}" "${db}" "${sql}"
    else
        mysql_host_run "${host}" "${port}" "${user}" "${pass}" "${db}" "${sql}"
    fi
}

mysql_select1_ok() {
    # mysql_select1_ok <host> <port> <user> <pass>  -> 0 if SELECT 1 succeeds
    local out
    out="$(mysql_cli_run "$1" "$2" "$3" "$4" "" "SELECT 1")"
    mysql_output_is_one "${out}"
}

sql_escape_ident() {
    # Backtick-quoted identifier (database name).
    local s="$1"
    s="${s//\`/\`\`}"
    printf '`%s`' "${s}"
}

sql_escape_literal() {
    # Single-quoted SQL string literal (user name or password).
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\'/\'\'}"
    printf "'%s'" "${s}"
}

docker_mysql_select1_status() {
    # ok | auth_fail | conn_wait | wait  (conn_wait/wait = keep polling)
    local out
    if docker_mysql_container_up; then
        out="$(mysql_docker_run "${DB_USER}" "${DB_PASS}" "" "SELECT 1")"
    else
        out="$(mysql_host_run "127.0.0.1" "3306" "${DB_USER}" "${DB_PASS}" "" "SELECT 1")"
    fi
    if mysql_output_is_one "${out}"; then
        echo "ok"
        return 0
    fi
    if echo "${out}" | grep -qiE "Access denied"; then
        echo "auth_fail"
        return 0
    fi
    if echo "${out}" | grep -qiE "Can't connect|Connection refused|timed out|Unknown MySQL server host|ERROR 2002|ERROR 2003"; then
        echo "conn_wait"
        return 0
    fi
    echo "wait"
}

wait_docker_mysql_user() {
    local max_wait=180
    info "等待 MySQL 就绪（最多 ${max_wait} 秒）..."
    local waited=0 status consecutive=0
    while [ "${waited}" -lt "${max_wait}" ]; do
        if ! docker_mysql_logs_final_ready; then
            consecutive=0
            sleep 2
            waited=$((waited + 2))
            printf "." >&2
            continue
        fi
        status="$(docker_mysql_select1_status)"
        case "${status}" in
            ok)
                consecutive=$((consecutive + 1))
                if [ "${consecutive}" -ge 2 ]; then
                    ok "MySQL 已就绪"
                    return 0
                fi
                ;;
            auth_fail)
                printf "\n" >&2
                die "MySQL 已启动，但用户名或密码错误。复用容器时请填写首次创建时的密码；不记得请选重新创建容器（或清空 /opt/oci-worker/data/mysql 后重装）。"
                ;;
            *)
                consecutive=0
                ;;
        esac
        sleep 2
        waited=$((waited + 2))
        printf "." >&2
    done
    printf "\n" >&2
    return 1
}

verify_docker_mysql_credentials() {
    info "验证数据库账号..."
    local probe
    probe="$(probe_database)"
    case "${probe}" in
        ok)
            ok "登录成功"
            ;;
        auth_fail)
            die "无法用当前用户名/密码连接容器内 MySQL（密码须与容器初始化时一致，或选择重新创建容器）"
            ;;
        conn_fail)
            die "无法连接 127.0.0.1:3306，请检查容器：docker logs oci-worker-mysql"
            ;;
        *)
            die "MySQL 返回错误：${probe#other:}"
            ;;
    esac
    check_database_quality || die "数据库自检未通过"
}

ensure_mysql_client() {
    if command -v mysql >/dev/null 2>&1; then
        return 0
    fi
    info "安装 MySQL 客户端（用于数据库自检）..."
    local pm
    pm="$(detect_pkg_mgr)"
    case "${pm}" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq
            # Try mysql-client first, fall back to mariadb-client
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq default-mysql-client 2>/dev/null \
                || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mariadb-client \
                || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mysql-client
            ;;
        dnf|yum)
            ${pm} install -y -q mysql || ${pm} install -y -q mariadb
            ;;
        *)
            warn "无法自动安装 mysql 客户端，将跳过数据库自检（可能踩坑）"
            ;;
    esac
}

probe_database() {
    # Echoes one of: ok | conn_fail | auth_fail | other:<msg>
    local out
    if [ "${DB_HOST}" = "127.0.0.1" ] && [ "${DB_PORT}" = "3306" ] && docker_mysql_container_up; then
        case "$(docker_mysql_select1_status)" in
            ok) echo "ok"; return 0 ;;
            auth_fail) echo "auth_fail"; return 0 ;;
            conn_wait|wait) echo "conn_fail"; return 0 ;;
            *) echo "other:docker probe failed"; return 0 ;;
        esac
    fi
    out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "" "SELECT 1")"
    if mysql_output_is_one "${out}"; then
        echo "ok"; return 0
    fi
    if echo "${out}" | grep -qiE "Can't connect|Connection refused|timed out|Unknown MySQL server host"; then
        echo "conn_fail"; return 0
    fi
    if echo "${out}" | grep -qiE "Access denied"; then
        echo "auth_fail"; return 0
    fi
    echo "other:${out}"
}

check_database_quality() {
    # Pre: DB_* set, connection works.
    # Verifies version, ability to use the database, charset, and DDL privileges.
    # Returns 0 on success, non-zero with messages on failure.
    local out

    # Version check
    out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "" "SELECT VERSION();")"
    if [ -z "${out}" ]; then
        err "无法获取 MySQL 版本：${out}"
        return 1
    fi
    local ver_line ver_major
    ver_line="$(echo "${out}" | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1)"
    ver_major="${ver_line%%.*}"
    if [ -z "${ver_major}" ] || [ "${ver_major}" -lt 8 ]; then
        err "MySQL 版本过低：${out}（需要 8.0+）"
        warn "请在面板/服务器升级到 MySQL 8.0 或更高版本"
        return 1
    fi
    ok "MySQL 版本：${ver_line:-${out}}"

    # Database existence
    out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "" \
            "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';")"
    if [ "${out}" != "${DB_NAME}" ]; then
        warn "数据库 \`${DB_NAME}\` 不存在或当前用户无权访问"
        if [ "$(ask_yes_no "尝试用当前账号自动创建数据库（utf8mb4）？" "Y")" = "y" ]; then
            local create_out
            create_out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "" \
                "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")"
            if [ -n "${create_out}" ]; then
                err "自动创建失败：${create_out}"
                warn "请在面板里手动创建数据库 ${DB_NAME}（字符集 utf8mb4），并授权给用户 ${DB_USER}"
                return 1
            fi
            ok "已创建数据库 ${DB_NAME}"
        else
            warn "请在面板里建库后重试"
            return 1
        fi
    else
        ok "数据库 ${DB_NAME} 已存在"
    fi

    # Charset check (after DB exists)
    out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "${DB_NAME}" \
        "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';")"
    case "${out}" in
        utf8mb4)
            ok "字符集：utf8mb4"
            ;;
        "")
            warn "无法读取字符集信息（可能权限不足），跳过此项"
            ;;
        *)
            warn "字符集为 ${out}，建议改为 utf8mb4 以避免存储 emoji/特殊字符出错"
            if [ "$(ask_yes_no "尝试自动 ALTER DATABASE 修复字符集？" "Y")" = "y" ]; then
                local alter_out
                alter_out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "" \
                    "ALTER DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")"
                if [ -n "${alter_out}" ]; then
                    warn "ALTER 失败（可能权限不足）：${alter_out}"
                    warn "请在面板里把库 ${DB_NAME} 改成 utf8mb4 后重试"
                else
                    ok "已修复字符集"
                fi
            fi
            ;;
    esac

    # Privilege probe: try to create+drop a temp table
    out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "${DB_NAME}" \
        "CREATE TABLE IF NOT EXISTS _ociworker_probe_(id INT) ENGINE=InnoDB; DROP TABLE _ociworker_probe_;")"
    if [ -n "${out}" ]; then
        err "DDL 权限测试失败：${out}"
        warn "请确认用户 ${DB_USER} 对库 ${DB_NAME} 拥有所有权限"
        return 1
    fi
    ok "DDL 权限：通过"
    return 0
}

prompt_db_existing() {
    # User picks existing MySQL (1Panel / Aapanel / pre-installed).
    section "数据库连接配置"
    cat >&2 <<EOF
请确保已在面板里准备好：
  1. 数据库（默认建议名：oci_worker）
  2. 用户（默认建议名：oci_worker）
  3. 字符集 utf8mb4 / utf8mb4_unicode_ci
  4. 用户对该库有所有权限
  5. MySQL 监听端口已暴露到宿主机（127.0.0.1:3306 通常即可）

EOF
    while true; do
        DB_HOST="$(ask "数据库地址" "127.0.0.1")"
        DB_PORT="$(ask "数据库端口" "3306")"
        DB_NAME="$(ask "数据库名"   "oci_worker")"
        DB_USER="$(ask "用户名"     "oci_worker")"
        DB_PASS="$(ask_password "密码")"

        if [ -z "${DB_PASS}" ]; then
            warn "密码不能为空"
            continue
        fi

        info "测试网络连通性 ${DB_HOST}:${DB_PORT}..."
        if command -v nc >/dev/null 2>&1; then
            if ! nc -z -w 5 "${DB_HOST}" "${DB_PORT}" 2>/dev/null; then
                err "无法连接 ${DB_HOST}:${DB_PORT}"
                cat >&2 <<'EOT'
可能原因（按概率排序）：
  1. 面板中 MySQL 容器/服务未启动，或端口未映射到宿主机
  2. 端口不是默认 3306（请在面板查看实际端口）
  3. 防火墙拦截（127.0.0.1 通常不会，远程地址需放行）
EOT
                if [ "$(ask_yes_no "重新输入连接信息？" "Y")" = "y" ]; then continue; fi
                return 1
            fi
            ok "网络连通"
        else
            warn "未安装 nc，跳过端口探测"
        fi

        info "测试登录..."
        local probe; probe="$(probe_database)"
        case "${probe}" in
            ok)
                ok "登录成功"
                ;;
            auth_fail)
                err "登录失败：用户名或密码错误，或 host 限制"
                cat >&2 <<EOT
常见原因：
  * 用户在面板里设置了"本地服务器(localhost)"权限，但脚本用 127.0.0.1 连接，
    MySQL 把 localhost(unix socket) 与 127.0.0.1(TCP) 当作不同 host 处理。
    解决：在面板里把用户的访问权限改为"所有人(%)"，或加一条 127.0.0.1。
  * 密码记错了。
EOT
                if [ "$(ask_yes_no "重新输入连接信息？" "Y")" = "y" ]; then continue; fi
                return 1
                ;;
            conn_fail)
                err "无法建立连接，请检查 MySQL 服务/端口"
                if [ "$(ask_yes_no "重新输入连接信息？" "Y")" = "y" ]; then continue; fi
                return 1
                ;;
            other:*)
                err "MySQL 返回错误：${probe#other:}"
                if [ "$(ask_yes_no "重新输入连接信息？" "Y")" = "y" ]; then continue; fi
                return 1
                ;;
        esac

        if check_database_quality; then
            ok "数据库自检全部通过"
            return 0
        fi

        if [ "$(ask_yes_no "数据库自检未通过，重新输入？" "Y")" = "y" ]; then
            continue
        fi
        return 1
    done
}

prompt_db_docker() {
    # Spin up an isolated MySQL 8.0 in Docker.
    section "Docker MySQL 自动安装"
    ensure_docker_ready
    DB_HOST="127.0.0.1"
    DB_PORT="3306"
    DB_NAME="$(ask "数据库名"   "oci_worker")"
    DB_USER="$(ask "用户名"     "oci_worker")"
    DB_PASS="$(ask_password "新建用户密码（至少 8 位，建议含字母数字）")"
    while [ "${#DB_PASS}" -lt 6 ]; do
        warn "密码太短"
        DB_PASS="$(ask_password "新建用户密码")"
    done
    local root_pass
    root_pass="$(ask_password "root 密码（用于初始化，可与上方相同）")"
    [ -n "${root_pass}" ] || root_pass="${DB_PASS}"

    if docker ps -a --format '{{.Names}}' | grep -qx "oci-worker-mysql"; then
        warn "已存在容器 oci-worker-mysql"
        if [ "$(ask_yes_no "重新创建？（会保留 /opt/oci-worker/data/mysql 数据目录）" "N")" = "y" ]; then
            docker rm -f oci-worker-mysql >/dev/null
        else
            info "复用已有容器"
        fi
    fi

    if docker ps -a --format '{{.Names}}' | grep -qx "oci-worker-mysql"; then
        if ! docker ps --format '{{.Names}}' | grep -qx "oci-worker-mysql"; then
            info "启动已有容器 oci-worker-mysql..."
            docker start oci-worker-mysql >/dev/null || die "启动容器失败：docker start oci-worker-mysql"
            wait_docker_mysql_user || die "MySQL 启动超时，请查看：docker logs oci-worker-mysql"
        fi
        verify_docker_mysql_credentials
        return 0
    fi

    info "启动 MySQL 8.0 容器..."
    mkdir -p /opt/oci-worker/data/mysql
    docker run -d \
        --name oci-worker-mysql \
        --restart always \
        -p 127.0.0.1:3306:3306 \
        -v /opt/oci-worker/data/mysql:/var/lib/mysql \
        -e MYSQL_ROOT_PASSWORD="${root_pass}" \
        -e MYSQL_DATABASE="${DB_NAME}" \
        -e MYSQL_USER="${DB_USER}" \
        -e MYSQL_PASSWORD="${DB_PASS}" \
        -e TZ=Asia/Shanghai \
        mysql:8.0 \
        --character-set-server=utf8mb4 \
        --collation-server=utf8mb4_unicode_ci >/dev/null \
        || die "MySQL 容器启动失败"
    wait_docker_mysql_user || die "MySQL 启动超时，请查看：docker logs oci-worker-mysql"
    verify_docker_mysql_credentials
}

prompt_db_root() {
    # User has MySQL root, let us auto-create db + user.
    section "用 root 自动创建数据库和用户"
    DB_HOST="$(ask "数据库地址" "127.0.0.1")"
    DB_PORT="$(ask "数据库端口" "3306")"
    local root_user root_pass
    root_user="$(ask "root 用户名" "root")"
    root_pass="$(ask_password "root 密码")"

    DB_NAME="$(ask "新建数据库名" "oci_worker")"
    DB_USER="$(ask "新建用户名"   "oci_worker")"
    DB_PASS="$(ask_password "新建用户密码")"
    while [ "${#DB_PASS}" -lt 6 ]; do
        warn "密码太短"
        DB_PASS="$(ask_password "新建用户密码")"
    done

    info "用 root 测试连接..."
    local probe_out
    if mysql_select1_ok "${DB_HOST}" "${DB_PORT}" "${root_user}" "${root_pass}"; then
        ok "root 登录成功"
    else
        probe_out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${root_user}" "${root_pass}" "" "SELECT 1")"
        die "root 登录失败：${probe_out}"
    fi

    info "创建数据库和用户..."
    local db_ident user_lit pass_lit sql_file
    db_ident="$(sql_escape_ident "${DB_NAME}")"
    user_lit="$(sql_escape_literal "${DB_USER}")"
    pass_lit="$(sql_escape_literal "${DB_PASS}")"
    sql_file="$(mktemp)"
    chmod 600 "${sql_file}"
    cat > "${sql_file}" <<EOF
CREATE DATABASE IF NOT EXISTS ${db_ident} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS ${user_lit}@'%' IDENTIFIED BY ${pass_lit};
CREATE USER IF NOT EXISTS ${user_lit}@'localhost' IDENTIFIED BY ${pass_lit};
GRANT ALL PRIVILEGES ON ${db_ident}.* TO ${user_lit}@'%';
GRANT ALL PRIVILEGES ON ${db_ident}.* TO ${user_lit}@'localhost';
ALTER USER ${user_lit}@'%' IDENTIFIED BY ${pass_lit};
ALTER USER ${user_lit}@'localhost' IDENTIFIED BY ${pass_lit};
FLUSH PRIVILEGES;
EOF
    local create_out errf
    errf="$(mktemp)"
    if ! MYSQL_PWD="${root_pass}" mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${root_user}" --connect-timeout=10 \
            < "${sql_file}" 2>"${errf}"; then
        create_out="$(cat "${errf}")"
        rm -f "${sql_file}" "${errf}"
        die "创建数据库/用户失败：${create_out}"
    fi
    rm -f "${errf}"
    rm -f "${sql_file}"
    ok "数据库 ${DB_NAME} 和用户 ${DB_USER} 已创建"

    if ! check_database_quality; then
        die "数据库自检未通过"
    fi
}

run_db_wizard() {
    section "数据库配置"
    local choice
    choice="$(ask_choice "请选择数据库使用方式：" 1 \
        "我已经有 MySQL（1Panel/宝塔/已安装的服务），手动填写连接信息" \
        "我没有数据库，让脚本用 Docker 帮我装一个独立 MySQL 8.0" \
        "我有 MySQL root 账号，让脚本帮我自动建库建用户")"
    ensure_mysql_client
    case "${choice}" in
        1) prompt_db_existing || die "数据库配置未完成，已退出安装。修复连接问题后可重跑 install.sh" ;;
        2) prompt_db_docker   || die "Docker MySQL 安装失败，请查看上方错误信息" ;;
        3) prompt_db_root     || die "用 root 自动建库失败，请查看上方错误信息" ;;
    esac
}

# -----------------------------------------------------------------------------
# Web settings
# -----------------------------------------------------------------------------
# 说明：管理员账号/密码不在脚本里设置。
# 后端 isSetupDone() 只看数据库 oci_kv 表里有没有记录，与 application.yml
# 里的 web.account / web.password 无关——yml 里的两个值只在数据库被清空、
# 用户尚未在浏览器完成 Setup 之前作为兜底默认值存在。
# 因此脚本只需要：
#   1. 收集 Web 端口
#   2. 在 yml 里塞一个占位账号 admin + 随机密码（用户永远不会用到）
#   3. 部署完成后引导用户去 http://ip:port 完成首次设置
WEB_PORT=""
WEB_DEFAULT_ACCOUNT="admin"
WEB_DEFAULT_PASSWORD=""
prompt_web() {
    section "Web 服务配置"
    while true; do
        WEB_PORT="$(ask "OCI Worker Web 端口" "${DEFAULT_WEB_PORT}")"
        if [[ "${WEB_PORT}" =~ ^[0-9]+$ ]] && [ "${WEB_PORT}" -ge 1 ] && [ "${WEB_PORT}" -le 65535 ]; then
            if [ "${WEB_PORT}" -eq 8008 ]; then
                warn "端口 8008 不可用，请换一个"
                continue
            fi
            break
        fi
        warn "端口无效"
    done

    # 32 字节随机十六进制（仅作为 yml 里的占位值，用户实际登录走浏览器 Setup 流程）
    if command -v openssl >/dev/null 2>&1; then
        WEB_DEFAULT_PASSWORD="$(openssl rand -hex 16)"
    else
        WEB_DEFAULT_PASSWORD="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
    fi

    cat >&2 <<EOF

[i] 管理员账号和密码不在 SSH 里设置，等服务起来后请到浏览器完成首次设置：
       http://<your-ip>:${WEB_PORT}
    （后端将在数据库里安全存储 sha256 哈希后的密码）

EOF
}

# -----------------------------------------------------------------------------
# Config / systemd
# -----------------------------------------------------------------------------
yaml_escape() {
    # Escape a string for safe inclusion inside a YAML double-quoted scalar.
    # Order matters: backslash first, then double-quote.
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf "%s" "${s}"
}

write_application_yml() {
    info "生成 application.yml..."
    mkdir -p "${INSTALL_DIR}" "${KEYS_DIR}" "${BACKUP_DIR}"

    if [ -f "${CONFIG_FILE}" ]; then
        cp -p "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%s)"
    fi

    local jdbc_url
    jdbc_url="jdbc:mysql://${DB_HOST}:${DB_PORT}/${DB_NAME}?useUnicode=true&characterEncoding=utf8&useSSL=false&serverTimezone=Asia/Shanghai&allowPublicKeyRetrieval=true"

    cat > "${CONFIG_FILE}" <<EOF
server:
  port: ${WEB_PORT}

web:
  # 仅作为兜底默认值；真实管理员账号/密码请在首次访问 Web 时设置。
  # 设置后会以 sha256 哈希存入数据库 oci_kv 表，与此处无关。
  account: "$(yaml_escape "${WEB_DEFAULT_ACCOUNT}")"
  password: "$(yaml_escape "${WEB_DEFAULT_PASSWORD}")"

spring:
  threads:
    virtual:
      enabled: false
  datasource:
    driver-class-name: com.mysql.cj.jdbc.Driver
    url: "$(yaml_escape "${jdbc_url}")"
    username: "$(yaml_escape "${DB_USER}")"
    password: "$(yaml_escape "${DB_PASS}")"
  sql:
    init:
      mode: never

mybatis-plus:
  mapper-locations: classpath*:com/ociworker/mapper/xml/*.xml,classpath*:mapper/*.xml

logging:
  pattern:
    console: "%d{yyyy-MM-dd HH:mm:ss} %-5level %msg%n"
  level:
    com.oracle.bmc: error
    c.o.b.h.c.j: error

oci-cfg:
  key-dir-path: ./keys
EOF
    chmod 600 "${CONFIG_FILE}"
    ok "配置文件已写入：${CONFIG_FILE}"
}

recommended_heap_mb() {
    local total_kb
    total_kb="$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
    if [ "${total_kb:-0}" -le 1048576 ]; then
        echo 256
    elif [ "${total_kb}" -le 2097152 ]; then
        echo 384
    elif [ "${total_kb}" -le 4194304 ]; then
        echo 512
    else
        echo 1024
    fi
}

write_systemd_unit() {
    local heap_mb
    heap_mb="$(recommended_heap_mb)"
    info "写入 systemd 服务：${SERVICE_NAME}..."
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=OCI Worker
After=network.target docker.service

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
Environment=SPRING_THREADS_VIRTUAL_ENABLED=false
ExecStart=/usr/local/bin/java -Xmx${heap_mb}m -Duser.timezone=Asia/Shanghai -Duser.dir=${INSTALL_DIR} -jar ${JAR_NAME} --spring.config.additional-location=file:${CONFIG_FILE}
Restart=on-failure
RestartSec=10
# 未设置时 systemd 常用默认约 90s，stop 期间脚本长时间无新日志，易被误认为卡死
TimeoutStopSec=45

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    ok "systemd 服务已注册"
}

JVM_DROPIN="/etc/systemd/system/${SERVICE_NAME}.service.d/20-managed-jvm-memory.conf"
JVM_DROPIN_BACKUP=""
JVM_DROPIN_CREATED=0

apply_managed_jvm_memory_migration() {
    local heap_mb unit_exec dropin_tmp
    heap_mb="$(recommended_heap_mb)"
    unit_exec="$(systemctl show -p ExecStart --value "${SERVICE_NAME}" 2>/dev/null || true)"

    # 只迁移项目历史安装器生成的 -Xmx256m；用户自定义 JVM 参数一律保留。
    if [[ "${unit_exec}" != *"/usr/local/bin/java"* ]] \
        || [[ "${unit_exec}" != *"-Xmx256m"* ]] \
        || [[ "${unit_exec}" != *"-Duser.timezone=Asia/Shanghai"* ]] \
        || [[ "${unit_exec}" != *"-Duser.dir=/opt/oci-worker"* ]] \
        || [[ "${unit_exec}" != *"oci-worker.jar"* ]] \
        || [[ "${unit_exec}" != *"/opt/oci-worker/application.yml"* ]]; then
        info "JVM 参数不是项目旧默认 -Xmx256m，保留现有配置"
        return 0
    fi

    mkdir -p "$(dirname "${JVM_DROPIN}")" || return 1
    if [ -f "${JVM_DROPIN}" ]; then
        JVM_DROPIN_BACKUP="${JVM_DROPIN}.bak.$(date +%Y%m%d%H%M%S)"
        cp -p "${JVM_DROPIN}" "${JVM_DROPIN_BACKUP}" || return 1
    else
        JVM_DROPIN_CREATED=1
    fi
    dropin_tmp="${JVM_DROPIN}.tmp.$$"
    if ! cat > "${dropin_tmp}" <<EOF
[Service]
ExecStart=
ExecStart=/usr/local/bin/java -Xmx${heap_mb}m -Duser.timezone=Asia/Shanghai -Duser.dir=${INSTALL_DIR} -jar ${JAR_NAME} --spring.config.additional-location=file:${CONFIG_FILE}
EOF
    then
        rm -f "${dropin_tmp}"
        return 1
    fi
    if ! mv "${dropin_tmp}" "${JVM_DROPIN}"; then
        rm -f "${dropin_tmp}"
        return 1
    fi
    systemctl daemon-reload || return 1
    ok "已将项目旧默认 JVM 堆从 256MB 自动调整为 ${heap_mb}MB"
}

rollback_managed_jvm_memory_migration() {
    if [ -n "${JVM_DROPIN_BACKUP}" ] && [ -f "${JVM_DROPIN_BACKUP}" ]; then
        mv "${JVM_DROPIN_BACKUP}" "${JVM_DROPIN}" \
            || warn "恢复原 JVM 配置失败：${JVM_DROPIN_BACKUP}"
    elif [ "${JVM_DROPIN_CREATED}" = "1" ]; then
        rm -f "${JVM_DROPIN}" || warn "删除新 JVM 配置失败：${JVM_DROPIN}"
    fi
    systemctl daemon-reload 2>/dev/null || warn "systemd 重新加载失败，请手动执行 systemctl daemon-reload"
}

# 已部署环境可能仍为旧版 unit（无 TimeoutStopSec），升级时 stop 会等满 systemd 默认超时（常见 ~90s）
apply_worker_stop_timeout_dropin() {
    mkdir -p "/etc/systemd/system/${SERVICE_NAME}.service.d"
    cat > "/etc/systemd/system/${SERVICE_NAME}.service.d/10-stop-timeout.conf" <<'EOF'
[Service]
TimeoutStopSec=45
EOF
    systemctl daemon-reload
}

# JDBC 与 OCI SDK 均包含阻塞调用。Web 请求若使用虚拟线程，会和抢机循环争抢少量载体线程，
# 可能在数据库空闲时仍出现全站 API 数十秒无响应。使用环境变量覆盖旧 application.yml，
# 无需改写用户配置文件，且对既有安装立即生效。
apply_platform_web_thread_isolation() {
    mkdir -p "$(dirname "${WEB_THREAD_DROPIN}")" || return 1
    cat > "${WEB_THREAD_DROPIN}" <<'EOF'
[Service]
Environment=SPRING_THREADS_VIRTUAL_ENABLED=false
EOF
    systemctl daemon-reload || return 1
    ok "已启用 Web 平台线程隔离，避免 OCI 抢机阻塞面板请求"
}

# -----------------------------------------------------------------------------
# JAR download
# -----------------------------------------------------------------------------
download_with_retry() {
    # download_with_retry <url> <dest>
    local url="$1" dest="$2"
    info "下载: ${url}"
    if ! curl -fSL --retry 3 --retry-delay 5 --connect-timeout 15 -o "${dest}" "${url}"; then
        return 1
    fi
}

file_size() {
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0
}

# Returns 0 on success, non-zero on failure. NEVER calls die() so callers
# can decide whether to roll back.
download_jar() {
    local destination="${1:-${INSTALL_DIR}/${JAR_NAME}}"
    info "下载 JAR（Release：${JAR_RELEASE_TAG}）…"
    local url tmp size attempt max
    url="https://github.com/${REPO}/releases/download/${JAR_RELEASE_TAG}/${JAR_ASSET}"
    tmp="${destination}.tmp"
    max=3
    attempt=0
    while [ "${attempt}" -lt "${max}" ]; do
        if download_with_retry "${url}" "${tmp}"; then
            break
        fi
        rm -f "${tmp}"
        attempt=$((attempt+1))
        if [ "${attempt}" -ge "${max}" ]; then
            err "JAR 下载失败"
            err "若出现 404，多为刚推送代码、或 GitHub Release 正更新，请过几分钟再试，并在仓库 Releases 页确认「${JAR_RELEASE_TAG}」下已有 ${JAR_ASSET}。"
            return 1
        fi
        warn "JAR 下载失败，20 秒后重试（第 ${attempt}/${max} 次，常见于 GitHub 刚更新时）"
        sleep 20
    done
    size="$(file_size "${tmp}")"
    if [ "${size}" -lt 1000000 ]; then
        rm -f "${tmp}"
        err "下载的 JAR 文件大小异常（${size} 字节），可能是 404 页面"
        return 1
    fi
    # Quick sanity: must be a valid ZIP/JAR
    if command -v unzip >/dev/null 2>&1; then
        if ! unzip -tq "${tmp}" >/dev/null 2>&1; then
            rm -f "${tmp}"
            err "下载的 JAR 损坏，请重试"
            return 1
        fi
    fi
    if ! mv "${tmp}" "${destination}"; then
        rm -f "${tmp}"
        err "JAR 写入目标路径失败：${destination}"
        return 1
    fi
    ok "JAR 已就绪：${destination}（$(numfmt --to=iec "${size}" 2>/dev/null || echo "${size} 字节")）"
    return 0
}

# -----------------------------------------------------------------------------
# Install / restart with rollback
# -----------------------------------------------------------------------------
configured_web_port() {
    local port
    port="$(awk '
        $0 ~ /^server:/ { in_server=1; next }
        in_server && $0 ~ /^[[:space:]]*port:[[:space:]]*[0-9]+/ {
            gsub(/[^0-9]/, "", $0); print $0; exit
        }
        in_server && $0 ~ /^[^[:space:]]/ { in_server=0 }
    ' "${CONFIG_FILE}" 2>/dev/null || true)"
    echo "${port:-${DEFAULT_WEB_PORT}}"
}

restart_with_rollback() {
    local rollback_config="${1:-yes}"
    local probe_mode="${2:-strict}"
    info "启动 ${SERVICE_NAME}..."
    if ! systemctl restart "${SERVICE_NAME}"; then
        if [ "${rollback_config}" = "yes" ]; then
            warn "服务启动失败，尝试回滚配置..."
            local last_bak
            last_bak="$(ls -1t "${CONFIG_FILE}.bak."* 2>/dev/null | head -n 1 || true)"
            if [ -n "${last_bak}" ]; then
                cp -p "${last_bak}" "${CONFIG_FILE}"
                systemctl restart "${SERVICE_NAME}" || true
                warn "已回滚到上一个配置：${last_bak}"
            fi
        else
            warn "服务启动失败；本次升级未修改 application.yml，不回退用户配置"
        fi
        err "请查看日志：journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
        return 1
    fi

    # systemd active 不等于应用已就绪；使用不访问数据库的进程内探针，
    # 避免首页鉴权或数据库恢复期间的短暂阻塞被误判为升级失败。
    local port deadline
    port="$(configured_web_port)"
    deadline=$((SECONDS + 60))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        sleep 2
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            if curl -fsS --connect-timeout 1 --max-time 2 -o /dev/null \
                    "http://127.0.0.1:${port}/api/sys/ready" 2>/dev/null; then
                ok "${SERVICE_NAME} 已运行，端口 ${port} 已就绪"
                return 0
            fi
            # 较早版本没有 /api/sys/ready。仅在回滚旧 JAR 时允许用首页 HTTP
            # 响应确认进程已恢复；新版本仍必须通过严格的进程内就绪探针。
            if [ "${probe_mode}" = "legacy" ] \
                && curl -sS --connect-timeout 1 --max-time 2 -o /dev/null \
                    "http://127.0.0.1:${port}/" 2>/dev/null; then
                ok "${SERVICE_NAME} 旧版本已恢复，端口 ${port} 可访问"
                return 0
            fi
        fi
        if systemctl is-failed --quiet "${SERVICE_NAME}"; then
            break
        fi
    done
    warn "${SERVICE_NAME} 未在 60 秒内通过端口就绪检查"
    return 1
}

# -----------------------------------------------------------------------------
# Firewall hint
# -----------------------------------------------------------------------------
firewall_open_port() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        info "ufw 已放行 ${port}/tcp"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "firewalld 已放行 ${port}/tcp"
    else
        iptables_open_port "${port}"
    fi
}

# OCI 官方镜像默认不启用 ufw/firewalld，而是由 netfilter-persistent 管理一组裸 iptables
# 规则，链尾通常是 REJECT。此前这里只处理 ufw/firewalld，两者都不可用时静默跳过，
# 导致换端口后新端口永远没有放行规则——服务正常监听却怎么都连不上。
iptables_open_port() {
    local port="$1"
    command -v iptables >/dev/null 2>&1 || return 0

    # 链里没有任何拒绝动作时不插规则：此时端口本就通，多插一条反而会覆盖
    # 使用者自己可能配置的精细限制（例如只允许特定来源访问面板）。
    if ! iptables -S INPUT 2>/dev/null \
        | grep -qE '^-P INPUT (DROP|REJECT)|^-A INPUT .*-j (DROP|REJECT)'; then
        return 0
    fi

    # 已放行则不重复插入，保证反复执行安装/改端口是幂等的。
    if iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1; then
        info "iptables 已存在 ${port}/tcp 放行规则"
        return 0
    fi

    # 必须插到链首：OCI 默认规则链尾是 REJECT，追加到末尾永远匹配不到。
    if ! iptables -I INPUT 1 -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1; then
        warn "iptables 放行 ${port}/tcp 失败，请手动执行：iptables -I INPUT 1 -p tcp --dport ${port} -j ACCEPT"
        return 0
    fi
    info "iptables 已放行 ${port}/tcp（规则插入 INPUT 链首）"
    iptables_persist
}

# 不持久化的话重启就丢，面板会再次变成打不开。
# 注意脚本启用了 set -e：这里所有可能失败的命令都必须包在 if 条件里，
# 否则一次保存失败就会让整个安装/升级流程中途退出。
iptables_persist() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        if netfilter-persistent save >/dev/null 2>&1; then
            info "iptables 规则已持久化"
            return 0
        fi
    fi
    if [ -f /etc/iptables/rules.v4 ] && command -v iptables-save >/dev/null 2>&1; then
        if iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
            info "iptables 规则已写入 /etc/iptables/rules.v4"
            return 0
        fi
    fi
    if [ -f /etc/sysconfig/iptables ] && command -v iptables-save >/dev/null 2>&1; then
        if iptables-save > /etc/sysconfig/iptables 2>/dev/null; then
            info "iptables 规则已写入 /etc/sysconfig/iptables"
            return 0
        fi
    fi
    warn "未找到 iptables 持久化方式，重启后放行规则会丢失；请自行保存（如 netfilter-persistent save）"
    return 0
}

cleanup_legacy_terminal_component() {
    systemctl stop "${LEGACY_TERMINAL_SERVICE}" 2>/dev/null || true
    systemctl disable "${LEGACY_TERMINAL_SERVICE}" 2>/dev/null || true
    rm -f "${LEGACY_TERMINAL_BIN}"
    rm -f "/etc/systemd/system/${LEGACY_TERMINAL_SERVICE}.service"
    systemctl daemon-reload 2>/dev/null || true
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${LEGACY_TERMINAL_CONTAINER}"; then
        docker stop "${LEGACY_TERMINAL_CONTAINER}" >/dev/null 2>&1 || true
        (cd /opt/oci-worker/webssh 2>/dev/null && docker compose down >/dev/null 2>&1) || true
    fi
}

security_notice() {
    section "安全提醒"
    cat >&2 <<EOF
* 推荐：用 Nginx 反向代理 + HTTPS（Let's Encrypt）保护 ${WEB_PORT}。
* 已自动放行本机防火墙的 ${WEB_PORT}/tcp。若使用云主机，还需在云控制台放行
  （OCI：网络 → VCN → 安全列表 → 入站规则），否则外部依旧连不上。
* AI 网关另占用这些端口，默认不放行；需要从外部调用时请自行开放：
    8080          OpenAI 兼容 /v1
    50000         负载均衡网关
    30000-39999   多租户网关（按启用的租户数量动态占用）
EOF
}

# -----------------------------------------------------------------------------
# ociworker management script installation
# -----------------------------------------------------------------------------
install_ociworker_cli() {
    # Source priority:
    #   1. Same directory as install.sh
    #   2. public main branch raw (always up-to-date)
    #   3. installer-latest release (fallback when raw is unreachable)
    local src=""
    local self_dir
    self_dir="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
    if [ -f "${self_dir}/ociworker" ]; then
        src="${self_dir}/ociworker"
    fi
    if [ -z "${src}" ]; then
        info "下载管理脚本 ociworker（优先 main 分支）..."
        local tmp="${TMP_DIR}/ociworker"
        if download_with_retry "${RAW_BASE}/ociworker" "${tmp}"; then
            src="${tmp}"
        elif download_with_retry "https://github.com/${REPO}/releases/download/${INSTALLER_RELEASE_TAG}/ociworker" "${tmp}"; then
            src="${tmp}"
        else
            warn "无法下载 ociworker（不影响主程序运行），可稍后手动安装"
            return 0
        fi
    fi
    if ! install -m 0755 "${src}" "${OCIWORKER_BIN}"; then
        warn "管理脚本安装失败（不影响主程序运行），可稍后重新执行安装器"
        return 0
    fi
    # python3 is required by `ociworker config` for safe YAML editing.
    if ! command -v python3 >/dev/null 2>&1; then
        info "安装 python3（被 ociworker config 子命令使用）..."
        pkg_install python3 || warn "python3 未能自动安装，ociworker config 子命令将不可用"
    fi
    ok "管理脚本已安装：${OCIWORKER_BIN}（敲 \`ociworker\` 进菜单）"
}

# =============================================================================
# Main entry points
# =============================================================================
do_install() {
    section "OCI Worker 智能安装向导"
    info "系统架构：$(uname -m) (映射为 ${ARCH})"
    install_jdk21

    run_db_wizard
    prompt_web

    section "下载与部署"
    mkdir -p "${INSTALL_DIR}" "${KEYS_DIR}" "${BACKUP_DIR}"
    download_jar || die "JAR 下载失败，无法继续安装"
    write_application_yml
    write_systemd_unit

    firewall_open_port "${WEB_PORT}"
    install_ociworker_cli

    if ! restart_with_rollback; then
        die "OCI Worker 启动失败，已尝试回滚。请查看日志后再决定是否重试。"
    fi

    cleanup_legacy_terminal_component

    security_notice

    local pub_ip
    pub_ip="$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "<your-server-ip>")"
    section "部署完成"
    cat >&2 <<EOF
访问地址:    http://${pub_ip}:${WEB_PORT}

下一步（必做）：
  1. 在浏览器打开上面的访问地址
  2. 按页面提示设置管理员账号和密码（密码至少 6 位）
  3. 设置完即可登录使用

防火墙提醒：
  * 已自动放行本机 ufw / firewalld 的 ${WEB_PORT}/tcp
  * 云厂商安全组里也要放行 ${WEB_PORT}/tcp（OCI/AWS/腾讯云等）
常用管理命令（敲 ociworker 进交互菜单）：
  ociworker status     查看状态
  ociworker logs       查看实时日志
  ociworker config     修改端口/数据库（含回滚；账号密码请在网页修改）
  ociworker update     更新到最新版本
  ociworker backup     备份数据库 + 配置 + 密钥
  ociworker tg-clean   清除 Telegram 绑定（无本机 mysql 时自动经 Docker MySQL 容器）
EOF
}

do_upgrade() {
    section "OCI Worker 升级模式"
    info "检测到已有安装：${INSTALL_DIR}"
    info "升级模式不会修改 application.yml 和数据库"

    # /run/lock 仅允许 root 写入，避免 root 安装器跟随 /tmp 中由低权限用户
    # 预先创建的符号链接。极简系统无 /run/lock 时退回 /run。
    local lock_dir="/run/lock"
    [ -d "${lock_dir}" ] || lock_dir="/run"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"${lock_dir}/oci-worker-upgrade.lock"
        flock -n 9 || die "已有另一个 OCI Worker 升级正在执行，请等待完成"
    else
        local lock_fallback="${lock_dir}/oci-worker-upgrade.lock.d"
        mkdir "${lock_fallback}" 2>/dev/null \
            || die "已有另一个 OCI Worker 升级正在执行，请等待完成"
        UPGRADE_LOCK_FALLBACK="${lock_fallback}"
    fi

    install_jdk21

    apply_worker_stop_timeout_dropin

    apply_platform_web_thread_isolation \
        || die "Web 线程隔离配置失败，未继续升级"

    # 先备份并下载校验，旧服务继续运行；仅在新包就绪后短暂停服切换。
    if [ ! -f "${INSTALL_DIR}/${JAR_NAME}" ]; then
        die "未找到当前 JAR：${INSTALL_DIR}/${JAR_NAME}，为避免无法回滚，未继续升级"
    fi
    rm -f "${INSTALL_DIR}/${JAR_NAME}.bak"
    cp -p "${INSTALL_DIR}/${JAR_NAME}" "${INSTALL_DIR}/${JAR_NAME}.bak" \
        || die "旧 JAR 备份失败，为避免无法回滚，未继续升级"

    local candidate_jar="${INSTALL_DIR}/${JAR_NAME}.candidate"
    rm -f "${candidate_jar}" "${candidate_jar}.tmp"
    if ! download_jar "${candidate_jar}"; then
        warn "JAR 下载失败，恢复旧版本"
        rm -f "${candidate_jar}" "${candidate_jar}.tmp"
        rm -f "${INSTALL_DIR}/${JAR_NAME}.bak"
        die "升级失败"
    fi

    info "新包已校验，停止 ${SERVICE_NAME} 并切换版本..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    if ! mv "${candidate_jar}" "${INSTALL_DIR}/${JAR_NAME}"; then
        warn "新 JAR 切换失败，继续使用旧版本"
        rm -f "${candidate_jar}" "${candidate_jar}.tmp"
        if [ ! -f "${INSTALL_DIR}/${JAR_NAME}" ] && [ -f "${INSTALL_DIR}/${JAR_NAME}.bak" ]; then
            cp -p "${INSTALL_DIR}/${JAR_NAME}.bak" "${INSTALL_DIR}/${JAR_NAME}" || true
        fi
        restart_with_rollback no legacy || warn "旧版本服务恢复失败，请立即查看 systemd 日志"
        die "升级失败"
    fi

    if ! apply_managed_jvm_memory_migration; then
        warn "JVM 配置迁移失败，恢复旧版本"
        [ -f "${INSTALL_DIR}/${JAR_NAME}.bak" ] && mv "${INSTALL_DIR}/${JAR_NAME}.bak" "${INSTALL_DIR}/${JAR_NAME}"
        rollback_managed_jvm_memory_migration
        restart_with_rollback no legacy || warn "旧版本服务恢复失败，请立即查看 systemd 日志"
        die "升级失败"
    fi

    install_ociworker_cli

    if restart_with_rollback no; then
        cleanup_legacy_terminal_component
        # On success, drop the JAR backup
        rm -f "${INSTALL_DIR}/${JAR_NAME}.bak" "${candidate_jar}" "${candidate_jar}.tmp"
        [ -n "${JVM_DROPIN_BACKUP}" ] && rm -f "${JVM_DROPIN_BACKUP}" || true
        ok "升级完成"
        local cur_port
        cur_port="$(awk '/^server:/{f=1;next} f && /^[^ ]/{f=0} f && /port:/{print $2; exit}' "${CONFIG_FILE}" 2>/dev/null | tr -d '"'\''' || true)"
        cur_port="${cur_port:-${DEFAULT_WEB_PORT}}"
        local pub_ip
        pub_ip="$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "<your-server-ip>")"
        section "升级完成"
        cat >&2 <<EOF
访问地址:    http://${pub_ip}:${cur_port}
查看日志:    journalctl -u ${SERVICE_NAME} -f
管理命令:    ociworker
EOF
    else
        warn "新版本启动失败，回滚到旧 JAR..."
        if [ -f "${INSTALL_DIR}/${JAR_NAME}.bak" ]; then
            mv "${INSTALL_DIR}/${JAR_NAME}.bak" "${INSTALL_DIR}/${JAR_NAME}"
        fi
        rollback_managed_jvm_memory_migration
        if restart_with_rollback no legacy; then
            warn "已回滚到旧版本和原 JVM 配置，旧服务已恢复"
        else
            err "旧 JAR 和 JVM 配置已恢复，但服务未能重新就绪，请立即查看 systemd 日志"
        fi
        die "升级失败，请查看日志"
    fi
}

main() {
    require_root
    if [ "${1:-}" = --patch-java-only ]; then
        patch_java_blocklist "${2:-java}"
        return
    fi
    if [ "${1:-}" = --runtime-only ]; then
        install_jdk21
        return
    fi
    require_systemd
    ARCH="$(detect_arch)"

    local mode; mode="$(detect_mode)"
    case "${mode}" in
        install) do_install ;;
        upgrade) do_upgrade ;;
    esac
}

main "$@"
