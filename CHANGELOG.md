# 更新日志 (CHANGELOG)

本文档记录 **Linux-ops-box** 的所有重大版本演进与功能迭代。
本项目的版本号严格遵循 [语义化版本规范 (Semantic Versioning 2.0.0)](https://semver.org/lang/zh-CN/)。

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
