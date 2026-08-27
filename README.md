# Linux-ops-box 终极系统运维工具箱

基于原生 Shell 函数构建的企业级 Linux 自动化运维管理工具箱，具备模块化架构、完善的双写审计日志、以及支持 `curl` 一键部署至全局环境等能力。

## ✨ 核心特性

- **多发行版兼容**: 深度适配 Ubuntu/Debian/CentOS/Rocky/Armbian/Alpine，自动识别底层包管理器（apt/dnf/yum/apk）。
- **完全解耦的架构**: 主程序仅 200 行负责 TUI 菜单分发，各类功能下沉至 `modules/` 子模块，互不干扰。
- **透明审计**: 所有状态输出通过专门的日志基座 `common.sh`，实现控制台高亮输出与 `/var/log/ck_system_init.log` 原文存档双写。
- **独立专家级工具**: 为高频组件（如 Docker/VPN/代理）提供完全独立的、具备实时版本采集能力的安装与管理脚本。
- **无损热升级与环境自愈**: 系统在线升级自动开启本地配置与历史备份文件热迁移，内置 crontab 定时任务与 JSON 管理器双向同步及失效清理机制，确保数据资产安全。

---

## 🚀 1. 系统初始化工具箱 (ck_sysinit)

用于服务器首选的初始化流程，涵盖基础环境搭建、安全边界加固、纯 Shell 微型状态监控以及高频故障排查机制。

### 快捷安装 (大陆加速版):

```bash
curl -sSL https://ghproxy.net/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/install_system.sh | sudo bash
```

> 安装完成后，在任何目录输入 `ck_sysinit` 即可呼出管理菜单；支持使用 `ck_sysinit --uninstall` 彻底清理环境。

### 主菜单功能一览:

| 序号 | 功能模块 | 核心子功能 | 对应模块文件 |
|:---:|:---|:---|:---|
| 1 | **系统软件包更新** | 依赖清理 / 内核升级 | `system_opt.sh` |
| 2 | **系统环境深度优化** | 换源 / BBR / Swap / 时区 | `system_opt.sh` |
| 3 | **常用专家工具集** | 最小化系统必备工具安装 | `system_opt.sh` |
| 4 | **SSH 远程安全加固** | 证书登录 / 端口自定义 / 防爆破 | `ssh_sec.sh` |
| 5 | **防火墙安全管理** | UFW / FirewallD TUI 管理 | `firewall_mgmt.sh` |
| 6 | **网络 IP 与网卡诊断** | 静态 IP / 路由 / 网卡信息 | `network.sh` |
| 7 | **系统资源与服务监控** | 进程 / Nginx 状态 / 磁盘 IO | `nginx_view.sh` |
| 8 | **数据库管理中心** | 备份/恢复/连接管理/定时备份/数据表归档 (详见 §5) | `db_mgmt_loader.sh` |
| 9 | **Docker 管理中心** | 安装/服务管理/Compose 编排 | `docker_mgmt.sh` |
| 10 | **VNC 服务管理中心** | 一键安装 VNC / 桌面自启动 / 多端口多账户 | `vnc_mgmt.sh` |
| 11 | **服务器代理配置** | Hosts 代理加速 / 环境变量代理 / Docker 镜像与信任 | `setup_proxy_registry.sh` |
| 12 | **SSL/TLS 证书管理中心** | ACME 联网商业证书申请 / 离线自签证书体系 / 私有根 CA | `ssl_cert.sh` / `acme.sh` |
| 13 | **硬盘检测与清理中心** | 磁盘使用率 / 大文件 / 大目录 / 智能清理辅助 | `disk_mgmt.sh` |
| 88 | **在线更新工具箱** | 自动探测最优下载通道并云端覆写 | 内置 |
| 99 | **卸载工具箱** | 清理软链接与守护目录 | 内置 |
| 0 | **退出工具箱** | 退出管理程序 | 内置 |

### 辅助模块体系:

