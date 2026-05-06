#!/bin/bash
# =================================================================
# 脚本名称: install_system.sh
# 描述: Linux-ops-box 在线快速安装部署程序
# 功能: 支持跨网端 curl 直装或本地 clone 目录自适应安装
# =================================================================

# 定义颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 定义版本号 (以更新日期为准)
VERSION="2026.04.17"

echo -e "${BLUE}==============================================${NC}"
echo -e "${GREEN}      Linux-ops-box 终极运维工具箱快捷部署     ${NC}"
echo -e "${CYAN}             版本号: v${VERSION}                ${NC}"
echo -e "${BLUE}==============================================${NC}"

# 1. 权限检测
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 安装向导需要 root 权限，请使用 sudo 执行 (例如: curl ... | sudo bash)。${NC}"
   exit 1
fi

TARGET_OPT="/opt/ck_sysinit"
TARGET_BIN="/usr/local/bin/ck_sysinit"
REPO_URL="https://github.com/kikock/Linux-ops-box.git"
# 定义默认拉取分支 (正式版建议设为 main)
REPO_BRANCH="main"

# 2. 卸载与更新逻辑触发
if [[ "$1" == "--uninstall" ]] || [[ "$1" == "-u" ]]; then
    echo -e "${YELLOW}==============================================${NC}"
    echo -e "${YELLOW}  正在启动 Linux-ops-box 卸载程序...          ${NC}"
    echo -e "${YELLOW}==============================================${NC}"
    read -p "  危险操作：是否确认彻底移除所有运维工具组件? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "  ⏳ 正在清理全局调令符: ${TARGET_BIN} ..."
        [ -f "$TARGET_BIN" ] || [ -L "$TARGET_BIN" ] && rm -f "$TARGET_BIN"
        [ -L "/usr/local/bin/sysinit" ] && rm -f "/usr/local/bin/sysinit"
        
        echo -e "  ⏳ 正在移除系统守护库: ${TARGET_OPT} ..."
        [ -d "$TARGET_OPT" ] && rm -rf "$TARGET_OPT"
        
        echo -e "\n${GREEN}🎉 卸载成功！「自动化系统运维工具箱」已从您的系统中彻底移除。${NC}"
        echo -e "${BLUE}==============================================${NC}"
        exit 0
    else
        echo -e "${CYAN}已取消卸载操作。${NC}"
        exit 0
    fi
