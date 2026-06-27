# OCI Worker Smart Installer (v2)

> This repository provides **install.sh + the ociworker CLI** and GitHub Releases (`latest` / `installer-latest`).
> Use the wizard below for new servers. For existing deployments, use `ociworker update` or rerun `install.sh` to upgrade.

## What It Solves

| Pain point | Manual config / commands | New install.sh |
| --- | --- | --- |
| Editing DB settings with `nano application.yml` after installation | Required | Entered directly in the wizard |
| Database connection failures with unclear causes | Troubleshoot manually | Automatic diagnosis with specific fixes |
| Using existing MySQL from 1Panel/Aapanel | Edit YAML manually | Dedicated wizard branch with tests and charset checks |
| Broken config prevents service startup | Restore manually | Automatic rollback to the previous version |
| Upgrades require many commands | Multi-step systemctl + curl | `ociworker update` or rerun install |
| Daily operations such as logs, restart, backup, uninstall | Multiple systemctl/journalctl commands | `ociworker` interactive menu |
| WebSSH depends on Docker | Common in older setups | Built-in binary, no Docker dependency |

## Release Assets

- Application JAR: **[`latest`](https://github.com/OCIworker/OCIworker/releases/tag/latest)** release
- Installer and CLI: **[`installer-latest`](https://github.com/OCIworker/OCIworker/releases/tag/installer-latest)** release (`install.sh`, `ociworker`)
- The systemd service name is `oci-worker`, compatible with earlier manual deployment paths. If `/opt/oci-worker` already exists, `install.sh` detects upgrade mode.

## Installation

Debian's default root shell is dash and does not support `<()` process substitution. Downloading first is recommended:

```bash
curl -fsSL https://github.com/OCIworker/OCIworker/releases/download/installer-latest/install.sh -o /tmp/install.sh
bash /tmp/install.sh
```

You can also pipe into bash on systems where root uses bash, such as many Ubuntu and CentOS setups:

```bash
curl -fsSL https://github.com/OCIworker/OCIworker/releases/download/installer-latest/install.sh | bash
```

The wizard asks for:

1. Database mode: existing MySQL from 1Panel/Aapanel, Docker-managed MySQL, or automatic creation with a MySQL root account.
2. Database connection details, with automatic tests and self-checks.
3. Web port.

Setup takes about 5 minutes. The installer does not set the administrator account/password over SSH. After the service starts, open `http://<ip>:<port>` in your browser and complete first-time setup. This is intentional: the backend stores the account password as a sha256 hash in the database, not in plaintext YAML.

## Upgrade

Use either command:

```bash
ociworker update
```

Or rerun `install.sh`. It automatically detects upgrade mode, replaces only the JAR, keeps `application.yml` and the database unchanged, and disables/removes the old standalone `oci-webssh` service if it exists.

If startup fails after an upgrade, the script automatically rolls back to the previous JAR.

## Using Existing MySQL from 1Panel / Aapanel

Choose option **1** in the first wizard step. Prepare the following first:

1. Create database `oci_worker` with charset `utf8mb4 / utf8mb4_unicode_ci`.
2. Create user `oci_worker`, grant it access to database `oci_worker`, and set access scope to **everyone (%)**. If you choose localhost only, authentication can fail because `127.0.0.1` is not the same as `localhost`.
3. Save the database password and enter it in the wizard.

The wizard checks:

- Whether the port is reachable.
- Whether login succeeds, including host restriction diagnosis on failure.
- MySQL version 8.0 or later.
- Database existence, charset, and DDL privileges.

Every failed check includes concrete remediation steps.

## Installing MySQL with Docker (Wizard Option 2)

The v2 installer:

- Creates or reuses container **`oci-worker-mysql`** on **`127.0.0.1:3306`**.
- Writes the connection to `/opt/oci-worker/application.yml`, with `spring.datasource.url` pointing at `localhost:3306`.
- Deploys `/usr/local/bin/ociworker`.

The host often will not have the `mysql` client installed. If `ensure_mysql_client` fails, the installer warns and continues. Use these paths:

| Operation | Method |
| --- | --- |
| Clear TG binding | `sudo ociworker tg-clean` or menu item `11) Clear TG binding`; it automatically runs `docker exec oci-worker-mysql` and reads the password from YAML |
| Inspect TG settings in the database | Prefer the list shown by `ociworker tg-clean` before deletion; do not guess the password, use `spring.datasource.password` from YAML |
| Back up the database | Install `default-mysql-client` and run `ociworker backup`, or run `docker exec oci-worker-mysql mysql ...` manually |

After clearing Telegram settings, the script prints: **Telegram notification settings have been cleared. Please log in to the panel and bind Telegram again.**

## Daily Management: `ociworker`

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

WebSSH is built into OCI Worker and starts/stops with the main service. It does not need or provide a separate toggle command.

When `ociworker config` changes settings, it backs up the original YAML first. If the new configuration fails to start, it automatically restores the previous version so the panel is not locked out by a bad edit.

## Installation Paths

| Path | Purpose |
| --- | --- |
| `/opt/oci-worker/oci-worker.jar` | Main application JAR |
| `/opt/oci-worker/application.yml` | Configuration file, mode 600 |
| `/opt/oci-worker/application.yml.bak.*` | Automatic configuration backup history |
| `/opt/oci-worker/keys/` | OCI PEM keys |
| `/opt/oci-worker/backups/` | `ociworker backup` output |
| `/etc/systemd/system/oci-worker.service` | Main application systemd unit |
| `/usr/local/bin/ociworker` | Management script |
| `/usr/local/bin/java` | JDK 21 symlink |

## Compatibility with Existing Deployments

| Scenario | Behavior |
| --- | --- |
| `/opt/oci-worker` already exists when install runs | Detects upgrade mode and keeps data plus `application.yml` |
| Docker or old standalone WebSSH is detected | Warns and cleans it during upgrade to avoid conflicts with the built-in terminal |
| Database schema differs | Backend automatically runs ALTER during startup |

## Security Notes

- WebSSH port `8008` listens on `0.0.0.0`, matching the old Docker behavior. Only allow the main web port, default `8818`, in your cloud security group. Do not expose `8008` publicly.
- OCI Worker embeds WebSSH into the main panel through a reverse proxy. Access the main port to use all WebSSH features.
- Use Nginx reverse proxy with Let's Encrypt HTTPS for the main port.
- Bind MySQL to `127.0.0.1`.

## Private Repository Usage

If the project repository becomes private:

1. The `installer-latest` release download needs a GitHub token:

   ```bash
   GH_TOKEN=ghp_xxx
   curl -fsSL -H "Authorization: token ${GH_TOKEN}" \
     https://api.github.com/repos/OCIworker/OCIworker/releases/tags/installer-latest \
     | grep browser_download_url | grep install.sh | cut -d'"' -f4 \
     | xargs curl -fsSL -H "Authorization: token ${GH_TOKEN}" -o install.sh
   bash install.sh
   ```

2. Or mirror `install.sh` to a public static address such as OSS, R2, or a public gist to keep a one-line install flow.

3. Add a read-only deploy key in repository Settings -> Deploy keys and reference it from `install.sh` if needed. Evaluate the security implications before doing this.

## Uninstall

```bash
ociworker uninstall
```

Every destructive step asks for confirmation: delete `/opt/oci-worker`, delete the MySQL container, delete the data directory, and so on.

## FAQ

**Q: Can I roll back to an older JAR after upgrading?**
A: Yes. `ociworker update` pulls from the `latest` release and automatically rolls back if the new version fails to start. For a full reinstall, run `ociworker uninstall`, keep `/opt/oci-worker`, then run `install.sh` again.

**Q: Will upgrades lose data?**
A: No. Upgrade mode only replaces the JAR. It does not touch `application.yml` or the database. During backend startup, `DatabaseGuardService` automatically adds new tables or fields with ALTER, preserving existing data.

**Q: Backend code was updated. Can I install directly?**
A: Yes. After the new JAR is published to the `latest` release, both `ociworker update` and rerunning `install.sh` pull the latest version.

**Q: What if I break application.yml?**
A: `ociworker config` creates a backup before changes and rolls back automatically if startup fails. If you edited the file manually, restore a previous version from `/opt/oci-worker/application.yml.bak.*`.

**Q: Why does the script not set the administrator account/password?**
A: Backend `AuthController` decides whether first-time setup is complete by checking the `oci_kv` database table for `web_account` and `web_password`. It does not read `web.account` or `web.password` from `application.yml`. Those YAML values are fallback defaults only when the database is empty and setup has not been completed in the browser. Setting credentials in the script would be misleading, so the installer intentionally guides users to browser setup instead. The database stores a sha256 hash, which is safer than plaintext YAML.

**Q: What if I forgot the web administrator password?**
A: You have three options:

1. If Telegram login was bound, choose "TG verification code" on the web login page, log in, and change the password.
2. Delete the password records from the database to trigger setup again:

   ```sql
   DELETE FROM oci_kv WHERE type='sys_config' AND code IN ('web_account','web_password');
   ```

   Refresh the browser after deletion. The panel returns to the Setup page so you can set a new account and password without losing other data.
3. As a last resort, run `ociworker uninstall`, keep the data directory, and install again. Data is retained and the password returns to the Setup flow.
