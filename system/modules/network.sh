#!/usr/bin/env bash
# ==============================================================================
# Linux-ops-box 网络 IP 与网卡诊断中心 (network.sh)
# 支持独立单兵运行与主程序微内核懒加载
# ==============================================================================

# 底座依赖自探测
if ! declare -f _log_info &>/dev/null; then
    _COMMON_PATHS=(
        "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
        "/opt/ck_sysinit/system/modules/common.sh"
        "/opt/ck_sysinit/modules/common.sh"
    )
    for _c in "${_COMMON_PATHS[@]}"; do
        if [ -f "$_c" ]; then source "$_c"; break; fi
    done
fi

GREEN="${GREEN:-\033[0;32m}"
BLUE="${BLUE:-\033[0;34m}"
RED="${RED:-\033[0;31m}"
YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"
NC="${NC:-\033[0m}"

show_network_info() {
    clear
    echo -e "${BLUE}================ 当前网络配置信息 ================${NC}"

    echo -e "\n${YELLOW}[ 网卡列表及 IP 地址 ]${NC}"
    ip -br addr show | while read -r line; do
        echo "  $line"
    done

    echo -e "\n${YELLOW}[ 默认路由/网关 ]${NC}"
    DEFAULT_GW=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
    if [ -n "$DEFAULT_GW" ]; then
        echo "  默认网关: $DEFAULT_GW"
    else
        echo "  未检测到默认网关"
    fi

    echo -e "\n${YELLOW}[ DNS 配置 ]${NC}"
    if [ -f /etc/resolv.conf ]; then
        grep -E "^nameserver" /etc/resolv.conf | while read -r line; do
            echo "  $line"
        done
    else
        echo "  未找到 /etc/resolv.conf"
    fi

    echo -e "\n${YELLOW}[ 底层网络引擎探测配置 ]${NC}"
    if command -v netplan &>/dev/null; then
        echo -e "  [ 检测到 Netplan 功能引擎 ]"
        NETPLAN_FILES=$(ls /etc/netplan/*.yaml 2>/dev/null)
        if [ -n "$NETPLAN_FILES" ]; then
            for f in $NETPLAN_FILES; do
                echo -e "  ${GREEN}--- $f ---${NC}"
                cat "$f" | sed 's/^/    /'
            done
        fi
    elif command -v nmcli &>/dev/null; then
        echo -e "  [ 检测到 NetworkManager(nmcli) 引擎 ]"
        nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | while IFS=: read -r nm_name nm_dev; do
            echo -e "  已激活连接: ${GREEN}$nm_name${NC} (绑定网卡: $nm_dev)"
        done
    elif [ -f /etc/network/interfaces ]; then
        echo -e "  [ 检测到传统 ifupdown (/etc/network/interfaces) 引擎 ]"
        echo -e "  ${GREEN}--- 接口文件定义部分 ---${NC}"
        grep -E "^(auto|iface|address|netmask|gateway|dns-)" /etc/network/interfaces | sed 's/^/    /'
    else
        echo "  未检测到已知的网络管理框架 (可能是无配置文件的 docker/lxc 容器等)"
    fi

    echo -e "${BLUE}==================================================${NC}"
    echo ""
    read -p "按回车键返回..."
}

# ==============================================================
# 网络引擎动态执行核心层 (Netplan / NetworkManager / ifupdown)
# ==============================================================

# Netplan 静态 IP 应用逻辑
_apply_netplan_static() {
    local net_nic="$1" net_ip="$2" net_gw="$3" net_dns="$4"
    local netplan_file="/etc/netplan/01-static-${net_nic}.yaml"
    for f in /etc/netplan/*.yaml; do [ -f "$f" ] && cp "$f" "${f}.bak.$(date +%F_%H%M%S)"; done
    cat > "$netplan_file" <<EOF
# 由 system_init.sh 自动生成 - $(date +"%Y-%m-%d %H:%M:%S")
network:
  version: 2
  renderer: networkd
  ethernets:
    ${net_nic}:
      dhcp4: false
      addresses:
        - ${net_ip}
      routes:
        - to: default
          via: ${net_gw}
      nameservers:
        addresses:
EOF
    IFS=',' read -ra DNS_ARR <<< "$net_dns"
    for d in "${DNS_ARR[@]}"; do echo "          - $(echo "$d" | xargs)" >> "$netplan_file"; done
    chmod 600 "$netplan_file"
    echo -e "${YELLOW}正在应用 Netplan 配置...${NC}"
    netplan apply 2>&1
    [ $? -eq 0 ] && echo -e "${GREEN}成功: 静态 IP 已配置并生效。${NC}" || echo -e "${RED}警告: netplan apply 出现异常。${NC}"
}

# nmcli 静态 IP 应用逻辑
_apply_nmcli_static() {
    local net_nic="$1" net_ip="$2" net_gw="$3" net_dns="$4"
    local conn_name=$(nmcli -t -f NAME,DEVICE connection show | grep ":${net_nic}" | head -n 1 | cut -d: -f1)
    if [ -z "$conn_name" ]; then
        conn_name="${net_nic}_conn"
        nmcli connection add type ethernet ifname "$net_nic" con-name "$conn_name" &>/dev/null
    fi
    nmcli connection modify "$conn_name" ipv4.addresses "$net_ip"
    nmcli connection modify "$conn_name" ipv4.gateway "$net_gw"
    local dns_list=""; IFS=',' read -ra DNS_ARR <<< "$net_dns"
    for d in "${DNS_ARR[@]}"; do dns_list="$dns_list $(echo "$d" | xargs)"; done
    [ -n "$dns_list" ] && nmcli connection modify "$conn_name" ipv4.dns "$dns_list"
    nmcli connection modify "$conn_name" ipv4.method manual
    nmcli connection up "$conn_name" 2>&1
    [ $? -eq 0 ] && echo -e "${GREEN}成功: NetworkManager 静态 IP 已配置并生效。${NC}" || echo -e "${RED}警告: nmcli 应用配置发现异常。${NC}"
}

# ifupdown 静态 IP 应用逻辑
_apply_ifupdown_static() {
    local net_nic="$1" net_ip="$2" net_gw="$3" net_dns="$4"
    local ifaces_file="/etc/network/interfaces"
    cp "$ifaces_file" "${ifaces_file}.bak.$(date +%F_%H%M%S)"
    local ip_addr=$(echo "$net_ip" | cut -d/ -f1)
    local prefix=$(echo "$net_ip" | cut -d/ -f2)
    # 子网掩码计算函数
    _prefix_to_netmask() {
        local p=$1 mask="" full=$((p/8)) part=$((p%8))
        for ((i=0; i<4; i++)); do
            if [ $i -lt $full ]; then mask+="255"
            elif [ $i -eq $full ]; then mask+=$(( 256 - 2**(8 - part) ))
            else mask+="0"; fi
            [ $i -lt 3 ] && mask+="."
        done
        echo "$mask"
    }
    local mask_str=$(_prefix_to_netmask "$prefix")
    sed -i "/iface $net_nic/d" "$ifaces_file"
    sed -i "/auto $net_nic/d" "$ifaces_file"
    echo -e "\n# added by system_init.sh\nauto $net_nic\niface $net_nic inet static\n    address $ip_addr\n    netmask $mask_str\n    gateway $net_gw" >> "$ifaces_file"
    if [ -n "$net_dns" ]; then
        local dns_list=$(echo "$net_dns" | sed 's/,/ /g')
        echo "    dns-nameservers $dns_list" >> "$ifaces_file"
        echo "# 由 system_init.sh 生成" > /etc/resolv.conf
        for d in $dns_list; do echo "nameserver $d" >> /etc/resolv.conf; done
    fi
    echo -e "${YELLOW}正在热重载网络服务...${NC}"
    if command -v systemctl &>/dev/null; then
        systemctl restart networking 2>/dev/null || systemctl restart network 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service networking restart 2>/dev/null
    else
        ifdown "$net_nic" && ifup "$net_nic"
    fi
    echo -e "${GREEN}成功: /etc/network/interfaces 静态 IP 设定并重载网络。${NC}"
}

# Netplan DHCP DHCP 应用逻辑
_apply_netplan_dhcp() {
    local net_nic="$1"
    local netplan_file="/etc/netplan/01-dhcp-${net_nic}.yaml"
    for f in /etc/netplan/*.yaml; do [ -f "$f" ] && cp "$f" "${f}.bak.$(date +%F_%H%M%S)"; done
    rm -f "/etc/netplan/01-static-${net_nic}.yaml" 2>/dev/null
    cat > "$netplan_file" <<EOF
# 由 system_init.sh 自动生成 - $(date +"%Y-%m-%d %H:%M:%S")
network:
  version: 2
  renderer: networkd
  ethernets:
    ${net_nic}:
      dhcp4: true
EOF
    chmod 600 "$netplan_file"
    echo -e "${YELLOW}正在应用 Netplan DHCP 模式...${NC}"
    netplan apply 2>&1
    [ $? -eq 0 ] && echo -e "${GREEN}成功: Netplan ($net_nic) DHCP 已生效。${NC}" || echo -e "${RED}警告: netplan apply 异常。${NC}"
}

# nmcli DHCP 应用逻辑
_apply_nmcli_dhcp() {
    local net_nic="$1"
    local conn_name=$(nmcli -t -f NAME,DEVICE connection show | grep ":${net_nic}" | head -n 1 | cut -d: -f1)
    if [ -z "$conn_name" ]; then
        conn_name="${net_nic}_conn"
        nmcli connection add type ethernet ifname "$net_nic" con-name "$conn_name" &>/dev/null
    fi
    nmcli connection modify "$conn_name" ipv4.method auto
    nmcli connection modify "$conn_name" ipv4.addresses ""
    nmcli connection modify "$conn_name" ipv4.gateway ""
    nmcli connection modify "$conn_name" ipv4.dns ""
    nmcli connection up "$conn_name" 2>&1
    [ $? -eq 0 ] && echo -e "${GREEN}成功: nmcli ($net_nic) 切换至 DHCP 已生效。${NC}" || echo -e "${RED}警告: nmcli 异常。${NC}"
}

# ifupdown DHCP 应用逻辑
_apply_ifupdown_dhcp() {
    local net_nic="$1"
    local ifaces_file="/etc/network/interfaces"
    cp "$ifaces_file" "${ifaces_file}.bak.$(date +%F_%H%M%S)"
    sed -i "/iface $net_nic/d" "$ifaces_file"
    sed -i "/auto $net_nic/d" "$ifaces_file"
    echo -e "\n# added by system_init.sh\nauto $net_nic\niface $net_nic inet dhcp" >> "$ifaces_file"
    echo -e "${YELLOW}正在热重载网络服务...${NC}"
    if command -v systemctl &>/dev/null; then
        systemctl restart networking 2>/dev/null || systemctl restart network 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service networking restart 2>/dev/null
    else
        ifdown "$net_nic" && ifup "$net_nic"
    fi
    echo -e "${GREEN}成功: ifupdown ($net_nic) 切换至 DHCP 并重载生效。${NC}"
}

# 配置静态 IP（交互式逐步输入）
configure_static_ip() {
    echo -e "\n${BLUE}--- 配置静态 IP 地址 ---${NC}"

    # 第 1 步：列出可用网卡并选择
    echo -e "${YELLOW}第 1 步: 选择要配置的网卡${NC}"
    echo -e "系统检测到以下网卡:"
    echo ""
    NIC_LIST=($(ls /sys/class/net/ | grep -v lo))
    if [ ${#NIC_LIST[@]} -eq 0 ]; then
        echo -e "${RED}错误: 未检测到可用网卡。${NC}"
        return
    fi
    for i in "${!NIC_LIST[@]}"; do
        NIC_STATUS=$(cat "/sys/class/net/${NIC_LIST[$i]}/operstate" 2>/dev/null || echo "未知")
        NIC_IP=$(ip -4 addr show "${NIC_LIST[$i]}" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
        echo "  [$((i+1))] ${NIC_LIST[$i]}  状态: $NIC_STATUS  当前IP: ${NIC_IP:-无}"
    done
    echo ""
    read -p "请输入网卡序号 [1-${#NIC_LIST[@]}]: " nic_idx
    if ! [[ "$nic_idx" =~ ^[0-9]+$ ]] || [ "$nic_idx" -lt 1 ] || [ "$nic_idx" -gt ${#NIC_LIST[@]} ]; then
        echo -e "${RED}错误: 无效的选择。${NC}"
        return
    fi
    NIC_NAME=${NIC_LIST[$((nic_idx-1))]}
    echo -e "${GREEN}已选择网卡: $NIC_NAME${NC}"

    # 第 2 步：输入 IP 地址和子网掩码
    echo -e "\n${YELLOW}第 2 步: 输入 IP 地址和子网掩码 (CIDR 格式)${NC}"
    echo -e "  示例: 192.168.1.100/24"
    read -p "请输入 IP/掩码: " STATIC_IP
    if ! echo "$STATIC_IP" | grep -qP '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$'; then
        echo -e "${RED}错误: IP 格式不正确，请使用 x.x.x.x/xx 格式。${NC}"
        return
    fi

    # 第 3 步：输入网关地址
    echo -e "\n${YELLOW}第 3 步: 输入默认网关地址${NC}"
    echo -e "  示例: 192.168.1.1"
    read -p "请输入网关: " GATEWAY
    if ! echo "$GATEWAY" | grep -qP '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$'; then
        echo -e "${RED}错误: 网关格式不正确。${NC}"
        return
    fi

    # 第 4 步：输入 DNS 服务器
    echo -e "\n${YELLOW}第 4 步: 输入 DNS 服务器${NC}"
    echo -e "  示例: 8.8.8.8,114.114.114.114 (多个用逗号分隔)"
    read -p "请输入 DNS [默认: 223.5.5.5,114.114.114.114]: " DNS_INPUT
    DNS_INPUT=${DNS_INPUT:-223.5.5.5,114.114.114.114}

    # 第 5 步：确认配置预览
    echo -e "\n${BLUE}============ 配置预览 ============${NC}"
    echo -e "  网卡:     $NIC_NAME"
    echo -e "  IP/掩码:  $STATIC_IP"
    echo -e "  网关:     $GATEWAY"
    echo -e "  DNS:      $DNS_INPUT"
    echo -e "${BLUE}==================================${NC}"
    echo ""
    read -p "确认应用以上配置? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}已取消操作。${NC}"
        return
    fi

    # 第 6 步：判定架构底层并路由到适用引擎执行应用
    echo -e "\n${YELLOW}第 6 步: 正在执行底层网络修改流程...${NC}"
    if command -v netplan &>/dev/null; then
        _apply_netplan_static "$NIC_NAME" "$STATIC_IP" "$GATEWAY" "$DNS_INPUT"
    elif command -v nmcli &>/dev/null; then
        _apply_nmcli_static "$NIC_NAME" "$STATIC_IP" "$GATEWAY" "$DNS_INPUT"
    elif [ -f /etc/network/interfaces ]; then
        _apply_ifupdown_static "$NIC_NAME" "$STATIC_IP" "$GATEWAY" "$DNS_INPUT"
    else
        echo -e "${RED}错误: 无法确定当前系统的标准网络控制管理工具。配置取消操作。${NC}"
        return
    fi
    echo -e "  新侦测 IP: $(ip -4 addr show "$NIC_NAME" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)"
}

# 切换为 DHCP 自动获取 IP
configure_dhcp_ip() {
    echo -e "\n${BLUE}--- 切换为 DHCP 自动获取 IP ---${NC}"

    # 列出可用网卡
    echo -e "${YELLOW}选择要切换为 DHCP 的网卡:${NC}"
    NIC_LIST=($(ls /sys/class/net/ | grep -v lo))
    if [ ${#NIC_LIST[@]} -eq 0 ]; then
        echo -e "${RED}错误: 未检测到可用网卡。${NC}"
        return
    fi
    for i in "${!NIC_LIST[@]}"; do
        NIC_STATUS=$(cat "/sys/class/net/${NIC_LIST[$i]}/operstate" 2>/dev/null || echo "未知")
        NIC_IP=$(ip -4 addr show "${NIC_LIST[$i]}" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
        echo "  [$((i+1))] ${NIC_LIST[$i]}  状态: $NIC_STATUS  当前IP: ${NIC_IP:-无}"
    done
    echo ""
    read -p "请输入网卡序号 [1-${#NIC_LIST[@]}]: " nic_idx
    if ! [[ "$nic_idx" =~ ^[0-9]+$ ]] || [ "$nic_idx" -lt 1 ] || [ "$nic_idx" -gt ${#NIC_LIST[@]} ]; then
        echo -e "${RED}错误: 无效的选择。${NC}"
        return
    fi
    NIC_NAME=${NIC_LIST[$((nic_idx-1))]}

    read -p "确认将 $NIC_NAME 切换为 DHCP 模式? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}已取消操作。${NC}"
        return
    fi

    # 路由底层执行机制
    if command -v netplan &>/dev/null; then
        _apply_netplan_dhcp "$NIC_NAME"
    elif command -v nmcli &>/dev/null; then
        _apply_nmcli_dhcp "$NIC_NAME"
    elif [ -f /etc/network/interfaces ]; then
        _apply_ifupdown_dhcp "$NIC_NAME"
    else
        echo -e "${RED}错误: 未检测到兼容的网络管理引擎配置机制。${NC}"
        return
    fi
    
    sleep 3  # 等待 DHCP 获取 IP
    NEW_IP=$(ip -4 addr show "$NIC_NAME" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
    echo -e "  当前 IP: ${NEW_IP:-正在获取中...}"
}

# ==============================================================
# IP 流量伪装与 NAT 转发管理 (内核 + 防火墙)
# ==============================================================

_update_sysctl_forward() {
    local enable=$1
    if [ "$enable" == "on" ]; then
        sysctl -w net.ipv4.ip_forward=1 &>/dev/null
        sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
        grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    else
        sysctl -w net.ipv4.ip_forward=0 &>/dev/null
        sed -i 's/^net.ipv4.ip_forward=1/#net.ipv4.ip_forward=1/' /etc/sysctl.conf
    fi
    sysctl -p &>/dev/null
}

manage_nat_forwarding() {
    local driver="unknown"
    if command -v ufw &>/dev/null; then driver="ufw"; fi
    if command -v firewall-cmd &>/dev/null; then driver="firewalld"; fi

    clear
    echo -e "${YELLOW}================ IP 流量伪装管理 (NAT 转发) ================${NC}"
    
    # 检测状态
    local forward_status=$(cat /proc/sys/net/ipv4/ip_forward)
    local masq_status="no"
    if [ "$driver" == "firewalld" ]; then
        masq_status=$(firewall-cmd --query-masquerade 2>/dev/null)
    elif [ "$driver" == "ufw" ]; then
        grep -q "DEFAULT_FORWARD_POLICY=\"ACCEPT\"" /etc/default/ufw && masq_status="yes"
    fi

    echo -e "内核转发状态: $([ "$forward_status" == "1" ] && echo -e "${GREEN}已开启${NC}" || echo -e "${RED}已关闭${NC}")"
    echo -e "防火墙伪装:   $([ "$masq_status" == "yes" ] && echo -e "${GREEN}Active${NC}" || echo -e "${RED}Inactive${NC}")"
    echo -e "--------------------------------------------------------"
    
    if [ "$masq_status" == "no" ]; then
        echo -e "${CYAN}提示:${NC} 开启后可实现 VPS 的 NAT 流量中转/隧道转发功能。"
        read -p "是否确认开启 IP 流量伪装? (y/n): " confirm < /dev/tty
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            _log_info "正在开启内核转发..."
            _update_sysctl_forward "on"
            _log_info "正在配置防火墙伪装规则..."
            if [ "$driver" == "firewalld" ]; then
                firewall-cmd --permanent --add-masquerade &>/dev/null
                firewall-cmd --reload &>/dev/null
            elif [ "$driver" == "ufw" ]; then
                sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
                # 这里简单处理，核心 UFW NAT 转发建议配合 _config_ufw_nat (如果需要更复杂的规则)
                ufw reload &>/dev/null
            fi
            _log_info "IP 流量伪装已成功开启。"
        fi
    else
        read -p "是否确认关闭 IP 流量伪装并停用数据转发? (y/n): " confirm < /dev/tty
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            _log_info "正在关闭防火墙伪装规则..."
            if [ "$driver" == "firewalld" ]; then
                firewall-cmd --permanent --remove-masquerade &>/dev/null
                firewall-cmd --reload &>/dev/null
            elif [ "$driver" == "ufw" ]; then
                sed -i 's/DEFAULT_FORWARD_POLICY="ACCEPT"/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw
                ufw reload &>/dev/null
            fi
            _log_info "正在关闭内核转发..."
            _update_sysctl_forward "off"
            _log_info "IP 流量伪装已关闭。"
        fi
    fi
    read -p "按回车键返回二级菜单..." < /dev/tty
}
# ==============================================================
# 优化 DNS 地址配置模块 (国内外优化/手动编辑)
# ==============================================================
optimize_dns_menu() {
    while true; do
        clear
        echo -e "${CYAN}------------------------${NC}"
        echo -e "${YELLOW}当前DNS地址${NC}"
        if [ -f /etc/resolv.conf ]; then
            cat /etc/resolv.conf
        else
            echo -e "${RED}未检测到 /etc/resolv.conf 配置文件${NC}"
        fi
        echo -e "${CYAN}------------------------${NC}"
        echo ""
        echo -e " 1. 国外DNS优化:"
        echo -e "    v4: 1.1.1.1 8.8.8.8"
        echo -e "    v6: 2606:4700:4700::1111 2001:4860:4860::8888"
        echo ""
        echo -e " 2. 国内DNS优化:"
        echo -e "    v4: 223.5.5.5 183.60.83.19"
        echo -e "    v6: 2400:3200::1 2400:da00::6666"
        echo ""
        echo -e " 3. 手动编辑DNS配置"
        echo -e "${CYAN}------------------------${NC}"
        echo -e " 0. 返回上一级选单"
        echo -e "${CYAN}------------------------${NC}"
        read -p "请输入你的选择: " dns_opt < /dev/tty

        case "$dns_opt" in
            1)
                echo -e "${YELLOW}正在写入国外优化 DNS...${NC}"
                [ -f /etc/resolv.conf ] && cp -f /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null
                [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
                cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
options timeout:2 attempts:3 rotate
EOF
                echo -e "${GREEN}✅ 成功: 国外 DNS 配置已应用。${NC}"
                sleep 1.2
                ;;
            2)
                echo -e "${YELLOW}正在写入国内优化 DNS...${NC}"
                [ -f /etc/resolv.conf ] && cp -f /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null
                [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
                cat > /etc/resolv.conf <<EOF
nameserver 223.5.5.5
nameserver 183.60.83.19
nameserver 2400:3200::1
nameserver 2400:da00::6666
options timeout:2 attempts:3 rotate
EOF
                echo -e "${GREEN}✅ 成功: 国内 DNS 配置已应用。${NC}"
                sleep 1.2
                ;;
            3)
                if command -v nano &>/dev/null; then
                    nano /etc/resolv.conf
                elif command -v vim &>/dev/null; then
                    vim /etc/resolv.conf
                else
                    vi /etc/resolv.conf
                fi
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}输入无效，请重新选择。${NC}"
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# IPv4 / IPv6 出站路由优先级调度中心 (/etc/gai.conf)
# ==============================================================================
manage_ip_priority_menu() {
    local gai_conf="/etc/gai.conf"
    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}        🔀 IPv4 / IPv6 出站解析优先级调度中心          ${NC}"
        echo -e "${CYAN}======================================================${NC}"

        # 探测当前状态
        local current_mode="双栈默认 (系统标准策略)"
        if [ -f "$gai_conf" ] && grep -qE "^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100" "$gai_conf"; then
            current_mode="${GREEN}优先使用 IPv4 (precedence ::ffff:0:0/96 100)${NC}"
        elif [ -f "$gai_conf" ] && grep -qE "^[[:space:]]*precedence[[:space:]]+::/0[[:space:]]+100" "$gai_conf"; then
            current_mode="${CYAN}优先使用 IPv6 (precedence ::/0 100)${NC}"
        fi

        echo -e " 当前调度策略: $current_mode"
        echo ""
        echo " 1. 🚀 设置优先使用 IPv4 (解决部分双栈网络中 IPv6 绕路或减速问题)"
        echo " 2. 🌐 设置优先使用 IPv6 (适合 IPv6 优质线路或纯 IPv6 优先环境)"
        echo " 3. 🔄 恢复系统默认策略 (移除自定义优先级规则)"
        echo " 4. 🔍 查看 /etc/gai.conf 配置文件全文"
        echo " 0. 返回上一级菜单"
        echo -e "${CYAN}======================================================${NC}"
        read -p "请输入操作选项 [0-4]: " prio_choice < /dev/tty

        case "$prio_choice" in
            1)
                echo -e "${YELLOW}正在配置优先使用 IPv4...${NC}"
                [ ! -f "$gai_conf" ] && touch "$gai_conf"
                sed -i '/precedence ::ffff:0:0\/96 100/d' "$gai_conf"
                sed -i '/precedence ::\/0 100/d' "$gai_conf"
                echo "precedence ::ffff:0:0/96 100" >> "$gai_conf"
                echo -e "${GREEN}✅ 成功: 已设置系统网络请求优先走 IPv4。${NC}"
                sleep 1.2
                ;;
            2)
                echo -e "${YELLOW}正在配置优先使用 IPv6...${NC}"
                [ ! -f "$gai_conf" ] && touch "$gai_conf"
                sed -i '/precedence ::ffff:0:0\/96 100/d' "$gai_conf"
                sed -i '/precedence ::\/0 100/d' "$gai_conf"
                echo "precedence ::/0 100" >> "$gai_conf"
                echo -e "${GREEN}✅ 成功: 已设置系统网络请求优先走 IPv6。${NC}"
                sleep 1.2
                ;;
            3)
                echo -e "${YELLOW}正在恢复系统默认调度策略...${NC}"
                if [ -f "$gai_conf" ]; then
                    sed -i '/precedence ::ffff:0:0\/96 100/d' "$gai_conf"
                    sed -i '/precedence ::\/0 100/d' "$gai_conf"
                fi
                echo -e "${GREEN}✅ 成功: 已清除自定义优先级，恢复系统默认。${NC}"
                sleep 1.2
                ;;
            4)
                clear
                echo -e "${BLUE}=== /etc/gai.conf 详细内容 ===${NC}"
                if [ -f "$gai_conf" ]; then
                    cat "$gai_conf"
                else
                    echo "文件 /etc/gai.conf 尚不存在（系统使用编译期内置默认规则）。"
                fi
                echo ""
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}输入无效，请重新选择。${NC}"
                sleep 1
                ;;
        esac
    done
}

network_menu() {
    while true; do
        clear
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}           网络 IP 配置 (二级菜单)            ${NC}"
        echo -e "${GREEN}==============================================${NC}"
        echo " 1. 🌐 优化 DNS 地址配置"
        echo " 2. 🔀 IPv4 / IPv6 出站路由优先级调度"
        echo " 3. 查看当前网络信息"
        echo " 4. 配置静态 IP (交互式)"
        echo " 5. 切换为 DHCP 自动获取"
        echo " 6. IP 流量伪装管理 (NAT 转发)"
        echo " 0. 返回主菜单"
        echo -e "${GREEN}==============================================${NC}"
        read -p "请选择操作 [0-6]: " net_choice

        case $net_choice in
            1) optimize_dns_menu ;;
            2) manage_ip_priority_menu ;;
            3) show_network_info ;;
            4) configure_static_ip; read -p "按回车键继续..." ;;
            5) configure_dhcp_ip; read -p "按回车键继续..." ;;
            6) manage_nat_forwarding ;;
            0) break ;;
            *) echo -e "${RED}无效输入。${NC}"; sleep 1 ;;
        esac
    done
}

# 双模运行守卫: 支持被主程序 source 引用或独立单兵执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    network_menu
fi
