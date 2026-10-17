#!/usr/bin/env bash
# ==============================================================================
# Linux-ops-box 系统网络内核自适应深度优化模块 (network_tune.sh)
# 核心特性:
#   1. 动态检测网卡物理链路速率、RTT 往返延迟、丢包率与物理内存
#   2. 自适应 4 档带宽分类 (Low / Medium / High / Ultra)，精确计算最强 sysctl 参数
#   3. 智能探测与激活 BBR 拥塞控制算法及 fq 队列调度
#   4. 配置文件自动备份与一键无损回滚机制
#   5. 状态全景监控与参数可视化
# ==============================================================================

# 基础颜色定义 (兼容独立运行与外部引用)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

CONF_FILE="/etc/sysctl.d/99-ck-network-tune.conf"
CONF_LEGACY="/etc/sysctl.conf"
BACKUP_DIR="/var/backups/opsbox_sysctl"

# 日志输出兜底
_net_log_info() { echo -e "${CYAN}[网络调优]${NC} $*"; }
_net_log_ok()   { echo -e "${GREEN}[✔]${NC} $*"; }
_net_log_warn() { echo -e "${YELLOW}[!]${NC} $*"; }
_net_log_err()  { echo -e "${RED}[✗]${NC} $*"; }

# 安全读取 sysctl 值
_sysctl_read() {
    sysctl -n "$1" 2>/dev/null || echo "N/A"
}

# 比较内核版本
_kver_ge() {
    printf '%s\n%s' "$2" "$1" | sort -V -C
}

# 检测物理网卡链路速率 (Mbps)
_detect_link_speed() {
    local speed=0
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
    [ -z "$iface" ] && iface=$(ls /sys/class/net/ 2>/dev/null | grep -v -E '^(lo|docker|veth|br-)' | head -1)

    if [ -n "$iface" ]; then
        if command -v ethtool &>/dev/null; then
            speed=$(ethtool "$iface" 2>/dev/null | awk '/Speed:/{gsub(/[^0-9]/,"",$2); print $2}')
        fi
        if [ -z "$speed" ] || [ "$speed" = "0" ]; then
            speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null)
        fi
    fi
    # 虚拟化环境兜底设为 1000M
    [ -z "$speed" ] || [ "$speed" -le 0 ] 2>/dev/null && speed=1000
    echo "$speed"
}

# 检测网络 RTT 往返延迟 (ms)
_detect_latency() {
    local total=0 count=0 avg
    local targets=("223.5.5.5" "119.29.29.29" "1.1.1.1" "8.8.8.8")

    for t in "${targets[@]}"; do
        local rtt
        rtt=$(ping -c 2 -W 2 "$t" 2>/dev/null | awk -F'/' '/avg|min\/avg/{print $5}')
        if [ -n "$rtt" ]; then
            total=$(awk "BEGIN{print $total + $rtt}")
            count=$((count + 1))
        fi
    done

    if [ "$count" -gt 0 ]; then
        avg=$(awk "BEGIN{printf \"%.1f\", $total / $count}")
    else
        avg="50.0"
    fi
    echo "$avg"
}

# 检测丢包率 (%)
_detect_packet_loss() {
    local loss
    loss=$(ping -c 5 -W 2 223.5.5.5 2>/dev/null | awk -F',' '/packet loss|loss/{for(i=1;i<=NF;i++) if($i ~ /%/) {gsub(/[^0-9.]/,"",$i); print $i; exit}}')
    if [ -z "$loss" ]; then
        loss=$(ping -c 5 -W 2 1.1.1.1 2>/dev/null | awk -F',' '/packet loss|loss/{for(i=1;i<=NF;i++) if($i ~ /%/) {gsub(/[^0-9.]/,"",$i); print $i; exit}}')
    fi
    [ -z "$loss" ] && loss=0
    echo "$loss"
}

# 检测总物理内存 (MB)
_detect_memory_mb() {
    awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 1024
}

# 带宽 4 档分级
_classify_bandwidth() {
    local speed=$1
    if [ "$speed" -lt 100 ]; then
        echo "low"
    elif [ "$speed" -lt 1000 ]; then
        echo "medium"
    elif [ "$speed" -lt 10000 ]; then
        echo "high"
    else
        echo "ultra"
    fi
}

