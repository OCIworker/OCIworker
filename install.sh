#!/usr/bin/env bash
# =============================================================================
# OCI Worker - Smart Installer (v2)
# -----------------------------------------------------------------------------
# Friendly interactive installer with the following features:
#   * First-install wizard: JDK / DB / port / WebSSH (binary) / systemd / firewall
#   * Upgrade mode (auto-detected): only refresh JAR + webssh binary, never
#     touches application.yml or the database.
#   * 1Panel / Aapanel friendly: supports "use existing MySQL" branch with
#     connectivity / charset / version / privilege auto-checks.
#   * Atomic config writes with .bak rollback if the new config breaks startup.
#
# This script is INDEPENDENT of the original deploy.sh / update.sh.
# It does NOT modify anything outside /opt/oci-worker, /etc/systemd/system,
# /usr/local/bin/ociworker, and (optionally) the firewall rules for port 8008.
#
# Run as root:
#   bash <(curl -fsSL https://github.com/<REPO>/releases/download/installer-latest/install.sh)
# 动效/Orbis UI 版 JAR（与上相同脚本，加环境变量；见 GitHub Release：ui-latest）：
#   curl -fsSL https://github.com/OCIworker/OCIworker/releases/download/installer-latest/install.sh -o /tmp/install.sh
#   sudo env OCI_WORKER_UI=1 bash /tmp/install.sh
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
readonly WEBSSH_BIN="${INSTALL_DIR}/oci-webssh"
readonly WEBSSH_SERVICE_NAME="oci-webssh"
readonly WEBSSH_SERVICE_FILE="/etc/systemd/system/${WEBSSH_SERVICE_NAME}.service"
# WebSSH port is HARD-CODED to 8008 because backend
# (WebSSHProxyController.java) reverse-proxies to http://127.0.0.1:8008.
readonly WEBSSH_PORT=8008

readonly REPO="OCIworker/OCIworker"
# 默认从 GitHub Releases 的 `latest` 下 master 构建的 JAR。
# 动效/Orbis（feature/ui-polish）预编译在 `ui-latest`；用 OCI_WORKER_UI=1 或首参 --ui 选择。
# 已装用户：/opt/oci-worker/.use-ui-jar 存在则升级也拉 UI 包；OCI_USE_MASTER_JAR=1 覆盖为 master 并取消该标记。
readonly JAR_TAG_DEFAULT="latest"
readonly JAR_TAG_UI="ui-latest"
readonly UI_CHANNEL_FILE="${INSTALL_DIR}/.use-ui-jar"
JAR_RELEASE_TAG="${JAR_TAG_DEFAULT}"
readonly INSTALLER_RELEASE_TAG="installer-latest"
readonly RAW_BASE="https://raw.githubusercontent.com/${REPO}/master"

readonly OCIWORKER_BIN="/usr/local/bin/ociworker"
readonly TMP_DIR="$(mktemp -d -t oci-worker-installer.XXXXXX)"

# JDK 21 (Adoptium Temurin)
readonly JDK_VERSION="21.0.7+6"
readonly JDK_VERSION_URLENC="21.0.7%2B6"
readonly JDK_VERSION_FILE="21.0.7_6"
readonly JDK_INSTALL_BASE="/opt/java"

