#!/bin/bash

# =================================================================
# 脚本名称: download_offline_packages.sh
# 适用环境: 【有互联网连接的 Linux 电脑】
# 描述: 自动下载 curl, openssl, lsof, socat, tar, wget, cron, dig, nano
#       等常用工具的离线安装包 (.deb / .rpm) 到 system/packages 目录
# 适配: Ubuntu / Debian / 银河麒麟 / 统信 UOS / Deepin /
#          CentOS / RHEL / Rocky / openEuler / Anolis OS
# =================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PKG_DIR="$SCRIPT_DIR/packages"
mkdir -p "$PKG_DIR"

echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}      📦 常用基础组件离线安装包批量下载工具          ${NC}"
echo -e "${CYAN}======================================================${NC}"

# 识别当前包管理工具
DISTRO_LABEL="未知"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_LABEL="${PRETTY_NAME:-${ID:-未知}}"
fi
if command -v apt-get &>/dev/null; then
    local_sub="$PKG_DIR/deb"
    mkdir -p "$local_sub"
    # 识别具体发行版给出友好提示
    case "$(echo "${ID:-}" | tr '[:upper:]' '[:lower:]')" in
        kylin|ubuntukylin|neokylin) echo -e "${GREEN}检测到 麒麟系 (银河麒麟/中标麒麟/Ubuntu Kylin) APT 环境${NC}" ;;
        uos|uniontechos|deepin*)    echo -e "${GREEN}检测到 统信 UOS / Deepin APT 环境${NC}" ;;
        *)                          echo -e "${GREEN}检测到 Debian/Ubuntu (APT) 环境${NC}" ;;
    esac
    echo -e "⏳ 正在更新软件索引并下载 .deb 离线包到: ${CYAN}${local_sub}${NC} ..."
    apt-get update -y 2>/dev/null || true
    cd "$local_sub"
    
    DEB_LIST=(curl openssl lsof socat tar wget cron dnsutils nano vim htop net-tools unzip zip)
    echo -e "下载目标: ${YELLOW}${DEB_LIST[*]}${NC}"
    
    for pkg in "${DEB_LIST[@]}"; do
        echo -n "  ➜ 正在下载 ${pkg} ... "
        if apt-get download "$pkg" &>/dev/null; then
            echo -e "${GREEN}[成功]${NC}"
        else
            echo -e "${YELLOW}[跳过/未找到]${NC}"
        fi
    done
    cd - >/dev/null

elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    local_sub="$PKG_DIR/rpm"
    mkdir -p "$local_sub"
    # 识别具体 RPM 发行版给出友好提示
    case "$(echo "${ID:-}" | tr '[:upper:]' '[:lower:]')" in
        kylin)                    echo -e "${GREEN}检测到 银河麒麟 V10 Server (YUM/DNF) 环境${NC}" ;;
        openeuler|euler|euleros) echo -e "${GREEN}检测到 openEuler/EulerOS (YUM/DNF) 环境${NC}" ;;
        anolis|tencentos)         echo -e "${GREEN}检测到 Anolis OS/TencentOS (YUM/DNF) 环境${NC}" ;;
        *)                        echo -e "${GREEN}检测到 CentOS/RHEL/Rocky/Alma (YUM/DNF) 环境${NC}" ;;
    esac
    echo -e "⏳ 正在下载 .rpm 离线包到: ${CYAN}${local_sub}${NC} ..."
    
    RPM_LIST=(curl openssl lsof socat tar wget cronie bind-utils nano vim-enhanced htop net-tools unzip zip)
    echo -e "下载目标: ${YELLOW}${RPM_LIST[*]}${NC}"
    
    if command -v dnf &>/dev/null; then
        dnf download --destdir="$local_sub" --resolve "${RPM_LIST[@]}" 2>/dev/null || true
    elif command -v yumdownloader &>/dev/null; then
        yumdownloader --destdir="$local_sub" --resolve "${RPM_LIST[@]}" 2>/dev/null || true
    else
        yum install -y yum-utils 2>/dev/null || true
        yumdownloader --destdir="$local_sub" --resolve "${RPM_LIST[@]}" 2>/dev/null || true
    fi

else
    echo -e "${RED}错误: 未能识别当前包管理器，仅支持 Debian/Ubuntu/麒麟/UOS 或 CentOS/RHEL/openEuler/Anolis。${NC}"
    exit 1
fi

COUNT=$(find "$PKG_DIR" -type f \( -name "*.deb" -o -name "*.rpm" \) | wc -l)
echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}🎉 离线安装包下载完成！共采集 ${YELLOW}${COUNT}${GREEN} 个离线包文件。${NC}"
echo -e " 📁 保存目录: ${CYAN}${PKG_DIR}${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "${YELLOW}使用方法:${NC}"
echo -e " 1. 将包含 packages/ 目录的工具箱拷贝至无网服务器；"
echo -e " 2. 在主菜单运行「3. 常用专家工具集安装」即可实现一键纯离线批量安装！"
echo -e "${GREEN}======================================================${NC}"