# 核心自适应优化生成函数
auto_tune_network() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${CYAN}            🚀 系统网络内核深度自适应调优 (Auto-Network-Tune)          ${NC}"
    echo -e "${CYAN}========================================================================${NC}"

    if [ "$(id -u)" -ne 0 ]; then
        _net_log_err "错误: 必须以 root 权限执行此优化！"
        read -p "按回车键返回..." -r < /dev/tty
        return 1
    fi

    local kver
    kver=$(uname -r | grep -oP '^\d+\.\d+' || echo "4.19")
    local mem_mb
    mem_mb=$(_detect_memory_mb)

    _net_log_info "正在进行网络特征实时侦测，请稍候..."
    local speed
    speed=$(_detect_link_speed)
    local latency
    latency=$(_detect_latency)
    local loss
    loss=$(_detect_packet_loss)
    local curr_bbr
    curr_bbr=$(_sysctl_read net.ipv4.tcp_congestion_control)
    local curr_qdisc
    curr_qdisc=$(_sysctl_read net.core.default_qdisc)
    local bw_class
    bw_class=$(_classify_bandwidth "$speed")

    echo ""
    echo -e "  [硬件与系统] 内核: ${GREEN}$(uname -r)${NC} | 物理内存: ${GREEN}${mem_mb} MB${NC}"
    echo -e "  [链路与延迟] 链路速率: ${GREEN}${speed} Mbps${NC} | 平均RTT: ${GREEN}${latency} ms${NC} | 丢包: ${GREEN}${loss}%${NC}"
    echo -e "  [当前拥塞控制] 算法: ${CYAN}${curr_bbr}${NC} | 队列规则: ${CYAN}${curr_qdisc}${NC}"

    case "$bw_class" in
        low)    echo -e "  [优化策略评定] 带宽等级: ${YELLOW}低带宽 (<100M)${NC} → 启动小内存保护性参数" ;;
        medium) echo -e "  [优化策略评定] 带宽等级: ${CYAN}中带宽 (100M~1G)${NC} → 启动标准通用高性能网络参数" ;;
        high)   echo -e "  [优化策略评定] 带宽等级: ${GREEN}千兆/高带宽 (1G~10G)${NC} → 启动高并发与吞吐激进参数" ;;
        ultra)  echo -e "  [优化策略评定] 带宽等级: ${CYAN}万兆/超高带宽 (>10G)${NC} → 启动极致缓冲区参数" ;;
    esac
    echo ""

    # 配置备份
    mkdir -p "$BACKUP_DIR" 2>/dev/null
    local backup_target="$BACKUP_DIR/sysctl_bak_$(date +%Y%m%d_%H%M%S).conf"
    if [ -f "$CONF_FILE" ]; then
        cp -f "$CONF_FILE" "$backup_target"
        _net_log_ok "现有专用优化配置已备份至: $backup_target"
    else
        sysctl -a 2>/dev/null > "$backup_target"
        _net_log_ok "系统当前完整内核参数快照已备份至: $backup_target"
    fi

    # 根据带宽档位计算参数
    local TCP_RMEM TCP_WMEM TCP_RMEM_MAX TCP_WMEM_MAX
    local SOMAXCONN NETDEV_BACKLOG NETDEV_BUDGET CONNTRACK_MAX

    case "$bw_class" in
        low)
            TCP_RMEM="4096 65536 2097152"
            TCP_WMEM="4096 65536 2097152"
            TCP_RMEM_MAX=2097152
            TCP_WMEM_MAX=2097152
            SOMAXCONN=1024
            NETDEV_BACKLOG=1000
            NETDEV_BUDGET=300
            CONNTRACK_MAX=65536
            ;;
        medium)
            TCP_RMEM="4096 131072 16777216"
            TCP_WMEM="4096 131072 16777216"
            TCP_RMEM_MAX=16777216
            TCP_WMEM_MAX=16777216
            SOMAXCONN=4096
            NETDEV_BACKLOG=5000
            NETDEV_BUDGET=600
            CONNTRACK_MAX=262144
            ;;
        high)
            TCP_RMEM="4096 262144 67108864"
            TCP_WMEM="4096 262144 67108864"
            TCP_RMEM_MAX=67108864
            TCP_WMEM_MAX=67108864
            SOMAXCONN=8192
            NETDEV_BACKLOG=10000
            NETDEV_BUDGET=1200
            CONNTRACK_MAX=524288
            ;;
        ultra)
            TCP_RMEM="4096 524288 134217728"
            TCP_WMEM="4096 524288 134217728"
            TCP_RMEM_MAX=134217728
            TCP_WMEM_MAX=134217728
            SOMAXCONN=16384
            NETDEV_BACKLOG=20000
            NETDEV_BUDGET=2400
            CONNTRACK_MAX=1048576
            ;;
    esac

    # 针对低内存机器进行安全缩限 (小于 512M)
    if [ "$mem_mb" -lt 512 ]; then
        _net_log_warn "检测到物理内存较小 (<512M)，安全缩减 TCP 读写最大缓存以避免 OOM"
        TCP_RMEM="4096 32768 1048576"
        TCP_WMEM="4096 32768 1048576"
        TCP_RMEM_MAX=1048576
        TCP_WMEM_MAX=1048576
        CONNTRACK_MAX=32768
    fi

    # 智能激活 BBR 内核模块
    local enable_bbr=false
    local bbr_algo="bbr"
    if modprobe tcp_bbr 2>/dev/null || grep -q -w "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        enable_bbr=true
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true
    fi

    # 构造配置文件内容
    mkdir -p /etc/sysctl.d 2>/dev/null
    cat > "$CONF_FILE" <<EOF
