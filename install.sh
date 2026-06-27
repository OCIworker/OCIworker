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
# This script is INDEPENDENT of the original deploy.sh / update.sh.
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
readonly LEGACY_WEBSSH_BIN="${INSTALL_DIR}/oci-webssh"
readonly LEGACY_WEBSSH_SERVICE="oci-webssh"

readonly REPO="OCIworker/OCIworker"
readonly JAR_RELEASE_TAG="latest"
readonly INSTALLER_RELEASE_TAG="installer-latest"
readonly RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"

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
            *) warn "Please enter y or n" ;;
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
        printf "Please select [%s]: " "${default}" >&2
        IFS= read -r reply </dev/tty || reply=""
        reply="${reply:-${default}}"
        if [[ "${reply}" =~ ^[0-9]+$ ]] && [ "${reply}" -ge 1 ] && [ "${reply}" -le "${#options[@]}" ]; then
            printf "%s" "${reply}"
            return 0
        fi
        warn "Please enter a number from 1 to ${#options[@]}"
    done
}

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Please run as root: sudo bash install.sh"
    fi
}

require_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        die "systemd was not detected. This script only supports systemd-based Linux distributions such as Debian, Ubuntu, and CentOS."
    fi
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) die "Unsupported CPU architecture: ${arch} (only amd64 and arm64 are supported)" ;;
    esac
}

# Returns "x64" or "aarch64" for Adoptium download URL
detect_jdk_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *) die "Unsupported CPU architecture" ;;
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
        *)   warn "Unrecognized package manager. Skipping installation: $*" ;;
    esac
}

ensure_cmd() {
    # ensure_cmd <cmd> [pkg-name]
    local cmd="$1" pkg="${2:-$1}"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        info "${cmd} was not found. Trying to install ${pkg}..."
        pkg_install "${pkg}" || warn "Failed to install ${pkg}. Please install it manually and retry."
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
        ok "JDK 21 is already installed: $(java_version_line)"
        return 0
    fi
    info "Installing JDK 21 (Adoptium Temurin)..."
    ensure_cmd curl
    ensure_cmd tar
    local jdk_arch tmp
    jdk_arch="$(detect_jdk_arch)"
    tmp="${TMP_DIR}/jdk21.tar.gz"
    if ! curl -fSL --retry 3 --retry-delay 5 --connect-timeout 15 \
            -o "${tmp}" \
            "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-${JDK_VERSION_URLENC}/OpenJDK21U-jre_${jdk_arch}_linux_hotspot_${JDK_VERSION_FILE}.tar.gz"; then
        die "Failed to download JDK. Check network access to GitHub."
    fi
    mkdir -p "${JDK_INSTALL_BASE}"
    tar -xzf "${tmp}" -C "${JDK_INSTALL_BASE}" || die "Failed to extract JDK"
    local jdk_dir
    jdk_dir="$(ls -d "${JDK_INSTALL_BASE}"/jdk-21* 2>/dev/null | sort -V | tail -n 1 || true)"
    [ -n "${jdk_dir}" ] || die "JDK installation directory was not found"
    ln -sf "${jdk_dir}/bin/java" /usr/local/bin/java
    ok "JDK 21 installation completed ($(java_version_line))"
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
    docker logs oci-worker-mysql 2>&1 | grep -qE 'ready for connections.*port: 3306'
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
    info "Waiting for MySQL to become ready (up to 60 seconds)..."
    local waited=0 status consecutive=0
    while [ "${waited}" -lt 60 ]; do
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
                    ok "MySQL is ready"
                    return 0
                fi
                ;;
            auth_fail)
                printf "\n" >&2
                die "MySQL has started, but the username or password is incorrect. When reusing a container, enter the password used at initial creation. If you do not remember it, recreate the container or clear /opt/oci-worker/data/mysql and reinstall."
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
    info "Verifying database credentials..."
    local probe
    probe="$(probe_database)"
    case "${probe}" in
        ok)
            ok "Login succeeded"
            ;;
        auth_fail)
            die "Unable to connect to MySQL inside the container with the current username/password. The password must match the container initialization value, or you must recreate the container."
            ;;
        conn_fail)
            die "Unable to connect to 127.0.0.1:3306. Check the container: docker logs oci-worker-mysql"
            ;;
        *)
            die "MySQL returned an error: ${probe#other:}"
            ;;
    esac
    check_database_quality || die "Database self-check failed"
}