| 模块文件 | 职能描述 |
|:---|:---|
| `common.sh` | 全局底座：颜色规范、双写审计日志 (`/var/log/ck_system_init.log`)、跨平台发行版自检 `_init_distro()` |
| `ssl_cert.sh` | SSL/TLS 证书管理中心：融合 ACME 联网申请与离线自签、专家级 SAN (IP/多域名/通配符)、私有根 CA 签发、PFX/PEM 格式互转、密钥对配对诊断 |
| `acme.sh` | ACME 证书自动化引擎：支持 Let's Encrypt / ZeroSSL、IP 证书、80 端口单域名与 DNS API 泛域名申请及自动续期 |
| `disk_mgmt.sh` | 硬盘检测与清理中心模块：多挂载点使用率图示、Top N 大文件/大目录扫描、分类占用统计与一键清理 |
| `ecs.sh` | ECS/云服务器专项运维工具集（性能监控大屏、IO 分析等） |
| `sing-box-plus.sh` | Sing-Box 代理管理集成模块（安装/配置/订阅管理） |
| `db_mgmt_loader.sh` | 数据库模块适配加载器，将 `db_manager/db_mgmt.sh` 接入 TUI 菜单 |
| `vnc_mgmt.sh` | VNC 服务管理中心模块：支持运行状态监控、一键部署实例、服务启停与彻底注销 |

---

## 🐳 2. Docker & Compose 专家管理工具

独立的 Docker 全生命周期管理工具，支持动态爬取官方最新版本、启动项管理、配置查看及卸载。

### 快捷安装/运行 (大陆加速版):

```bash
curl -sSL https://ghproxy.net/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/install_docker.sh | sudo bash
```

### 核心功能:

1. **实时采集**: 自动从 Docker 官网与 Github API 抓取最近 8 个稳定版本供选择。
2. **状态感知**: 启动即显示当前引擎版本、运行状态与编排工具状态。
3. **运维集成**: 内置启动、停止、重启、查看 `daemon.json` 等高频运维指令。
4. **多架构感知与深层适配**: 自适应识别 CPU 架构 (支持 x86_64 及 aarch64)，并深度兼容如 Ubuntu 22.04 (Jammy) 等现代发行版的内置官方软件源交互。

---

## 🛡 3. VPS-VPN 专家工具 (install_vpn.sh)

为您的 VPS 提供医疗级加密隧道与隐身代理。内置 WireGuard & Xray-Reality 协议支持及深度网络诊断。

### 快捷运行 (支持扫码一键联):

```bash
curl -sSL https://ghproxy.net/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/install_vpn.sh | sudo bash
```

### 核心功能:

1. **WireGuard (UDP 隧道)**: 内核级负载，一键生成服务端/客户端密钥及防火墙策略。
2. **Xray-Reality (TCP 代理)**: 极致防探测加密，直接伪装知名网站，支持控制台打印码/链接。
3. **游戏联机与网速诊断**: 针对 Nintendo / PSN / Xbox / Steam 等平台节点的一键延迟与带宽检测。
4. **域名路由链路分析**: 结合 HTTP 响应拆解 (DNS/TCP/TTFB)、Traceroute 染色路径图与 MTR 丢包扫描。

---

## 🛸 4. NaiveProxy 自动化安装 (naive_install.sh)

基于 Caddy 补丁版的极致隐身代理方案，采用 HTTP/3 协议栈，目前是最难以被感知的代理分发技术。

### 快捷安装 (大陆加速版):

```bash
curl -sSL https://ghproxy.net/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/scripts/naive_install.sh | sudo bash
```

### 核心功能:

1. **二合一部署**: 脚本支持在部署 NaiveProxy 的同时，同步开启标准 **HTTP 认证代理** 模式。
2. **SSL 自动签证**: 自动申请 Let's Encrypt 证书，并配置强化的伪装站点。
3. **极致性能**: 自动注入 BBR 加速参数，适配最前沿的 Caddy forwardproxy 插件。

---

## 🖥 5. 通用 Linux VNC 一键部署与服务管理器 (install_vnc.sh)

独立的 VNC 全自动安装与管理工具，深度适配银河麒麟高级服务器 (V10)、openEuler、CentOS、Rocky、AlmaLinux、Ubuntu、Debian、Arch Linux 以及 Alpine Linux 等主流操作系统发行版。

### 快捷安装/配置 (主控端/独立拉取):

```bash
curl -sSL https://ghproxy.net/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/install_vnc.sh | sudo bash
```

### 核心特性:

1. **多端环境诊断与 GUI 一键直装**: 智能检测系统是否已具备图形环境。若无，提供一键式 UKUI (麒麟默认) / MATE / XFCE 等桌面环境自适应安装。对 CentOS/Rocky/AlmaLinux 等红帽系发行版自动检测并启用 EPEL 软件源，对 Debian/Ubuntu 自动集成 `dbus-x11` 会话锁，对 Arch & Alpine 执行跨架构依赖预置，彻底消除“黑屏”或“仅有鼠标”的空视窗痛点。
2. **密码安全标准**: 自动限制密码长度在 6~8 位（超长智能截断符合 TigerVNC 规范），动态创建用户专属的 `.vnc/passwd` 安全权限环。
3. **极速自启守护映射**: 
   - **现代架构 (Kylin V10 SP2/SP3, openEuler 22.03+, RHEL/Rocky/Alma 8+)**: 基于 `/etc/tigervnc/vncserver.users` 绑定多端口与多用户，动态生成 `session` 桌面配置。
   - **经典与其它架构 (CentOS 7, Debian, Ubuntu, Arch, Alpine)**: 自动提取模板；若环境缺省，则基于系统命令动态构建极其稳健的兼容型 `systemd` 服务，提供无感自启。
4. **锁文件深度重置**: 遭遇断电、服务崩溃导致的 X11 锁残留（`/tmp/.X*-lock`）时，系统自动执行深度链条扫描并重置以确保 100% 重启成功率。
5. **防火墙联动放行**: 自动感知 FirewallD 或 UFW，动态计算端口（5900 + 桌面显示编号）并写入放行策略。

---

## 🗄 6. 数据库管理中心 (db_manager)

已内置于 `ck_sysinit` 主菜单 **「8. 数据库管理中心」**，无需单独部署。支持 MySQL / PostgreSQL 的宿主机直连与 Docker 容器两种连接模式。

> **版本**: v2.1 | 工具入口 Banner 为 `数据库管理工具 v2.1 — MySQL / PostgreSQL 备份恢复管理`

### 目录结构与数据持久化:

- **备份路径下沉**: 默认备份及归档文件统一下沉持久化至外部独立目录 `/opt/backups/`，确保跨版本更新时数据完全安全，并支持老版本数据的平滑自动搬迁。
- **定时任务双向同步**: 物理 `crontab` 任务记录与本地 JSON 管理器支持热加载并自动双向对齐，极大程度避免历史定时策略遗失。

```text
system/db_manager/
├── db_mgmt.sh           # 核心引擎 (v2.1+)
├── .env.db              # 全局配置 (备份目录/压缩策略/保留数量)
├── db_connections.json  # 多连接配置持久化存储
└── archive_rules.json   # 数据表归档规则持久化存储 (自动生成)
```

### 主菜单结构 (5+0):

| 选项 | 功能 | 子功能说明 |
|:---:|:---|:---|
| `[1]` | **备份数据库** | 序号/通配符/全量三种批量选择模式；gzip 流式压缩；自动轮转旧备份 |
| `[2]` | **恢复数据库** | 单库精选文件版本 / 批量最新备份自动恢复；目标库不存在时自动创建 |
| `[3]` | **管理数据库连接配置** | 查看/添加/删除连接；支持 Host 直连和 Docker 容器两种模式；写入前自动测试连通性 |
| `[4]` | **定时备份管理** | 添加/查看/删除 crontab 任务；支持每日/每周/自定义表达式；日志落盘 `cron.log` |
| `[5]` | **数据表归档管理** | 基于时间字段的冷热数据分离（详见下方） |
| `[0]` | 退出 | — |

### §5 数据表归档管理 (archive_menu):

针对大表冷热数据分离场景。规则持久化存储于 `archive_rules.json`，支持 crontab 自动调度。

| 子选项 | 操作 |
|:---:|:---|
| `[1]` | 添加归档规则（指定库名/表名/时间字段/保留天数/模式/批次大小） |
| `[2]` | 查看所有归档规则 |
| `[3]` | 删除归档规则 |
| `[4]` | 立即执行归档（支持单条规则或全部规则）|
| `[5]` | 定时归档 — 添加 cron 任务 |
| `[6]` | 定时归档 — 查看 cron 任务 |
| `[7]` | 定时归档 — 删除 cron 任务 |

**归档模式**:
- **move** (默认): 将过期行迁移至归档表（`_archive` 后缀），使用 `ON DUPLICATE KEY UPDATE` 原子批次操作，数据保留可查。
- **delete**: 直接批量删除过期行，彻底释放存储空间。

> 自动为时间字段添加索引（若不存在）以消除归档时的全表扫描瓶颈；批次大小/最大批数可调，避免长事务锁表。

### 连接模式示例:

```
# Host 直连模式
  主机: 192.168.1.100  端口: 3306  用户: root  → [HOST]

# Docker 容器模式 (无需宿主机安装 mysql 客户端)
  容器名: mysql-prod                            → [DOCKER]
```

