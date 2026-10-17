#!/usr/bin/env bash
# ==============================================================================
# Linux-ops-box Telegram 运维告警通知中心 (notify.sh)
# 核心特性:
#   1. 专注 Telegram Bot 极速告警推送 (轻量、免国内复杂审核、实时推送)
#   2. 统一发送函数: send_tg_notify(title, content, level)
#   3. 系统资源自动巡检守护: CPU(持续高负载) / 内存(不足) / 磁盘(>85%预警, >95%严重)
#   4. 告警风暴智能抑制 (同类异常 1 小时内不重复轰炸)
#   5. Crontab 定时调度一键部署与移除
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_FILE="/etc/opsbox_notify.conf"
MONITOR_SCRIPT="/usr/local/bin/opsbox_monitor.sh"
CRON_TAG="# OPSBOX_HEALTH_MONITOR"

# 加载配置
_load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    # 默认监控阈值
    CPU_THRESHOLD="${CPU_THRESHOLD:-90}"
    MEM_THRESHOLD="${MEM_THRESHOLD:-90}"
    DISK_THRESHOLD="${DISK_THRESHOLD:-85}"
    CRIT_DISK_THRESHOLD="${CRIT_DISK_THRESHOLD:-95}"
}

# 保存配置
_save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null
    cat > "$CONFIG_FILE" <<EOF
# Linux-ops-box Telegram 告警配置
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

# 监控阈值 (%)
CPU_THRESHOLD="${CPU_THRESHOLD:-90}"
MEM_THRESHOLD="${MEM_THRESHOLD:-90}"
DISK_THRESHOLD="${DISK_THRESHOLD:-85}"
CRIT_DISK_THRESHOLD="${CRIT_DISK_THRESHOLD:-95}"
EOF
    chmod 600 "$CONFIG_FILE" 2>/dev/null
}

# 获取主机身份
_get_host_identity() {
    local ip
    ip=$(ip route show default 2>/dev/null | awk '/default/{print $7}' | head -1)
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "$(hostname) [${ip:-127.0.0.1}]"
}

