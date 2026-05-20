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
if [ -f "$BASE_DIR/modules/db_mgmt_loader.sh" ]; then
    source "$BASE_DIR/modules/db_mgmt_loader.sh"
fi
if [ -f "$BASE_DIR/modules/docker_mgmt.sh" ]; then
    source "$BASE_DIR/modules/docker_mgmt.sh"
fi
if [ -f "$BASE_DIR/modules/vnc_mgmt.sh" ]; then
    source "$BASE_DIR/modules/vnc_mgmt.sh"
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

# ================================================================
# 辅助函数: 测试代理源下载速度与连通性 (超时 2 秒)
# ================================================================
_test_proxy_speed() {
    local url="$1"
    if command -v curl &>/dev/null; then
        local score
        # 1. 运行 curl 探测并将退出码和 time_total 分离，不使用容易产生多行输出的对冲写法
        score=$(curl -o /dev/null -s -w "%{time_total}" -m 2 -I "$url")
        local exit_code=$?
        
        # 2. 只有当 curl 成功连接（退出码为 0）且获取到值时，才进行毫秒数值转化
        if [ $exit_code -eq 0 ] && [ -n "$score" ]; then
            # 兼容性浮点转整数：秒与毫秒前3位切分 (例如 1.208170 拆为 1 秒和 208 毫秒)
            local sec=$(echo "$score" | cut -d. -f1)
            local ms=$(echo "$score" | cut -d. -f2 | cut -c1-3)
            
            # 补齐 ms 保证其是 3 位数
            while [ ${#ms} -lt 3 ]; do
                ms="${ms}0"
            done
            
            # 剔除前导 0 防止 Bash 将其误判为八进制 (例如 085 变 85，000 变 0)
            sec=$(echo "$sec" | sed 's/^0*//')
            [ -z "$sec" ] && sec=0
            ms=$(echo "$ms" | sed 's/^0*//')
            [ -z "$ms" ] && ms=0
            
            local total_ms=$(( sec * 1000 + ms ))
            echo "$total_ms"
            return 0
        fi
    elif command -v wget &>/dev/null; then
        local start_t end_t
        start_t=$(date +%s)
        if wget --spider -q -T 2 "$url" &>/dev/null; then
            end_t=$(date +%s)
            local diff=$(( (end_t - start_t) * 1000 ))
            [ $diff -eq 0 ] && diff=150
            echo "$diff"
            return 0
        fi
    fi
    echo "9999"
    return 1
}

# ================================================================
# 工具箱在线更新函数
# ================================================================
_update_toolbox() {
    local PROXIES=(
        "https://github.com"
        "https://ghproxy.net"
        "https://mirror.ghproxy.com"
        "https://gh-proxy.com"
    )
    local PROXY_NAMES=(
        "🌐 GitHub 官方直连 (https://github.com)"
        "🚀 加速通道 A: GHProxy.net (国内推荐)"
        "🚀 加速通道 B: Mirror.ghproxy.com (备用)"
        "🚀 加速通道 C: GH-proxy.com (备用)"
    )

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        clear
        echo -e "${RED}  ✗ 系统缺少 curl 和 wget，无法在线更新！${NC}"
        echo -e "  请先安装 curl: apt install curl  或  yum install curl"
        read -p "  按任意键返回菜单..." -n1 < /dev/tty
        return
    fi

    local CHOSEN_PROXY=""
    
    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}          Linux-ops-box 在线更新配置                  ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo -e "请选择 GitHub 下载源/加速代理通道："
        echo -e " 1. ⚡ 智能自动探测最佳通道 (推荐)"
        echo -e " 2. ${PROXY_NAMES[0]}"
        echo -e " 3. ${PROXY_NAMES[1]}"
        echo -e " 4. ${PROXY_NAMES[2]}"
        echo -e " 5. ${PROXY_NAMES[3]}"
        echo -e " 6. ✏️  手动输入自定义加速前缀"
        echo -e " 0. ↩ 返回主菜单"
        echo -e "${CYAN}======================================================${NC}"
        read -p "请输入选项 [0-6]: " proxy_choice < /dev/tty

        case $proxy_choice in
            1)
                echo -e "\n⏳ 正在动态探测各通道延迟，请稍候..."
                local min_latency=9999
                local best_idx=0
                
                for i in "${!PROXIES[@]}"; do
                    local test_url
                    if [ "${PROXIES[$i]}" = "https://github.com" ]; then
                        test_url="https://github.com/kikock/Linux-ops-box"
                    else
                        test_url="${PROXIES[$i]}/https://github.com/kikock/Linux-ops-box"
                    fi
                    
                    echo -n "   ➜ 正在测试 [${PROXY_NAMES[$i]}] ... "
                    local latency
                    latency=$(_test_proxy_speed "$test_url")
                    
                    if [ "$latency" -lt 9999 ]; then
                        echo -e "${GREEN}${latency} ms${NC}"
                        if [ "$latency" -lt "$min_latency" ]; then
                            min_latency=$latency
                            best_idx=$i
                        fi
                    else
                        echo -e "${RED}连接超时/不可用${NC}"
                    fi
                done
                
                if [ "$min_latency" -eq 9999 ]; then
                    echo -e "\n${RED}❌ 所有预设通道均无法连接！建议手动输入自定义代理或检查网络。${NC}"
                    read -p "按任意键重新选择..." -n1 < /dev/tty
                    continue
                else
                    CHOSEN_PROXY="${PROXIES[$best_idx]}"
                    echo -e "\n${GREEN}✓ 自动探测完成！已选择最佳通道: [${PROXY_NAMES[$best_idx]}] (延迟 ${min_latency} ms)${NC}"
                    sleep 1.5
                fi
                ;;
            2) CHOSEN_PROXY="${PROXIES[0]}" ;;
            3) CHOSEN_PROXY="${PROXIES[1]}" ;;
            4) CHOSEN_PROXY="${PROXIES[2]}" ;;
            5) CHOSEN_PROXY="${PROXIES[3]}" ;;
            6)
                echo -e "\n请输入您的自定义 GitHub 加速前缀（如 https://github.akams.cn/）："
                read -p "前缀 URL: " custom_prefix < /dev/tty
                if [ -z "$custom_prefix" ]; then
                    echo -e "${RED}输入不能为空！${NC}"
                    sleep 1
                    continue
                fi
                if [[ ! "$custom_prefix" =~ ^https?:// ]]; then
                    echo -e "${RED}格式错误：必须以 http:// 或 https:// 开头！${NC}"
                    sleep 1.5
                    continue
                fi
                CHOSEN_PROXY="$custom_prefix"
                ;;
            0) return ;;
            *) echo -e "${RED}输入无效，请重新选择。${NC}"; sleep 1; continue ;;
        esac

        local FINAL_URL
        if [ "$CHOSEN_PROXY" = "https://github.com" ]; then
            FINAL_URL="https://github.com/kikock/Linux-ops-box/raw/main/install_system.sh"
        else
            FINAL_URL="${CHOSEN_PROXY%/}/https://github.com/kikock/Linux-ops-box/raw/main/install_system.sh"
        fi

        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}          Linux-ops-box 在线更新程序                  ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo -e "  ➜ 选定下载源: ${YELLOW}${CHOSEN_PROXY}${NC}"
        echo -e "  ➜ 最终资源 URL: ${CYAN}${FINAL_URL}${NC}"
        echo -e "  ⏳ 正在从云端拉取最新安装器，请稍候..."

        local TMP_INSTALLER="/tmp/ops_box_updater_$$.sh"
        local dl_success=false

        if command -v curl &>/dev/null; then
            if curl -fsSL --connect-timeout 8 -o "${TMP_INSTALLER}" "${FINAL_URL}"; then
                dl_success=true
            fi
        else
            if wget -qO "${TMP_INSTALLER}" --connect-timeout=8 "${FINAL_URL}"; then
                dl_success=true
            fi
        fi

        if [ "$dl_success" = "true" ] && [ -f "${TMP_INSTALLER}" ] && [ -s "${TMP_INSTALLER}" ]; then
            if head -n 5 "${TMP_INSTALLER}" | grep -qE '#!/bin/|#!/usr/bin/'; then
                chmod +x "${TMP_INSTALLER}"
                echo -e "${GREEN}  ✓ 最新安装器拉取成功！正在启动更新覆盖流程...${NC}"
                echo -e "${CYAN}======================================================${NC}"
                
                export LINUX_OPS_BOX_PROXY="${CHOSEN_PROXY}"
                bash "${TMP_INSTALLER}" --update
                local EXIT_CODE=$?
                rm -f "${TMP_INSTALLER}"

                if [ $EXIT_CODE -eq 0 ]; then
                    echo -e "\n${GREEN}🎉 工具箱已成功更新至最新版本！建议重新运行 ck_sysinit 加载新版。${NC}"
                else
                    echo -e "\n${RED}❌ 更新过程中遇到错误（退出码: ${EXIT_CODE}），请检查系统日志。${NC}"
                fi
                read -p "  按任意键返回主菜单..." -n1 < /dev/tty
                return
            else
                echo -e "${RED}  ❌ 校验失败：拉取的文件内容无效（可能已被代理劫持或重定向至报错页面）。${NC}"
                rm -f "${TMP_INSTALLER}"
            fi
        else
            echo -e "${RED}  ❌ 下载失败：网络连接超时或目标源无响应。${NC}"
            rm -f "${TMP_INSTALLER}"
        fi

        echo -e "\n${YELLOW}  提示: 当前下载源可能已失效或被封锁。${NC}"
        echo "  [1] 重新选择其他下载通道 / 重新探测"
        echo "  [2] 重试当前下载通道"
        echo "  [0] 取消更新并返回主菜单"
        read -p "  请选择下一步操作 [1-2, 0]: " retry_opt < /dev/tty
        case $retry_opt in
            2) continue ;;
            0) return ;;
            *) continue ;;
        esac
    done
}

