# Linux-ops-box 终极系统运维工具箱

基于原生 Shell 函数构建的企业级 Linux 自动化运维管理工具箱，具备模块化架构、完善的双写审计日志、以及支持 `curl` 一键部署至全局环境等能力。

## ✨ 核心特性

- **多发行版兼容**: 深度适配 Ubuntu/Debian/CentOS/Rocky/Armbian/Alpine，自动识别底层包管理器（apt/dnf/yum/apk）。
- **完全解耦的架构**: 主程序仅 200 行负责 TUI 菜单分发，各类功能下沉至 `modules/` 子模块，互不干扰。
- **透明审计**: 所有状态输出通过专门的日志基座 `common.sh`，实现控制台高亮输出与 `/var/log/ck_system_init.log` 原文存档双写。
- **独立专家级工具**: 为高频组件（如 Docker）提供完全独立的、具备实时版本采集能力的安装与管理脚本。

---

## 🚀 1. 系统初始化工具箱 (sysinit)

用于服务器首选的初始化流程，包括 SSH 安全防范、网络配置、系统优化等。

### 快捷安装 (大陆加速版):
```bash
curl -sSL https://ghproxy.net/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/install_system.sh | sudo bash
```
> 安装完成后，在任何目录输入 `sysinit` 即可呼出管理菜单。

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

## 🛠 开发扩展说明

1. 在 `system/modules/` 下建立新的处理逻辑 (`xxx.sh`)。
2. 内部所有的控制台输出请统一弃用 `echo`，改为调用 `_log_info`、`_log_warn` 以及 `_log_err`。
3. 在 `system/system_init.sh` 中增加一个模块引用语句及菜单分发即可！

## 📄 LICENSE
MIT License.