# 发送 Telegram 消息
# 参数: $1=标题 $2=内容 $3=级别 (INFO|WARN|CRITICAL)
send_tg_notify() {
    _load_config
    local title="${1:-系统通知}"
    local content="${2:-无内容}"
    local level="${3:-INFO}"
    local host_id
    host_id=$(_get_host_identity)
    local cur_time
    cur_time=$(date '+%Y-%m-%d %H:%M:%S')

    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        echo -e "${YELLOW}[!] Telegram 未配置，请先在菜单中配置 Bot Token 与 Chat ID。${NC}"
        return 1
    fi

    # 图标级别修饰
    local icon="ℹ️"
    [ "$level" = "WARN" ] && icon="⚠️"
    [ "$level" = "CRITICAL" ] && icon="🚨"

    local tg_url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
    local message="${icon} *【Linux-ops-box 运维告警】*
*主机:* \`${host_id}\`
*级别:* *${level}*
*事件:* *${title}*
*时间:* \`${cur_time}\`
*详情:*
${content}"

    local res
    res=$(curl -s -m 8 -X POST "$tg_url" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "parse_mode=Markdown" \
        --data-urlencode "text=${message}")

    if echo "$res" | grep -q '"ok":true'; then
        return 0
    else
        echo -e "${RED}[✗] Telegram 发送失败: ${res}${NC}"
        return 1
    fi
}

# 部署独立巡检守护脚本
_deploy_monitor_daemon() {
    _load_config
    cat > "$MONITOR_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Linux-ops-box Telegram 后台健康巡检守护脚本 (Crontab 托管)
CONFIG_FILE="/etc/opsbox_notify.conf"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

CPU_THRESHOLD="${CPU_THRESHOLD:-90}"
MEM_THRESHOLD="${MEM_THRESHOLD:-90}"
DISK_THRESHOLD="${DISK_THRESHOLD:-85}"
CRIT_DISK_THRESHOLD="${CRIT_DISK_THRESHOLD:-95}"

# 告警风暴抑制 (同类异常 1 小时内不重复轰炸)
_can_alert() {
    local tag="$1"
    local lock="/tmp/.opsbox_alert_${tag}"
    local now
    now=$(date +%s)
    if [ -f "$lock" ]; then
        local last
        last=$(cat "$lock" 2>/dev/null || echo 0)
        if [ $((now - last)) -lt 3600 ]; then
            return 1
        fi
    fi
    echo "$now" > "$lock"
    return 0
}

NOTIFY_MOD="/opt/ck_sysinit/system/modules/notify.sh"
[ ! -f "$NOTIFY_MOD" ] && NOTIFY_MOD="$(dirname "$(readlink -f "$0")")/notify.sh"
[ ! -f "$NOTIFY_MOD" ] && NOTIFY_MOD="/usr/local/bin/notify.sh"

_do_send() {
    local title="$1" content="$2" level="$3"
    if [ -f "$NOTIFY_MOD" ]; then
        bash -c "source '$NOTIFY_MOD' && send_tg_notify '$title' '$content' '$level'" &>/dev/null
    fi
}

# 1. 检测 CPU
cpu_idle=$(top -bn1 2>/dev/null | awk -F',' '/Cpu\(s\)/{for(i=1;i<=NF;i++) if($i ~ /id/) {gsub(/[^0-9.]/,"",$i); print $i; exit}}')
if [ -n "$cpu_idle" ]; then
    cpu_usage=$(awk "BEGIN{printf \"%.0f\", 100 - $cpu_idle}")
    if [ "$cpu_usage" -ge "$CPU_THRESHOLD" ] && _can_alert "cpu"; then
        _do_send "CPU 持续高负载预警" "当前 CPU 整体使用率达到 ${cpu_usage}% (阈值 ${CPU_THRESHOLD}%)，请及时排查异常进程。" "WARN"
    fi
fi

# 2. 检测内存
mem_total=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
mem_avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
if [ -n "$mem_total" ] && [ -n "$mem_avail" ] && [ "$mem_total" -gt 0 ]; then
    mem_used_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
    if [ "$mem_used_pct" -ge "$MEM_THRESHOLD" ] && _can_alert "mem"; then
        _do_send "内存资源紧缺预警" "系统物理内存使用率已达 ${mem_used_pct}% (阈值 ${MEM_THRESHOLD}%)，剩余可用内存: $((mem_avail / 1024))MB。" "WARN"
    fi
fi

# 3. 检测磁盘空间
while read -r fs size used avail pct mount; do
    pct_num=${pct%%%}
    if [ "$pct_num" -ge "$CRIT_DISK_THRESHOLD" ]; then
        if _can_alert "disk_crit_${mount//\//_}"; then
            _do_send "磁盘空间濒临满载(紧急)" "挂载点 [${mount}] 使用率已达 ${pct} (紧急阈值 ${CRIT_DISK_THRESHOLD}%)，可用仅 ${avail}，可能导致服务宕机！" "CRITICAL"
        fi
    elif [ "$pct_num" -ge "$DISK_THRESHOLD" ]; then
        if _can_alert "disk_warn_${mount//\//_}"; then
            _do_send "磁盘空间不足预警" "挂载点 [${mount}] 使用率已达 ${pct} (预警阈值 ${DISK_THRESHOLD}%)，可用空间: ${avail}。" "WARN"
        fi
    fi
done < <(df -h -P | awk 'NR>1 && $1 ~ /^\/dev\//{print $0}')
EOF
    chmod +x "$MONITOR_SCRIPT"
}

# 开启 Crontab 巡检
enable_monitor_cron() {
    _deploy_monitor_daemon
    local cron_job="*/5 * * * * $MONITOR_SCRIPT >/dev/null 2>&1 $CRON_TAG"
    (crontab -l 2>/dev/null | grep -v "$CRON_TAG") | crontab -
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
    echo -e "${GREEN}✅ 已成功挂载 Telegram 巡检守护 Crontab (每 5 分钟自动检测一次)。${NC}"
}

# 移除 Crontab 巡检
disable_monitor_cron() {
    (crontab -l 2>/dev/null | grep -v "$CRON_TAG") | crontab -
    echo -e "${GREEN}✅ 已停用并移除后台自动健康巡检任务。${NC}"
}

# 立即执行一次健康扫描
run_inspect_now() {
    echo ""
    echo -e "${CYAN}=== 正在执行系统资源实时健康扫描 ===${NC}"
    local cpu_idle
    cpu_idle=$(top -bn1 2>/dev/null | awk -F',' '/Cpu\(s\)/{for(i=1;i<=NF;i++) if($i ~ /id/) {gsub(/[^0-9.]/,"",$i); print $i; exit}}')
    local cpu_usage="未知"
    [ -n "$cpu_idle" ] && cpu_usage=$(awk "BEGIN{printf \"%.1f%%\", 100 - $cpu_idle}")
    echo -e "  ● CPU 使用率   : ${GREEN}${cpu_usage}${NC} (告警阈值: ${CPU_THRESHOLD}%)"

    local mem_total
    mem_total=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
    local mem_avail
    mem_avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "$mem_total" ] && [ -n "$mem_avail" ]; then
        local mem_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
        echo -e "  ● 内存使用率   : ${GREEN}${mem_pct}%${NC} (已用: $(( (mem_total - mem_avail)/1024 ))M / 总计: $((mem_total/1024))M)"
    fi

    echo -e "  ● 物理磁盘状态 :"
    df -h -P | awk 'NR>1 && $1 ~ /^\/dev\//{printf "     - 挂载点 %-12s: 使用率 %-5s (剩余 %s)\n", $6, $5, $4}'

    echo ""
    if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        echo -e "  ● Telegram 守护 : ${GREEN}● 运行中 (每 5 分钟巡检)${NC}"
    else
        echo -e "  ● Telegram 守护 : ${YELLOW}○ 未开启${NC}"
    fi
    echo ""
}

# 配置 Telegram 参数
_configure_tg() {
    _load_config
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}          ⚙️ 配置 Telegram 告警机器人参数             ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e " 1. Telegram Bot Token : ${GREEN}${TG_BOT_TOKEN:-未配置}${NC}"
    echo -e " 2. Telegram Chat ID   : ${GREEN}${TG_CHAT_ID:-未配置}${NC}"
    echo -e " 3. 监控阈值: CPU=${CPU_THRESHOLD}% | 内存=${MEM_THRESHOLD}% | 磁盘=${DISK_THRESHOLD}%"
    echo -e " 0. 返回"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${YELLOW}提示: Chat ID 可通过在 TG 中向 @userinfobot 发送消息获取。${NC}"
    read -p "请选择修改项 [0-3]: " tg_opt < /dev/tty

    case "$tg_opt" in
        1)
            read -p "请输入 Telegram Bot Token: " TG_BOT_TOKEN < /dev/tty
            _save_config
            ;;
        2)
            read -p "请输入 Telegram Chat ID: " TG_CHAT_ID < /dev/tty
            _save_config
            ;;
        3)
            read -p "CPU 告警阈值 (当前 ${CPU_THRESHOLD}%): " new_cpu < /dev/tty
            [ -n "$new_cpu" ] && CPU_THRESHOLD="$new_cpu"
            read -p "内存告警阈值 (当前 ${MEM_THRESHOLD}%): " new_mem < /dev/tty
            [ -n "$new_mem" ] && MEM_THRESHOLD="$new_mem"
            read -p "磁盘预警阈值 (当前 ${DISK_THRESHOLD}%): " new_disk < /dev/tty
            [ -n "$new_disk" ] && DISK_THRESHOLD="$new_disk"
            _save_config
            ;;
        0) return 0 ;;
    esac
}

# Telegram 告警模块菜单
notify_menu() {
    _load_config
    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}       📢 Telegram 运维告警通知中心 (Alert-Notify)      ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo -e " 当前主机: ${GREEN}$(_get_host_identity)${NC}"
        echo -e " 绑定状态: $([ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] && echo -e "${GREEN}● 已绑定 Bot${NC}" || echo -e "${YELLOW}○ 未配置 Token/ChatID${NC}")"
        echo -e " 巡检守护: $(crontab -l 2>/dev/null | grep -q "$CRON_TAG" && echo -e "${GREEN}● 运行中 (每5分钟巡检)${NC}" || echo -e "${YELLOW}○ 未开启${NC}")"
        echo ""
        echo -e " 1. ⚙️ 配置 Telegram 参数 (Bot Token / Chat ID / 阈值)"
        echo -e " 2. 📨 发送一次 Telegram 测试通知 (验证连通性)"
        echo -e " 3. 🛡 开启后台巡检守护 (Crontab 每5分钟自动监控)"
        echo -e " 4. ⏹ 停止后台巡检守护"
        echo -e " 5. 🔍 立即执行一次系统健康自检"
        echo -e " 0. 返回上级菜单"
        echo -e "${CYAN}======================================================${NC}"
        read -p "请选择操作 [0-5]: " tg_choice < /dev/tty

        case "$tg_choice" in
            1)
                _configure_tg
                ;;
            2)
                echo -e "${YELLOW}正在向 Telegram 发送测试告警...${NC}"
                if send_tg_notify "连通性测试" "恭喜！这是一条来自 Linux-ops-box 的测试通知，说明您的 Telegram Bot 与 Chat ID 配置正确、网络通畅。" "INFO"; then
                    echo -e "${GREEN}✅ 测试消息发送成功，请前往 Telegram 查看。${NC}"
                fi
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            3)
                if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
                    echo -e "${RED}错误: 请先配置 Bot Token 与 Chat ID 后再开启守护！${NC}"
                else
                    enable_monitor_cron
                fi
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            4)
                disable_monitor_cron
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            5)
                run_inspect_now
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}输入有误，请输入 0-5 之间的选项。${NC}"
                sleep 1
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    notify_menu
fi