ensure_mysql_client() {
    if command -v mysql >/dev/null 2>&1; then
        return 0
    fi
    info "Installing MySQL client for database self-checks..."
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
            warn "Unable to install the mysql client automatically. Database self-checks will be skipped, which may hide setup issues."
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
        err "Unable to get MySQL version: ${out}"
        return 1
    fi
    local ver_line ver_major
    ver_line="$(echo "${out}" | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1)"
    ver_major="${ver_line%%.*}"
    if [ -z "${ver_major}" ] || [ "${ver_major}" -lt 8 ]; then
        err "MySQL version is too old: ${out} (8.0+ is required)"
        warn "Upgrade MySQL to 8.0 or later in your panel or server."
        return 1
    fi
    ok "MySQL version: ${ver_line:-${out}}"

    # Database existence
    out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "" \
            "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';")"
    if [ "${out}" != "${DB_NAME}" ]; then
        warn "Database \`${DB_NAME}\` does not exist or the current user cannot access it."
        if [ "$(ask_yes_no "Try to create the database automatically with the current account (utf8mb4)?" "Y")" = "y" ]; then
            local create_out
            create_out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "" \
                "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")"
            if [ -n "${create_out}" ]; then
                err "Automatic creation failed: ${create_out}"
                warn "Create database ${DB_NAME} manually in the panel with utf8mb4 charset, then grant access to user ${DB_USER}."
                return 1
            fi
            ok "Created database ${DB_NAME}"
        else
            warn "Create the database in the panel and retry."
            return 1
        fi
    else
        ok "Database ${DB_NAME} exists"
    fi

    # Charset check (after DB exists)
    out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "${DB_NAME}" \
        "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';")"
    case "${out}" in
        utf8mb4)
            ok "Charset: utf8mb4"
            ;;
        "")
            warn "Unable to read charset information, possibly due to insufficient permissions. Skipping this check."
            ;;
        *)
            warn "Charset is ${out}. Change it to utf8mb4 to avoid errors when storing emoji or special characters."
            if [ "$(ask_yes_no "Try to fix the charset automatically with ALTER DATABASE?" "Y")" = "y" ]; then
                local alter_out
                alter_out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "" \
                    "ALTER DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")"
                if [ -n "${alter_out}" ]; then
                    warn "ALTER failed, possibly due to insufficient permissions: ${alter_out}"
                    warn "Change database ${DB_NAME} to utf8mb4 in the panel and retry."
                else
                    ok "Charset fixed"
                fi
            fi
            ;;
    esac

    # Privilege probe: try to create+drop a temp table
    out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASS}" "${DB_NAME}" \
        "CREATE TABLE IF NOT EXISTS _ociworker_probe_(id INT) ENGINE=InnoDB; DROP TABLE _ociworker_probe_;")"
    if [ -n "${out}" ]; then
        err "DDL privilege test failed: ${out}"
        warn "Confirm that user ${DB_USER} has all privileges on database ${DB_NAME}."
        return 1
    fi
    ok "DDL privileges: passed"
    return 0
}

prompt_db_existing() {
    # User picks existing MySQL (1Panel / Aapanel / pre-installed).
    section "Database Connection Configuration"
    cat >&2 <<EOF
Make sure the following are ready in your panel:
  1. Database (recommended default name: oci_worker)
  2. User (recommended default name: oci_worker)
  3. Charset utf8mb4 / utf8mb4_unicode_ci
  4. The user has all privileges on this database
  5. The MySQL listening port is exposed to the host (127.0.0.1:3306 is usually enough)

EOF
    while true; do
        DB_HOST="$(ask "Database host" "127.0.0.1")"
        DB_PORT="$(ask "Database port" "3306")"
        DB_NAME="$(ask "Database name" "oci_worker")"
        DB_USER="$(ask "Username"      "oci_worker")"
        DB_PASS="$(ask_password "Password")"

        if [ -z "${DB_PASS}" ]; then
            warn "Password cannot be empty"
            continue
        fi

        info "Testing network connectivity to ${DB_HOST}:${DB_PORT}..."
        if command -v nc >/dev/null 2>&1; then
            if ! nc -z -w 5 "${DB_HOST}" "${DB_PORT}" 2>/dev/null; then
                err "Unable to connect to ${DB_HOST}:${DB_PORT}"
                cat >&2 <<'EOT'
Possible causes, roughly in order of likelihood:
  1. The MySQL container/service in the panel is not running, or the port is not mapped to the host
  2. The port is not the default 3306; check the actual port in the panel
  3. A firewall is blocking access; 127.0.0.1 usually is not blocked, but remote addresses need allow rules
EOT
                if [ "$(ask_yes_no "Re-enter connection information?" "Y")" = "y" ]; then continue; fi
                return 1
            fi
            ok "Network is reachable"
        else
            warn "nc is not installed. Skipping port probing."
        fi

        info "Testing login..."
        local probe; probe="$(probe_database)"
        case "${probe}" in
            ok)
                ok "Login succeeded"
                ;;
            auth_fail)
                err "Login failed: username/password is incorrect, or host access is restricted."
                cat >&2 <<EOT
