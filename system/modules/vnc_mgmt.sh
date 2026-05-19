#!/bin/bash
# =================================================================
# 模块名称: vnc_mgmt.sh
# 描述: VNC 服务管理中心模块 (Linux-ops-box 专用)
# 功能: 提供 TUI 图形化菜单，支持 VNC 一键配置、启停、删除及自启维护
# =================================================================

# 1. 扫描当前系统配置的 VNC 实例
_vnc_scan_instances() {
    instances=()
    # 扫描 modern 架构模式下的配置
    if [ -f /etc/tigervnc/vncserver.users ]; then
        while read -r line || [[ -n "$line" ]]; do
            # 去除首尾空格
            line=$(echo "$line" | xargs)
            [[ "$line" =~ ^# ]] && continue
            [[ -z "$line" ]] && continue
            if [[ "$line" =~ ^:([0-9]+)=(.*) ]]; then
                instances+=("${BASH_REMATCH[1]}:${BASH_REMATCH[2]}")
            fi
        done < /etc/tigervnc/vncserver.users
    fi

    # 扫描 legacy systemd 配置文件
    for f in /etc/systemd/system/vncserver@:*.service; do
        [ -f "$f" ] || continue
        local filename=$(basename "$f")
        if [[ "$filename" =~ ^vncserver@:([0-9]+)\.service$ ]]; then
            local dnum="${BASH_REMATCH[1]}"
            local found=false
            for inst in "${instances[@]}"; do
                if [[ "$inst" =~ ^${dnum}: ]]; then
                    found=true
                    break
                fi
            done
            if [ "$found" = false ]; then
                local user=$(grep -E "^User=" "$f" | cut -d= -f2 | xargs)
                user=${user:-未知}
                instances+=("${dnum}:${user}")
            fi
        fi
    done
}

# 2. 一键配置安装实例
vnc_install_instance() {
    local script_path="$BASE_DIR/install_vnc.sh"
    if [ ! -f "$script_path" ]; then
        script_path="/opt/ck_sysinit/install_vnc.sh"
    fi
    
    if [ -f "$script_path" ]; then
        bash "$script_path" < /dev/tty
    else
        _log_err "未找到 VNC 独立安装脚本，正在尝试一键云端拉取..."
        # 兼容云端拉取 (根据 repository 自适应)
        local GH_MIRROR="https://github.com"
        if command -v curl &>/dev/null; then
            if ! curl -Is -m 3 "https://github.com" | head -1 | grep -q '200\|301\|302'; then
                GH_MIRROR="https://ghproxy.net/https://github.com"
            fi
            curl -fsSL -o /tmp/install_vnc.sh "${GH_MIRROR}/kikock/Linux-ops-box/raw/main/install_vnc.sh"
        else
            _log_err "缺少 curl 工具，无法自动云端安装。"
            read -p "按回车键返回..." < /dev/tty
            return 1
        fi
        
        if [ -f /tmp/install_vnc.sh ]; then
            chmod +x /tmp/install_vnc.sh
            bash /tmp/install_vnc.sh < /dev/tty
            rm -f /tmp/install_vnc.sh
        else
            _log_err "拉取 VNC 脚本失败，请手动检查网络。"
        fi
    fi
    read -p "配置流程已结束，按回车键返回主菜单..." < /dev/tty
}

# 3. 运行状态面板
vnc_show_running_panel() {
    clear
    echo -e "${CYAN}================ 当前 VNC 服务监控面板 ================${NC}"
    
    _vnc_scan_instances
    
    if [ ${#instances[@]} -eq 0 ]; then
        echo -e " ${YELLOW}●${NC} 暂无任何配置完备的 VNC 实例。"
    else
        local header_line1=$(printf "${BLUE}%-8s | %-12s | %-12s | %-15s | %-10s${NC}\n" "桌面号" "监听端口" "服务用户" "自启挂载状态" "当前运行态")
        local header_line2=$(printf "${BLUE}%-8s | %-12s | %-12s | %-15s | %-10s${NC}\n" "--------" "------------" "------------" "---------------" "----------")
        echo -e "$header_line1"
        echo -e "$header_line2"
        for inst in "${instances[@]}"; do
            local dnum=$(echo "$inst" | cut -d: -f1)
            local user=$(echo "$inst" | cut -d: -f2)
            local port=$((5900 + dnum))
            
            # 自启状态
            local autostart="未启用"
            local autostart_color="${RED}"
            if systemctl is-enabled --quiet "vncserver@:${dnum}.service" 2>/dev/null; then
                autostart="已启用"
                autostart_color="${GREEN}"
            fi
            
            # 运行状态
            local runstate="已停止"
            local runstate_color="${RED}"
            if systemctl is-active --quiet "vncserver@:${dnum}.service" 2>/dev/null; then
                runstate="活动中"
                runstate_color="${GREEN}"
            fi
            
            local line_str=$(printf "%-8s | %-12s | %-12s | ${autostart_color}%-15s${NC} | ${runstate_color}%-10s${NC}\n" ":$dnum" "$port" "$user" "$autostart" "$runstate")
            echo -e "$line_str"
        done
    fi
    
    echo -e "\n${YELLOW}----- 底层网络端口占用状态 -----${NC}"
    if command -v ss &>/dev/null; then
        ss -tlnp | grep -E "vnc|Xvnc" || echo " 暂无活动 VNC 进程监听 TCP 端口。"
    else
        netstat -tlnp | grep -E "vnc|Xvnc" || echo " 暂无活动 VNC 进程监听 TCP 端口。"
    fi
    echo -e "${CYAN}======================================================${NC}"
    read -p "按回车键返回..." < /dev/tty
}

# 3.5. 详细状态与日志审计
vnc_inspect_status() {
    while true; do
        clear
        echo -e "${CYAN}================ VNC 实例详细状态与日志审计 ================${NC}"
        
        _vnc_scan_instances
        
        if [ ${#instances[@]} -eq 0 ]; then
            echo -e "${YELLOW}当前系统中无任何已配置的 VNC 实例。${NC}"
            read -p "按回车键返回..." < /dev/tty
            return
        fi

        echo "当前已配置的 VNC 实例列表:"
        for i in "${!instances[@]}"; do
            local dnum=$(echo "${instances[$i]}" | cut -d: -f1)
            local user=$(echo "${instances[$i]}" | cut -d: -f2)
            local status="${RED}已停止${NC}"
            systemctl is-active --quiet "vncserver@:${dnum}.service" && status="${GREEN}运行中${NC}"
            echo -e "  [$((i+1))] 桌面 :${dnum} (端口 $((5900+dnum))) | 用户: ${CYAN}${user}${NC} | 状态: ${status}"
        done
        echo "  [0] 返回上级菜单"
        echo -e "------------------------------------------------------------"
        read -p "请输入要审计的实例序号: " idx < /dev/tty
        
        if [[ "$idx" -eq 0 ]]; then
            break
        elif [[ "$idx" -gt 0 && "$idx" -le "${#instances[@]}" ]]; then
            local dnum=$(echo "${instances[$((idx-1))]}" | cut -d: -f1)
            local user=$(echo "${instances[$((idx-1))]}" | cut -d: -f2)
            local port=$((5900 + dnum))
            
            clear
            echo -e "${CYAN}================ 实例详细状态监控 (: ${dnum}) ================${NC}"
            echo -e "1. 关联系统用户: ${YELLOW}${user}${NC}"
            echo -e "2. 服务自启配置: $(systemctl is-enabled --quiet "vncserver@:${dnum}.service" 2>/dev/null && echo -e "${GREEN}已启用自启${NC}" || echo -e "${RED}未启用自启${NC}")"
            
            echo -e "\n3. Systemd 详细活动状态:"
            echo -e "------------------------------------------------------------"
            systemctl status "vncserver@:${dnum}.service" &>/dev/null
            local status_exit=$?
            if [ "$status_exit" -eq 4 ]; then
                echo -e "${RED}无法拉取 Systemd 状态或服务未配置。${NC}"
            else
                systemctl status "vncserver@:${dnum}.service" --no-pager -n 10
            fi
            echo -e "------------------------------------------------------------"
            
            echo -e "\n4. 活动连接会话审计:"
            echo -e "------------------------------------------------------------"
            local active_conns=""
            if command -v ss &>/dev/null; then
                active_conns=$(ss -tn | grep -E "ESTAB.*:${port}" | awk '{print $5}')
            else
                active_conns=$(netstat -an | grep "ESTABLISHED" | grep ":${port}" | awk '{print $5}')
            fi
            
            if [ -n "$active_conns" ]; then
                echo -e "${GREEN}● 检测到当前有活动远程连接 !${NC}"
                echo "$active_conns" | while read -r conn; do
                    echo -e "   -> 远程客户端 IP: ${YELLOW}${conn}${NC}"
                done
            else
                echo -e "   暂无活动的外部网络客户端连接 (监听端口 ${port} 空闲)"
            fi
            echo -e "------------------------------------------------------------"
            
            echo -e "\n5. 历史运行日志回溯 (末尾 15 行):"
            echo -e "------------------------------------------------------------"
            local user_home=$(eval echo "~${user}")
            local log_file=""
            if [ -d "$user_home/.vnc" ]; then
                log_file=$(ls -t "$user_home"/.vnc/*.log 2>/dev/null | head -1)
            fi
            
            if [ -n "$log_file" ] && [ -f "$log_file" ]; then
                echo -e "日志路径: ${BLUE}${log_file}${NC} (大小: $(du -sh "$log_file" | awk '{print $1}'))"
                echo -e "--- 日志正文 ---"
                tail -n 15 "$log_file"
                echo -e "----------------"
            else
                echo -e "${YELLOW}未发现该用户的活动 VNC 运行日志 (.log) 文件。${NC}"
            fi
            echo -e "------------------------------------------------------------"
            read -p "按回车键返回审计列表..." < /dev/tty
        else
            echo -e "${RED}输入无效，请重新选择。${NC}"
            sleep 1
        fi
    done
}

# 4. 启停管理控制台
vnc_action_controller() {
    while true; do
        clear
        echo -e "${CYAN}================ 启停/重启 VNC 实例 ================${NC}"
        
        _vnc_scan_instances
        
        if [ ${#instances[@]} -eq 0 ]; then
            echo -e "${YELLOW}当前系统中无任何已注册的 VNC 实例。${NC}"
            read -p "按回车键返回..." < /dev/tty
            return
        fi

        echo "当前 VNC 实例列表:"
        for i in "${!instances[@]}"; do
            local dnum=$(echo "${instances[$i]}" | cut -d: -f1)
            local user=$(echo "${instances[$i]}" | cut -d: -f2)
            local status="${RED}已停止${NC}"
            systemctl is-active --quiet "vncserver@:${dnum}.service" && status="${GREEN}运行中${NC}"
            echo -e "  [$((i+1))] 桌面 :${dnum} (端口 $((5900+dnum))) | 用户: ${CYAN}${user}${NC} | 状态: ${status}"
        done
        echo "  [0] 返回上级菜单"
        echo -e "------------------------------------------------------"
        read -p "请输入要操作的实例序号: " idx < /dev/tty
        
        if [[ "$idx" -eq 0 ]]; then
            break
        elif [[ "$idx" -gt 0 && "$idx" -le "${#instances[@]}" ]]; then
            local dnum=$(echo "${instances[$((idx-1))]}" | cut -d: -f1)
            
            echo -e "\n选择操作类型:"
            echo -e "  1. ${GREEN}启动实例${NC} (Start)"
            echo -e "  2. ${RED}停止实例${NC} (Stop)"
            echo -e "  3. ${YELLOW}重启实例${NC} (Restart)"
            read -p "请选择操作 [1-3]: " op_type < /dev/tty
            
            case "$op_type" in
                1)
                    _log_info "正在为您唤醒 vncserver@:${dnum}.service ..."
                    # 清除 X 锁，防黑屏/无法启动
                    rm -f /tmp/.X${dnum}-lock 2>/dev/null
                    rm -f /tmp/.X11-unix/X${dnum} 2>/dev/null
                    systemctl start "vncserver@:${dnum}.service"
                    ;;
                2)
                    _log_info "正在停止 vncserver@:${dnum}.service ..."
                    systemctl stop "vncserver@:${dnum}.service"
                    ;;
                3)
                    _log_info "正在为您重置 vncserver@:${dnum}.service ..."
                    rm -f /tmp/.X${dnum}-lock 2>/dev/null
                    rm -f /tmp/.X11-unix/X${dnum} 2>/dev/null
                    systemctl restart "vncserver@:${dnum}.service"
                    ;;
                *)
                    echo -e "${RED}选项无效。${NC}"
                    sleep 1
                    continue
                    ;;
            esac
            _log_info "操作执行完毕。"
            sleep 1.5
        else
            echo -e "${RED}输入无效，请重新选择。${NC}"
            sleep 1
        fi
    done
}

# 5. 删除已存在的 VNC 服务实例与清理锁文件
vnc_remove_instance() {
    while true; do
        clear
        echo -e "${RED}================ 彻底卸载与注销 VNC 实例 ================${NC}"
        
        _vnc_scan_instances
        
        if [ ${#instances[@]} -eq 0 ]; then
            echo -e "${YELLOW}当前系统中无任何已注册的 VNC 实例。${NC}"
            read -p "按回车键返回..." < /dev/tty
            return
        fi

        echo "可注销的 VNC 实例列表:"
        for i in "${!instances[@]}"; do
            local dnum=$(echo "${instances[$i]}" | cut -d: -f1)
            local user=$(echo "${instances[$i]}" | cut -d: -f2)
            echo -e "  [$((i+1))] 注销桌面 :${dnum} (端口 $((5900+dnum))) | 用户: ${CYAN}${user}${NC}"
        done
        echo "  [0] 返回上级菜单"
        echo -e "${RED}---------------------------------------------------------${NC}"
        read -p "请输入要注销的实例序号: " idx < /dev/tty
        
        if [[ "$idx" -eq 0 ]]; then
            break
        elif [[ "$idx" -gt 0 && "$idx" -le "${#instances[@]}" ]]; then
            local dnum=$(echo "${instances[$((idx-1))]}" | cut -d: -f1)
            local user=$(echo "${instances[$((idx-1))]}" | cut -d: -f2)
            
            echo -e "${YELLOW}警告: 该操作将停止桌面 :${dnum} 服务的后台，删除 systemd 托管，并注销自启！${NC}"
            read -p "是否确认删除该实例? [y/N]: " confirm < /dev/tty
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                _log_warn "正在彻底移除桌面 :${dnum} 的 VNC 实例链条..."
                
                # 1. 关停并禁用服务
                systemctl disable --now "vncserver@:${dnum}.service" &>/dev/null
                
                # 2. 清理 Systemd Unit 文件
                rm -f "/etc/systemd/system/vncserver@:${dnum}.service" 2>/dev/null
                
                # 3. 清理 vncserver.users 映射关系
                if [ -f /etc/tigervnc/vncserver.users ]; then
                    sed -i "/^:${dnum}=/d" /etc/tigervnc/vncserver.users
                fi
                
                # 4. 清理 X 缓存与锁文件，防止残留导致后续创建同号桌面黑屏
                rm -f /tmp/.X${dnum}-lock 2>/dev/null
                rm -f /tmp/.X11-unix/X${dnum} 2>/dev/null
                
                # 5. 刷新守护进程
                systemctl daemon-reload
                
                _log_info "桌面 :${dnum} VNC 实例注销成功。"
                sleep 1.5
            else
                _log_info "操作取消。"
                sleep 1
            fi
        else
            echo -e "${RED}输入无效，请重新选择。${NC}"
            sleep 1
        fi
    done
}

# 6. VNC 主入口
vnc_management_center() {
    while true; do
        clear
        echo -e "${CYAN}================ VNC 服务管理中心 ================${NC}"
        echo " 1. 查看当前 VNC 实例运行态与端口监听"
        echo " 2. 一键新建并部署 VNC 服务实例 (开机自启)"
        echo " 3. 查看指定 VNC 实例详细状态与日志审计"
        echo " 4. 管理已有 VNC 实例 (启动/停止/重启)"
        echo " 5. 彻底注销并清除已注册的 VNC 实例"
        echo " 0. 返回主菜单"
        echo -e "${CYAN}==================================================${NC}"
        read -p "请输入操作选项 [0-5]: " vnc_choice < /dev/tty
        
        case "$vnc_choice" in
            1) vnc_show_running_panel ;;
            2) vnc_install_instance ;;
            3) vnc_inspect_status ;;
            4) vnc_action_controller ;;
            5) vnc_remove_instance ;;
            0) break ;;
            *) echo -e "${RED}输入无效，请重新选择。${NC}"; sleep 1 ;;
        esac
    done
}