# --- MODULE SETUP COMPLETE ---
# 自动进入 TUI 面板
_update_live_data

# 主菜单循环
while true; do
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}      Linux 系统初始化工具箱 v2.1 - By kikock      ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    _draw_menu_header
    echo -e "${GREEN}══════════════ 🛠  系统运维中心 ══════════════${NC}"
    echo " 1. 系统软件包更新       (清理冗余/内核升级)"
    echo " 2. 系统环境深度优化     (换源/BBR/Swap/时区)"
    echo " 3. 常用专家工具集安装   (最小化系统必备)"
    echo " 4. SSH 远程安全加固     (证书/端口/防爆破)"
    echo " 5. 防火墙安全管理中心   (UFW/FirewallD)"
    echo " 6. 网络 IP 与网卡诊断   (静态IP/路由/MTR)"
    echo " 7. 系统资源与服务监控   (进程/Nginx/磁盘/IO)"
    echo -e "${GREEN}══════════════ 📦  基础服务中心 ══════════════${NC}"
    echo " 8. 数据库管理中心       (MySQL/PostgreSQL 备份归档)"
    echo " 9. Docker 管理中心      (安装/服务管理/Compose)"
    echo " 10. VNC 服务管理中心     (一键安装/自启/多账户)"
    echo -e "${GREEN}══════════════ ⚙   工具箱管理   ══════════════${NC}"
    echo -e "${YELLOW} 11. ♻  在线更新工具箱${NC}"
    echo -e "${RED} 12. 🗑  卸载此工具箱${NC}"
    echo " 0.  退出工具箱"
    echo -e "${GREEN}==============================================${NC}"
    read -p "请输入指令编号 [0-12]: " choice < /dev/tty

    case $choice in
        1)  update_system_packages ;;
        2)  system_optimization_menu ;;
        3)  install_common_tools ;;
        4)  ssh_menu ;;
        5)  firewall_menu ;;
        6)  network_menu ;;
        7)  nginx_menu ;;
        8)  db_management_center ;;
        9)  docker_management_center ;;
        10) vnc_management_center ;;
        11) _update_toolbox ;;
        12)
            echo -e "${YELLOW}警告: 即将执行彻底卸载程序...${NC}"
            read -p "是否确认从系统中移除 Linux-ops-box? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                rm -f "/usr/local/bin/ck_sysinit" 2>/dev/null
                rm -f "/usr/local/bin/sysinit"    2>/dev/null
                echo -e "${GREEN}✅ 全局调令符已清理。${NC}"
                echo -e "${YELLOW}请在退出后手动执行以下指令完成最后清理：${NC}"
                echo -e "  ${CYAN}rm -rf /opt/ck_sysinit${NC}"
                echo -e "${BLUE}感谢使用！${NC}"
                exit 0
            fi
            ;;
        0) echo -e "${BLUE}感谢使用，再见！- kikock${NC}"; exit 0 ;;
        *) echo -e "${RED}输入无效，请重新选择。${NC}"; sleep 1 ;;
    esac
done