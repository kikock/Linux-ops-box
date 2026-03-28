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

echo -e "${BLUE}==============================================${NC}"
echo -e "${GREEN}      Linux-ops-box 终极运维工具箱快捷部署     ${NC}"
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
REPO_BRANCH="dev1.0"

# 2. 核心源码定位：自动判定是本地执行还是云端 curl 管道执行
HAS_LOCAL_FILES=false
if [ -d "$PWD/system" ] && [ -f "$PWD/system/system_init.sh" ]; then
    HAS_LOCAL_FILES=true
    SRC_DIR="$PWD/system"
    echo -e "${GREEN}[本地源码检测] 发现 system/ 目录，将使用本地直接安装...${NC}"
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
        rm -rf "/tmp/Linux-ops-box-${REPO_BRANCH}" /tmp/ops-box.tar.gz
        curl -L -# -o /tmp/ops-box.tar.gz "$TAR_URL"
        
        echo -e "  ⏳ 正在解压系统内核引擎..."
        mkdir -p "/tmp/Linux-ops-box-${REPO_BRANCH}"
        tar -xzf /tmp/ops-box.tar.gz -C /tmp
        SRC_DIR="/tmp/Linux-ops-box-${REPO_BRANCH}/system"
        
    elif command -v wget &>/dev/null && command -v unzip &>/dev/null; then
        echo -e "  ➜ 引擎: wget + unzip \n  ⏳ 正在下载系统镜像压缩包，若卡住请耐心等待..."
        rm -rf /tmp/Linux-ops-box-main /tmp/ops-box.zip
        wget -O /tmp/ops-box.zip --show-progress "$ZIP_URL"
        
        echo -e "  ⏳ 正在解压系统内核引擎..."
        unzip -q /tmp/ops-box.zip -d /tmp/
        SRC_DIR="/tmp/Linux-ops-box-main/system"
        
    elif command -v git &>/dev/null; then
        echo -e "  ➜ 引擎: git clone \n  ⏳ 正在拉取源码库仓库 [分支: ${REPO_BRANCH}]..."
        rm -rf /tmp/Linux-ops-box
        git clone --progress -b "${REPO_BRANCH}" "$GIT_REPO_URL" /tmp/Linux-ops-box
        SRC_DIR="/tmp/Linux-ops-box/system"
        
    else
        echo -e "${RED}致命错误: 您的系统环境既没有 git，也没有 curl/tar 或 wget/unzip 组合，无法实现在线下载！${NC}"
        echo -e "解决办法: 请先使用系统包管理器安装 curl 或是手工下载。${NC}"
        exit 1
    fi
    
    if [ ! -d "$SRC_DIR" ] || [ ! -f "$SRC_DIR/system_init.sh" ]; then
        echo -e "${RED}致命错误: 从 Github 源码下载失败，网络离线或仓库尚未公开！${NC}"
        exit 1
    fi
fi

# 3. 开始最终部署
echo -e "\n[1/3] 正在构建系统级守护库: ${TARGET_OPT} ..."
mkdir -p "$TARGET_OPT"

echo -e "[2/3] 正在同步核心微服务文件与外挂模块引擎 ..."
# 覆盖同步所有主脚本及模块体系
cp -a "$SRC_DIR/system_init.sh" "$TARGET_OPT/"
if [ -d "$SRC_DIR/modules" ]; then
    cp -r -a "$SRC_DIR/modules" "$TARGET_OPT/"
fi
# 同步离线安装包或额外资源文件夹 (如 docker) 如果存在的话
for extra_dir in docker nginx static config; do
    if [ -d "$SRC_DIR/$extra_dir" ]; then
        cp -r -a "$SRC_DIR/$extra_dir" "$TARGET_OPT/"
    fi
done

# 赋予执行权限
chmod +x "$TARGET_OPT/system_init.sh"
for sh_file in "$TARGET_OPT"/modules/*.sh; do
    [ -f "$sh_file" ] && chmod +x "$sh_file"
done

echo -e "[3/3] 正在向上编译链接统全局调令符 ..."
# 清理旧版本指令残留 (如果有的话)
[ -L "/usr/local/bin/sysinit" ] && rm -f "/usr/local/bin/sysinit"
ln -sf "$TARGET_OPT/system_init.sh" "$TARGET_BIN"

# 清理临时下载痕迹 (如果是云端拉取)
if [ "$HAS_LOCAL_FILES" = false ]; then
    rm -rf "/tmp/Linux-ops-box-${REPO_BRANCH}" /tmp/ops-box.zip /tmp/Linux-ops-box /tmp/ops-box.tar.gz
fi

echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN}🎉 恭喜！「自动化系统运维工具箱」全模块安装穿透成功！${NC}"
echo -e "您现在可以在当前操作系统的 ${YELLOW}任意目录、任意位置${NC} 敲击以下指令快速呼出 TUI 控制台：\n"
echo -e "  🔥  ${CYAN}ck_sysinit${NC}"
echo -e "\n${BLUE}==============================================${NC}"
exit 0
