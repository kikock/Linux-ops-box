# Linux-ops-box 终极系统运维工具箱

基于原生 Shell 函数构建的企业级 Linux 自动化运维管理工具箱，具备模块化架构、完善的双写审计日志、以及支持 `curl` 一键部署至全局环境等能力。

## ✨ 核心特性

- **多发行版兼容**: 深度适配 Ubuntu/Debian/CentOS/Rocky/Armbian/Alpine，自动识别底层包管理器（apt/dnf/yum/apk）。
- **完全解耦的架构**: 主程序仅 200 行负责 TUI 菜单分发，各类功能下沉至 `modules/` 子模块，互不干扰。
- **透明审计**: 所有状态输出通过专门的日志基座 `common.sh`，实现控制台高亮输出与 `/var/log/ck_system_init.log` 原文存档双写。
- **独立专家级工具**: 为高频组件（如 Docker/VPN/代理）提供完全独立的、具备实时版本采集能力的安装与管理脚本。

---

## 🚀 1. 系统初始化工具箱 (ck_sysinit)

用于服务器首选的初始化流程，包括 SSH 安全防范、网络配置、系统优化等。

### 快捷安装 (大陆加速版):
```bash
curl -sSL https://ghproxy.net/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/install_system.sh | sudo bash
```
> 安装完成后，在任何目录输入 `ck_sysinit` 即可呼出管理菜单。

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

## 📦 5. 离线安装方案 (无网络环境)

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
- [ ] **数据库管理中心**: 提供 MySQL、PostgreSQL、Redis 的 TUI 仪表盘与配置优化工具。
- [ ] **SSL 证书管家**: 集成 `acme.sh` 的全量生命周期管理，支持自动化 DNS-01 验证。

### 🌠 长期规划 (v3.0+)
- [ ] **插件市场化**: 实现 `ck_sysinit install <plugin_name>` 动态插件分发与版本控制。
- [ ] **极致安全扫描**: 引入二进制级的 Rootkit 检测、容器安全逃逸审计以及防火墙动态黑名单。
- [ ] **多端控制**: 探索基于 Go 语言重构的、内置 Web 仪表盘的分布式运维底座。

---

## 📄 LICENSE
MIT License.
