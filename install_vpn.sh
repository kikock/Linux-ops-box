#!/bin/bash
# =================================================================
# 脚本名称: install_vpn.sh
# 描述: VPS-VPN 专家管理工具 (v1.0)
# 协议支持: WireGuard (高性能隧道) / Xray-Reality (流量隐蔽代理)
# =================================================================

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 权限检测
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 该工具需要 root 权限，请使用 sudo 执行。${NC}"
   exit 1
fi

# 自动包管理器检测
if command -v apt-get &>/dev/null; then
    PKG_MGR="apt-get"
elif command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
elif command -v apk &>/dev/null; then
    PKG_MGR="apk"
else
    PKG_MGR="echo"
fi

# 基础环境架构自摸
ARCH=$(uname -m)
XRAY_ARCH="64"
[ "$ARCH" = "aarch64" ] && XRAY_ARCH="arm64-v8a"

# ================================================================
# 私有辅助函数: Github 线路自适应探测
# ================================================================
_get_gh_mirror() {
    if curl -Is -m 3 "https://github.com" | head -1 | grep -q '200\|301\|302'; then
        echo "https://github.com"
    else
        echo "https://ghproxy.net/https://github.com"
    fi
}

# ================================================================
# 私有辅助函数: BBR 加速自检与开启
# ================================================================
check_and_enable_bbr() {
    echo -e "  ⏳ 正在检测内核 BBR 拥塞控制算法状态..."
    local BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [[ "$BBR_STATUS" == "bbr" ]]; then
        echo -e "${GREEN}  ✓ BBR 加速已在内核层生效。${NC}"
    else
        echo -e "${YELLOW}  ⚠ 未检测到 BBR 加速，建议开启以提升 VPN 链路同步性能。${NC}"
        read -p " 是否现在一键开启 BBR? (y/n) " bbr_confirm < /dev/tty
        if [[ "$bbr_confirm" =~ ^[Yy]$ ]]; then
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p &>/dev/null
            echo -e "${GREEN}  ✓ BBR 指令已下达，已刷新内核参。${NC}"
        fi
    fi
}

# ================================================================
# 1. 协议 A: WireGuard 自动化安装逻辑
# ================================================================
install_wireguard() {
    clear
    echo -e "${CYAN}================ 核心部署: WireGuard (高速隧道) ================${NC}"
    
    # 检测环境并安装依赖
    if command -v wg &>/dev/null; then
        echo -e "${YELLOW}检测到 WireGuard 已存在于系统中。${NC}"
    else
        echo -e "  ➜ 正在静默注入 WireGuard 内核工具包..."
        # 兼容性多包管理器处理
        if command -v apt-get &>/dev/null; then
            apt-get update && apt-get install -y wireguard qrencode curl
        elif command -v yum &>/dev/null; then
            yum install -y elrepo-release epel-release
            yum install -y kmod-wireguard wireguard-tools qrencode
        fi
    fi

    local WG_DIR="/etc/wireguard"
    [ ! -d "$WG_DIR" ] && mkdir -p "$WG_DIR"
    
    local SERV_PRIV_KEY=$(wg genkey)
    local SERV_PUB_KEY=$(echo "$SERV_PRIV_KEY" | wg pubkey)
    local CLI_PRIV_KEY=$(wg genkey)
    local CLI_PUB_KEY=$(echo "$CLI_PRIV_KEY" | wg pubkey)
    local SERVER_IP=$(curl -s ip.sb || curl -s ifconfig.me)
    local LISTEN_PORT=$((RANDOM % 10000 + 40000))

    echo -e "  ➜ 正在塑造网道拓扑 (私网网段: 10.0.0.1/24)..."
    cat > ${WG_DIR}/wg0.conf <<EOF
[Interface]
PrivateKey = ${SERV_PRIV_KEY}
Address = 10.0.0.1/24
ListenPort = ${LISTEN_PORT}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1) -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1) -j MASQUERADE

[Peer]
PublicKey = ${CLI_PUB_KEY}
AllowedIPs = 10.0.0.2/32
EOF

    # 开启转发
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wg.conf
    sysctl -p /etc/systemd/system/99-wg.conf &>/dev/null 2>&1

    # 启动
    systemctl enable --now wg-quick@wg0 &>/dev/null
    
    # 生成客户端配置
    local CLIENT_CONF="[Interface]
PrivateKey = ${CLI_PRIV_KEY}
Address = 10.0.0.2/24
DNS = 8.8.8.8
MTU = 1420

