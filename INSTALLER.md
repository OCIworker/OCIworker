# OCI Worker 智能安装器（v2）

> 本仓库提供 **install.sh + ociworker CLI** 与 GitHub Releases（`latest` / `installer-latest`）。  
> 新机器请用下方向导安装；已部署机器可用 `ociworker update` 或重跑 `install.sh` 升级。

## 它解决了什么

| 痛点                                       | 手动改配置 / 敲命令           | 新 install.sh                       |
| ------------------------------------------ | ----------------------------- | ----------------------------------- |
| 装完要 `nano application.yml` 手改 DB 配置 | ✅ 需要                       | ❌ 向导里直接填                     |
| 数据库连不上时不知道为什么                 | 自己排查                      | 自动诊断，给精确修复建议            |
| 用 1Panel/宝塔已有 MySQL                   | 自己改 yml                    | 向导分支，自动测试 + 修字符集       |
| 配置改坏了服务起不来                       | 手动恢复                      | 自动回滚到上一版                    |
| 升级要敲一堆命令                           | 多步 systemctl + curl         | `ociworker update` 或重跑 install   |
| 日常运维（看日志/重启/备份/卸载）          | 一堆 systemctl/journalctl     | `ociworker` 进菜单                  |
| WebSSH 依赖 Docker                         | 旧方案常见                    | 二进制版，无 Docker 依赖            |

## 发布产物

- 应用 JAR：**[`latest`](https://github.com/OCIworker/OCIworker/releases/tag/latest)** Release
- 安装器与 CLI：**[`installer-latest`](https://github.com/OCIworker/OCIworker/releases/tag/installer-latest)** Release（`install.sh`、`ociworker`）
- systemd 服务名均为 `oci-worker`，与历史手动部署路径兼容；若目录 `/opt/oci-worker` 已存在，`install.sh` 会识别为升级模式

## 安装

> Debian 默认 root shell 是 dash，不支持 `<()` 进程替换。**推荐先下载再执行**：

```bash
curl -fsSL https://github.com/OCIworker/OCIworker/releases/download/installer-latest/install.sh -o /tmp/install.sh
bash /tmp/install.sh
```

或者管道执行（Ubuntu / CentOS 等 root 是 bash 的也可以用 `bash <(curl ...)`）：

```bash
curl -fsSL https://github.com/OCIworker/OCIworker/releases/download/installer-latest/install.sh | bash
```

向导会问：

1. 数据库使用方式：**1) 已有 MySQL（1Panel/宝塔） / 2) 用 Docker 装 / 3) 我有 root**
2. 数据库连接信息（自动测试 + 自检）
3. Web 端口

5 分钟搞定，**不在 SSH 里设置管理员账号密码**——服务起来后到浏览器 `http://<ip>:<端口>` 完成首次设置即可。这是后端的设计：账号密码以 sha256 哈希存进数据库，不进 yml，更安全。

## 升级

任选其一：

```bash
ociworker update
```

或重跑 install.sh —— 它会自动识别为升级模式，**只换 JAR（终端已并入主程序），不动 application.yml 和数据库**；升级时会停用并清理旧版独立 `oci-webssh` 服务（若存在）。

升级失败会自动回滚到旧 JAR。

## 用 1Panel / 宝塔已有 MySQL

向导第一步选 **1**，准备工作：

1. 在面板里建库：库名 `oci_worker`，字符集 `utf8mb4 / utf8mb4_unicode_ci`
2. 建用户：用户名 `ociworker`，授权到 `oci_worker` 库，**访问权限选"所有人(%)"**
   （选 localhost 会因为 `127.0.0.1` ≠ `localhost` 导致认证失败，向导会识别并提示）
3. 把数据库连接密码记下来填进向导

向导会自动检查：

- 端口能否连通
- 登录是否成功（失败时识别 host 限制问题并给修复指引）
- MySQL 版本 ≥ 8.0
- 库存在 / 字符集 / DDL 权限

任何一项不通过都会**给出具体的解决步骤**，绝不让你卡死。

## 用 Docker 装 MySQL（向导选 ②）

v2 安装器会：

- 创建/复用容器 **`oci-worker-mysql`**，端口 **`127.0.0.1:3306`**
- 把连接写入 `/opt/oci-worker/application.yml`（`spring.datasource.url` 为 `localhost:3306`）
- 部署 `/usr/local/bin/ociworker`

本机**多数不会**安装 `mysql` 客户端（`ensure_mysql_client` 失败时安装器会警告并继续），因此：

| 操作 | 做法 |
|------|------|
| 清除 TG 绑定 | **`sudo ociworker tg-clean`** 或菜单 **11）清除Tg绑定**（自动 `docker exec oci-worker-mysql`，密码来自 yml） |
| 查库里的 TG 配置 | 优先用 `ociworker tg-clean` 前的列表；勿猜密码，以 yml 里 `spring.datasource.password` 为准 |
| 备份数据库 | 建议 `apt install -y default-mysql-client` 后 `ociworker backup`，或自行 `docker exec oci-worker-mysql mysql …` |

清除后提示：**telegram通知已清除，请登录面板重新绑定。**

## 日常管理：`ociworker`

```bash
ociworker                  # 进交互菜单
ociworker status           # 服务状态
ociworker start/stop/restart
ociworker logs             # 实时日志
ociworker config           # 改端口/数据库（含回滚；账号密码请到 Web 设置）
ociworker update           # 一键升级
ociworker backup           # 备份数据库 + 配置 + keys
ociworker restore <file>   # 从备份恢复
ociworker tg-clean         # 清除 Telegram 绑定（无 mysql 客户端时自动 docker exec oci-worker-mysql）
ociworker version          # 查看版本
ociworker uninstall        # 卸载（每步都问，给后悔药）
```

