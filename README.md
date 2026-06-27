# OCI Worker

OCI Worker is an Oracle Cloud Infrastructure (OCI) management panel built with Spring Boot 3, Vue 3, and Ant Design Vue.

> The v2 smart installer is available now: a guided deployment flow that takes about 5 minutes, supports existing MySQL from 1Panel/Aapanel, performs database self-checks, protects configuration changes with rollback, and installs the `ociworker` management CLI. See "One-Click Installation" below.

## Features

- **Multi-tenant configuration management**: add, edit, delete, and batch import OCI configs; drag-and-drop PEM upload.
- **Batch instance claiming with resume support**: run tasks across multiple tenants, persist tasks, and resume automatically after service restarts.
- **Instance management**: start, stop, restart, terminate, rename, edit Flex shape settings, and view security lists, boot volumes, networking, and traffic statistics in one place.
- **User management**: list domain users, create users, reset passwords, clear MFA, and manage administrator groups.
- **IP management**: change public IPs, manage ephemeral and reserved IPs, add secondary IPs, and use IPv6.
- **Security list management**: view, add, and delete ingress/egress rules; allow all ports with one action.
- **Boot volume management**: view and edit boot volumes, with quick presets for 50/100/150/200 GB and 120 VPUs/GB.
- **Serial console**: connect to instance serial consoles through OCI internal channels and open WebSSH for emergency recovery when networking fails.
- **Virtual cloud network tools**: view VCNs and subnets, and create, bind, unbind, or delete reserved IPs.
- **Live logs**: stream full backend logs in real time over WebSocket.
- **Notifications**: Telegram Bot notifications for login events, tasks, and daily reports.
- **System updates**: check for updates from the web UI and automatically pull the latest version from GitHub Releases.
- **Encrypted backup and restore**: migrate data safely.
- **Login security**: set a custom administrator account on first use, use 24-hour tokens, change passwords online, and protect login with Telegram verification codes.

## Tech Stack

- **Backend**: Spring Boot 3.5, JDK 21 with virtual threads, MyBatis-Plus, MySQL 8.0
- **Frontend**: Vue 3, Vite, Ant Design Vue 4, Pinia, Vue Router 4
- **OCI SDK**: oci-java-sdk 3.83+

## One-Click Installation (Recommended, v2 Smart Installer)

Works on Debian, Ubuntu, and CentOS, with ARM64 and AMD64 support. The installer is fully interactive and does not require manual file edits after deployment.

### What It Does

- Installs JDK 21, downloads the latest JAR, creates the systemd service, and opens the local firewall port.
- Offers three database paths: existing MySQL from 1Panel/Aapanel or another panel, Docker-managed MySQL 8.0, or automatic database/user creation with a MySQL root account.
- Runs database self-checks for connectivity, version, charset, and DDL privileges, then shows actionable fixes on failure.
- Automatically rolls back `application.yml` if a configuration change prevents the service from starting.
- Installs the `ociworker` management CLI for status, logs, backups, upgrades, and uninstall.

### Install Command

Download and run the installer:

```bash
curl -fsSL https://github.com/OCIworker/OCIworker/releases/download/installer-latest/install.sh -o /tmp/install.sh
sudo bash /tmp/install.sh
```

The wizard asks for the database mode, database connection details, and web port. After installation, open `http://<your-ip>:<port>` in your browser to set the administrator account.

Full documentation: [INSTALLER.md](./INSTALLER.md)

## One-Click Update

### Option 1: Management CLI (Recommended)

```bash
sudo ociworker update
```

This stops the service, backs up the old JAR, downloads the new JAR, starts the new version, and automatically rolls back to the old JAR if startup fails.

### Option 2: Web UI Update

Open "System Settings -> System Update", click "Check for updates", then use "One-click update". The panel downloads and restarts automatically.

### Option 3: Rerun the Installer

`install.sh` automatically detects upgrade mode. It only replaces the JAR and WebSSH binary, and does not modify `application.yml` or the database:

```bash
sudo bash /tmp/install.sh
```

## Daily Management: `ociworker`

> Avoid mixing installation modes.
> The recommended Docker database path is: run the `install.sh` wizard, choose "install MySQL with Docker", use container `oci-worker-mysql`, and keep `application.yml` pointing at `localhost:3306`. See [INSTALLER.md](./INSTALLER.md).
> In this mode, the host usually does not have a `mysql` command. Use `ociworker tg-clean`, which can automatically enter the Docker container.

