# Linux-ops-box 终极系统运维工具箱

基于原生 Shell 函数构建的企业级 Linux 自动化运维管理工具箱，具备模块化架构、完善的双写审计日志、以及支持 `curl` 一键部署至全局环境等能力。

## ✨ 核心特性

- **多发行版全覆盖**: 深度适配 Ubuntu/Debian/CentOS/Rocky/Armbian/Alpine/Arch Linux/openSUSE 及国产信创（银河麒麟/统信UOS/openEuler/龙蜥），自动识别并适配底层包管理器（apt/dnf/yum/apk/pacman/zypper）。
- **微内核按需懒加载 (Lazy-Loading)**: 主程序彻底移除开机静态全量 source，改造为动态按需加载模块，启动速度提升数倍，零内存污染与全局变量踩踏。
- **全模块双模单兵运行**: 全量子模块均具备自探测底座与独立执行守卫，既可由 `ck_sysinit` 统一调度，也可在终端直接以单脚本独立执行（如 `bash system/modules/network_tune.sh`）。
- **系统与网络自适应调优**: 自动探测网卡物理链路带宽与实时网络 RTT 延迟/丢包率，分档动态计算 TCP 读写缓冲与队列上限，结合 BBR 加速与一键回滚。
- **企业级安全防护机制**: 内置跨终端并发文件锁（Linux `flock` 120s 防死锁）、系统安装前磁盘容量安全预检（`_check_disk_space` 防撑爆根分区）与子模块安全返回规范。
- **透明审计与运维告警**: 日志基座 `common.sh` 实现控制台高亮与 `/var/log/ck_system_init.log` 双写存盘；集成 Telegram Bot 实时超限推送与防风暴抑制。

---

## 🚀 1. 系统初始化工具箱 (ck_sysinit)

用于服务器首选的初始化流程，涵盖基础环境搭建、安全边界加固、纯 Shell 微型状态监控以及高频故障排查机制。

### 快捷安装 (大陆加速版):

```bash
curl -sSL https://ghfast.top/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/install_system.sh | sudo bash
```

> 安装完成后，在任何目录输入 `ck_sysinit` 即可呼出管理菜单；支持使用 `ck_sysinit --uninstall` 彻底清理环境。

### 主菜单功能一览:

| 序号 | 功能模块 | 核心子功能 | 对应模块文件 |
|:---:|:---|:---|:---|
| 1 | **系统软件包更新** | 依赖清理 / 内核升级 | `system_opt.sh` |
| 2 | **系统环境深度优化** | 换源 / Swap / 挂载 / **Linux系统网络内核自适应深度调优 (BBR/大缓冲区/防OOM)** | `system_opt.sh` / `network_tune.sh` |
| 3 | **常用专家工具集** | **常用基础软件管理看板 (Kejilion风格双列看板/单选多选全量/安全卸载)** / 离线包采集 / 本地离线部署 / Mise 多运行时管理 | `system_opt.sh` |
| 4 | **SSH 远程安全加固** | 证书登录 / 端口自定义 / 防爆破 / 服务状态监控 / 一键重启与安装 | `ssh_sec.sh` |
| 5 | **防火墙安全管理** | UFW / FirewallD TUI 管理 | `firewall_mgmt.sh` |
| 6 | **网络 IP 与网卡诊断** | **优化 DNS 地址配置 (国内外/手动编辑)** / **IPv4 与 IPv6 出站解析优先级调度 (/etc/gai.conf)** / 静态 IP / 路由 / NAT 转发 | `network.sh` |
| 7 | **系统资源与服务监控** | 进程 / Nginx 站点配置解析 / 磁盘 IO 实时监控 / 硬件总览 | `nginx_view.sh` |
| 8 | **数据库管理中心** | 备份/恢复/连接管理/定时备份/数据表归档 (详见 §6) | `db_mgmt_loader.sh` |
| 9 | **Docker 管理中心** | 安装/服务管理/Compose 编排 / **国内镜像加速源智能并发测速与自愈 / HTTP私有库安全隔离** | `docker_mgmt.sh` |
| 10 | **VNC 服务管理中心** | 一键安装 VNC / 桌面自启动 / 多端口多账户 | `vnc_mgmt.sh` |
| 11 | **服务器代理配置** | Hosts 代理加速 / 环境变量代理 / Docker 镜像与信任 | `setup_proxy_registry.sh` |
| 12 | **SSL/TLS 证书管理中心** | ACME 联网商业证书申请 / 离线自签证书体系 / 私有根 CA | `ssl_cert.sh` / `acme.sh` |
| 13 | **硬盘检测与清理中心** | 磁盘使用率 / 大文件 / 大目录 / 智能清理辅助 | `disk_mgmt.sh` |
| 14 | **系统时间管理中心** | 系统时区配置 / RTC硬件时钟 / NTP服务器搭建 / 多源对齐 / 开机同步 (详见 §7) | `time_mgmt.sh` |
| 15 | **Telegram 运维告警中心** | Bot 消息推送 / CPU/内存/磁盘超限告警 (>85%预警, >95%严重) / Crontab 守护 / 防刷屏风暴抑制 | `notify.sh` |
| 88 | **在线更新工具箱** | 智能探测最优加速通道 (支持5大源测速) 并云端热覆写 | 内置 |
| 99 | **卸载工具箱** | 清理软链接与守护目录 | 内置 |
| 0 | **退出工具箱** | 退出管理程序 | 内置 |