Common causes:
  * The panel set this user to "local server (localhost)" access, but the script connects through 127.0.0.1.
    MySQL treats localhost (Unix socket) and 127.0.0.1 (TCP) as different hosts.
    Fix: change the user's access scope in the panel to "everyone (%)", or add 127.0.0.1.
  * The password is wrong.
EOT
                if [ "$(ask_yes_no "Re-enter connection information?" "Y")" = "y" ]; then continue; fi
                return 1
                ;;
            conn_fail)
                err "Unable to connect. Check the MySQL service and port."
                if [ "$(ask_yes_no "Re-enter connection information?" "Y")" = "y" ]; then continue; fi
                return 1
                ;;
            other:*)
                err "MySQL returned an error: ${probe#other:}"
                if [ "$(ask_yes_no "Re-enter connection information?" "Y")" = "y" ]; then continue; fi
                return 1
                ;;
        esac

        if check_database_quality; then
            ok "All database self-checks passed"
            return 0
        fi

        if [ "$(ask_yes_no "Database self-check failed. Re-enter information?" "Y")" = "y" ]; then
            continue
        fi
        return 1
    done
}

prompt_db_docker() {
    # Spin up an isolated MySQL 8.0 in Docker.
    section "Docker MySQL Automatic Installation"
    if ! command -v docker >/dev/null 2>&1; then
        info "Docker was not detected. Installing..."
        curl -fsSL https://get.docker.com | sh || die "Docker installation failed"
    fi
    DB_HOST="127.0.0.1"
    DB_PORT="3306"
    DB_NAME="$(ask "Database name" "oci_worker")"
    DB_USER="$(ask "Username"      "oci_worker")"
    DB_PASS="$(ask_password "New user password (at least 8 characters; letters and numbers recommended)")"
    while [ "${#DB_PASS}" -lt 6 ]; do
        warn "Password is too short"
        DB_PASS="$(ask_password "New user password")"
    done
    local root_pass
    root_pass="$(ask_password "root password (used for initialization; can match the password above)")"
    [ -n "${root_pass}" ] || root_pass="${DB_PASS}"

    if docker ps -a --format '{{.Names}}' | grep -qx "oci-worker-mysql"; then
        warn "Container oci-worker-mysql already exists"
        if [ "$(ask_yes_no "Recreate it? The /opt/oci-worker/data/mysql data directory will be kept." "N")" = "y" ]; then
            docker rm -f oci-worker-mysql >/dev/null
        else
            info "Reusing existing container"
        fi
    fi

    if docker ps -a --format '{{.Names}}' | grep -qx "oci-worker-mysql"; then
        if ! docker ps --format '{{.Names}}' | grep -qx "oci-worker-mysql"; then
            info "Starting existing container oci-worker-mysql..."
            docker start oci-worker-mysql >/dev/null || die "Failed to start container: docker start oci-worker-mysql"
            wait_docker_mysql_user || die "MySQL startup timed out. Check: docker logs oci-worker-mysql"
        fi
        verify_docker_mysql_credentials
        return 0
    fi

    info "Starting MySQL 8.0 container..."
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
        || die "Failed to start MySQL container"
    wait_docker_mysql_user || die "MySQL startup timed out. Check: docker logs oci-worker-mysql"
    verify_docker_mysql_credentials
}

