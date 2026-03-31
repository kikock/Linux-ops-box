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

# Nginx 菜单重构
nginx_menu() {
    while true; do
        clear
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}      服务 / 站点实时监控中心 (二级菜单)      ${NC}"
        echo -e "${GREEN}==============================================${NC}"
        echo " 1. 查看 Nginx 配置列表与站点映射"
        echo " 2. 查看系统应用资源占用 (Top 15)"
        echo " 3. 筛选 Web 相关服务状态 (Nginx/Java/PHP...)"
        echo " 0. 返回主菜单"
        echo -e "${GREEN}==============================================${NC}"
        read -p "请选择操作 [0-3]: " nginx_choice

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
            0) break ;;
            *) echo -e "${RED}无效输入。${NC}"; sleep 1 ;;
        esac
    done
}

# 一键安装常用软件包
