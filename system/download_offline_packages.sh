#!/bin/bash

# =================================================================
# 脚本名称: download_offline_packages.sh
# 适用环境: 【有互联网连接的 Linux 电脑】
# 描述: 自动下载常用工具离线安装包 (.deb / .rpm) 到 system/packages 目录
#       覆盖范围:
#         [基础工具] curl, openssl, lsof, socat, tar, wget, cron, dig, nano, vim
#         [时间管理] chrony, ntpdate, ntp(含ntpq), util-linux(hwclock), tzdata
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

    # ── 基础工具 ────────────────────────────────────────────────────
    DEB_BASIC=(curl openssl lsof socat tar wget cron dnsutils nano vim htop net-tools unzip zip)
    # ── 时间管理工具 (time_mgmt.sh 依赖) ────────────────────────────
    # chrony   : chronyc 命令 (现代 NTP 守护进程)
    # ntpdate  : 手动单次同步
    # ntp      : ntpq 状态查询工具
    # util-linux: hwclock 硬件时钟读写
    # tzdata   : 时区数据库 (date 时区切换依赖)
    DEB_TIME=(chrony ntpdate ntp util-linux tzdata)
    DEB_LIST=("${DEB_BASIC[@]}" "${DEB_TIME[@]}")

    echo -e "下载目标:"
    echo -e "  ${CYAN}[基础工具]${NC} ${DEB_BASIC[*]}"
    echo -e "  ${CYAN}[时间管理]${NC} ${DEB_TIME[*]}"
    echo ""

    for pkg in "${DEB_LIST[@]}"; do
        echo -n "  ➜ 正在下载 ${pkg} (含依赖) ... "
        # 使用 apt-get --download-only 自动解析并下载依赖树
        # 若 --download-only 失败则退回 apt-get download（单包无依赖）
        if apt-get install --download-only --reinstall -y "$pkg" &>/dev/null 2>&1; then
            # apt-get install --download-only 会把包下在 /var/cache/apt/archives/
            # 将所有新增的 .deb 移入当前目录（过滤掉已存在的同名文件）
            find /var/cache/apt/archives/ -maxdepth 1 -name "*.deb" \
                ! -name 'lock' 2>/dev/null | while read -r f; do
                bn="$(basename "$f")"
                [ ! -f "$bn" ] && cp -n "$f" . 2>/dev/null || true
            done
            echo -e "${GREEN}[成功+依赖]${NC}"
        elif apt-get download "$pkg" &>/dev/null 2>&1; then
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

    # ── 基础工具 ────────────────────────────────────────────────────
    RPM_BASIC=(curl openssl lsof socat tar wget cronie bind-utils nano vim-enhanced htop net-tools unzip zip)
    # ── 时间管理工具 (time_mgmt.sh 依赖) ────────────────────────────
    # chrony   : chronyc (现代 NTP 守护进程)
    # ntp      : ntpdate + ntpq (注: RHEL 8+ 上游已废弃 ntpdate 独立包)
    # util-linux: hwclock 硬件时钟读写
    # tzdata   : 时区数据库
    RPM_TIME=(chrony ntp util-linux tzdata)
    RPM_LIST=("${RPM_BASIC[@]}" "${RPM_TIME[@]}")

    echo -e "下载目标:"
    echo -e "  ${CYAN}[基础工具]${NC} ${RPM_BASIC[*]}"
    echo -e "  ${CYAN}[时间管理]${NC} ${RPM_TIME[*]}"
    echo ""

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
