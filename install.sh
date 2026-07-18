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
readonly JDK_VERSION_URLENC="21.0.7%2B6"
readonly JDK_VERSION_FILE="21.0.7_6"
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
    # Capture full java -version (avoids SIGPIPE on `head` under pipefail).
    if ! command -v java >/dev/null 2>&1; then
        return 1
    fi
    local v
    v="$(java -version 2>&1 || true)"
    printf "%s\n" "${v}" | sed -n '1p'
}

java_is_21() {
    local line
    line="$(java_version_line 2>/dev/null || true)"
    [ -n "${line}" ] || return 1
    printf "%s" "${line}" | grep -Eq '"21(\.|")'
}

install_jdk21() {
    if java_is_21; then
        ok "JDK 21 已安装：$(java_version_line)"
        return 0
    fi
    info "安装 JDK 21 (Adoptium Temurin)..."
    ensure_cmd curl
    ensure_cmd tar
    local jdk_arch tmp
    jdk_arch="$(detect_jdk_arch)"
    tmp="${TMP_DIR}/jdk21.tar.gz"
    if ! curl -fSL --retry 3 --retry-delay 5 --connect-timeout 15 \
            -o "${tmp}" \
            "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-${JDK_VERSION_URLENC}/OpenJDK21U-jre_${jdk_arch}_linux_hotspot_${JDK_VERSION_FILE}.tar.gz"; then
        die "JDK 下载失败，请检查网络（GitHub 是否可访问）"
    fi
    mkdir -p "${JDK_INSTALL_BASE}"
    tar -xzf "${tmp}" -C "${JDK_INSTALL_BASE}" || die "JDK 解压失败"
    local jdk_dir
    jdk_dir="$(ls -d "${JDK_INSTALL_BASE}"/jdk-21* 2>/dev/null | sort -V | tail -n 1 || true)"
    [ -n "${jdk_dir}" ] || die "JDK 安装目录未找到"
    ln -sf "${jdk_dir}/bin/java" /usr/local/bin/java
    ok "JDK 21 安装完成 ($(java_version_line))"
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
        WEB_PORT="$(ask "OCI Worker Web 端口" "8818")"
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
    echo "${port:-8818}"
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
    fi
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
        cur_port="${cur_port:-8818}"
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
    require_systemd
    ARCH="$(detect_arch)"

    local mode; mode="$(detect_mode)"
    case "${mode}" in
        install) do_install ;;
        upgrade) do_upgrade ;;
    esac
}

main "$@"