### 辅助模块体系:

| 模块文件 | 职能描述 |
|:---|:---|
| `common.sh` | 全局底座：颜色规范、双写审计日志 (`/var/log/ck_system_init.log`)、跨平台包管理器统一支持 (`apt/dnf/yum/apk/pacman/zypper`)、**并发互斥安全锁 (`flock` 120s 防死锁)**、**系统级安装前磁盘预检 (`_check_disk_space`)** |
| `network_tune.sh` | **Linux 系统网络内核自适应深度调优中心**：链路物理带宽自动识别、并发全球 ICMP 测算 RTT 延迟与丢包率、4 档自适应 TCP 读写缓冲与队列优化、BBR 拥塞算法一键激活与无损配置回滚 |
| `notify.sh` | **Telegram 运维告警中心**：轻量级 Bot 绑定、Markdown 格式告警卡片、Crontab 定时巡检（CPU/内存/磁盘）、1 小时告警风暴抑制锁 |
| `time_mgmt.sh` | 系统时间管理中心：硬件时钟 (RTC/hwclock) 读写与校准、Docker NTP 服务器 (cturra/ntp) 一键部署、纯 Bash UDP 123 零依赖健康探测、Chrony/ntpdate 客户端配置与开机自启、时钟漂移综合诊断 |
| `ssl_cert.sh` | SSL/TLS 证书管理中心：融合 ACME 联网申请与离线自签、专家级 SAN (IP/多域名/通配符)、私有根 CA 签发、PFX/PEM 格式互转、密钥对配对诊断 |
| `acme.sh` | ACME 证书自动化引擎：支持 Let's Encrypt / ZeroSSL、IP 证书、80 端口单域名与 DNS API 泛域名申请及自动续期 |
| `disk_mgmt.sh` | 硬盘检测与清理中心模块：多挂载点使用率图示、Top N 大文件/大目录扫描、分类占用统计与一键清理 |
| `ssh_sec.sh` | SSH 远程安全加固与服务管理：证书密钥免密登录、安全端口变更、防爆破扫描、服务运行状态诊断、守护进程开机自启、一键重启与在线/离线安装 |
| `ecs.sh` | ECS/云服务器专项运维工具集（性能监控大屏、IO 分析等） |
| `sing-box-plus.sh` | Sing-Box 代理管理集成模块（安装/配置/订阅管理） |
| `db_mgmt_loader.sh` | 数据库模块适配加载器，将 `db_manager/db_mgmt.sh` 接入 TUI 菜单 |
| `vnc_mgmt.sh` | VNC 服务管理中心模块：支持运行状态监控、一键部署实例、服务启停与彻底注销 |
| `nginx_view.sh` | 系统资源与服务监控：Nginx 站点配置自动解析、Top 15 进程监控、内存与磁盘 I/O 监控、硬件总览 |