# -----------------------------------------------------------------------------
# Cleanup on exit
# -----------------------------------------------------------------------------
cleanup() {
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
    local pm="$(detect_pkg_mgr)"
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

mysql_cli_run() {
    # mysql_cli_run <host> <port> <user> <pass> <db_or_empty> <sql>
    # Returns mysql output. Uses MYSQL_PWD env to avoid leaking via ps.
    local host="$1" port="$2" user="$3" pass="$4" db="$5" sql="$6"
    local args=(-h"${host}" -P"${port}" -u"${user}" -N -B --connect-timeout=5)
    if [ -n "${db}" ]; then
        args+=("${db}")
    fi
    MYSQL_PWD="${pass}" mysql "${args[@]}" -e "${sql}" 2>&1
}

ensure_mysql_client() {
    if command -v mysql >/dev/null 2>&1; then
        return 0
    fi
    info "安装 MySQL 客户端（用于数据库自检）..."
    local pm="$(detect_pkg_mgr)"
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
    out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "" "SELECT 1" 2>&1 || true)"
    if echo "${out}" | grep -q "^1$"; then
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
    out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "" "SELECT VERSION();" 2>&1 || true)"
    if [ -z "${out}" ]; then
        err "无法获取 MySQL 版本：${out}"
        return 1
    fi
    local ver_major
    ver_major="$(echo "${out}" | head -n 1 | cut -d. -f1 | tr -d -c '0-9')"
    if [ -z "${ver_major}" ] || [ "${ver_major}" -lt 8 ]; then
        err "MySQL 版本过低：${out}（需要 8.0+）"
        warn "请在面板/服务器升级到 MySQL 8.0 或更高版本"
        return 1
    fi
    ok "MySQL 版本：$(echo "${out}" | head -n 1)"

    # Database existence
    out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "" \
            "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';" 2>&1 || true)"
    if [ "${out}" != "${DB_NAME}" ]; then
        warn "数据库 \`${DB_NAME}\` 不存在或当前用户无权访问"
        if [ "$(ask_yes_no "尝试用当前账号自动创建数据库（utf8mb4）？" "Y")" = "y" ]; then
            local create_out
            create_out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "" \
                "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>&1 || true)"
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
        "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';" 2>&1 || true)"
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
                    "ALTER DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>&1 || true)"
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
        "CREATE TABLE IF NOT EXISTS _ociworker_probe_(id INT) ENGINE=InnoDB; DROP TABLE _ociworker_probe_;" 2>&1 || true)"
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
  2. 用户（默认建议名：ociworker）
  3. 字符集 utf8mb4 / utf8mb4_unicode_ci
  4. 用户对该库有所有权限
  5. MySQL 监听端口已暴露到宿主机（127.0.0.1:3306 通常即可）

EOF
    while true; do
        DB_HOST="$(ask "数据库地址" "127.0.0.1")"
        DB_PORT="$(ask "数据库端口" "3306")"
        DB_NAME="$(ask "数据库名"   "oci_worker")"
        DB_USER="$(ask "用户名"     "ociworker")"
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
    if ! command -v docker >/dev/null 2>&1; then
        info "未检测到 Docker，正在安装..."
        curl -fsSL https://get.docker.com | sh || die "Docker 安装失败"
    fi
    DB_HOST="127.0.0.1"
    DB_PORT="3306"
    DB_NAME="$(ask "数据库名"   "oci_worker")"
    DB_USER="$(ask "用户名"     "ociworker")"
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

    if ! docker ps --format '{{.Names}}' | grep -qx "oci-worker-mysql"; then
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
        info "等待 MySQL 启动（最多 60 秒）..."
        local waited=0
        while [ "${waited}" -lt 60 ]; do
            if MYSQL_PWD="${DB_PASS}" mysql -h127.0.0.1 -P3306 -u"${DB_USER}" --connect-timeout=2 -e "SELECT 1" >/dev/null 2>&1; then
                ok "MySQL 已就绪"
                return 0
            fi
            sleep 2
            waited=$((waited + 2))
            printf "." >&2
        done
        printf "\n" >&2
        die "MySQL 启动超时，请查看：docker logs oci-worker-mysql"
    fi
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
    DB_USER="$(ask "新建用户名"   "ociworker")"
    DB_PASS="$(ask_password "新建用户密码")"
    while [ "${#DB_PASS}" -lt 6 ]; do
        warn "密码太短"
        DB_PASS="$(ask_password "新建用户密码")"
    done

    info "用 root 测试连接..."
    local probe_out
    probe_out="$(MYSQL_PWD="${root_pass}" mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${root_user}" --connect-timeout=5 -e "SELECT 1" 2>&1 || true)"
    if ! echo "${probe_out}" | grep -q "^1$"; then
        die "root 登录失败：${probe_out}"
    fi
    ok "root 登录成功"

    info "创建数据库和用户..."
    MYSQL_PWD="${root_pass}" mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${root_user}" <<EOF || die "创建数据库/用户失败"
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
FLUSH PRIVILEGES;
EOF
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
            if [ "${WEB_PORT}" -eq "${WEBSSH_PORT}" ]; then
                warn "端口 ${WEBSSH_PORT} 被 WebSSH 占用，请换一个"
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
      enabled: true
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