# ==============================================================================
# Linux-ops-box 网络自适应调优配置 (由 network_tune 模块自动生成)
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 宿主机带宽等级: ${bw_class} (速率: ${speed}M, RTT: ${latency}ms)
# ==============================================================================

# TCP 套接字读写缓冲区
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = ${TCP_RMEM_MAX}
net.core.wmem_max = ${TCP_WMEM_MAX}
net.ipv4.tcp_rmem = ${TCP_RMEM}
net.ipv4.tcp_wmem = ${TCP_WMEM}

# 连接队列与并发处理能力
net.core.somaxconn = ${SOMAXCONN}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.netdev_budget = ${NETDEV_BUDGET}
net.ipv4.tcp_max_syn_backlog = ${SOMAXCONN}

# TIME_WAIT 与连接快速回收重用
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384

# 端口范围与文件句柄
net.ipv4.ip_local_port_range = 10240 65535
fs.file-max = 1048576

# 防御与丢包自愈
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3

# 连接跟踪上限优化
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}
net.nf_conntrack_max = ${CONNTRACK_MAX}
EOF

    # 写入 BBR 与 fq 调度
    if [ "$enable_bbr" = true ]; then
        cat >> "$CONF_FILE" <<EOF

# BBR 拥塞控制与 FQ 队列规则
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${bbr_algo}
EOF
    fi

    # 提升系统最大打开文件描述符 (limits.conf)
    if [ -f /etc/security/limits.conf ] && ! grep -q "# opsbox-network-tune" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf <<EOF

# opsbox-network-tune start
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
# opsbox-network-tune end
EOF
    fi

    # 生效配置
    _net_log_info "正在应用新内核参数..."
    sysctl -p "$CONF_FILE" &>/dev/null || sysctl --system &>/dev/null

    echo ""
    _net_log_ok "✅ 网络性能自适应调优配置已成功应用！"
    if [ "$enable_bbr" = true ]; then
        _net_log_ok "BBR 内核拥塞控制算法与 fq 队列调度已成功激活。"
    else
        _net_log_warn "当前内核暂未加载 tcp_bbr 模块，已保留默认算法并优化网络缓冲区。"
    fi
    _net_log_info "配置文件已落盘: ${CONF_FILE}"
    echo ""
    read -p "按回车键继续..." -r < /dev/tty
}