elif [[ "$1" == "--update" ]] || [[ "$1" == "-up" ]]; then
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${CYAN}  正在启动 Linux-ops-box 在线更新程序...      ${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo -e "  ⏳ 正在准备云端重装环境..."
    # 模拟进入云端安装模式，直接通过当前脚本执行安装流程即可
    # 如果用户是通过直接运行本地脚本带参数执行，则继续向下运行安装逻辑
    # 如果是未来通过别名调用，逻辑也是一致的：重新同步云端/本地代码。
fi

# 3. 核心源码定位：自动判定是本地执行还是云端 curl 管道执行
HAS_LOCAL_FILES=false
# 如果是更新模式，强制走云端下载流程
if [[ "$1" == "--update" ]] || [[ "$1" == "-up" ]]; then
    echo -e "${YELLOW}[更新模式] 正在忽略本地缓存，强制从云端获取最新版本...${NC}"
else
    if [ -d "$PWD/system" ] && [ -f "$PWD/system/system_init.sh" ]; then
        HAS_LOCAL_FILES=true
        SRC_DIR="$PWD/system"
        echo -e "${GREEN}[本地源码检测] 发现 system/ 目录，将使用本地直接安装...${NC}"
    fi
fi

if [ "$HAS_LOCAL_FILES" = false ]; then
    echo -e "${YELLOW}[云端库检测] 未在当前目录发现源码，尝试从 Github 为您实时静默下载...${NC}"
    
    # 动态探测并自适应 Github 访问路线
    GH_MIRROR="https://github.com"
    echo -e "  ⏳ 正在探测 Github 官方直连可用性..."
    
    # 连通性探测：使用 3秒超时 尝试访问目标仓库
    if command -v curl &>/dev/null; then
        if curl -Is -m 3 "https://github.com/kikock/Linux-ops-box" | head -1 | grep -qE 'HTTP/.*(200|301|302)'; then
            echo -e "${GREEN}  ✓ Github 官方通道顺畅，已启用直连模式。${NC}"
        else
            echo -e "${YELLOW}  ⚠ Github 直连受阻或超时，自动为您切换国内加速镜像池 (ghproxy.net)...${NC}"
            GH_MIRROR="https://ghproxy.net/https://github.com"
        fi
    elif command -v wget &>/dev/null; then
        if wget --spider -q -T 3 "https://github.com/kikock/Linux-ops-box"; then
            echo -e "${GREEN}  ✓ Github 官方通道顺畅，已启用直连模式。${NC}"
        else
            echo -e "${YELLOW}  ⚠ Github 直连受阻或超时，自动为您切换国内加速镜像池 (ghproxy.net)...${NC}"
            GH_MIRROR="https://ghproxy.net/https://github.com"
        fi
    else
        GH_MIRROR="https://ghproxy.net/https://github.com"
    fi

    TAR_URL="$GH_MIRROR/kikock/Linux-ops-box/archive/refs/heads/${REPO_BRANCH}.tar.gz"
    ZIP_URL="$GH_MIRROR/kikock/Linux-ops-box/archive/refs/heads/${REPO_BRANCH}.zip"
    GIT_REPO_URL="$GH_MIRROR/kikock/Linux-ops-box.git"
    
    # 优先尝试 curl 配合 tar (最常见组合)
    if command -v curl &>/dev/null && command -v tar &>/dev/null; then
        echo -e "  ➜ 引擎: curl + tar \n  ⏳ 正在下载系统镜像压缩包，请耐心等待进度条走完..."
        rm -rf /tmp/ops-box-tar-dir /tmp/ops-box.tar.gz
        mkdir -p /tmp/ops-box-tar-dir
        curl -L -# -o /tmp/ops-box.tar.gz "$TAR_URL"
        
        echo -e "  ⏳ 正在解压系统内核引擎..."
        tar -xzf /tmp/ops-box.tar.gz -C /tmp/ops-box-tar-dir
        # 动态定位 system 目录，不再硬编码分支名后缀
        SRC_DIR=$(find /tmp/ops-box-tar-dir -maxdepth 3 -name "system" -type d | head -n 1)
        
    elif command -v wget &>/dev/null && command -v unzip &>/dev/null; then
        echo -e "  ➜ 引擎: wget + unzip \n  ⏳ 正在下载系统镜像压缩包，若卡住请耐心等待..."
        rm -rf /tmp/ops-box-zip-dir /tmp/ops-box.zip
        mkdir -p /tmp/ops-box-zip-dir
        wget -O /tmp/ops-box.zip --show-progress "$ZIP_URL"
        
        echo -e "  ⏳ 正在解压系统内核引擎..."
        unzip -q /tmp/ops-box.zip -d /tmp/ops-box-zip-dir
        SRC_DIR=$(find /tmp/ops-box-zip-dir -maxdepth 3 -name "system" -type d | head -n 1)
        
    elif command -v git &>/dev/null; then
        echo -e "  ➜ 引擎: git clone \n  ⏳ 正在拉取源码库仓库 [分支: ${REPO_BRANCH}]..."
        rm -rf /tmp/Linux-ops-box-git
        git clone --progress -b "${REPO_BRANCH}" "$GIT_REPO_URL" /tmp/Linux-ops-box-git
        SRC_DIR="/tmp/Linux-ops-box-git/system"
        
    else
        echo -e "${RED}致命错误: 您的系统环境既没有 git，也没有 curl/tar 或 wget/unzip 组合，无法实现在线下载！${NC}"
        echo -e "解决办法: 请先使用系统包管理器安装 curl 或是手工下载。${NC}"
        exit 1
    fi
    
    if [ -z "$SRC_DIR" ] || [ ! -d "$SRC_DIR" ] || [ ! -f "$SRC_DIR/system_init.sh" ]; then
        echo -e "${RED}致命错误: 从 Github 源码下载失败或解压路径匹配错误！${NC}"
        echo -e "调试信息: 搜索到的源码路径为 [$SRC_DIR]${NC}"
        exit 1
    fi
fi

# 3. 开始最终部署
echo -e "\n[1/3] 正在构建系统级守护库: ${TARGET_OPT} ..."
# 清理可能存在的旧目录，确保全新同步
[ -d "$TARGET_OPT" ] && rm -rf "$TARGET_OPT"
mkdir -p "$TARGET_OPT"

echo -e "[2/3] 正在同步核心微服务文件与外挂模块引擎 ..."
# 同步主程序及模块体系
cp -rf "$SRC_DIR/system_init.sh" "$TARGET_OPT/"
if [ -d "$SRC_DIR/modules" ]; then
    cp -rf "$SRC_DIR/modules" "$TARGET_OPT/"
fi
# 同步离线安装包或额外资源文件夹 (如 docker, nginx 等)
for extra_dir in docker nginx static config db_manager; do
    if [ -d "$SRC_DIR/$extra_dir" ]; then
        cp -rf "$SRC_DIR/$extra_dir" "$TARGET_OPT/"
    fi
done

# 权限标准化清洗 (针对 Anolis OS/CentOS 8 严格模式)
echo -e "  ⏳ 正在标准化全局权限协议 [755]..."
chmod -R 755 "$TARGET_OPT"
find "$TARGET_OPT" -type f -name "*.sh" -exec chmod +x {} \;

echo -e "[3/3] 正在向上编译链接系统全局调令符 ..."
# 移除过时链接并建立标准的软链接
[ -L "/usr/local/bin/sysinit" ] && rm -f "/usr/local/bin/sysinit"
rm -f "$TARGET_BIN"
ln -sf "$TARGET_OPT/system_init.sh" "$TARGET_BIN"
chmod +x "$TARGET_BIN"

# 清理临时下载痕迹 (如果是云端拉取)
if [ "$HAS_LOCAL_FILES" = false ]; then
    rm -rf /tmp/ops-box-tar-dir /tmp/ops-box-zip-dir /tmp/Linux-ops-box-git /tmp/ops-box.tar.gz /tmp/ops-box.zip
fi

echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN}🎉 恭喜！「自动化系统运维工具箱」全模块安装穿透成功！${NC}"
echo -e "您现在可以在当前操作系统的 ${YELLOW}任意目录、任意位置${NC} 敲击以下指令快速呼出 TUI 控制台：\n"
echo -e "  🔥  ${CYAN}ck_sysinit${NC}"

# PATH 连通性辅助检测
if ! command -v ck_sysinit &>/dev/null; then
    echo -e "\n${YELLOW}提示: 检测到 /usr/local/bin 未在您的当前 PATH 中，请执行以下命令刷新环境：${NC}"
    echo -e "  ${CYAN}export PATH=\$PATH:/usr/local/bin && source /etc/profile${NC}"
fi

echo -e "\n${CYAN}提示: 如需更新版本，请执行以下命令：${NC}"
echo -e "  🔥  ${YELLOW}ck_sysinit --update${NC}"

echo -e "\n${BLUE}==============================================${NC}"
exit 0