write_systemd_unit() {
    info "写入 systemd 服务：${SERVICE_NAME}..."
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=OCI Worker
After=network.target docker.service

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/local/bin/java -Xmx256m -Duser.timezone=Asia/Shanghai -Duser.dir=${INSTALL_DIR} -jar ${JAR_NAME} --spring.config.additional-location=file:${CONFIG_FILE}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    ok "systemd 服务已注册"
}

# -----------------------------------------------------------------------------
# JAR / WebSSH binary download
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
    if [ "${JAR_RELEASE_TAG}" = "${JAR_TAG_UI}" ]; then
        info "下载动效/Orbis UI 版 JAR（Release：${JAR_RELEASE_TAG}）…"
    else
        info "下载 JAR（Release：${JAR_RELEASE_TAG}）…"
    fi
    local url tmp size attempt max
    url="https://github.com/${REPO}/releases/download/${JAR_RELEASE_TAG}/${JAR_ASSET}"
    tmp="${INSTALL_DIR}/${JAR_NAME}.tmp"
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
            if [ "${JAR_RELEASE_TAG}" = "${JAR_TAG_UI}" ]; then
                err "动效/Orbis 需存在 Release「${JAR_TAG_UI}」；由 feature/ui-polish 分支 CI 构建。尚无时可先用默认安装（不设置 OCI_WORKER_UI）。"
            else
                err "若出现 404，多为刚推送代码、或 GitHub Release 正更新，请过几分钟再试，并在仓库 Releases 页确认「${JAR_RELEASE_TAG}」下已有 ${JAR_ASSET}。"
            fi
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
    mv "${tmp}" "${INSTALL_DIR}/${JAR_NAME}"
    ok "JAR 已就绪：$(numfmt --to=iec "${size}" 2>/dev/null || echo "${size} 字节")"
    return 0
}

download_webssh_binary() {
    info "下载 WebSSH 二进制 (${ARCH})..."
    local url tmp size
    url="https://github.com/${REPO}/releases/download/${INSTALLER_RELEASE_TAG}/oci-webssh-linux-${ARCH}"
    tmp="${WEBSSH_BIN}.tmp"
    if ! download_with_retry "${url}" "${tmp}"; then
        rm -f "${tmp}"
        err "WebSSH 下载失败"
        return 1
    fi
    size="$(file_size "${tmp}")"
    if [ "${size}" -lt 1000000 ]; then
        rm -f "${tmp}"
        err "WebSSH 二进制大小异常（${size} 字节），可能是 404 页面"
        return 1
    fi
    chmod +x "${tmp}"
    mv "${tmp}" "${WEBSSH_BIN}"
    ok "WebSSH 二进制已就绪"
    return 0
}

write_webssh_systemd() {
    info "写入 systemd 服务：${WEBSSH_SERVICE_NAME}..."
    cat > "${WEBSSH_SERVICE_FILE}" <<EOF
[Unit]
Description=OCI WebSSH (binary mode, used by oci-worker)
After=network.target
PartOf=${SERVICE_NAME}.service

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${WEBSSH_BIN} -p ${WEBSSH_PORT} -s -t 120
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${WEBSSH_SERVICE_NAME}" >/dev/null 2>&1 || true
    ok "WebSSH systemd 服务已注册"
}

