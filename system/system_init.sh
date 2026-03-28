#!/bin/bash

# =================================================================
# 脚本名称: system_init.sh
# 描述: Linux 系统初始化工具箱 (多发行版适配)
# 适配: Ubuntu / Debian / Armbian / Raspberry Pi OS /
#       CentOS / RHEL / Fedora / Alpine Linux
# 制作人: kikock
# =================================================================

# 检查是否以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo "错误: 请使用 sudo 或 root 用户运行此脚本。"
   exit 1
fi

# 动态挂载共享组件库 (包含全局参数、日志基座跨平台诊断 _init_distro)
# 解决 sysinit 全局软链接调用时的上下文飘移问题
BASE_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
if [ -f "$BASE_DIR/modules/common.sh" ]; then
    source "$BASE_DIR/modules/common.sh"
else
    echo -e "\033[0;31m[致命错误]\033[0m 找不到核心库文件: $BASE_DIR/modules/common.sh"
    echo "请确保已完整配置脚本目录结构。工具初始化阻断。"
    exit 1
fi

# 引入下属模块
if [ -f "$BASE_DIR/modules/ssh_sec.sh" ]; then
    source "$BASE_DIR/modules/ssh_sec.sh"
fi
if [ -f "$BASE_DIR/modules/docker_app.sh" ]; then
    source "$BASE_DIR/modules/docker_app.sh"
fi
if [ -f "$BASE_DIR/modules/network.sh" ]; then
    source "$BASE_DIR/modules/network.sh"
fi
if [ -f "$BASE_DIR/modules/nginx_view.sh" ]; then
    source "$BASE_DIR/modules/nginx_view.sh"
fi
if [ -f "$BASE_DIR/modules/system_opt.sh" ]; then
    source "$BASE_DIR/modules/system_opt.sh"
fi

# ================================================================
# 启动时系统摘要 (进入脚本第一屏)
# ================================================================
_show_startup_banner() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}      Linux 系统初始化工具箱 v2.0 - By kikock      ${NC}"
    echo -e "${CYAN}======================================================${NC}"

    local OS_NAME="${DISTRO_NAME:-未知}"
    local KERNEL
    KERNEL=$(uname -r)
    local ARCH
    ARCH=$(uname -m)
    local IP_ADDR
    IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
    local UPTIME_STR
    UPTIME_STR=$(uptime -p 2>/dev/null || uptime | awk -F',' '{print $1}' | sed 's/.*up /up /')

    # 内存
    local MEM_LINE
    MEM_LINE=$(free -h 2>/dev/null | awk '/Mem|内存/{print $2" 总 /",$3" 用"}')
    [ -z "$MEM_LINE" ] && MEM_LINE="(无法读取)"

    # 磁盘
    local DISK_USAGE
    DISK_USAGE=$(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')

    echo -e " ${YELLOW}系统:${NC}  $OS_NAME"
    echo -e " ${YELLOW}内核:${NC}  $KERNEL  ${YELLOW}架构:${NC} $ARCH"
    echo -e " ${YELLOW}内存:${NC}  $MEM_LINE"
    echo -e " ${YELLOW}磁盘:${NC}  $DISK_USAGE"
    echo -e " ${YELLOW}IP:${NC}    $IP_ADDR"
    echo -e " ${YELLOW}运行:${NC}  $UPTIME_STR"
    echo -e " ${YELLOW}包管理:${NC} ${PKG_MGR}  ${YELLOW}发行族:${NC} ${DISTRO_FAMILY}"
    echo -e "${CYAN}======================================================${NC}"
    echo ""
    read -p "按回车键进入管理菜单..."
}

