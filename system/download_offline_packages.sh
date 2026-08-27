#!/bin/bash

# =================================================================
# 脚本名称: download_offline_packages.sh
# 适用环境: 【有互联网连接的 Linux 电脑】
# 描述: 自动下载 curl, openssl, lsof, socat, tar, wget, cron, dig, nano
#       等常用工具的离线安装包 (.deb / .rpm) 到 system/packages 目录
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

# 检测当前包管理工具
if command -v apt-get &>/dev/null; then
    echo -e "${GREEN}检测到 Debian/Ubuntu (APT) 环境${NC}"
    echo -e "⏳ 正在更新软件索引并下载 .deb 离线包到: ${CYAN}${PKG_DIR}${NC} ..."
    apt-get update -y 2>/dev/null || true
    cd "$PKG_DIR"
    
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
    echo -e "${GREEN}检测到 CentOS/RHEL/Rocky/Alma (YUM/DNF) 环境${NC}"
    echo -e "⏳ 正在下载 .rpm 离线包到: ${CYAN}${PKG_DIR}${NC} ..."
    
    RPM_LIST=(curl openssl lsof socat tar wget cronie bind-utils nano vim-enhanced htop net-tools unzip zip)
    echo -e "下载目标: ${YELLOW}${RPM_LIST[*]}${NC}"
    
    if command -v dnf &>/dev/null; then
        dnf download --destdir="$PKG_DIR" --resolve "${RPM_LIST[@]}" 2>/dev/null || true
    elif command -v yumdownloader &>/dev/null; then
        yumdownloader --destdir="$PKG_DIR" --resolve "${RPM_LIST[@]}" 2>/dev/null || true
    else
        yum install -y yum-utils 2>/dev/null || true
        yumdownloader --destdir="$PKG_DIR" --resolve "${RPM_LIST[@]}" 2>/dev/null || true
    fi

else
    echo -e "${RED}错误: 未能识别当前包管理器，仅支持 Debian/Ubuntu 或 CentOS/RHEL。${NC}"
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