---

## 🐳 2. Docker & Compose 专家管理工具

独立的 Docker 全生命周期管理工具，支持动态爬取官方最新版本、启动项管理、配置查看及卸载。

### 快捷安装/运行 (大陆加速版):

```bash
curl -sSL https://ghfast.top/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/install_docker.sh | sudo bash
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
curl -sSL https://ghfast.top/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/install_vpn.sh | sudo bash
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
curl -sSL https://ghfast.top/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/naive_install.sh | sudo bash
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
curl -sSL https://ghfast.top/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/install_vnc.sh | sudo bash
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

## ⏰ 7. 系统时间管理中心 (time_mgmt.sh)

已内置于 `ck_sysinit` 主菜单 **「14. 系统时间管理中心」**。深度适配全系列主流与信创 Linux 发行版（Ubuntu/Debian/CentOS/RHEL/Rocky/Alma/银河麒麟/统信UOS/openEuler 等），提供一站式时间基准同步、NTP 局域网/公网服务端搭建及硬件时钟精准管理。

### 核心特性:

1. **Docker NTP 服务器一键部署 (A端/服务端)**:
   - 基于轻量稳定的 `cturra/ntp` 容器镜像，支持自定义 UDP 映射端口（默认 123）。
   - 内置国内优质时钟源矩阵（阿里云、腾讯云、国家授时中心、pool.ntp.org）。
   - 支持**离线孤岛模式**（自动将本机系统时钟伪装为 Stratum 10 本地参考时钟源，供完全物理隔离的机房局域网设备同步）。
2. **客户端同步与开机自启 (B端/客户端)**:
   - **双模自动探测**: 优先推荐并配置高精度 `Chrony` 守护进程，在缺失环境自动降级生成稳健的 `ntpdate` 定时同步脚本与 `systemd` 服务。
   - **环境自愈与冲突清理**: 自动识别并处理 `systemd-timesyncd` 与 `chrony` 冲突，解决信创/旧系统下的 service mask 状态，确保持久化自启生效。
3. **零依赖健康诊断 (纯 Bash UDP 123 探测)**:
   - 独创利用 Bash 内置虚拟流 `/dev/udp/` 构造 48 字节标准 NTP v3 报文，无需系统预装任何 `ntpq` 或 `ntpdate` 即可毫秒级探测目标 NTP 服务器的存活性与延迟。
4. **硬件时钟与漂移全面诊断**:
   - RTC / hwclock 硬件时钟状态读取、系统时间对齐写入硬件时钟 (`hwclock -w`)，彻底消除多系统切换或离线断电导致的时钟漂移。
5. **客户端在线/离线一键安装**:
   - 联动 `system/packages` 本地离线包库与在线官方源，一键安装 `chrony`、`ntpdate` 等运维必备工具。

---

## 🧰 8. Mise 多运行时管理中心 (system_opt.sh)

已内置于 `ck_sysinit` 主菜单 **「3. 常用专家工具集安装」** 之 **「4. Mise 多运行时环境管理」**。基于 Rust 构建的现代极速环境管理器 **Mise**（前身为 rtx），可一站式无缝取代 SDKMAN、nvm、gvm、pyenv。

### 核心特性:

1. **一键极速安装与自动激活**:
   - 自动探测多架构二进制并安装至 `/usr/local/bin/mise`，支持官方渠道与国内 GitHub 加速镜像拉取。
   - 自动配置 `/etc/profile.d/mise.sh` 与用户 `~/.bashrc`，实现系统级无感激活与 Shims 软链接管理。
2. **国内语言镜像源一键加速**:
   - 联动配置 Go 模块代理 (`https://goproxy.cn,direct`)、NPM 镜像源 (`https://registry.npmmirror.com`) 与 Python Pip 清华大学开源镜像源。
