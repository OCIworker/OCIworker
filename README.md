# OCI Worker

基于 Spring Boot 3 + Vue 3 + Ant Design Vue 开发的 Oracle Cloud (OCI) 管理面板。

> **v2 智能安装器** 已上线：5 分钟向导式部署，支持 1Panel / 宝塔已有 MySQL，自动数据库自检 + 配置回滚保护，附赠 `ociworker` 管理 CLI。详见下方"一键安装"。

## 功能特性

- **多租户配置管理**：批量添加、编辑、删除，快速导入 OCI 配置，PEM 拖拽上传
- **批量抢机 + 断点续抢**：多租户同时抢机，任务持久化，服务重启自动恢复
- **实例管理**：启动/停止/重启/终止，修改名称及 Flex 规格，一站式查看安全列表/引导卷/网络/流量统计
- **用户管理**：查看域中用户，创建用户，重置密码，清理 MFA，管理员组操作
- **IP 管理**：一键更换公网 IP，临时/预留 IP 管理，辅助 IP 添加，IPv6 支持
- **安全列表管理**：入站/出站规则查看、添加、删除，一键放行所有端口
- **引导卷管理**：查看/编辑引导卷，快捷预设（50/100/150/200 GB，120 VPUs/GB 一键调整）
- **串行控制台**：通过 OCI 内部通道连接实例串口，WebSSH 一键打开，用于网络异常时紧急救援
- **虚拟云网络**：VCN / 子网查看，预留 IP 管理（创建、绑定、解绑、删除）
- **实时日志查看**：WebSocket 实时推送全量后端日志
- **消息通知**：Telegram Bot 通知（登录、任务、每日播报）
- **系统更新**：Web 页面一键检查更新 + 自动从 GitHub Releases 拉取最新版本
- **加密备份恢复**：数据迁移
- **登录安全**：首次使用自定义管理员账户，Token 24 小时过期，支持在线修改密码，Telegram 验证码保护

## 技术栈

- **后端**：Spring Boot 3.5 + JDK 21 (虚拟线程) + MyBatis-Plus + MySQL 8.0
- **前端**：Vue 3 + Vite + Ant Design Vue 4 + Pinia + Vue Router 4
- **OCI SDK**：oci-java-sdk 3.83+

---

## 一键安装（推荐 · v2 智能安装器）

适用于 Debian / Ubuntu / CentOS（支持 ARM64 和 AMD64）。**5 分钟搞定**，全程交互式向导，**不需要事后手改任何文件**。

### 它做了什么

- 自动安装 JDK 21、下载最新 JAR、生成 systemd 服务、放行防火墙
- **数据库三选一**：① 已有 MySQL（1Panel / 宝塔等面板）② Docker 自动装 MySQL 8.0 ③ 我有 root，脚本自动建库建用户
- **数据库自检**：连通性 / 版本 / 字符集 / DDL 权限，失败给出**精确的修复建议**
- **配置改坏自动回滚**：服务起不来时自动还原上一版 `application.yml`
- 装完顺便部署 `ociworker` 管理 CLI（一个命令搞定状态/日志/备份/升级/卸载）

### 一键安装命令

复制粘贴执行即可（Debian / Ubuntu / CentOS 通用）：

```bash
curl -fsSL https://github.com/OCIworker/OCIworker/releases/download/installer-latest/install.sh -o /tmp/install.sh
sudo bash /tmp/install.sh
```

向导会问你：① 数据库使用方式 ② 数据库连接信息 ③ Web 端口。装完后浏览器访问 `http://<你的IP>:<端口>` 设置管理员账号即可登录。

详细文档：[INSTALLER.md](./INSTALLER.md)

### 动效/Orbis UI 版