handle_existing_docker_webssh() {
    # If the original deploy.sh installed WebSSH via Docker, ask user before disabling.
    if command -v docker >/dev/null 2>&1 && \
       docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "webssh"; then
        warn "检测到原 Docker 版 WebSSH 容器仍在运行（容器名: webssh）"
        if [ "$(ask_yes_no "停止并禁用 Docker 版，改用二进制版？（推荐）" "Y")" = "y" ]; then
            docker stop webssh >/dev/null 2>&1 || true
            (cd /opt/oci-worker/webssh 2>/dev/null && docker compose down >/dev/null 2>&1) || true
            ok "Docker 版 WebSSH 已停止"
        else
            warn "保留 Docker 版 WebSSH，将跳过二进制版安装（避免 8008 端口冲突）"
            return 1
        fi
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Install / restart with rollback
# -----------------------------------------------------------------------------
restart_with_rollback() {
    info "启动 ${SERVICE_NAME}..."
    if ! systemctl restart "${SERVICE_NAME}"; then
        warn "服务启动失败，尝试回滚配置..."
        local last_bak
        last_bak="$(ls -1t "${CONFIG_FILE}.bak."* 2>/dev/null | head -n 1 || true)"
        if [ -n "${last_bak}" ]; then
            cp -p "${last_bak}" "${CONFIG_FILE}"
            systemctl restart "${SERVICE_NAME}" || true
            warn "已回滚到上一个配置：${last_bak}"
        fi
        err "请查看日志：journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
        return 1
    fi

    # Wait briefly for service to settle.
    local i
    for i in 1 2 3 4 5; do
        sleep 2
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            ok "${SERVICE_NAME} 已运行"
            return 0
        fi
    done
    warn "${SERVICE_NAME} 启动状态未稳定，请用 journalctl 查看"
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

security_notice() {
    section "安全提醒"
    cat >&2 <<EOF
* WebSSH 端口 ${WEBSSH_PORT} 监听 0.0.0.0（与原 Docker 版一致）。
  强烈建议：通过云厂商安全组只放行 ${WEB_PORT}（OCI Worker 主端口），
  不要把 ${WEBSSH_PORT} 暴露公网，避免被未授权访问。
* OCI Worker 已通过反向代理把 WebSSH 嵌入主面板，从公网访问 ${WEB_PORT} 即可使用全部功能。
* 推荐：用 Nginx 反向代理 + HTTPS（Let's Encrypt）保护 ${WEB_PORT}。
EOF
}

# -----------------------------------------------------------------------------
# ociworker management script installation
# -----------------------------------------------------------------------------
install_ociworker_cli() {
    # Source priority:
    #   1. Same dir as install.sh (development / cloned repo)
    #   2. master branch raw (always up-to-date)
    #   3. installer-latest release (fallback when raw is unreachable)
    local src=""
    local self_dir
    self_dir="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
    if [ -f "${self_dir}/ociworker" ]; then
        src="${self_dir}/ociworker"
    fi
    if [ -z "${src}" ]; then
        info "下载管理脚本 ociworker（优先 master 分支）..."
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
    install -m 0755 "${src}" "${OCIWORKER_BIN}"
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
truthy() {
    case "${1:-}" in 1|true|yes|y|Y) return 0 ;; *) return 1 ;; esac
}

# 决定 JAR 来自 `latest`（master）或 `ui-latest`（feature/ui-polish 预构建）
resolve_jar_release_tag() {
    JAR_RELEASE_TAG="${JAR_TAG_DEFAULT}"
    if [ -f "${UI_CHANNEL_FILE}" ]; then
        JAR_RELEASE_TAG="${JAR_TAG_UI}"
    fi
    if [ -n "${OCI_WORKER_UI:-}" ] && truthy "${OCI_WORKER_UI}"; then
        JAR_RELEASE_TAG="${JAR_TAG_UI}"
    fi
    if [ -n "${OCI_USE_MASTER_JAR:-}" ] && truthy "${OCI_USE_MASTER_JAR}"; then
        JAR_RELEASE_TAG="${JAR_TAG_DEFAULT}"
    fi
}

# 在完整安装/升级成功后再落盘，避免起不来时误切渠道
commit_ui_channel_state() {
    if [ "${JAR_RELEASE_TAG}" = "${JAR_TAG_UI}" ]; then
        touch "${UI_CHANNEL_FILE}" 2>/dev/null || true
    else
        rm -f "${UI_CHANNEL_FILE}" 2>/dev/null || true
    fi
}

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

    # WebSSH is optional; failure here should NOT abort the main install.
    if handle_existing_docker_webssh; then
        if download_webssh_binary; then
            write_webssh_systemd
            if systemctl restart "${WEBSSH_SERVICE_NAME}"; then
                ok "WebSSH 已启动（端口 ${WEBSSH_PORT}）"
            else
                warn "WebSSH 启动失败：journalctl -u ${WEBSSH_SERVICE_NAME} -n 30 --no-pager"
            fi
        else
            warn "WebSSH 下载失败，跳过（不影响主程序）"
            warn "稍后可重跑 install.sh，或用 ociworker update 重试"
        fi
    fi

    firewall_open_port "${WEB_PORT}"
    install_ociworker_cli

    if ! restart_with_rollback; then
        die "OCI Worker 启动失败，已尝试回滚。请查看日志后再决定是否重试。"
    fi

    commit_ui_channel_state

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
  * 不要放行 ${WEBSSH_PORT}/tcp（WebSSH 已通过反向代理嵌入主面板）

常用管理命令（敲 ociworker 进交互菜单）：
  ociworker status     查看状态
  ociworker logs       查看实时日志
  ociworker config     修改端口/数据库（含回滚；账号密码请在网页修改）
  ociworker update     更新到最新版本
  ociworker backup     备份数据库 + 配置 + 密钥
EOF
}

