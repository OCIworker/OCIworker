# OCI Worker 智能安装器（v2）

本说明配合本仓库 **Releases** 中的 `install.sh` 使用。安装程序、JAR、WebSSH 二进制均从 **GitHub Releases** 下载，**不需要**在本机保留任何业务源码。

## 安装

**Debian** 默认 root 为 dash，不支持 `bash <(curl …)` 这种写法，**建议先下载再执行**：

```bash
curl -fsSL https://github.com/OCIworker/OCIworker/releases/download/installer-latest/install.sh -o /tmp/install.sh
sudo bash /tmp/install.sh
```

或用 root 执行 `bash /tmp/install.sh`（未用 `sudo` 时也请保证是 root）。

可选「管道」方式（环境为 bash 时）：

```bash
curl -fsSL https://github.com/OCIworker/OCIworker/releases/download/installer-latest/install.sh | sudo bash
```

向导会依次询问：

1. 数据库方式：**已有 MySQL（1Panel/宝塔等）** / **Docker 装 MySQL 8** / **本机 root 自动建库**  
2. 数据库连接（会做多项自检，不通过会给出可操作的修复建议）  
3. Web 服务端口  

**管理员账号**不在 SSH 里设置，服务起来后在浏览器 `http://<IP>:<端口>` 走首次设置流程；密码以数据库中的哈希保存，比写在配置文件里更安全。

## 升级

任选其一：

```bash
sudo ociworker update
```

或再次执行之前保存的 `install.sh`（**升级模式**只更新 JAR 与 `oci-webssh` 二进制，**不会**乱改 `application.yml` 和已有数据库）。失败时安装器/脚本会尽量回滚到上一版 JAR。

## 与 1Panel / 宝塔 已有 MySQL 配合

先在面板中：

1. 建库名 `oci_worker`，字符集 **utf8mb4**，排序 **utf8mb4_unicode_ci**  
2. 用户授权该库 **全部**权限，**主机**选 **%**（不要只 `localhost`）  
3. 记录主机、端口、用户、密码

向导第一步选「1）已有 MySQL」并填写。若连接失败，脚本会结合错误信息提示（例如主机限制、版本低于 8.0 等）。

## 安装后的路径

| 路径 | 说明 |
|------|------|
| `/opt/oci-worker/oci-worker.jar` | 主程序 |
| `/opt/oci-worker/oci-webssh` | WebSSH 二进制（端口 8008，与面板反代配合） |
| `/opt/oci-worker/application.yml` | 主配置，权限通常为 600 |
| `/opt/oci-worker/application.yml.bak.*` | 自动备份，改坏可手工恢复 |
| `/opt/oci-worker/keys/` | OCI PEM 等 |
| `/opt/oci-worker/backups/` | `ociworker backup` 输出 |
| `/etc/systemd/system/oci-worker.service` | 主服务 |
| `/etc/systemd/system/oci-webssh.service` | WebSSH 服务 |
| `/usr/local/bin/ociworker` | 管理脚本 |
| `/usr/local/bin/java` | 安装器为 JRE 21 创建的软链（若用安装器自带 JDK 路径） |

## 日常：`ociworker` 命令

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
ociworker restore <备份包>
ociworker version
ociworker uninstall
```

WebSSH 与主服务由同一套逻辑协调启停，**不需要**单独为 WebSSH 开一套陌生命令；面板内访问 Web 端口即可用 WebSSH 能力（具体见产品界面）。

## 安全

- 云安全组/防火墙一般**只放行业务 Web 端口**（如 8818），**不要**把 WebSSH 的 8008 对公网大开（若仅本机+反代，按你当前网络架构收紧即可）。  
- MySQL 建议只监听 `127.0.0.1`；对外勿暴露 3306。  
- 生产环境建议用 **HTTPS**（Nginx 等反代 + 证书）。

## 卸载

```bash
ociworker uninstall
```

按提示分步确认（是否删数据目录、是否删 Docker 库容器等），避免误删。

## 常见问题

**Q：`curl` 下不到 `install.sh` 或返回 404？**  
A：先确认本机**能访问 `github.com`**。再打开 [Releases 里 `installer-latest`](https://github.com/OCIworker/OCIworker/releases/tag/installer-latest) 看是否有 **`install.sh` 附件**。第一行**必须**写全：`-o /tmp/install.sh`（不能只写到 `/tmp/`）。

**Q：改坏 `application.yml` 登不进去？**  
A：看 `/opt/oci-worker/application.yml.bak.*`；若用了 `ociworker config`，一般会自动尝试回滚。

**Q：升级会丢数据吗？**  
A：正常**升级模式**不覆盖库与 yml 内容，只换 JAR 和 WebSSH 二进制。数据库结构由应用启动时按需自动迁移，具体以版本说明为准。

**Q：为什么向导里不直接设管理员密码？**  
A：以浏览器首次设置为准，秘密写入数据库，避免在 SSH/脚本里散落明文或误解 `application.yml` 里的占位字段。