prompt_db_root() {
    # User has MySQL root, let us auto-create db + user.
    section "Automatically Create Database and User with root"
    DB_HOST="$(ask "Database host" "127.0.0.1")"
    DB_PORT="$(ask "Database port" "3306")"
    local root_user root_pass
    root_user="$(ask "root username" "root")"
    root_pass="$(ask_password "root password")"

    DB_NAME="$(ask "New database name" "oci_worker")"
    DB_USER="$(ask "New username"      "oci_worker")"
    DB_PASS="$(ask_password "New user password")"
    while [ "${#DB_PASS}" -lt 6 ]; do
        warn "Password is too short"
        DB_PASS="$(ask_password "New user password")"
    done

    info "Testing connection with root..."
    local probe_out
    if mysql_select1_ok "${DB_HOST}" "${DB_PORT}" "${root_user}" "${root_pass}"; then
        ok "root login succeeded"
    else
        probe_out="$(mysql_cli_run "${DB_HOST}" "${DB_PORT}" "${root_user}" "${root_pass}" "" "SELECT 1")"
        die "root login failed: ${probe_out}"
    fi

    info "Creating database and user..."
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
        die "Failed to create database/user: ${create_out}"
    fi
    rm -f "${errf}"
    rm -f "${sql_file}"
    ok "Database ${DB_NAME} and user ${DB_USER} created"

    if ! check_database_quality; then
        die "Database self-check failed"
    fi
}

run_db_wizard() {
    section "Database Configuration"
    local choice
    choice="$(ask_choice "Choose how to use MySQL:" 1 \
        "I already have MySQL (1Panel/Aapanel/pre-installed service); enter connection details manually" \
        "I do not have a database; let the script install an isolated MySQL 8.0 with Docker" \
        "I have a MySQL root account; let the script create the database and user")"
    ensure_mysql_client
    case "${choice}" in
        1) prompt_db_existing || die "Database configuration was not completed. Installation exited. Fix the connection issue and rerun install.sh." ;;
        2) prompt_db_docker   || die "Docker MySQL installation failed. Check the error above." ;;
        3) prompt_db_root     || die "Automatic database creation with root failed. Check the error above." ;;
    esac
}

# -----------------------------------------------------------------------------
# Web settings
# -----------------------------------------------------------------------------
# Administrator account/password are not set in this script.
# The backend isSetupDone() check only looks for records in the oci_kv table.
# It does not use web.account / web.password from application.yml. Those YAML
# values are fallback defaults only when the database has been cleared and the
# user has not completed Setup in the browser yet.
# Therefore, this script only needs to:
#   1. Collect the web port
#   2. Write a placeholder admin account and random password to YAML
#   3. Guide the user to http://ip:port for first-time setup after deployment
WEB_PORT=""
WEB_DEFAULT_ACCOUNT="admin"
WEB_DEFAULT_PASSWORD=""
prompt_web() {
    section "Web Service Configuration"
    while true; do
        WEB_PORT="$(ask "OCI Worker Web port" "8818")"
        if [[ "${WEB_PORT}" =~ ^[0-9]+$ ]] && [ "${WEB_PORT}" -ge 1 ] && [ "${WEB_PORT}" -le 65535 ]; then
            if [ "${WEB_PORT}" -eq 8008 ]; then
                warn "Port 8008 is unavailable. Choose another port."
                continue
            fi
            break
        fi
        warn "Invalid port"
    done

    # 32 random hex bytes. This is only a YAML placeholder; actual login is
    # configured through the browser Setup flow.
    if command -v openssl >/dev/null 2>&1; then
        WEB_DEFAULT_PASSWORD="$(openssl rand -hex 16)"
    else
        WEB_DEFAULT_PASSWORD="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
    fi

    cat >&2 <<EOF

[i] The administrator account and password are not set in SSH. After the
    service starts, complete first-time setup in your browser:
       http://<your-ip>:${WEB_PORT}
    The backend stores the password securely in the database as a sha256 hash.

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
    info "Generating application.yml..."
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
  # Fallback defaults only. Set the real administrator account/password on first
  # web access. After setup, the password is stored as a sha256 hash in the
  # oci_kv database table and is unrelated to this file.
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
    ok "Configuration file written: ${CONFIG_FILE}"
}

write_systemd_unit() {
    info "Writing systemd service: ${SERVICE_NAME}..."
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
# Without this, systemd commonly defaults to about 90s. During stop, the script
# may show no new logs for a while and look stuck.
TimeoutStopSec=45

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    ok "systemd service registered"
}

# Existing deployments may still use an old unit without TimeoutStopSec. During
# upgrades, stop can wait for the full systemd default timeout, commonly ~90s.
apply_worker_stop_timeout_dropin() {
    mkdir -p "/etc/systemd/system/${SERVICE_NAME}.service.d"
    cat > "/etc/systemd/system/${SERVICE_NAME}.service.d/10-stop-timeout.conf" <<'EOF'
[Service]
TimeoutStopSec=45
EOF
    systemctl daemon-reload
}