# 1. 查看系统信息函数
show_sys_info() {
    clear
    echo -e "${BLUE}================ 系统详细信息 ================${NC}"

    # 操作系统
    local OS_NAME="${DISTRO_NAME:-}"
    [ -z "$OS_NAME" ] && OS_NAME=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -z "$OS_NAME" ] && OS_NAME="未知"

    local KERNEL
    KERNEL=$(uname -r)
    local ARCH
    ARCH=$(uname -m)

    # CPU 型号 (兼容 lscpu 和 /proc/cpuinfo)
    local CPU_MODEL
    if command -v lscpu &>/dev/null; then
        CPU_MODEL=$(lscpu 2>/dev/null | grep -E "^Model name|^型号" | head -1 | cut -d: -f2 | xargs)
    fi
    [ -z "$CPU_MODEL" ] && CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
    [ -z "$CPU_MODEL" ] && CPU_MODEL="未知"

    # CPU 核心数
    local CPU_CORES
    CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "?")

    # 内存 (兼容 free -h 的不同输出格式)
    local MEM_TOTAL MEM_USED MEM_FREE
    local MEM_LINE
    MEM_LINE=$(free -h 2>/dev/null | grep -E "^Mem|^内存" || free -h 2>/dev/null | sed -n '2p')
    MEM_TOTAL=$(echo "$MEM_LINE" | awk '{print $2}')
    MEM_USED=$(echo "$MEM_LINE"  | awk '{print $3}')
    MEM_FREE=$(echo "$MEM_LINE"  | awk '{print $4}')

    # Swap
    local SWAP_TOTAL SWAP_USED
    local SWAP_LINE
    SWAP_LINE=$(free -h 2>/dev/null | grep -E "^Swap|^交换" || free -h 2>/dev/null | sed -n '3p')
    SWAP_TOTAL=$(echo "$SWAP_LINE" | awk '{print $2}')
    SWAP_USED=$(echo "$SWAP_LINE"  | awk '{print $3}')

    # 磁盘
    local DISK_INFO
    DISK_INFO=$(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')

    # 网络 IP
    local IP_ADDR
    IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')

    # 运行时间
    local UPTIME
    UPTIME=$(uptime -p 2>/dev/null || uptime | awk -F',' '{print $1}' | sed 's/.*up /up /')

    # 系统负载
    local LOAD
    LOAD=$(uptime | awk -F'[,:]' '{print $(NF-2)","$(NF-1)","$NF}' | xargs)

    # 核心温度 (兼容多平台)
    local TEMP="未知"
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        [ -f "$zone" ] && TEMP=$(awk '{printf "%.1f°C", $1/1000}' "$zone") && break
    done
    # Raspberry Pi 温度读取
    if command -v vcgencmd &>/dev/null; then
        TEMP=$(vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9.]+' | head -1)
        [ -n "$TEMP" ] && TEMP="${TEMP}°C (RPi)"
    fi

    # 输出
    echo -e "${YELLOW}操作系统:${NC}  $OS_NAME"
    echo -e "${YELLOW}发行族:${NC}    $DISTRO_FAMILY  (包管理: $PKG_MGR)"
    echo -e "${YELLOW}内核版本:${NC}  $KERNEL"
    echo -e "${YELLOW}系统架构:${NC}  $ARCH"
    echo -e "${YELLOW}处理器:${NC}    $CPU_MODEL ($CPU_CORES 核)"
    echo -e "${YELLOW}系统负载:${NC}  $LOAD"
    echo -e "${YELLOW}根分区:${NC}    $DISK_INFO"
    echo -e "${YELLOW}物理内存:${NC}  $MEM_TOTAL (已用: $MEM_USED / 空闲: $MEM_FREE)"
    echo -e "${YELLOW}虚拟内存:${NC}  $SWAP_TOTAL (已用: $SWAP_USED)"
    echo -e "${YELLOW}核心温度:${NC}  $TEMP"
    echo -e "${YELLOW}内网 IP:${NC}   $IP_ADDR"
    echo -e "${YELLOW}运行时间:${NC}  $UPTIME"
    echo -e "${BLUE}==============================================${NC}"
    echo ""
    read -p "按回车键返回主菜单..."
}

# --- MODULE SETUP COMPLETE ---
_show_startup_banner

# 主菜单循环
while true; do
    clear
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}   Linux 系统初始化工具箱 - By kikock        ${NC}"
    echo -e "${GREEN}   系统: ${YELLOW}${DISTRO_NAME:-未知}${GREEN}${NC}"
    echo -e "${GREEN}   包管理: ${YELLOW}${PKG_MGR}${GREEN}  发行族: ${YELLOW}${DISTRO_FAMILY}${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo " 1. 查看系统详细信息"
    echo " 2. SSH 远程连接管理 (含证书配置)"
    echo " 3. Docker 管理 (安装/卸载/命令/Web)"
    echo " 4. 系统软件包更新"
    echo " 5. 系统环境优化 (源/BBR/Swap/时区)"
    echo " 6. 网络 IP 配置 (静态IP/DHCP)"
    echo " 7. Nginx 配置查看"
    echo " 8. 安装常用软件包 (针对最小化系统)"
    echo " 0. 退出脚本"
    echo -e "${GREEN}==============================================${NC}"
    read -p "请输入选项 [0-8]: " choice

    case $choice in
        1) show_sys_info ;;
        2) ssh_menu ;;
        3) docker_menu ;;
        4) update_system_packages ;;
        5) system_optimization_menu ;;
        6) network_menu ;;
        7) nginx_menu ;;
        8) install_common_tools ;;
        0) echo -e "${BLUE}感谢使用，再见！- kikock${NC}"; exit 0 ;;
        *) echo -e "${RED}输入无效，请重新选择。${NC}" ; sleep 1 ;;
    esac
done