[Peer]
PublicKey = ${SERV_PUB_KEY}
Endpoint = ${SERVER_IP}:${LISTEN_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25"

    echo -e "\n${GREEN}🎉 WireGuard 基础设施搭建圆满完成！${NC}"
    echo -e "${YELLOW}---------------- 客户端配置导出 (Mobile/PC) ----------------${NC}"
    echo "$CLIENT_CONF"
    echo -e "${YELLOW}----------------------------------------------------------${NC}"
    
    if command -v qrencode &>/dev/null; then
        echo -e " 🤳 建议扫码快速添加配置:"
        echo "$CLIENT_CONF" | qrencode -t ansiutf8
    fi

    read -p "配置已展示，按回车键返回..." < /dev/tty
}

# ================================================================
# 2. 协议 B: Xray-Reality 自动化安装逻辑 (待实现后期补充)
# ================================================================
install_xray_reality() {
    clear
    echo -e "${CYAN}================ 核心部署: Xray REALITY (隐身协议) ================${NC}"
    
    # 获取加速镜像
    local MIRROR=$(_get_gh_mirror)
    
    # 1. 获取最新版本并下载
    echo -e "  ⏳ 正在检索 Xray 最新发布版..."
    local XRAY_LATEST=$(curl -sL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep '"tag_name":' | head -1 | cut -d '"' -f 4)
    [ -z "$XRAY_LATEST" ] && XRAY_LATEST="v1.8.4" # 兜底
    
    local DL_URL="${MIRROR}/XTLS/Xray-core/releases/download/${XRAY_LATEST}/Xray-linux-${XRAY_ARCH}.zip"
    echo -e "  ➜ 目标版本: $XRAY_LATEST"
    
    rm -f /tmp/xray.zip && rm -rf /tmp/xray_temp
    if ! curl -L -f -# -o /tmp/xray.zip "$DL_URL"; then
        echo -e "${RED}致命错误: Xray 下载失败。${NC}"
        return 1
    fi

    # 2. 安装二进制文件
    mkdir -p /tmp/xray_temp && unzip -q /tmp/xray.zip -d /tmp/xray_temp
    mkdir -p /usr/local/bin/xray-core /etc/xray
    cp -f /tmp/xray_temp/xray /usr/local/bin/xray
    chmod +x /usr/local/bin/xray

    # 3. 核心配置生成 (REALITY)
    local UUID=$(/usr/local/bin/xray uuid)
    local KEYS=$(/usr/local/bin/xray x25519)
    local PRIV_KEY=$(echo "$KEYS" | grep "Private key" | awk '{print $3}')
    local PUB_KEY=$(echo "$KEYS" | grep "Public key" | awk '{print $3}')
    local SHORT_ID=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 8)
    local PORT=$((RANDOM % 10000 + 30000))
    local SERVER_IP=$(curl -s ip.sb || curl -s ifconfig.me)
    local DEST_SERVER="www.microsoft.com:443"

    cat > /etc/xray/config.json <<EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "port": ${PORT},
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": false,
                "dest": "${DEST_SERVER}",
                "xver": 0,
                "serverNames": ["www.microsoft.com"],
                "privateKey": "${PRIV_KEY}",
                "shortIds": ["${SHORT_ID}"]
            }
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF

    # 4. 注册服务
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now xray &>/dev/null

    # 5. 导出配置地址
    local VLESS_URL="vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&encryption=none&pbk=${PUB_KEY}&headerType=none&fp=chrome&spx=%2F&type=tcp&sni=www.microsoft.com&sid=${SHORT_ID}&flow=xtls-rprx-vision#Linux-ops-VPN"

    echo -e "\n${GREEN}🎉 Xray-Reality 代理矩阵已架设完成！${NC}"
    echo -e "${YELLOW}---------------- 客户端连接链接 (VLESS) ----------------${NC}"
    echo -e "${CYAN}${VLESS_URL}${NC}"
    echo -e "${YELLOW}--------------------------------------------------------${NC}"
    
    if command -v qrencode &>/dev/null; then
        echo -e " 🤳 建议扫码快速导入客户端 (V2RayNG/v2box/Shadowrocket):"
        echo "$VLESS_URL" | qrencode -t ansiutf8
    fi

    read -p "安装工作已就绪，按回车返回菜单..." < /dev/tty
}

