_nginx_print_header() {
    printf "${BLUE}%-50s | %-10s | %-25s | %-40s${NC}\n" "配置文件路径" "端口" "域名 (ServerName)" "后端/根目录"
    printf "${BLUE}%-50s | %-10s | %-25s | %-40s${NC}\n" "--------------------------------------------------" "----------" "-------------------------" "----------------------------------------"
}

# Nginx 单文件解析
_nginx_parse_config() {
    local file=$1
    local listen_port=""
    local server_name=""
    local location_target=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^server[[:space:]]*\{ ]]; then
            listen_port=""; server_name=""; location_target=""
        fi
        regex_listen='listen[[:space:]]+([^;]+);'
        regex_sname='server_name[[:space:]]+([^;]+);'
        regex_proxy='proxy_pass[[:space:]]+([^;]+);'
        regex_root='root[[:space:]]+([^;]+);'
        [[ "$line" =~ $regex_listen ]] && listen_port=$(echo "${BASH_REMATCH[1]}" | cut -d' ' -f1)
        [[ "$line" =~ $regex_sname  ]] && server_name="${BASH_REMATCH[1]}"
        [[ "$line" =~ $regex_proxy  ]] && location_target="Proxy: ${BASH_REMATCH[1]}"
        [[ "$line" =~ $regex_root && -z "$location_target" ]] && location_target="Root: ${BASH_REMATCH[1]}"
        if [[ "$line" == "}" && -n "$listen_port" ]]; then
            local dp="$file"
            [[ ${#dp} -gt 50 ]]            && dp="...${dp: -47}"
            [[ ${#server_name} -gt 25 ]]   && server_name="${server_name:0:22}..."
            [[ ${#location_target} -gt 40 ]] && location_target="${location_target:0:37}..."
            printf "%-50s | %-10s | %-25s | %-40s\n" "$dp" "$listen_port" "$server_name" "$location_target"
        fi
    done < "$file"
}

# Nginx 递归解析 include
_nginx_find_configs() {
    local main_conf=$1
    local base_dir=$(dirname "$main_conf")
    _nginx_parse_config "$main_conf"
    grep -E "include[[:space:]]+([^;]+);" "$main_conf" | \
        sed -E 's/.*include[[:space:]]+([^;]+);.*/\1/' | while read -r inc; do
        [[ ! "$inc" =~ ^/ ]] && inc="$base_dir/$inc"
        for sub in $inc; do
            [ -f "$sub" ] && _nginx_parse_config "$sub"
        done
    done
}

# Nginx 配置查看主函数
nginx_config_view() {
    clear
    echo -e "${YELLOW}正在扫描 Nginx 配置信息...${NC}"
    local nginx_conf=""

    # 优先从 nginx -t 获取主配置路径
    if command -v nginx &>/dev/null; then
        nginx_conf=$(nginx -t 2>&1 | grep -oE "file[[:space:]]+[^[:space:]]+[[:space:]]+syntax" | awk '{print $2}' | head -1)
    fi

    # 备选常用路径
    if [[ -z "$nginx_conf" ]]; then
        for p in "/etc/nginx/nginx.conf" "/usr/local/nginx/conf/nginx.conf" "/opt/nginx/conf/nginx.conf"; do
            [[ -f "$p" ]] && nginx_conf="$p" && break
        done
    fi

    if [[ -z "$nginx_conf" ]]; then
        echo -e "${RED}错误: 未找到 Nginx 配置文件。${NC}"
        echo -e "${YELLOW}提示: 可手动输入配置文件路径进行解析。${NC}"
        read -p "请输入配置文件完整路径 (直接回车跳过): " manual_conf
        if [[ -n "$manual_conf" && -f "$manual_conf" ]]; then
            nginx_conf="$manual_conf"
        else
            echo -e "${RED}未指定有效路径，退出。${NC}"
            read -p "按回车键返回..."
            return
        fi
    fi

    echo -e "${GREEN}找到主配置文件: $nginx_conf${NC}\n"
    _nginx_print_header
    _nginx_find_configs "$nginx_conf"
    echo -e "\n${GREEN}扫描完成。${NC}"
    read -p "按回车键返回..."
}

# Nginx 站点与运行应用监控中心
_display_process_table() {
    local filter=$1
    local title="系统实时资源占用 (Top 15)"
    [[ -n "$filter" ]] && title="Web 应用专项监控 ($filter)"
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${GREEN}●${NC} ${YELLOW}${title}${NC}"
    printf "${BLUE}%-20s | %-7s | %-7s | %-10s | %-8s${NC}\n" "应用名称" "PID" "CPU%" "内存(RSS)" "状态"
    printf "${BLUE}%-20s | %-7s | %-7s | %-10s | %-8s${NC}\n" "--------------------" "-------" "-------" "----------" "--------"

    # 采集 ps 数据并处理
    # 过滤掉 ps, grep, awk 本身及脚本进程
    local filter_cmd="grep -vE 'ps|grep|awk|system_init|nginx_view'"
    [[ -n "$filter" ]] && filter_cmd="grep -iE '$filter'"

    ps -eo comm,pid,pcpu,rss,stat --sort=-pcpu | sed 1d | eval "$filter_cmd" | head -n 15 | while read -r comm pid pcpu rss stat; do
        # 内存转换 (RSS 是 KB)
        local mem_str
        if [ "$rss" -gt 1048576 ]; then
            mem_str=$(echo "scale=1; $rss/1024/1024" | bc)G
        elif [ "$rss" -gt 1024 ]; then
            mem_str=$(echo "scale=1; $rss/1024" | bc)M
        else
            mem_str="${rss}K"
        fi
        
        # 截断超长进程名
        [[ ${#comm} -gt 20 ]] && comm="${comm:0:17}..."
        
        printf "%-20s | %-7s | %-7s | %-10s | %-8s\n" "$comm" "$pid" "$pcpu%" "$mem_str" "$stat"
    done
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

_app_monitor_view() {
    local web_keywords="nginx|php|java|mysql|redis|node|httpd|python|tomcat|go"
    local mode="all"
    while true; do
        clear
        echo -e "${GREEN}======================================================${NC}"
        echo -e "${GREEN}          服务/应用实时资源监控中心 (TUI)             ${NC}"
        echo -e "${GREEN}======================================================${NC}"
        
        if [ "$mode" == "web" ]; then
            _display_process_table "$web_keywords"
            echo -e "\n [C] 切换全量视图 | [R] 手动刷新 | [Q] 返回二级菜单"
        else
            _display_process_table ""
            echo -e "\n [W] 切换Web专项 | [R] 手动刷新 | [Q] 返回二级菜单"
        fi

        read -t 5 -n 1 -s -p "已开启自动刷新 (5s)... " key
        case "$key" in
            [Ww]) mode="web" ;;
            [Cc]) mode="all" ;;
            [Rr]) continue ;;
            [Qq]) return ;;
        esac
    done
}

_display_disk_io() {
    echo -e " ${GREEN}●${NC} ${YELLOW}磁盘实时 I/O 速率 (采样周期: 1s)${NC}"
    printf "${BLUE}%-15s | %-15s | %-15s${NC}\n" "磁盘设备" "读取 (KB/s)" "写入 (KB/s)"
    printf "${BLUE}%-15s | %-15s | %-15s${NC}\n" "---------------" "---------------" "---------------"

    # 获取初始采样数据 (字段3:设备名, 字段6:读取扇区, 字段10:写入扇区)
    local stats1=$(cat /proc/diskstats | awk '$3 !~ /^[0-9]+$/ && $3 !~ /^loop/ && $3 !~ /^ram/ {print $3, $6, $10}')
    sleep 1
    local stats2=$(cat /proc/diskstats | awk '$3 !~ /^[0-9]+$/ && $3 !~ /^loop/ && $3 !~ /^ram/ {print $3, $6, $10}')
    
    # 解析并计算差异
    echo "$stats1" | while read dev s1_read s1_write; do
        local s2_data=$(echo "$stats2" | grep -w "^$dev")
        if [ -n "$s2_data" ]; then
            local s2_read=$(echo "$s2_data" | awk '{print $2}')
            local s2_write=$(echo "$s2_data" | awk '{print $3}')
            
            # 计算每秒 KB (扇区大小通常为 512B)
            local read_kb=$(( (s2_read - s1_read) * 512 / 1024 ))
            local write_kb=$(( (s2_write - s1_write) * 512 / 1024 ))
            
            # 仅显示有活动速率的设备
            if [ "$read_kb" -gt 0 ] || [ "$write_kb" -gt 0 ]; then
                printf "%-15s | %-15s | %-15s\n" "$dev" "${read_kb} KB/s" "${write_kb} KB/s"
            fi
        fi
    done
}

_display_disk_usage() {
    echo -e " ${GREEN}●${NC} ${YELLOW}磁盘分区与挂载点状态 (df -Th)${NC}"
    printf "${BLUE}%-20s | %-8s | %-7s | %-7s | %-5s | %-15s${NC}\n" "文件系统" "类型" "容量" "已用" "使用%" "挂载点"
    printf "${BLUE}%-20s | %-8s | %-7s | %-7s | %-5s | %-15s${NC}\n" "--------------------" "--------" "-------" "-------" "-----" "---------------"
    df -Th | grep -vE "tmpfs|devtmpfs|overlay|shm" | sed 1d | sort -hr -k 5 | while read -r fs type size used avail pct mount; do
        [[ ${#fs} -gt 20 ]] && fs="...${fs: -17}"
        printf "%-20s | %-8s | %-7s | %-7s | %-5s | %-15s\n" "$fs" "$type" "$size" "$used" "$pct" "$mount"
    done
    
    if command -v lsblk &>/dev/null; then
        echo -e "\n ${GREEN}●${NC} ${YELLOW}物理硬盘拓扑 (lsblk)${NC}"
        lsblk -p -o NAME,FSTYPE,SIZE,MOUNTPOINT | grep -v "loop"
    fi
}

_resource_monitoring_view() {
    while true; do
        clear
        echo -e "${GREEN}======================================================${NC}"
        echo -e "${GREEN}          系统资源实时监控中心 (TUI)                  ${NC}"
        echo -e "${GREEN}======================================================${NC}"
        
        # 1. 内存概览
        echo -e " ${GREEN}●${NC} ${YELLOW}内存与交换分区状态${NC}"
        free -h | grep -E "^Mem|^内存|^Swap|^交换"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        # 2. 磁盘 IO (会有 1s 延迟阻塞)
        _display_disk_io
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        # 3. 基础磁盘使用
        DISK_LIVE=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')
        echo -e " ${GREEN}●${NC} 根分区占用: ${CYAN}${DISK_LIVE}${NC}"
        
        echo -e "\n [R] 手动刷新 | [D] 详细磁盘分区 | [Q] 返回二级菜单"
        
        read -t 5 -n 1 -s -p "已开启自动刷新 (5s)... " key
        case "$key" in
            [Dd]) 
                clear
                _display_disk_usage
                read -p "按回车键返回监控中心..."
                ;;
            [Rr]) continue ;;
            [Qq]) return ;;
        esac
    done
}

# Nginx 菜单重构
nginx_menu() {
    while true; do
        clear
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}      系统资源与服务监控中心 (二级菜单)      ${NC}"
        echo -e "${GREEN}==============================================${NC}"
        echo " 1. 查看 Nginx 配置列表与站点映射"
        echo " 2. 查看系统应用资源占用 (Top 15)"
        echo " 3. 筛选 Web 相关服务状态 (Nginx/Java/PHP...)"
        echo " 4. 系统内存与磁盘 I/O 实时监控 (TUI)"
        echo " 5. 详细磁盘分区与挂载状态查看"
        echo " 0. 返回主菜单"
        echo -e "${GREEN}==============================================${NC}"
        read -p "请选择操作 [0-5]: " nginx_choice

        case $nginx_choice in
            1) nginx_config_view ;;
            2) _app_monitor_view ;;
            3) 
                # 直接进入 Web 模式
                local web_keywords="nginx|php|java|mysql|redis|node|httpd|python|tomcat|go"
                clear
                _display_process_table "$web_keywords"
                read -p "按回车键继续..."
                _app_monitor_view 
                ;;
            4) _resource_monitoring_view ;;
            5) 
                clear
                _display_disk_usage
                read -p "按回车键返回..."
                ;;
            0) break ;;
            *) echo -e "${RED}无效输入。${NC}"; sleep 1 ;;
        esac
    done
}

# 一键安装常用软件包