### Docker Install: Clear Telegram Binding

When the panel reports "Telegram lost", run:

```bash
sudo ociworker tg-clean
# Or use the ociworker menu: 11) Clear TG binding
```

The script reads credentials from `/opt/oci-worker/application.yml`, enters the `oci-worker-mysql` container, and deletes `tg_%` entries from `oci_kv` in the same database used by the panel. To refresh the script:

```bash
sudo curl -fsSL https://raw.githubusercontent.com/OCIworker/OCIworker/main/ociworker -o /usr/local/bin/ociworker
sudo chmod +x /usr/local/bin/ociworker
```

Common commands:

```bash
ociworker                  # Open the interactive menu
ociworker status           # Service status
ociworker start/stop/restart
ociworker logs             # Live logs
ociworker config           # Change port/database with rollback; change account/password in the web UI
ociworker update           # One-click upgrade
ociworker backup           # Back up database, configuration, and keys
ociworker restore <file>   # Restore from a backup
ociworker tg-clean         # Clear Telegram binding; uses Docker MySQL automatically if host mysql is missing
ociworker version          # Show version information
ociworker uninstall        # Uninstall with confirmation at every step
```

## Using Panel-Managed MySQL (1Panel / Aapanel)

### Prepare These Three Things in the Panel

1. **Database**: name it `oci_worker` and use charset `utf8mb4 / utf8mb4_unicode_ci`. This is required to store emoji and special characters correctly.
2. **User**: grant all privileges on that database, and set access to **everyone (%)**. Choosing only `localhost` can cause Access denied errors because the installer connects to `127.0.0.1`.
3. **MySQL version**: use MySQL 8.0 or later. MySQL 5.7 is not supported.

Then run `install.sh`, choose "1) existing MySQL", and enter the connection details.

### Move an Existing Installation to Panel-Managed MySQL

Migrate data before changing the connection. Otherwise the panel will point at an empty database and ask for first-time setup again.

```bash
# 1. Back up current data
ociworker backup
# Output: /opt/oci-worker/backups/backup-xxxxxxxx-xxxx.tar.gz

# 2. Import dump.sql into the new panel database
cd /tmp && tar xzf /opt/oci-worker/backups/backup-*.tar.gz
mysql -h127.0.0.1 -P<panel-mysql-port> -uoci_worker -p oci_worker < dump.sql

# 3. Switch to the new database in one operation with restart validation and rollback
ociworker config
```

If even automatic rollback fails, restore a previous version from `/opt/oci-worker/application.yml.bak.*`.

## Configuration

Edit `/opt/oci-worker/application.yml` if you must:

```yaml
server:
  port: 8818            # Service port

web:
  account: admin        # Default login account before first browser setup
  password: admin123    # Default password before first browser setup

spring:
  datasource:
    url: jdbc:mysql://localhost:3306/oci_worker?useUnicode=true&characterEncoding=utf8&useSSL=false&serverTimezone=Asia/Shanghai&allowPublicKeyRetrieval=true
    username: oci_worker
    password: ociworker123

oci-cfg:
  key-dir-path: ./keys  # PEM key directory
```

### Manually Create the MySQL Database

If you use an existing MySQL service, create the database first:

```sql
CREATE DATABASE IF NOT EXISTS oci_worker
  DEFAULT CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'oci_worker'@'%' IDENTIFIED BY 'ociworker123';
GRANT ALL PRIVILEGES ON oci_worker.* TO 'oci_worker'@'%';
FLUSH PRIVILEGES;
```

## Directory Layout

This repository is used for installation and release assets. It does not contain the application source code. The application JAR is published in [Releases `latest`](https://github.com/OCIworker/OCIworker/releases/tag/latest).

```text
/opt/oci-worker/          # Production deployment directory
|-- oci-worker.jar        # Application JAR from Release latest
|-- oci-webssh            # WebSSH binary
|-- application.yml       # Configuration file, mode 600
|-- application.yml.bak.* # Automatic configuration backup history
|-- keys/                 # PEM key directory
`-- backups/              # ociworker backup output directory

/usr/local/bin/ociworker  # Management CLI
```

## Disclaimer

- You are responsible for account bans caused by excessive instance starts or public IP changes.
- Use Nginx reverse proxy with HTTPS when possible.
- Use key-based SSH login to reduce brute-force risk.
- Bind MySQL to `127.0.0.1` and never expose it to the public internet, or attackers may wipe the database.
- First installation guides you through administrator account setup; the password must be at least 6 characters.