# ================================================================
# 3. 游戏联机环境与网速诊断工具
# ================================================================
network_diagnosis() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}       游戏联机环境与网速诊断工具             ${NC}"
    echo -e "${CYAN}======================================================${NC}"

    # 检测 bc 依赖
    if ! command -v bc &>/dev/null; then
        echo -e "  ⏳ 正在补充依赖 [bc] ..."
        ${PKG_MGR} install -y bc &>/dev/null
    fi

    # 1. 本机 IP 与地理位置信息
    echo -e "${YELLOW}[1] 本机网络身份探测:${NC}"
    local IP_INFO=$(curl -s -m 5 https://ipapi.co/json/ 2>/dev/null)
    if [ -n "$IP_INFO" ]; then
        local CUR_IP=$(echo "$IP_INFO" | grep -oE '"ip": "[^"]+"' | cut -d'"' -f4)
        local ORG=$(echo "$IP_INFO" | grep -oE '"org": "[^"]+"' | cut -d'"' -f4)
        local CITY=$(echo "$IP_INFO" | grep -oE '"city": "[^"]+"' | cut -d'"' -f4)
        local COUNTRY=$(echo "$IP_INFO" | grep -oE '"country_name": "[^"]+"' | cut -d'"' -f4)
        echo -e "    公网 IP: ${GREEN}$CUR_IP${NC}"
        echo -e "    运营商:  ${GREEN}$ORG${NC}"
        echo -e "    所在地:  ${GREEN}$CITY, $COUNTRY${NC}"
    else
        echo -e "    ${RED}✗ 无法连接到 IP 探测服务 (超时)${NC}"
    fi
    echo ""

    # 2. 游戏平台核心节点延迟测试 (Ping)
    test_ping() {
        local name=$1
        local host=$2
        echo -n -e "    测试 ${CYAN}%-15s${NC} -> " "$name"
        local result=$(ping -c 4 -W 2 "$host" 2>/dev/null | tail -1 | awk -F '/' '{print $5}')
        if [ -n "$result" ]; then
            if (( $(echo "$result < 50" | bc -l) )); then
                echo -e "${GREEN}${result} ms (极佳)${NC}"
            elif (( $(echo "$result < 150" | bc -l) )); then
                echo -e "${YELLOW}${result} ms (一般)${NC}"
            else
                echo -e "${RED}${result} ms (高延迟)${NC}"
            fi
        else
            echo -e "${RED}超时 (无法访问)${NC}"
        fi
    }

    echo -e "${YELLOW}[2] 游戏平台联机节点延迟 (Latency):${NC}"
    test_ping "Switch eShop" "ctest.cdn.nintendo.net"
    test_ping "PSN Store"    "us.np.community.playstation.net"
    test_ping "Xbox Live"    "xboxlive.com"
    test_ping "Steam Global" "steampowered.com"
    echo ""

    # 3. 下载速度测试
    echo -e "${YELLOW}[3] 基础带宽下载速度检测:${NC}"
    if command -v speedtest-cli &>/dev/null; then
        speedtest-cli --simple
    else
        echo -n "    正在通过标准节点拉取测速文件 (10MB)... "
        local START_TIME=$(date +%s)
        if curl -s -o /dev/null http://speedtest.tele2.net/10MB.zip; then
            local END_TIME=$(date +%s)
            local DIFF_TIME=$((END_TIME - START_TIME))
            [ $DIFF_TIME -le 0 ] && DIFF_TIME=1
            local SPEED=$((10 / DIFF_TIME))
            echo -e "${GREEN}${SPEED} MB/s${NC}"
        else
            echo -e "${RED}测速失败 (网络不通)${NC}"
        fi
    fi

    echo -e "${CYAN}======================================================${NC}"
    echo -e "${YELLOW}提示: 若 NS 联机 NAT 类型不理想，请检查 WireGuard 的 UDP 转发。${NC}"
    read -p "诊断完成，按回车键返回菜单..." < /dev/tty
}

