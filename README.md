# Linux-ops-box 终极系统运维工具箱

基于原生 Shell 函数构建的企业级 Linux 自动化运维管理工具箱，具备模块化架构、完善的双写审计日志、以及支持 `curl` 一键部署至全局环境等能力。

## ✨ 核心特性

- **多发行版兼容**: 深度适配 Ubuntu/Debian/CentOS/Rocky/Armbian/Alpine，自动识别底层包管理器（apt/dnf/yum/apk）。
- **完全解耦的架构**: 主程序仅 200 行负责 TUI（图形化交互界面）和分发控制，各类功能下沉至 `modules/` 子模块，互不干扰。
- **透明审计**: 所有状态输出通过专门的日志基座 `common.sh`，实现控制台高亮输出与 `/var/log/tk_system_init.log` 原文存档双写。
- **免密部署**: 在线/离线双通道部署安装机制。

## 🚀 快捷部署与安装

> **注意限制**: 下载与安装全程需要 `root` 权限。

### 方法一：极速在线部署 (推荐) 
无需预先安装 git，只要服务器支持 `curl` 和外网即可：

#### 🌎 给具有通畅国际网络的服务器：
```bash
curl -sSL https://raw.githubusercontent.com/kikock/Linux-ops-box/main/install_system.sh | sudo bash
```

#### 🇨🇳 给中国大陆的服务器 (针对 Github 封锁/污染优化)：
如果上述原站地址会卡住或无响应，请直接使用下面的全境内地加速镜像点运行：
```bash
curl -sSL https://ghproxy.net/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/install_system.sh | sudo bash
```
> *(安装脚本在第二阶段拉取引擎源码时，也会自适应复用镜像点，保障顺畅落盘)*

### 方法二：本地 / 离线网闸主机部署
如果您要在一台完全没有公网环境的机器上部署，可按照以下步骤操作：

1. 下载整个仓库源码包（通过 Download ZIP 或者您有内网跳板机克隆）。
2. 将 `Linux-ops-box` 文件夹传到目标服务器。
3. 进入该文件夹并执行本地安装：
```bash
cd Linux-ops-box
sudo bash install_system.sh
```

## 🛠 开发扩展说明

未来开发者可以很方便地追加系统管理功能：

1. 在 `system/modules/` 下建立新的处理逻辑 (`xxx.sh`)。
2. 内部所有的控制台输出请统一弃用 `echo`，改为调用 `_log_info "提示内容"`，`_log_warn` 以及 `_log_err`。
3. 在 `system/system_init.sh` 中增加一个模块引用语句及菜单分发即可！

## 📄 LICENSE
MIT License.
