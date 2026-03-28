#!/bin/bash

# =================================================================
# 模块名称: firewall_mgmt.sh
# 描述: 多发行版防火墙管理模块 (UFW / FirewallD)
# 支持: 状态查看、开关控制、端口规则增删
# =================================================================

# 探测防火墙驱动
_get_fw_driver() {
    if command -v ufw &>/dev/null; then
        echo "ufw"
    elif command -v firewall-cmd &>/dev/null; then
        echo "firewalld"
    else
        echo "unknown"
    fi
}

# 1. 显示状态与规则
fw_show_status() {
    local driver=$(_get_fw_driver)
    clear
    echo -e "${BLUE}================ 当前防火墙状态 ================${NC}"

    case "$driver" in
        ufw)
            local status_raw=$(ufw status verbose 2>/dev/null)
            if echo "$status_raw" | grep -q "Status: active"; then
                echo -e "驱动类型: ${CYAN}UFW${NC}  状态: ${GREEN}[已启用]${NC}"
                echo -e "规则列表:"
                ufw status numbered
            else
                echo -e "驱动类型: ${CYAN}UFW${NC}  状态: ${RED}[已停用]${NC}"
            fi
            ;;
        firewalld)
            if systemctl is-active --quiet firewalld 2>/dev/null; then
                echo -e "驱动类型: ${CYAN}FirewallD${NC}  状态: ${GREEN}[已启用]${NC}"
                echo -e "规则列表 (Public Zone):"
                firewall-cmd --list-all 2>/dev/null | grep -E "services|ports|protocols|masquerade"
            else
                echo -e "驱动类型: ${CYAN}FirewallD${NC}  状态: ${RED}[已停用]${NC}"
            fi
            ;;
        *)
            echo -e "${RED}错误: 未能在系统中探测到支持的防火墙驱动 (UFW 或 FirewallD)。${NC}"
            ;;
    esac
    echo -e "${BLUE}==============================================${NC}"
    echo ""
    read -p "按回车键返回..." < /dev/tty
}

# 2. 启停管理
fw_toggle_status() {
    local driver=$(_get_fw_driver)
    local current_state="inactive"
    
    # 状态判定
    if [ "$driver" == "ufw" ]; then
        ufw status | grep -q "active" && current_state="active"
    elif [ "$driver" == "firewalld" ]; then
        systemctl is-active --quiet firewalld && current_state="active"
    fi

    clear
    echo -e "${YELLOW}================ 防火墙启停控制 ================${NC}"
    if [ "$current_state" == "active" ]; then
        echo -e "当前状态: ${GREEN}运行中${NC}"
        read -p "是否确认停用防火墙并禁止自启动? (y/N): " op < /dev/tty
        if [[ "$op" =~ ^[Yy]$ ]]; then
            _log_info "正在关闭防火墙..."
            if [ "$driver" == "ufw" ]; then
                ufw disable
            else
                systemctl stop firewalld
                systemctl disable firewalld
            fi
            _log_info "防火墙已成功关闭。"
        fi
    else
        echo -e "当前状态: ${RED}已停止${NC}"
        echo -e "${YELLOW}[重要提示]${NC} 开启前将自动检测并放行当前 SSH 端口以防失联。"
        read -p "是否确认开启防火墙并设为自启动? (y/N): " op < /dev/tty
        if [[ "$op" =~ ^[Yy]$ ]]; then
            # 自动探测并加固 SSH 安全
            local current_ssh_port=$(grep -E "^Port|^#Port" /etc/ssh/sshd_config | grep -v "#" | awk '{print $2}')
            current_ssh_port=${current_ssh_port:-22}
            
            _log_info "正在预放行 SSH 端口: $current_ssh_port"
            if [ "$driver" == "ufw" ]; then
                ufw allow "$current_ssh_port/tcp" &>/dev/null
                echo "y" | ufw enable
            else
                systemctl start firewalld
                systemctl enable firewalld
                firewall-cmd --permanent --add-port="$current_ssh_port/tcp" &>/dev/null
                firewall-cmd --reload &>/dev/null
            fi
            _log_info "防火墙已启动并配置完成。"
        fi
    fi
    read -p "操作完成，按回车键返回..." < /dev/tty
}

# 3. 端口规则管理
fw_port_manager() {
    local driver=$(_get_fw_driver)
    [ "$driver" == "unknown" ] && return

    while true; do
        clear
        echo -e "${BLUE}================ 端口规则管理 ================${NC}"
        echo " 1. 添加开放端口 (Allow)"
        echo " 2. 关闭/删除端口 (Deny/Remove)"
        echo " 0. 返回上级菜单"
        echo -e "${BLUE}==============================================${NC}"
        read -p "请选择操作 [0-2]: " op < /dev/tty

        case "$op" in
            1)
                read -p "输入端口号 (如 8080): " port < /dev/tty
                read -p "输入协议 (tcp/udp, 默认 tcp): " proto < /dev/tty
                proto=${proto:-tcp}
                if [ "$driver" == "ufw" ]; then
                    ufw allow "$port/$proto"
                else
                    firewall-cmd --permanent --add-port="$port/$proto"
                    firewall-cmd --reload
                fi
                _log_info "已成功开放端口: $port ($proto)"
                sleep 1
                ;;
            2)
                read -p "输入要关闭的端口号: " port < /dev/tty
                read -p "输入协议 (tcp/udp, 默认 tcp): " proto < /dev/tty
                proto=${proto:-tcp}
                if [ "$driver" == "ufw" ]; then
                    ufw delete allow "$port/$proto"
                else
                    firewall-cmd --permanent --remove-port="$port/$proto"
                    firewall-cmd --reload
                fi
                _log_info "已成功关闭端口规则: $port ($proto)"
                sleep 1
                ;;
            0) break ;;
        esac
    done
}

# 防火墙管理子菜单入口
firewall_menu() {
    local driver=$(_get_fw_driver)
    if [ "$driver" == "unknown" ]; then
        _log_err "当前发行版不支持或未安装常用防火墙管理工具 (UFW/FirewallD)。"
        read -p "按回车键返回主菜单..." < /dev/tty
        return
    fi

    while true; do
        clear
        echo -e "${CYAN}================ 防火墙管理中心 ================${NC}"
        echo -e " 探测到管理工具: ${YELLOW}$driver${NC}"
        echo "------------------------------------------------"
        echo " 1. 查看防火墙实时状态与规则列表"
        echo " 2. 切换防火墙开关 (启用 / 禁用)"
        echo " 3. 快速配置端口开放/关闭规则"
        echo " 0. 返回系统初始化主菜单"
        echo -e "${CYAN}================================================${NC}"
        read -p "请输入选项 [0-3]: " fw_choice < /dev/tty

        case "$fw_choice" in
            1) fw_show_status ;;
            2) fw_toggle_status ;;
            3) fw_port_manager ;;
            0) break ;;
            *) echo -e "${RED}输入无效。${NC}"; sleep 1 ;;
        esac
    done
}