3. **版本查看与健康自检**:
   - 实时查询 Mise 核心版本、已安装清单 (`mise ls`)、全局生效版本 (`mise current`) 以及当前终端实际解析命令的执行输出。
4. **多语言一站式生命周期管理**:
   - **Java (JDK)**: 预置 LTS 版本推荐（Java 8, 11, 17, 21），支持 Adoptium/Temurin 等上游二进制自动获取与全局切换。
   - **Node.js**: 预置稳定支持版本推荐（Node.js 18, 20, 22, LTS），自动接管 npm 环境。
   - **Go (Golang)**: 预置官方稳定版推荐（Go 1.21, 1.22, 1.23, latest），开箱即用。
   - **Python**: 自动预检并补齐底层编译与系统依赖库（gcc, openssl, zlib, ffi），支持 Python 3.10, 3.11, 3.12 及自定义版本。
5. **企业级一键四件套打包部署**:
   - 提供「Java 21 + Node.js LTS + Go latest + Python 3.12」组合一键并行拉取并设定为系统全局环境。

---

## 📦 9. 离线安装与内置工具包体系 (system/packages)

针对物理隔离、内网断网环境或海外源受限场景，本工具箱提供 **代码免网部署** 与 **底层工具离线 deb/rpm 包预置** 的双重保障。

### 1. 内置双架构基础工具离线包库 (`system/packages/`)

- **DEB 体系 (Debian / Ubuntu / 统信UOS / 银河麒麟桌面版)**: 预置 `curl`, `wget`, `nano`, `vim`, `tar`, `net-tools`, `htop`, `unzip`, `zip`, `cron`, `openssl`, `lsof`, `socat`, `openssh-server`, `chrony`, `ntpdate`, `dnsutils` 等 17 个关键基础工具官方主包。
- **RPM 体系 (CentOS 7/8 / RHEL / Rocky / AlmaLinux / openEuler)**: 预置 `bind-utils`, `chrony`, `cronie`, `curl`, `htop`, `lsof`, `nano`, `net-tools`, `ntpdate`, `openssl`, `tar`, `unzip`, `wget`, `zip` 等 14 个基础核心 rpm 工具包。
- **离线包同步脚本 (`system/download_offline_packages.sh`)**: 在一台有外网的机器上运行该脚本，即可一键自动检测并拉取/补齐最新版本的双架构离线工具包。

### 2. 离线服务器部署步骤