# ================================================================
# 4. 域名测速与路由链路分析工具
# ================================================================
domain_route_analysis() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}       域名测速与路由链路分析工具             ${NC}"
    echo -e "${CYAN}======================================================${NC}"

    # 检查并安装必要工具
    for cmd in traceroute mtr; do
        if ! command -v $cmd &>/dev/null; then
            echo -e "${YELLOW}正在安装缺失工具: $cmd...${NC}"
            ${PKG_MGR} install -y $cmd &>/dev/null
        fi
    done

    read -p "请输入要测试的域名 (默认 ctest.cdn.nintendo.net): " TARGET < /dev/tty
    TARGET=${TARGET:-ctest.cdn.nintendo.net}
    # 提取纯域名/IP
    local DOMAIN=$(echo $TARGET | sed -e 's|^[^/]*//||' -e 's|/.*$||')

    # --- 第一部分：HTTP 响应时间拆解 ---
    echo -e "\n${YELLOW}[1] HTTP 链路响应拆解:${NC}"
    curl -o /dev/null -s -w \
        "    DNS 解析:   ${CYAN}%{time_namelookup} s${NC}\n\
    TCP 握手:   ${CYAN}%{time_connect} s${NC}\n\
    首字节响应: ${CYAN}%{time_starttransfer} s${NC}\n\
    总计耗时:   ${GREEN}%{time_total} s${NC}\n" \
        -L --max-time 10 "http://$DOMAIN"

    # --- 第二部分：路由图 (Traceroute) ---
    echo -e "${YELLOW}[2] 路由追踪路径图 (Traceroute):${NC}"
    echo -e "${BLUE}序号   IP 地址            节点延迟 (RTT)${NC}"
    echo -e "------------------------------------------------------"
    traceroute -q 1 -w 1 -n "$DOMAIN" 2>/dev/null | awk '
        NR>1 {
            if ($2 == "*") {
                printf "  %-4s  %-15s    %s\n", $1, "* * *", "请求超时"
            } else {
                color="'${GREEN}'"; 
                if ($3 > 100) color="'${RED}'";
                printf "  %-4s  %-15s    %s%s ms%s\n", $1, $2, color, $3, "'${NC}'"
            }
        }
    '
    echo -e "------------------------------------------------------"

    # --- 第三部分：动态链路稳定性测试 (MTR) ---
    echo -e "\n${YELLOW}[3] 链路丢包率与稳定性检测 (MTR 10次轮询):${NC}"
    mtr -rw -c 10 "$DOMAIN" | tail -n +2 | awk '{
        printf "  节点: %-18s  丢包: %-4s  平均延迟: %-6s\n", $2, $3, $6
    }'

    echo -e "\n${CYAN}======================================================${NC}"
    read -p "分析完成，按回车键返回..." < /dev/tty
}

# ================================================================
# 0. 巡航管理主循环
# ================================================================
while true; do
    clear
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}       VPS-VPN 专家工具箱 (Linux-ops-box)             ${NC}"
    echo -e "${GREEN}======================================================${NC}"
    # 基础状态概览
    local WG_S="停止"
    systemctl is-active wg-quick@wg0 &>/dev/null && WG_S="${GREEN}运行中${NC}"
    
    echo -e " 🛡  WireGuard 状态: $WG_S"
    echo -e "${GREEN}------------------------------------------------------${NC}"
    echo " 1. 部署/更新 WireGuard (极速 VPN)"
    echo " 2. 部署/更新 Xray-Reality (流量隐形代理)"
    echo " 3. 系统 BBR 加速自检与开启"
    echo " 4. 彻底卸载所有 VPN/代理组件"
    echo " 5. 运行游戏联机与网速诊断"
    echo " 6. 域名测速与路由链路分析"
    echo " 0. 退出工具箱"
    echo -e "${GREEN}======================================================${NC}"
    read -p "请选择交互选项 [0-6]: " main_choice < /dev/tty

    case "$main_choice" in
        1) install_wireguard ;;
        2) install_xray_reality ;;
        3) check_and_enable_bbr ;;
        4) 
            clear
            echo -e "${RED}==================== 危险: 彻底卸载 VPN 组件 ====================${NC}"
            read -p " 是否确认彻底清除系统中的 VPN/Proxy 核心? (y/N) " un_conf < /dev/tty
            if [[ "$un_conf" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW} [1/2] 正在剥离 WireGuard 链路...${NC}"
                wg-quick down wg0 &>/dev/null
                systemctl disable --now wg-quick@wg0 &>/dev/null
                rm -rf /etc/wireguard
                
                echo -e "${YELLOW} [2/2] 正在关停 Xray 代理矩阵...${NC}"
                systemctl disable --now xray &>/dev/null
                rm -f /etc/systemd/system/xray.service
                rm -rf /etc/xray /usr/local/bin/xray
                
                systemctl daemon-reload
                echo -e "${GREEN} 所有 VPN 组件已从系统总线移除。${NC}"
            fi
            read -p "按回车键返回..." < /dev/tty
            ;;
        5) network_diagnosis ;;
        6) domain_route_analysis ;;
        0) exit 0 ;;
        *) echo -e "${RED} 无效参数${NC}"; sleep 1 ;;
    esac
done