与上**同一**安装器，JAR 来自 **Release [ui-latest](https://github.com/OCIworker/OCIworker/releases/tag/ui-latest)**（`feature/ui-polish` 的 CI 产物）。`ociworker update` 默认继续用 UI 包；**切回原版**见下「一键切回原版」。

### 一键安装命令

复制粘贴执行即可（Debian / Ubuntu / CentOS 通用）：

```bash
curl -fsSL https://github.com/OCIworker/OCIworker/releases/download/installer-latest/install.sh -o /tmp/install.sh
sudo env OCI_WORKER_UI=1 bash /tmp/install.sh
```

（等效：`sudo bash /tmp/install.sh --ui`）

**一键切回原版**（已装过服务、要改回与 master 一致的 `latest` JAR）：

```bash
curl -fsSL https://github.com/OCIworker/OCIworker/releases/download/installer-latest/install.sh -o /tmp/install.sh && sudo env OCI_USE_MASTER_JAR=1 bash /tmp/install.sh
```

（或：`sudo rm -f /opt/oci-worker/.use-ui-jar && sudo ociworker update`）

---

## 一键更新

### 方式一：管理脚本一键更新（推荐）

```bash
sudo ociworker update
```

自动完成：停止服务 → 备份旧 JAR → 下载新 JAR → 启动新版 → **失败自动回滚到旧 JAR**。

### 方式二：Web 页面更新

「系统设置 → 系统更新」中点「检查更新」→「一键更新」，自动下载和重启。

### 方式三：重跑安装脚本

`install.sh` 会自动识别为升级模式，**只换 JAR 和 webssh 二进制，不动 `application.yml` 和数据库**：

```bash
sudo bash /tmp/install.sh
```

---

## 日常管理：`ociworker`

```bash
ociworker                  # 进交互菜单（最常用）
ociworker status           # 服务状态
ociworker start/stop/restart
ociworker logs             # 实时日志
ociworker config           # 改端口/数据库（含自动回滚；账号密码请到 Web 设置）
ociworker update           # 一键升级
ociworker backup           # 备份数据库 + 配置 + keys
ociworker restore <file>   # 从备份恢复
ociworker version          # 查看版本
ociworker uninstall        # 卸载（每步都问，给后悔药）
```

---

## 使用面板自带的 MySQL（1Panel / 宝塔）

### 在面板里准备 3 件事

1. **建库**：库名 `oci_worker`，**字符集 `utf8mb4 / utf8mb4_unicode_ci`**（必须，否则 emoji 乱码）
2. **建用户**：授权该库所有权限，**访问权限选「所有人(%)」**（重要，选 `localhost` 会报 Access denied）
3. **MySQL 版本 8.0 或更高**（不支持 5.7）

准备好后跑 `install.sh`，第一步选 **「1) 已有 MySQL」**，把连接信息填进去即可。

### 已经装好了，想把数据库换到面板上

**先迁数据再改连接**，否则账号会丢、需要重新设置：

```bash
# 1. 备份当前数据
ociworker backup
# 输出：/opt/oci-worker/backups/backup-xxxxxxxx-xxxx.tar.gz

# 2. 把 dump.sql 导入面板的新库
cd /tmp && tar xzf /opt/oci-worker/backups/backup-*.tar.gz
mysql -h127.0.0.1 -P<面板MySQL端口> -uociworker -p oci_worker < dump.sql

# 3. 切换到新数据库（一次性改完，自动重启验证 + 失败自动回滚，不用先停服）
ociworker config   # 选 2) 数据库修改 / 迁移，按提示填新库的地址/端口/库名/用户名/密码
```

> 万一连自动回滚都失败：从 `/opt/oci-worker/application.yml.bak.*` 找历史版本手动还原即可。

---

## 备用：经典脚本（老用户/已部署机器）

> 如果你已经用老脚本部署过，**继续用没问题**——新旧方案 systemd 服务名/路径完全一致，互兼容。  
> 新机器**推荐用上面的 v2 智能安装器**。

<details>
<summary>展开：经典 deploy.sh / update.sh 用法</summary>

### 第一步：启动 MySQL

```bash
curl -fsSL https://get.docker.com | sh

docker run -d \
  --name oci-worker-mysql \
  --restart always \
  -p 127.0.0.1:3306:3306 \
  -v /opt/oci-worker/data/mysql:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD=root123 \
  -e MYSQL_DATABASE=oci_worker \
  -e MYSQL_USER=ociworker \
  -e MYSQL_PASSWORD=ociworker123 \
  -e TZ=Asia/Shanghai \
  mysql:8.0 --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
```