#### Step 1: 准备安装包 (有网机器)
在一台可以访问外网的机器上下载完整源码包（含 `system/packages/`）：
- **方案 A (Git)**: `git clone https://github.com/kikock/Linux-ops-box.git`
- **方案 B (ZIP)**: 通过浏览器访问 [GitHub 仓库](https://github.com/kikock/Linux-ops-box) 下载并解压 `Source Code (zip)`。

#### Step 2: 文件夹传输 (离线服务器)
使用 `scp`、`sftp` 或 U 盘等手段，将解压后的 `Linux-ops-box` 文件夹整体上传到服务器某目录下。

#### Step 3: 执行本地部署
进入该文件夹，直接以 `root` 权限运行安装脚本：
```bash
cd Linux-ops-box
sudo bash install_system.sh
```

> **逻辑说明**: 安装程序检测到当前目录存在 `system/` 子目录后，会自动跳过 Github 云端检索，实现秒级的本地软链接及守护库构建。同时内置的离线包库可在完全断网环境下为各模块提供基础工具支撑。

---

## ⌨️ 10. 命令行参数 (CLI)

`ck_sysinit` 支持以下命令行参数，可在任意目录直接执行：

| 参数 | 别名 | 功能 |
|:---|:---|:---|
| *(无参数)* | — | 直接进入 TUI 交互主菜单 |
| `--update` | `-up` | **在线更新**：智能测速并探测最佳下载通道，下载最新版并覆盖安装 |
| `--uninstall` | `-u` | **彻底卸载**：删除 `/usr/local/bin/ck_sysinit` 软链接及 `/opt/ck_sysinit` 守护目录 |

```bash
# 在线更新到最新版 (支持智能延迟探测)
ck_sysinit --update

# 彻底卸载
ck_sysinit --uninstall
# 或通过安装脚本卸载
curl -sSL https://ghfast.top/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/install_system.sh | sudo bash -s -- --uninstall
```

---

## 🛠 11. 开发扩展说明 (Developer Guide)

本工具箱采用高度模块化的 Shell 函数架构，极易进行二次开发。

### 1. 新建模块与双模范式 (Dual-Mode Invocation)

在 `system/modules/` 下建立 `.sh` 文件，并遵循以下解耦与双模规范：

- **通用底座自探测**: 模块头部统一添加通用底座加载检测，确保单兵执行时具备完整日志与包管理底座：
  ```bash
  _CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$_CURRENT_DIR/common.sh" ]; then
      source "$_CURRENT_DIR/common.sh"
  fi
  ```
- **双模运行守卫**: 模块尾部必须通过 `BASH_SOURCE` 守卫独立执行入口，支持单兵执行与主菜单动态挂载：
  ```bash
  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
      your_module_main_menu
  fi
  ```
- **安全返回规范**: 模块内子流程中断必须使用 `return`，严禁直接使用 `exit`，防止误杀管理员当前主 Shell。
- **日志双写与并发保护**: 统一调用 `_log_info` / `_log_err`；涉及安装包操作调用 `_run_with_ops_lock` 并通过 `_check_disk_space` 进行磁盘空间预检。

### 2. 微内核动态按需挂载流程 (Lazy-Loading)

1. 在 `system/system_init.sh` 的主菜单 `while true` 循环中增加菜单项编号。
2. 在 `case "$main_choice"` 分支中，使用 `_load_module` 动态懒加载对应模块并调用入口函数：
   ```bash
   16)
       _load_module "your_module.sh"
       your_module_main_menu
       ;;
   ```
3. 无需在主程序头部进行任何静态 `source`，确保微内核极致轻量与隔离。

---

## 🚀 12. 后续更新计划 (Roadmap)

我们致力于将 `Linux-ops-box` 打造为最懂运维、最轻量的企业级 TUI 工具箱。

### 📅 近期目标 (v2.x)

- [x] **运维告警集成**: ✅ 已落地 Telegram 机器人告警中心（支持 CPU/内存/磁盘超限告警、Crontab 定时守护与 1 小时风暴抑制）。
- [x] **自适应网络内核优化**: ✅ 已落地（自适应带宽与延迟测算、4 档计算优化、BBR/fq 一键激活与无损配置回滚）。
- [x] **架构微内核全量解耦**: ✅ 已落地（主程序动态懒加载、全模块双模单兵运行、安全退出规范化）。
- [x] **数据库管理中心**: ✅ MySQL / PostgreSQL TUI 管理（含 Docker 容器模式、定时备份、多连接管理、数据表自动化归档）。
- [x] **SSL 证书管家**: ✅ 已落地（融合 `acme.sh` 商业证书与 `openssl` 离线自签、IP 证书、DNS API 泛域名申请、私有根 CA 签发）。
- [x] **系统时间管理中心**: ✅ 已落地（支持 RTC 硬件时钟读写、Docker NTP 服务端搭建、Chrony/ntpdate 客户端自启与纯 Bash UDP 123 零依赖健康探测）。
- [ ] **Redis 管理扩展**: 基于数据库管理中心框架，扩展 Redis 键值浏览与 RDB/AOF 备份支持。

### 🌠 长期规划 (v3.0+)

- [ ] **插件市场化**: 实现 `ck_sysinit install <plugin_name>` 动态插件分发与版本控制。
- [ ] **极致安全扫描**: 引入二进制级的 Rootkit 检测、容器安全逃逸审计以及防火墙动态黑名单。
- [ ] **多端控制**: 探索基于 Go 语言重构的、内置 Web 仪表盘的分布式运维底座。

---

## 📄 LICENSE

MIT License.