do_upgrade() {
    section "OCI Worker 升级模式"
    info "检测到已有安装：${INSTALL_DIR}"
    info "升级模式不会修改 application.yml 和数据库"

    install_jdk21

    info "停止 ${SERVICE_NAME}..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true

    # Backup current JAR before replacing
    if [ -f "${INSTALL_DIR}/${JAR_NAME}" ]; then
        cp -p "${INSTALL_DIR}/${JAR_NAME}" "${INSTALL_DIR}/${JAR_NAME}.bak"
    fi

    if ! download_jar; then
        warn "JAR 下载失败，恢复旧版本"
        [ -f "${INSTALL_DIR}/${JAR_NAME}.bak" ] && mv "${INSTALL_DIR}/${JAR_NAME}.bak" "${INSTALL_DIR}/${JAR_NAME}"
        systemctl start "${SERVICE_NAME}" || true
        die "升级失败"
    fi

    # WebSSH binary is optional during upgrade; keep existing if download fails.
    if handle_existing_docker_webssh; then
        if download_webssh_binary; then
            [ -f "${WEBSSH_SERVICE_FILE}" ] || write_webssh_systemd
            systemctl restart "${WEBSSH_SERVICE_NAME}" 2>/dev/null \
                || warn "WebSSH 重启失败：journalctl -u ${WEBSSH_SERVICE_NAME} -n 30 --no-pager"
        else
            warn "WebSSH 下载失败，保留原 WebSSH（不影响主程序）"
        fi
    fi

    install_ociworker_cli

    if restart_with_rollback; then
        # On success, drop the JAR backup
        rm -f "${INSTALL_DIR}/${JAR_NAME}.bak"
        commit_ui_channel_state
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
            systemctl restart "${SERVICE_NAME}" || true
            warn "已回滚到旧版本"
        fi
        die "升级失败，请查看日志"
    fi
}

main() {
    require_root
    resolve_jar_release_tag
    require_systemd
    ARCH="$(detect_arch)"

    local mode; mode="$(detect_mode)"
    case "${mode}" in
        install) do_install ;;
        upgrade) do_upgrade ;;
    esac
}

if [ "${1:-}" = "--ui" ]; then
    OCI_WORKER_UI=1
    shift
fi

main "$@"