# -----------------------------------------------------------------------------
# JAR download
# -----------------------------------------------------------------------------
download_with_retry() {
    # download_with_retry <url> <dest>
    local url="$1" dest="$2"
    info "Downloading: ${url}"
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
    info "Downloading JAR (release: ${JAR_RELEASE_TAG})..."
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
            err "JAR download failed"
            err "If you see a 404, the code may have just been pushed or the GitHub Release may still be updating. Wait a few minutes and confirm that ${JAR_ASSET} exists under release ${JAR_RELEASE_TAG}."
            return 1
        fi
        warn "JAR download failed. Retrying in 20 seconds (${attempt}/${max}); this is common right after GitHub updates."
        sleep 20
    done
    size="$(file_size "${tmp}")"
    if [ "${size}" -lt 1000000 ]; then
        rm -f "${tmp}"
        err "Downloaded JAR size looks abnormal (${size} bytes); this may be a 404 page."
        return 1
    fi
    # Quick sanity: must be a valid ZIP/JAR
    if command -v unzip >/dev/null 2>&1; then
        if ! unzip -tq "${tmp}" >/dev/null 2>&1; then
            rm -f "${tmp}"
            err "Downloaded JAR is corrupt. Please retry."
            return 1
        fi
    fi
    mv "${tmp}" "${INSTALL_DIR}/${JAR_NAME}"
    ok "JAR is ready: $(numfmt --to=iec "${size}" 2>/dev/null || echo "${size} bytes")"
    return 0
}

# -----------------------------------------------------------------------------
# Install / restart with rollback
# -----------------------------------------------------------------------------
restart_with_rollback() {
    info "Starting ${SERVICE_NAME}..."
    if ! systemctl restart "${SERVICE_NAME}"; then
        warn "Service startup failed. Trying to roll back configuration..."
        local last_bak
        last_bak="$(ls -1t "${CONFIG_FILE}.bak."* 2>/dev/null | head -n 1 || true)"
        if [ -n "${last_bak}" ]; then
            cp -p "${last_bak}" "${CONFIG_FILE}"
            systemctl restart "${SERVICE_NAME}" || true
            warn "Rolled back to previous configuration: ${last_bak}"
        fi
        err "Check logs: journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
        return 1
    fi

    # Wait briefly for service to settle.
    local i
    for i in 1 2 3 4 5; do
        sleep 2
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            ok "${SERVICE_NAME} is running"
            return 0
        fi
    done
    warn "${SERVICE_NAME} startup status is not stable yet. Check with journalctl."
    return 1
}

# -----------------------------------------------------------------------------
# Firewall hint
# -----------------------------------------------------------------------------
firewall_open_port() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        info "ufw allowed ${port}/tcp"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "firewalld allowed ${port}/tcp"
    fi
}

cleanup_legacy_webssh() {
    systemctl stop "${LEGACY_WEBSSH_SERVICE}" 2>/dev/null || true
    systemctl disable "${LEGACY_WEBSSH_SERVICE}" 2>/dev/null || true
    rm -f "${LEGACY_WEBSSH_BIN}"
    rm -f "/etc/systemd/system/${LEGACY_WEBSSH_SERVICE}.service"
    systemctl daemon-reload 2>/dev/null || true
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "webssh"; then
        docker stop webssh >/dev/null 2>&1 || true
        (cd /opt/oci-worker/webssh 2>/dev/null && docker compose down >/dev/null 2>&1) || true
    fi
}

