# OCI Worker 智能安装器（v2）

> 这是 **新增的可选安装方案**，与原 `deploy.sh` / `update.sh` 完全独立。  
> **现有用户什么都不用改**，原方案继续可用。  
> 想要更友好的安装体验、内置管理命令、配置回滚保护，就用这个。

## 它解决了什么

| 痛点                                       | 原 deploy.sh                  | 新 install.sh                       |
| ------------------------------------------ | ----------------------------- | ----------------------------------- |
| 装完要 `nano application.yml` 手改 DB 配置 | ✅ 需要                       | ❌ 向导里直接填                     |
| 数据库连不上时不知道为什么                 | 自己排查                      | 自动诊断，给精确修复建议            |
| 用 1Panel/宝塔已有 MySQL                   | 自己改 yml                    | 向导分支，自动测试 + 修字符集       |
| 配置改坏了服务起不来                       | 手动恢复                      | 自动回滚到上一版                    |
| 升级要敲一堆命令                           | `update.sh`                   | `ociworker update` 或重跑 install   |
| 日常运维（看日志/重启/备份/卸载）          | 一堆 systemctl/journalctl     | `ociworker` 进菜单                  |
| WebSSH 依赖 Docker                         | 必须                          | 二进制版，无 Docker 依赖            |

## 与原方案的关系

- **后端 Java 代码 / 前端 Vue 代码 / WebSSH Go 源码：一字未改**
- 原 `deploy.sh` / `update.sh` / `webssh/Dockerfile` / `webssh/docker-compose.yml`：一字未改
- `latest` GitHub Release（JAR）：原 `build.yml` 继续维护，不动
- 新方案的产物全部发布到 **独立的 `installer-latest` Release**，互不影响
- systemd 服务名都叫 `oci-worker`，新老方案在系统层面**互兼容**
  - 用 `deploy.sh` 装的服务器，可以直接跑 `install.sh` 平滑接管（自动识别为升级）
  - 反之亦然

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

### 动效 / Orbis UI 版

预编译 JAR 发布在独立的 **[ui-latest](https://github.com/OCIworker/OCIworker/releases/tag/ui-latest)**。与上面同一脚本，任选一：

- `env OCI_WORKER_UI=1 bash /tmp/install.sh`
- `bash /tmp/install.sh --ui`

升级走 `ociworker update` 或重跑 `install.sh` 时，若已存在 `/opt/oci-worker/.use-ui-jar`，会续拉 `ui-latest`。改回与 `master` 一致的 JAR：环境变量 `OCI_USE_MASTER_JAR=1` 同脚本升级，或先删除 `.use-ui-jar` 再升级。

## 升级

任选其一：

```bash
ociworker update
```

或重跑 install.sh —— 它会自动识别为升级模式，**只换 JAR 和 webssh 二进制，不动 application.yml 和数据库**。

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
ociworker version          # 查看版本
ociworker uninstall        # 卸载（每步都问，给后悔药）
```

> WebSSH 是 OCI Worker 的内置组件，与主服务一起自动启停，**不需要也不提供单独的开关命令**。

`config` 修改时会**自动备份原 yml**，新配置启动失败时**自动回滚**到上一版，保证不会因为手抖把面板搞登不进去。

## 安装路径

| 路径                                     | 用途                          |
| ---------------------------------------- | ----------------------------- |
| `/opt/oci-worker/oci-worker.jar`         | 主程序 JAR                    |
| `/opt/oci-worker/oci-webssh`             | WebSSH 二进制                 |
| `/opt/oci-worker/application.yml`        | 配置文件（权限 600）          |
| `/opt/oci-worker/application.yml.bak.*`  | 自动备份历史                  |
| `/opt/oci-worker/keys/`                  | OCI PEM 密钥                  |
| `/opt/oci-worker/backups/`               | `ociworker backup` 输出目录   |
| `/etc/systemd/system/oci-worker.service` | 主程序 systemd                |
| `/etc/systemd/system/oci-webssh.service` | WebSSH systemd                |
| `/usr/local/bin/ociworker`               | 管理脚本                      |
| `/usr/local/bin/java`                    | JDK 21 软链                   |

## 与原 deploy.sh 的兼容

| 场景                                   | 行为                                                |
| -------------------------------------- | --------------------------------------------------- |
| 老用户（用 deploy.sh 装的）跑 install  | 自动识别为升级，保留所有数据和配置                 |
| 老用户继续用 update.sh                 | 完全正常，新方案不影响                              |
| 检测到 Docker 版 WebSSH 容器           | 询问是否切换到二进制版（拒绝则跳过，避免端口冲突） |
| 数据库表结构差异                       | 后端 `DatabaseGuardService` 启动时自动 ALTER       |

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

**Q: 装了新版还能切回旧版吗？**  
A: 能。`ociworker uninstall` 时**保留 `/opt/oci-worker`** 目录（选 N），然后跑原 `deploy.sh` 即可。或者直接用 `deploy.sh` 重写 systemd 单元，老用户怎么用就怎么用。

**Q: 升级会丢数据吗？**  
A: 不会。升级模式只换 JAR + webssh 二进制，**完全不动 application.yml 和数据库**。后端启动时由 `DatabaseGuardService` 自动 ALTER 加新表/新字段，旧数据 100% 保留。

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
