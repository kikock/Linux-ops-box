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

if [ -f "$BASE_DIR/modules/network.sh" ]; then
    source "$BASE_DIR/modules/network.sh"
fi
if [ -f "$BASE_DIR/modules/nginx_view.sh" ]; then
    source "$BASE_DIR/modules/nginx_view.sh"
fi
if [ -f "$BASE_DIR/modules/system_opt.sh" ]; then
    source "$BASE_DIR/modules/system_opt.sh"
fi
if [ -f "$BASE_DIR/modules/firewall_mgmt.sh" ]; then
    source "$BASE_DIR/modules/firewall_mgmt.sh"
fi

# ================================================================
# 1. 静态环境参数自检 (只在启动时检索 1 次，缓存以提升性能)
# ================================================================
_log_info "正在采集硬件指纹与网络拓扑..."
OS_NAME="${DISTRO_NAME:-未知}"
KERNEL=$(uname -r)
ARCH=$(uname -m)
IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
# 获取默认网卡 MAC 地址
PRIMARY_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {print $5}' | head -1)
[ -z "$PRIMARY_IF" ] && PRIMARY_IF=$(ls /sys/class/net/ | grep -v "lo" | head -1)
MAC_ADDR=$(cat /sys/class/net/${PRIMARY_IF}/address 2>/dev/null || echo "未知")
CPU_MODEL=$(lscpu 2>/dev/null | grep -E "^Model name|^型号" | head -1 | cut -d: -f2 | xargs)
[ -z "$CPU_MODEL" ] && CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
[ -z "$CPU_MODEL" ] && CPU_MODEL="未知处理器"

# ----------------------------------------------------------------
# 2. 动态指标仪表盘逻辑
# ----------------------------------------------------------------
_update_live_data() {
    # 负载与 Uptime
    LOAD_LIVE=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    UPTIME_LIVE=$(uptime -p 2>/dev/null | sed 's/up //')
    [ -z "$UPTIME_LIVE" ] && UPTIME_LIVE=$(uptime | awk -F',' '{print $1}' | sed 's/.*up //')

    # 内存 (总 / 已用) + 百分比
    local MEM_RAW
    MEM_RAW=$(free 2>/dev/null | grep -E "^Mem|^内存")
    local MEM_TOTAL_KB=$(echo "$MEM_RAW" | awk '{print $2}')
    local MEM_USED_KB=$(echo "$MEM_RAW" | awk '{print $3}')
    if [ -n "$MEM_TOTAL_KB" ] && [ "$MEM_TOTAL_KB" -gt 0 ]; then
        MEM_PCT=$((MEM_USED_KB * 100 / MEM_TOTAL_KB))
        MEM_STR=$(free -h 2>/dev/null | grep -E "^Mem|^内存" | awk '{printf "%s / %s", $3, $2}')
    else
        MEM_PCT=0; MEM_STR="无法获取"
    fi

    # Swap 占用
    local SWAP_RAW
    SWAP_RAW=$(free 2>/dev/null | grep -E "^Swap|^交换")
    local SWAP_TOTAL_KB=$(echo "$SWAP_RAW" | awk '{print $2}')
    local SWAP_USED_KB=$(echo "$SWAP_RAW" | awk '{print $3}')
    if [ -n "$SWAP_TOTAL_KB" ] && [ "$SWAP_TOTAL_KB" -gt 0 ]; then
        SWAP_PCT=$((SWAP_USED_KB * 100 / SWAP_TOTAL_KB))
        SWAP_STR=$(free -h 2>/dev/null | grep -E "^Swap|^交换" | awk '{printf "%s / %s", $3, $2}')
    else
        SWAP_PCT=0; SWAP_STR="未启用或无法获取"
    fi

    # 磁盘 (总 / 已用)
    DISK_LIVE=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')
}

_draw_menu_header() {
    _update_live_data
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${GREEN}●${NC} 系统环境: ${GREEN}${OS_NAME} (${ARCH})${NC}"
    echo -e " ${GREEN}●${NC} 内核版本: ${KERNEL}"
    echo -e " ${GREEN}●${NC} 网路负载: ${YELLOW}IP: ${IP_ADDR:-未知} ${NC}| ${YELLOW}MAC: ${MAC_ADDR}${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
    echo -e " ${CYAN}●${NC} CPU 负载: ${CYAN}${LOAD_LIVE}${NC}"
    echo -e " ${CYAN}●${NC} 系统运行: ${UPTIME_LIVE}"
    echo -e " ${CYAN}●${NC} 内存占用: ${MEM_STR} (${MEM_PCT}%)"
    echo -e " ${CYAN}●${NC} 交换分区: ${SWAP_STR} (${SWAP_PCT}%)"
    echo -e " ${CYAN}●${NC} 磁盘空间: ${DISK_LIVE}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# --- MODULE SETUP COMPLETE ---
# 自动进入 TUI 面板
_update_live_data

# 主菜单循环
while true; do
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}      Linux 系统初始化工具箱 v2.0 - By kikock      ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    _draw_menu_header
    echo -e "${GREEN}================== 运维指令中心 ==================${NC}"
    echo " 1. SSH 远程安全配置 (证书/端口/防爆破)"
    echo " 2. 系统软件包更新 (清理冗余/内核升级)"
    echo " 3. 系统环境优化 (源/BBR/Swap/时区)"
    echo " 4. 网络 IP 管理 (静态IP/网卡诊断)"
    echo " 5. 服务/站点实时监控中心"
    echo " 6. 常用专家工具集安装 (最小化系统必备)"
    echo " 7. 防火墙安全管理中心 (UFW/FirewallD)"
    echo -e "${RED} 9. 彻底卸载此工具箱 (清理自启动与链接)${NC}"
    echo " 0. 退出工具箱"
    echo -e "${GREEN}==================================================${NC}"
    read -p "请输入指令编号 [0-9]: " choice < /dev/tty

    case $choice in
        1) ssh_menu ;;
        2) update_system_packages ;;
        3) system_optimization_menu ;;
        4) network_menu ;;
        5) nginx_menu ;;
        6) install_common_tools ;;
        7) firewall_menu ;;
        9) 
            echo -e "${YELLOW}警告: 即将执行彻底卸载程序...${NC}"
            read -p "是否确认从系统中移除 Linux-ops-box? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # 清理软链接
                rm -f "/usr/local/bin/ck_sysinit" 2>/dev/null
                rm -f "/usr/local/bin/sysinit" 2>/dev/null
                # 提示用户手动删除目录 (因为脚本正在从该目录运行，无法自删)
                echo -e "${GREEN}✅ 全局调令符已清理。${NC}"
                echo -e "${YELLOW}由于脚本正在运行，请在退出后手动执行以下指令完成最后清理：${NC}"
                echo -e "  ${CYAN}rm -rf /opt/ck_sysinit${NC}"
                echo -e "${BLUE}感谢使用！${NC}"
                exit 0
            fi
            ;;
        0) echo -e "${BLUE}感谢使用，再见！- kikock${NC}"; exit 0 ;;
        *) echo -e "${RED}输入无效，请重新选择。${NC}" ; sleep 1 ;;
    esac
done