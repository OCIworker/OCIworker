# OCI Worker

基于 Spring Boot 3 + Vue 3 的 **Oracle Cloud (OCI) 管理面板**。本仓库**只放安装说明**；**主程序 JAR、安装脚本、WebSSH 二进制**在 [GitHub Releases](https://github.com/OCIworker/OCIworker/releases)：

| Release 标签 | 内容（安装器会按标签下载） |
|--------------|----------------------------|
| `installer-latest` | `install.sh`、`ociworker`、Linux `amd64` / `arm64` 的 `oci-webssh` |
| `latest` | 主程序 `oci-worker-1.0.0.jar`（升级与面板「检查更新」会用到） |

> **v2 智能安装器**：向导部署，支持 1Panel / 宝塔已有 MySQL、数据库自检、配置改坏回滚、附带 `ociworker` 命令。详细说明见 [INSTALLER.md](./INSTALLER.md)。

## 功能概览

- 多租户 OCI 配置、抢机、实例/网络/安全列表/WebSSH/VCN 等常用能力  
- Telegram 通知、面板内/命令行**从本仓库 Releases 拉包**更新、备份与首次管理员设置等  

（完整产品能力以安装后界面为准。）

---

## 安装前请确认（测试/正式环境通用）

- **系统**：64 位 **Debian / Ubuntu / CentOS**，CPU 为 **x86_64（amd64）** 或 **ARM64**  
- **权限**：有 **root** 或可用 **`sudo`** 执行安装脚本与写 `/opt`、systemd  
- **网络**：服务器能访问 **`github.com`** 及 Releases 资源（`curl` 要成功拉取；国内若不稳需自备代理/镜像，否则第一行会失败）  
- **本机工具**：有 **`curl`**、**`bash`**

以上满足后，再执行下方命令。

---

## 一键安装（v2）

全程交互，一般**无需**事后再手改文件。安装器会装 **JDK 21**、从 Releases 拉取 **JAR 与 WebSSH 二进制**、写 **systemd** 等。数据库可自选：已有 MySQL、脚本用 Docker 装、或本机有 root 时由脚本建库。

**在服务器上复制执行**（**两行都要执行**；第一行必须完整，结尾是 **`/tmp/install.sh`**，不是 `/tmp/`）：

```bash
curl -fsSL https://github.com/OCIworker/OCIworker/releases/download/installer-latest/install.sh -o /tmp/install.sh
sudo bash /tmp/install.sh
```

非 root 登录时务必带 `sudo`；已是 root 时可直接 `bash /tmp/install.sh`（见 [INSTALLER.md](./INSTALLER.md) 说明）。

安装向导会问：**① 数据库使用方式 ② 连接信息 ③ Web 端口**。完成后浏览器访问 `http://<你的IP或域名>:<端口>`，按页面完成**首次设置管理员**再登录。

---

## 装好后：怎么更新

```bash
sudo ociworker update
```

或在 Web：**系统设置 → 系统更新**。  
也可再运行之前的 `/tmp/install.sh`（**升级模式**会更新 JAR 和 WebSSH，**不随便覆盖**你现有的 `application.yml` 和数据库，具体以安装器行为为准）。

---

## 日常命令：`ociworker`

分条执行即可（勿把多条粘成一行）：

```bash
ociworker                  # 交互菜单
ociworker status
ociworker start
ociworker stop
ociworker restart
ociworker logs
ociworker config
ociworker update
ociworker backup
ociworker restore <备份包路径>
ociworker version
ociworker uninstall
```

---

## 1Panel / 宝塔 上已有 MySQL 时

1. 建库名 **`oci_worker`**，字符集 **utf8mb4**，排序 **utf8mb4_unicode_ci**  
2. 为专用用户授该库**全部权限**，**主机**选 **%**（只 `localhost` 很容易连失败）  
3. MySQL **8.0 及以上**  

装完后要迁库：先 `ociworker backup` 再导库，最后 `ociworker config` 改连新库；细节见 [INSTALLER.md](./INSTALLER.md)。

---

## 服务器上常见路径

| 说明 | 路径 |
|------|------|
| 主程序 | `/opt/oci-worker/oci-worker.jar` |
| WebSSH 二进制 | `/opt/oci-worker/oci-webssh` |
| 主配置 | `/opt/oci-worker/application.yml` |
| PEM 等 | `/opt/oci-worker/keys/` |
| 备份输出 | `/opt/oci-worker/backups/` |
| 管理命令 | `/usr/local/bin/ociworker` |

---

## 安装/更新失败时先看这些

- **`curl` 报错、404、空文件**：能否访问 GitHub、Release 里是否仍有 [installer-latest](https://github.com/OCIworker/OCIworker/releases/tag/installer-latest) 附件。  
- **`Permission denied`**：是否用了 `root` / `sudo`。  
- **端口/防火墙**：向导里填的 **Web 端口**在安全组/防火墙中是否放行。  

仍有问题可打开 [INSTALLER.md](./INSTALLER.md) 的「常见问题」一节。

---

## 免责声明

- 因 OCI 操作或抢机/换 IP 过频等导致的账号、合规风险，由使用者自行承担。  
- 生产环境建议 **HTTPS**（Nginx 等反代）与 **SSH 密钥**登录。  
- **不要**把 MySQL 对公网暴露；建议只监听本机或内网。