### 第二步：部署 / 更新

```bash
# 部署
bash <(curl -sL https://raw.githubusercontent.com/OCIworker/OCIworker/master/deploy.sh)

# 更新
bash <(curl -sL https://raw.githubusercontent.com/OCIworker/OCIworker/master/update.sh)
```

### 老方案的运维命令

```bash
systemctl status oci-worker
journalctl -u oci-worker -f
systemctl restart oci-worker
nano /opt/oci-worker/application.yml
```

部署完成后访问 `http://你的IP:8818`，**首次访问会进入初始化页面**设置管理员账号密码（至少 6 位）。

</details>

---

## 本地开发

**后端**（需要 JDK 21 + Maven）：

```bash
cd backend
mvn spring-boot:run
```

**前端**（需要 Node.js 18+）：

```bash
cd frontend
npm install
npm run dev
```

访问 http://localhost:5173，首次使用需在初始化页面设置管理员账户

### 生产构建

```bash
# 构建前端
cd frontend && npm run build

# 构建后端（前端产物已自动输出到 backend/src/main/resources/dist/）
cd backend && mvn clean package -DskipTests

# 运行
java -jar target/oci-worker-1.0.0.jar
```

---

## 配置说明

编辑 `/opt/oci-worker/application.yml`：

```yaml
server:
  port: 8818            # 服务端口

web:
  account: admin        # 默认登录账号（首次安装时会在页面设置新的）
  password: admin123    # 默认密码（首次安装时会在页面设置新的）

spring:
  datasource:
    url: jdbc:mysql://localhost:3306/oci_worker?useUnicode=true&characterEncoding=utf8&useSSL=false&serverTimezone=Asia/Shanghai&allowPublicKeyRetrieval=true
    username: ociworker
    password: ociworker123

oci-cfg:
  key-dir-path: ./keys  # PEM 密钥存放目录
```

### 手动创建 MySQL 数据库

如果使用已有的 MySQL 服务，需要先创建数据库：

```sql
CREATE DATABASE IF NOT EXISTS oci_worker
  DEFAULT CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'ociworker'@'%' IDENTIFIED BY 'ociworker123';
GRANT ALL PRIVILEGES ON oci_worker.* TO 'ociworker'@'%';
FLUSH PRIVILEGES;
```

---

## 目录结构

```
/opt/oci-worker/          # 生产部署目录
├── oci-worker.jar        # 应用 JAR
├── oci-webssh            # WebSSH 二进制（v2 安装器部署）
├── application.yml       # 配置文件（权限 600）
├── application.yml.bak.* # 配置自动备份历史
├── keys/                 # PEM 密钥目录
└── backups/              # ociworker backup 输出目录

/usr/local/bin/ociworker  # 管理 CLI（v2 安装器部署）

oci-worker/               # 源码目录
├── backend/              # Spring Boot 后端（pom.xml + src/）
├── frontend/             # Vue 3 前端（package.json + src/）
├── webssh/               # Go 写的 WebSSH 服务（含 systemd unit）
├── install.sh            # v2 智能安装器（推荐）
├── ociworker             # v2 管理 CLI 源
├── INSTALLER.md          # v2 安装器详细文档
├── deploy.sh             # 经典一键部署脚本（兼容保留）
├── update.sh             # 经典一键更新脚本（兼容保留）
├── docker-compose.yml    # MySQL Docker 配置
└── README.md
```

## 免责声明

- 因开机、换 IP 频率过高而导致的封号，使用者自行承担
- 建议使用 Nginx 反向代理配置 HTTPS 访问
- 建议使用密钥登录服务器，防止 SSH 爆破
- MySQL 端口务必绑定 `127.0.0.1`，切勿暴露到公网，否则可能被勒索攻击清空数据
- 首次安装会引导设置管理员账户，密码至少 6 位
