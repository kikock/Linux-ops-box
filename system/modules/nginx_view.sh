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

# Nginx 管理二级菜单
nginx_menu() {
    while true; do
        clear
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}          Nginx 配置管理 (二级菜单)           ${NC}"
        echo -e "${GREEN}==============================================${NC}"
        echo " 1. 查看 Nginx 配置列表 (自动扫描)"
        echo " 0. 返回主菜单"
        echo -e "${GREEN}==============================================${NC}"
        read -p "请选择操作 [0-1]: " nginx_choice

        case $nginx_choice in
            1) nginx_config_view ;;
            0) break ;;
            *) echo -e "${RED}无效输入。${NC}"; sleep 1 ;;
        esac
    done
}

# 一键安装常用软件包