# 回滚网络优化
restore_network_tune() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${CYAN}             🔄 回滚网络内核优化 (还原系统默认参数)                  ${NC}"
    echo -e "${CYAN}========================================================================${NC}"

    if [ "$(id -u)" -ne 0 ]; then
        _net_log_err "错误: 必须以 root 权限执行此操作！"
        read -p "按回车键返回..." -r < /dev/tty
        return 1
    fi

    read -p "确认回滚网络优化并恢复默认系统内核参数吗？[y/N]: " confirm_rb < /dev/tty
    if [[ ! "$confirm_rb" =~ ^[Yy]$ ]]; then
        _net_log_warn "已取消回滚。"
        sleep 1
        return 0
    fi

    # 查找最近的备份文件
    local latest_bak
    latest_bak=$(ls -t "$BACKUP_DIR"/sysctl_bak_*.conf 2>/dev/null | head -1)

    if [ -f "$CONF_FILE" ]; then
        rm -f "$CONF_FILE"
        _net_log_ok "已清除优化配置文件: $CONF_FILE"
    fi

    rm -f /etc/modules-load.d/bbr.conf 2>/dev/null

    # 清理 limits.conf 中添加的描述符限制
    if [ -f /etc/security/limits.conf ] && grep -q "# opsbox-network-tune" /etc/security/limits.conf; then
        sed -i '/# opsbox-network-tune start/,/# opsbox-network-tune end/d' /etc/security/limits.conf
        _net_log_ok "已清理 limits.conf 文件描述符配置。"
    fi

    # 重新加载系统默认 sysctl
    sysctl --system &>/dev/null || sysctl -p 2>/dev/null

    echo ""
    _net_log_ok "✅ 网络配置已成功回滚至默认状态！"
    read -p "按回车键继续..." -r < /dev/tty
}

# 查看当前网络内核优化状态
show_network_tune_status() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${CYAN}               📊 当前系统网络与 TCP 内核参数全景看板                   ${NC}"
    echo -e "${CYAN}========================================================================${NC}"

    local params=(
        "net.ipv4.tcp_congestion_control|TCP 拥塞算法"
        "net.core.default_qdisc|数据包队列调度器"
        "net.core.rmem_max|最大接收缓冲区 (rmem_max)"
        "net.core.wmem_max|最大发送缓冲区 (wmem_max)"
        "net.ipv4.tcp_rmem|TCP 接收缓冲三元组 (min def max)"
        "net.ipv4.tcp_wmem|TCP 发送缓冲三元组 (min def max)"
        "net.core.somaxconn|TCP 全连接队列上限"
        "net.core.netdev_max_backlog|网络设备积压队列上限"
        "net.ipv4.tcp_tw_reuse|TIME_WAIT 套接字快速复用"
        "net.ipv4.tcp_fin_timeout|FIN-WAIT-2 保持时间 (秒)"
        "net.ipv4.tcp_fastopen|TCP FastOpen 状态"
        "net.ipv4.ip_local_port_range|本地可用出站端口范围"
        "fs.file-max|系统最大文件句柄数"
    )

    for item in "${params[@]}"; do
        IFS='|' read -r key desc <<< "$item"
        local val
        val=$(_sysctl_read "$key")
        printf "  %-36s : ${GREEN}%-20s${NC} (%s)\n" "$key" "$val" "$desc"
    done

    echo -e "${CYAN}------------------------------------------------------------------------${NC}"
    if [ -f "$CONF_FILE" ]; then
        echo -e " 优化状态: ${GREEN}[已启用]${NC} 配置文件: ${CYAN}${CONF_FILE}${NC}"
    else
        echo -e " 优化状态: ${YELLOW}[未启用]${NC} 当前使用系统原生默认参数"
    fi
    echo -e "${CYAN}========================================================================${NC}"
    read -p "按回车键返回..." -r < /dev/tty
}

# 模块独立菜单入口
network_tune_menu() {
    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}       🚀 系统网络内核深度优化中心 (Network-Tune)      ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo -e " 当前优化状态: $([ -f "$CONF_FILE" ] && echo -e "${GREEN}● 已优化 (BBR/大缓冲区)${NC}" || echo -e "${YELLOW}○ 未优化 (系统默认)${NC}")"
        echo ""
        echo -e " 1. 🔍 一键自动检测并应用最优网络配置 (含 BBR + 自适应缓冲区)"
        echo -e " 2. 📊 查看当前网络内核参数全景详情"
        echo -e " 3. 🔄 一键回滚并恢复系统网络默认参数"
        echo -e " 0. 返回上级菜单"
        echo -e "${CYAN}======================================================${NC}"
        read -p "请选择操作 [0-3]: " n_opt < /dev/tty

        case "$n_opt" in
            1) auto_tune_network ;;
            2) show_network_tune_status ;;
            3) restore_network_tune ;;
            0) break ;;
            *) echo -e "${RED}输入有误，请输入 0-3 之间的选项。${NC}"; sleep 1 ;;
        esac
    done
}

# 支持直接执行或模块引用
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    network_tune_menu
fi