## 📦 7. 离线安装方案 (无网络环境)

针对物理隔离、内网环境或 Github 连接极其不稳定的场景，本工具箱支持 **“有网下载、离线部署”** 的自适应本地安装逻辑。

### Step 1: 准备安装包 (有网机器)

在一台可以访问外网的机器上下载完整源码包，并传输至目标服务器：

- **方案 A (Git)**: `git clone https://github.com/kikock/Linux-ops-box.git`
- **方案 B (ZIP)**: 通过浏览器访问 [Github 仓库](https://github.com/kikock/Linux-ops-box) 下载 `Source Code (zip)`。

### Step 2: 文件夹传输 (离线服务器)

使用 `scp`、`sftp` 或 U 盘等手段，将解压后的 `Linux-ops-box` 文件夹整体上传到服务器某目录下。

### Step 3: 执行本地部署

进入该文件夹，直接以 `root` 权限运行安装脚本：

```bash
cd Linux-ops-box
sudo bash install_system.sh
```

> **逻辑说明**: 安装程序检测到当前目录存在 `system/` 子目录后，会自动跳过 Github 云端检索，实现秒级的本地软链接及守护库构建工作。

---

## ⌨️ 8. 命令行参数 (CLI)

`ck_sysinit` 支持以下命令行参数，可在任意目录直接执行：

| 参数 | 别名 | 功能 |
|:---|:---|:---|
| *(无参数)* | — | 直接进入 TUI 交互菜单 |
| `--update` | `-up` | **在线更新**：自动探测 GitHub 直连/镜像，下载最新版并覆盖安装 |
| `--uninstall` | `-u` | **彻底卸载**：删除 `/usr/local/bin/ck_sysinit` 软链接及 `/opt/ck_sysinit` 守护目录 |

```bash
# 在线更新到最新版
ck_sysinit --update

# 彻底卸载
ck_sysinit --uninstall
# 或通过安装脚本卸载
curl -sSL https://ghproxy.net/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/install_system.sh | sudo bash -s -- --uninstall
```

---

## 🛠 开发扩展说明 (Developer Guide)

本工具箱采用高度模块化的 Shell 函数架构，极易进行二次开发。

### 1. 新建模块范式

在 `system/modules/` 下建立 `.sh` 文件，并遵循以下规范：

- **全局环境**: 直接使用 `common.sh` 中导出的全局变量 (如 `$GREEN`, `$CYAN`, `$OS_NAME`, `$PKG_MGR`)。
- **函数包裹**: 所有逻辑必须封装在函数内，避免在 `source` 时产生副作用。
- **日志双写**: 强制使用 `_log_info` 等标准日志接口，严禁直接使用 `echo` 以确保审计。
- **范态参考**: 建议参考 `modules/nginx_view.sh` 的 TUI 实现逻辑。

### 2. 菜单挂载流程

1. 编辑 `system/system_init.sh`。
2. 在文件头部执行 `source "$BASE_DIR/modules/your_module.sh"`。
3. 在 `while true` 循环中增加菜单项编号。
4. 在 `case` 语句块中分发执行对应的模块函数。

---

## 🚀 后续更新计划 (Roadmap)

我们致力于将 `Linux-ops-box` 打造为最懂运维、最轻量的 TUI 工具箱。

### 📅 近期目标 (v2.x)

- [ ] **运维告警集成**: 支持 Telegram / 钉钉 / 飞书 机器人推送系统关键指标异常告警。
- [x] **数据库管理中心**: ✅ MySQL / PostgreSQL TUI 管理（v2.1 已落地，含 Docker 容器模式、定时备份、多连接管理、数据表自动化归档）。
- [ ] **SSL 证书管家**: 集成 `acme.sh` 的全量生命周期管理，支持自动化 DNS-01 验证。
- [ ] **Redis 管理扩展**: 基于数据库管理中心框架，扩展 Redis 键值浏览与 RDB/AOF 备份支持。

### 🌠 长期规划 (v3.0+)

- [ ] **插件市场化**: 实现 `ck_sysinit install <plugin_name>` 动态插件分发与版本控制。
- [ ] **极致安全扫描**: 引入二进制级的 Rootkit 检测、容器安全逃逸审计以及防火墙动态黑名单。
- [ ] **多端控制**: 探索基于 Go 语言重构的、内置 Web 仪表盘的分布式运维底座。

---

## 📄 LICENSE

MIT License.