> WebSSH 是 OCI Worker 的内置组件，与主服务一起自动启停，**不需要也不提供单独的开关命令**。

`config` 修改时会**自动备份原 yml**，新配置启动失败时**自动回滚**到上一版，保证不会因为手抖把面板搞登不进去。

## 安装路径

| 路径                                     | 用途                          |
| ---------------------------------------- | ----------------------------- |
| `/opt/oci-worker/oci-worker.jar`         | 主程序 JAR                    |
| `/opt/oci-worker/application.yml`        | 配置文件（权限 600）          |
| `/opt/oci-worker/application.yml.bak.*`  | 自动备份历史                  |
| `/opt/oci-worker/keys/`                  | OCI PEM 密钥                  |
| `/opt/oci-worker/backups/`               | `ociworker backup` 输出目录   |
| `/etc/systemd/system/oci-worker.service` | 主程序 systemd                |
| `/usr/local/bin/ociworker`               | 管理脚本                      |
| `/usr/local/bin/java`                    | JDK 21 软链                   |

## 与已有部署的兼容

| 场景                                   | 行为                                                |
| -------------------------------------- | --------------------------------------------------- |
| `/opt/oci-worker` 已存在时跑 install   | 自动识别为升级，保留数据和 `application.yml`       |
| 检测到 Docker 或旧版独立 WebSSH        | 升级时提示并清理，避免与内置终端冲突               |
| 数据库表结构差异                       | 后端启动时自动 ALTER                               |

## 安全提醒

- WebSSH 端口 `8008` 监听 `0.0.0.0`（与原 Docker 版一致）。**云厂商安全组只放行 Web 端口**（默认 8818），不要把 8008 暴露公网
- OCI Worker 已通过反向代理把 WebSSH 嵌入主面板，访问主端口即可使用 WebSSH 全部功能
- 推荐用 Nginx 反代 + Let's Encrypt HTTPS 保护主端口
- MySQL 端口务必绑定 `127.0.0.1`

## 私有仓库使用说明

如果项目仓库变成私有：

1. `installer-latest` Release 的下载链接需要带 GitHub Token：

   ```bash
   GH_TOKEN=ghp_xxx
   curl -fsSL -H "Authorization: token ${GH_TOKEN}" \
     https://api.github.com/repos/OCIworker/OCIworker/releases/tags/installer-latest \
     | grep browser_download_url | grep install.sh | cut -d'"' -f4 \
     | xargs curl -fsSL -H "Authorization: token ${GH_TOKEN}" -o install.sh
   bash install.sh
   ```

2. 或者把 `install.sh` 镜像到一个公开静态地址（自建 OSS / R2 / 公开 gist），保持一行装体验

3. 仓库 Settings → Deploy keys 里加一个只读 key，写入 `install.sh` 头部，避免每次手动传 token（安全性需评估）

## 卸载

```bash
ociworker uninstall
```

每一步都会问你（删 `/opt/oci-worker`？删 MySQL 容器？删数据目录？），不会一刀切。

## FAQ

**Q: 装了新版还能切回旧版 JAR 吗？**  
A: 能。`ociworker update` 会从 `latest` Release 拉取；升级失败会自动回滚到上一版 JAR。若要整包重装，可用 `ociworker uninstall` 时保留 `/opt/oci-worker` 数据目录后再跑 `install.sh`。

**Q: 升级会丢数据吗？**  
A: 不会。升级模式只换 JAR，**完全不动 application.yml 和数据库**。后端启动时由 `DatabaseGuardService` 自动 ALTER 加新表/新字段，旧数据 100% 保留。

**Q: 后端代码升级了，能直接 install 吗？**  
A: 可以。新版 JAR 推到 `latest` Release 后，`ociworker update` 或重跑 `install.sh` 都会拉最新版本。

**Q: 改坏了 application.yml 怎么办？**  
A: `ociworker config` 修改时会自动备份并在启动失败时回滚。手动改的话可以从 `/opt/oci-worker/application.yml.bak.*` 找历史版本。

**Q: 为什么不在脚本里设置管理员账号密码？**  
A: 后端 `AuthController` 判断"是否首次安装"只看数据库 `oci_kv` 表里有没有 `web_account / web_password` 两条记录，**不读** `application.yml` 里的 `web.account / web.password`。yml 里的两个字段只在数据库被清空、用户尚未在浏览器完成 Setup 时作为兜底默认值。所以脚本里设置的账号密码不会生效，反而误导用户，我们干脆去掉这一步。后端这样设计是因为数据库里能存 sha256 哈希，比 yml 明文更安全。

**Q: 忘记 Web 管理员密码怎么办？**  
A: 三种办法：
1. 如果绑过 Telegram 登录：Web 登录页选"TG 验证码"绕过密码登录，登入后改密码
2. 直接清掉数据库里的密码记录，触发重新 Setup：
   ```sql
   DELETE FROM oci_kv WHERE type='sys_config' AND code IN ('web_account','web_password');
   ```
   清完刷新浏览器，会回到 Setup 页，重新设置即可（其他数据不丢）
3. 万不得已：`ociworker uninstall` 选保留数据，重新安装一次（数据保留，密码会回到 Setup 流程）
