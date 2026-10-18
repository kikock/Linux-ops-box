# 更新日志 (CHANGELOG)

本文档记录 **Linux-ops-box** 的所有重大版本演进与功能迭代。
本项目的版本号严格遵循 [语义化版本规范 (Semantic Versioning 2.0.0)](https://semver.org/lang/zh-CN/)。

## [v2.6.0] - 2026-10-18

### 🚀 新增功能 (Features)
- **初始菜单仪表盘维度增强 (`system_init.sh`)**:
  - **CPU 架构与规格全景**: 自动探测 CPU 架构代码（x86_64、aarch64、loongarch64、riscv64、armv7l 等），并转换映射为友好的中文解读、多核心数与处理器型号；
  - **系统时区与偏移标注**: 通过 `timedatectl` -> `/etc/timezone` -> `/etc/localtime` 多级策略，精准解析当前时区及 UTC 偏移量（如 `Asia/Shanghai (CST, UTC+08:00)`）；
  - **当前系统时间实时展示**: 仪表盘动态更新并展示年月日时分秒，方便校对服务器时间。
- **全链路脚本与命令审计执行日志 (`common.sh`)**:
  - **命令双写执行器 (`_log_exec` / `_run_cmd_log`)**: 自动记录命令调用上下文、执行耗时、状态码（Exit Code），并在控制台实时呈现的同时清洗 ANSI 彩色转义码持久化至 `/var/log/ck_system_init.log`；
  - **安全降级与轮转保护 (`_rotate_log_if_needed`)**: 无 root 或 `/var/log` 权限时平滑降级至 `/tmp/ck_system_init.log`；单文件满 10MB 自动轮转至 `.1`，彻底规避磁盘空间耗尽风险；
  - **菜单与微服务操作审计**: 主菜单选择、微模块懒加载（`_load_module`）以及卸载退出操作全生命周期审计留痕。
- **精细化系统版本探测与指令抽象层 (`common.sh`)**:
  - **版本号深度解析**: 在 `_init_distro` 中提取全局 `DISTRO_VERSION_ID` 与 `DISTRO_MAJOR_VER`（大版本主号），精准支撑 Ubuntu 20/22/24、Debian 10/11/12、RHEL/CentOS 7/8/9、openEuler 等多代际条件判断；
  - **跨系统指令适配引擎 (`_init_system_commands`)**: 统一抽象不同发行版及版本间的底层命令差异，涵盖 Init 体系（`systemd` / `openrc` / `sysvinit`）、防火墙工具（`ufw` / `firewalld` / `awall` / `nftables` / `iptables`）、网络管理栈（`netplan` / `nmcli` / `ifupdown` / `network-scripts`）、时间同步服务（`chronyd` / `systemd-timesyncd` / `ntp`）、包清理指令及安全组件检测（SELinux / AppArmor）。
- **VPS 综合 IP 质量与纯净度体检 (`vps_mgmt.sh`)**:
  - **集成 Check.Place 权威诊断引擎 (`bash <(curl -Ls https://Check.Place) -I`)**: 自动检测 VPS IP 欺诈度评分（Fraud Score）、原生 IP 属性、双栈网络连通性、流媒体平台解锁能力（Netflix / Disney+ / YouTube 等）及邮件服务商黑名单（Spamhaus）；
  - **多通道高可用与防劫持保护**: 支持官方源与国内 GitHub 加速镜像自动容灾切换，采用独立脚本落盘隔离，规避管道直接执行导致的 stdin 交互劫持问题。

---

## [v2.5.0] - 2026-10-17

### 🚀 新增功能 (Features)
- **Linux 系统内核网络参数自适应调优 (`network_tune.sh`)**:
  - 自动探测物理网卡链路速度（`/sys/class/net/<iface>/speed`）；
  - 全球多节点并发 ICMP 探测计算平均 RTT 延迟与丢包率；
  - 分 4 档（Low / Medium / High / Ultra）动态计算最优 TCP 读写缓冲区与队列上限；
  - 激活 BBR 拥塞算法与 `fq` 队列调度，具备全量快照备份与一键无损回滚能力。
- **常用基础软件管理看板矩阵 (`system_opt.sh`)**:
  - 采用 Kejilion 风格的双列实时状态看板，覆盖 22 项常用系统运维组件；
  - 支持单选安装/修复、空格分隔多选批量安装、`a`/`all` 一键全量安装；
  - 针对 `sudo`、`openssh-server`、`tar` 等基础工具具备二次确认安全防呆卸载。
- **Telegram 运维告警通知中心 (`notify.sh`)**:
  - 极简绑定 Telegram Bot Token 与 Chat ID；
  - 实时监控 CPU 负载、物理内存空闲率与物理磁盘使用率（>85% 预警，>95% 严重告警）；
  - 一键挂载 Crontab 后台守护，内置 1 小时告警风暴抑制锁。
- **Docker 镜像源智能分流与国内自愈加速 (`docker_mgmt.sh`)**:
  - 并发探活测试国内各大主流镜像节点（DaoCloud/1Panel/网易/百度/交大等），自动选取延迟最低的前 3 个节点写入 `daemon.json` 并重启 Docker；
  - 严格隔离 HTTP 私有库（写入 `insecure-registries`）与 HTTPS 加速源（写入 `registry-mirrors`），杜绝协议降级连接失败；
  - 支持自定义 Cloudflare Worker 等反向代理加速域名，支持一键清除加速恢复官方海外直连。
- **网络 IP 增强与出站路由优先级调度 (`network.sh`)**:
  - 增加 **优化 DNS 地址配置**：一键切换国外 DNS（1.1.1.1 / 8.8.8.8）、国内 DNS（223.5.5.5 / 183.60.83.19）或手动快速调起文本编辑器；
  - 增加 **IPv4 / IPv6 出站路由优先级调度**：管理 `/etc/gai.conf`，一键配置 `precedence ::ffff:0:0/96 100`，使系统优先走 IPv4，解决部分双栈网络下 IPv6 绕路卡顿问题。
- **VPS 节点与代理服务管理中心 (`vps_mgmt.sh`)**:
  - 聚合集成 **VPS-VPN 专家工具 (`install_vpn.sh`)**（WireGuard 隧道与 Xray-Reality 流量隐蔽代理）；
  - 聚合集成 **NaiveProxy 自动化安装与管理 (`naive_install.sh`)**（基于 Caddy 补丁版的 HTTP/3 隐身代理）；
  - 深度集成 **Sing-box-yg 精装桶小白专享一键五协议共存脚本 (yonggekkk)**：支持一键官方拉取安装/更新，以及安装完成后一键直接呼出 `sb` 管理控制台。
- **企业级安全底座强化 (`common.sh`)**:
  - 引入基于 Linux `flock` 的跨终端并发安全文件锁 `_run_with_ops_lock`（120 秒防死锁超时），杜绝包管理器数据库并发损坏；
  - 新增系统级安装前磁盘预检机制 `_check_disk_space`，在大批量安装工具或部署 Docker 前强制核验可用容量，防止撑爆根分区；
  - 包管理器适配扩展至 **Arch Linux (`pacman`)** 与 **openSUSE (`zypper`)**。

### 🔄 架构重构 (Refactoring)
- **微内核按需懒加载 (Lazy-Loading)**:
  - 重构 `system_init.sh`，彻底移除主程序启动时对全部 15+ 模块的静态全量 `source`；
  - 引入 `_load_module` 动态路由加载引擎，仅在用户按下菜单编号时按需加载对应模块，显著减少启动开销与内存占用，彻底杜绝全局命名空间污染。
- **全量存量模块标准化双模单兵运行 (Dual-Mode)**:
  - 为所有业务模块（`ssh_sec`, `network`, `firewall_mgmt`, `system_opt`, `docker_mgmt`, `disk_mgmt`, `time_mgmt`, `vnc_mgmt`, `ssl_cert`, `db_mgmt_loader`, `nginx_view`, `notify`, `network_tune`）增加统一的通用底座自探测与 `BASH_SOURCE` 双模守卫；
  - 支持管理员在终端随时单独执行任意模块脚本，无需依赖主菜单启动。
- **异常退出安全规范化**:
  - 排查并消除了存量子模块中误退主终端 Shell 的破坏性 `exit` 指令，规范为标准 `return`。

### 🐛 缺陷修复 (Bug Fixes)
- **数据库管理中心平滑退出修复 (`db_mgmt.sh`)**:
  - 修复了在数据库管理中心选择退出（选项 0）时直接执行 `exit 0` 导致主进程误杀退出终端的问题，改造为 `break` 安全平滑返回 `ck_sysinit` 主菜单。
- **Sing-box-yg 安装空跑无反应修复 (`vps_mgmt.sh`)**:
  - 修复了最小化系统中因缺失 `wget` 导致的静默报错秒退；
  - 修复了使用 `bash <(...)` 进程替换管道导致子脚本标准输入（stdin）被劫持、交互式 `read` 无法接收按键而中断的问题；
  - 引入 4 大国内加速镜像自动降级重试机制与脚本临时落盘 TTY 独占执行，彻底解决大陆节点 GitHub 阻断与键盘交互冲突。

---

## [v2.1.0] - 2026-09-20

### 🚀 新增功能
- **数据库管理中心 (db_mgmt.sh / db_mgmt_loader.sh)**:
  - MySQL / PostgreSQL 备份与恢复交互式 TUI 管理；
  - 支持 Host 直连与 Docker 容器免客户端连接双模式；
  - 数据表归档冷热分离管理机制与定时归档调度。
- **系统时间管理中心 (time_mgmt.sh)**:
  - Docker NTP 服务器 (cturra/ntp) 一键部署；
  - 独创纯 Bash UDP 123 零依赖 NTP 报文健康探活探测；
  - RTC 硬件时钟读写与漂移校准。
- **Mise 多运行时环境集成 (system_opt.sh)**:
  - 基于 Rust Mise 快速管理 Java、Node.js、Go、Python 多版本；
  - 国内语言源加速配置与一键装机四件套组合推荐。

---

## [v2.0.0] - 2026-08-15

### 🚀 新增功能
- 全量架构物理模块化解耦，拆分为 `system/modules/` 子模块；
- 实现控制台输出与 `/var/log/ck_system_init.log` 审计双写；
- 离线服务器安装包预置体系与离线包同步脚本。