security_notice() {
    section "Security Notice"
    cat >&2 <<EOF
* Recommended: protect port ${WEB_PORT} with an Nginx reverse proxy and HTTPS (Let's Encrypt).
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
        info "Downloading ociworker management script (main branch first)..."
        local tmp="${TMP_DIR}/ociworker"
        if download_with_retry "${RAW_BASE}/ociworker" "${tmp}"; then
            src="${tmp}"
        elif download_with_retry "https://github.com/${REPO}/releases/download/${INSTALLER_RELEASE_TAG}/ociworker" "${tmp}"; then
            src="${tmp}"
        else
            warn "Unable to download ociworker. The main application can still run; you can install it manually later."
            return 0
        fi
    fi
    install -m 0755 "${src}" "${OCIWORKER_BIN}"
    # python3 is required by `ociworker config` for safe YAML editing.
    if ! command -v python3 >/dev/null 2>&1; then
        info "Installing python3, required by the ociworker config subcommand..."
        pkg_install python3 || warn "python3 could not be installed automatically; the ociworker config subcommand will be unavailable."
    fi
    ok "Management script installed: ${OCIWORKER_BIN} (run \`ociworker\` for the menu)"
}

# =============================================================================
# Main entry points
# =============================================================================
do_install() {
    section "OCI Worker Smart Installation Wizard"
    info "System architecture: $(uname -m) (mapped to ${ARCH})"
    install_jdk21

    run_db_wizard
    prompt_web

    section "Download and Deploy"
    mkdir -p "${INSTALL_DIR}" "${KEYS_DIR}" "${BACKUP_DIR}"
    download_jar || die "JAR download failed. Cannot continue installation."
    write_application_yml
    write_systemd_unit

    cleanup_legacy_webssh

    firewall_open_port "${WEB_PORT}"
    install_ociworker_cli

    if ! restart_with_rollback; then
        die "OCI Worker failed to start. Rollback was attempted. Check logs before deciding whether to retry."
    fi

    security_notice

    local pub_ip
    pub_ip="$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "<your-server-ip>")"
    section "Deployment Complete"
    cat >&2 <<EOF
Access URL:    http://${pub_ip}:${WEB_PORT}

Next steps (required):
  1. Open the access URL above in your browser
  2. Follow the page prompts to set the administrator account and password (password must be at least 6 characters)
  3. Log in after setup is complete

Firewall reminder:
  * Local ufw / firewalld has automatically allowed ${WEB_PORT}/tcp
  * Also allow ${WEB_PORT}/tcp in your cloud security group (OCI/AWS/Tencent Cloud, etc.)
Common management commands (run ociworker for the interactive menu):
  ociworker status     Show status
  ociworker logs       Show live logs
  ociworker config     Change port/database with rollback; change account/password in the web UI
  ociworker update     Update to the latest version
  ociworker backup     Back up database, configuration, and keys
  ociworker tg-clean   Clear Telegram binding; uses Docker MySQL automatically if host mysql is missing
EOF
}

do_upgrade() {
    section "OCI Worker Upgrade Mode"
    info "Existing installation detected: ${INSTALL_DIR}"
    info "Upgrade mode will not modify application.yml or the database"

    install_jdk21

    apply_worker_stop_timeout_dropin

    info "Stopping ${SERVICE_NAME}..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true

    # Backup current JAR before replacing
    if [ -f "${INSTALL_DIR}/${JAR_NAME}" ]; then
        cp -p "${INSTALL_DIR}/${JAR_NAME}" "${INSTALL_DIR}/${JAR_NAME}.bak"
    fi

    if ! download_jar; then
        warn "JAR download failed. Restoring old version."
        [ -f "${INSTALL_DIR}/${JAR_NAME}.bak" ] && mv "${INSTALL_DIR}/${JAR_NAME}.bak" "${INSTALL_DIR}/${JAR_NAME}"
        systemctl start "${SERVICE_NAME}" || true
        die "Upgrade failed"
    fi

    cleanup_legacy_webssh

    install_ociworker_cli

    if restart_with_rollback; then
        # On success, drop the JAR backup
        rm -f "${INSTALL_DIR}/${JAR_NAME}.bak"
        ok "Upgrade completed"
        local cur_port
        cur_port="$(awk '/^server:/{f=1;next} f && /^[^ ]/{f=0} f && /port:/{print $2; exit}' "${CONFIG_FILE}" 2>/dev/null | tr -d '"'\''' || true)"
        cur_port="${cur_port:-8818}"
        local pub_ip
        pub_ip="$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "<your-server-ip>")"
        section "Upgrade Complete"
        cat >&2 <<EOF
Access URL:    http://${pub_ip}:${cur_port}
View logs:     journalctl -u ${SERVICE_NAME} -f
Management:    ociworker
EOF
    else
        warn "New version failed to start. Rolling back to the old JAR..."
        if [ -f "${INSTALL_DIR}/${JAR_NAME}.bak" ]; then
            mv "${INSTALL_DIR}/${JAR_NAME}.bak" "${INSTALL_DIR}/${JAR_NAME}"
            systemctl restart "${SERVICE_NAME}" || true
            warn "Rolled back to the old version"
        fi
        die "Upgrade failed. Check logs."
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
