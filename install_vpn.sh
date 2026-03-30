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

# 统一模块存储目录
CK_MODULE_DIR="/opt/ck_sysinit/modules"
mkdir -p "$CK_MODULE_DIR"

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
# 3. 协议 C: Sing-Box-Plus (18节点/WARP解锁) 整合调用
# ================================================================
install_singbox_plus() {
    local SBP_SCRIPT="${CK_MODULE_DIR}/sing-box-plus.sh"

    clear
    echo -e "${CYAN}================ 核心部署: Sing-Box-Plus (全能代理) ================${NC}"
    
    # 确保目录存在
    mkdir -p "$CK_MODULE_DIR"

    if [[ ! -f "$SBP_SCRIPT" ]]; then
        echo -e "${YELLOW}警告: 未在项目目录下检测到 sing-box-plus.sh，尝试一键拉取...${NC}"
        local MIRROR=$(_get_gh_mirror)
        if ! curl -L -f -# -o "$SBP_SCRIPT" "https://raw.githubusercontent.com/Alvin9999-newpac/Sing-Box-Plus/main/sing-box-plus.sh"; then
            echo -e "${RED}致命错误: Sing-Box-Plus 脚本下载失败，请检查网络联通性。${NC}"
            read -p "按回车手动返回..." < /dev/tty
            return 1
        fi
    fi

    chmod +x "$SBP_SCRIPT"
    echo -e "  ➜ 正在唤起 Sing-Box-Plus 内部管理矩阵..."
    # 核心调用：显式重定向 TTY 解决交互循环问题
    bash "$SBP_SCRIPT" < /dev/tty
}

# ================================================================
# 4. VPS 融合怪测评工具 (全项性能/流媒体测试)
# ================================================================
vps_fusion_test() {
    local ECS_SCRIPT="${CK_MODULE_DIR}/ecs.sh"

    clear
    echo -e "${CYAN}================ 核心工具: VPS 融合怪 (本地引擎) ================${NC}"
    
    # 确保目录存在
    mkdir -p "$CK_MODULE_DIR"

    if [[ ! -f "$ECS_SCRIPT" ]]; then
        echo -e "${YELLOW}警告: 未在模块目录下检测到 ecs.sh，尝试重新拉取...${NC}"
        if ! curl -L -f -# -o "$ECS_SCRIPT" "https://gitlab.com/spiritysdx/za/-/raw/main/ecs.sh"; then
            echo -e "${RED}致命错误: 无法获取测评引擎，请检查网络。${NC}"
            read -p "按回车手动返回..." < /dev/tty
            return 1
        fi
    fi

    echo -e "${YELLOW}提示: 该脚本将执行性能/带宽/流媒体等全量测试，耗时预计 5-10 分钟。${NC}"
    chmod +x "$ECS_SCRIPT"
    echo -e "  ➜ 正在唤起 融合怪 (ecs.sh) 进行全向测评..."
    
    # 核心调用：显式重定向 TTY 解决交互循环问题
    bash "$ECS_SCRIPT" < /dev/tty
    
    read -p "测评流程已结束，按回车键返回..." < /dev/tty
}

# ================================================================
# 5. 游戏联机环境与网速诊断工具
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
    # 使用多源对冲机制，防止单一 API 失效
    local IP_INFO=$(curl -s -m 5 https://ipapi.co/json/ 2>/dev/null || curl -s -m 5 http://ip-api.com/json/ 2>/dev/null)
    if [ -n "$IP_INFO" ] && [[ "$IP_INFO" == *"ip"* || "$IP_INFO" == *"query"* ]]; then
        local CUR_IP=$(echo "$IP_INFO" | grep -oE '"(ip|query)": "[^"]+"' | head -1 | cut -d'"' -f4)
        local ORG=$(echo "$IP_INFO" | grep -oE '"(org|as|isp)": "[^"]+"' | head -1 | cut -d'"' -f4)
        local CITY=$(echo "$IP_INFO" | grep -oE '"city": "[^"]+"' | head -1 | cut -d'"' -f4)
        local COUNTRY=$(echo "$IP_INFO" | grep -oE '"(country_name|country)": "[^"]+"' | head -1 | cut -d'"' -f4)
        
        echo -e "    公网 IP: ${GREEN}${CUR_IP:-未知}${NC}"
        echo -e "    运营商:  ${GREEN}${ORG:-未知}${NC}"
        [ -n "$CITY" ] && [ -n "$COUNTRY" ] && echo -e "    所在地:  ${GREEN}$CITY, $COUNTRY${NC}" || echo -e "    所在地:  ${GREEN}${CITY:-}${COUNTRY:-未知}${NC}"
    else
        echo -e "    ${RED}✗ 无法连接到 IP 探测服务 (GitHub/CDN 阻断或 API 超时)${NC}"
    fi
    echo ""

    # 2. 游戏平台核心节点延迟测试 (Ping)
    test_ping() {
        local name=$1
        local host=$2
        printf "    测试 ${CYAN}%-15s${NC} -> " "$name"
        
        # 预检：DNS 是否能解析
        if ! host "$host" &>/dev/null && ! ping -c 1 -W 1 "$host" &>/dev/null; then
            echo -e "${RED}域名无法解析 (DNS 故障)${NC}"
            return
        fi

        # 兼容性 Ping 解析逻辑 (针对不同 OS 输出)
        local ping_out=$(ping -c 4 -W 2 "$host" 2>/dev/null)
        local result=$(echo "$ping_out" | tail -1 | grep '/' | awk -F '/' '{print $5}')
        [ -z "$result" ] && result=$(echo "$ping_out" | grep 'avg' | awk -F'/' '{print $5}')

        if [ -n "$result" ]; then
            if (( $(echo "$result < 50" | bc -l) )); then
                echo -e "${GREEN}${result} ms (极佳)${NC}"
            elif (( $(echo "$result < 150" | bc -l) )); then
                echo -e "${YELLOW}${result} ms (一般)${NC}"
            else
                echo -e "${RED}${result} ms (高延迟)${NC}"
            fi
        else
            echo -e "${RED}超时 (节点防火墙阻断)${NC}"
        fi
    }

    echo -e "${YELLOW}[2] 游戏平台联机节点延迟 (Latency):${NC}"
    test_ping "Switch eShop" "ctest.cdn.nintendo.net"
    test_ping "PSN Store"    "gs-sec.ww.np.dl.playstation.net"
    test_ping "Xbox Live"    "xsts.auth.xboxlive.com"
    test_ping "Steam Global" "steamcommunity.com"
    echo ""

    # 3. 下载速度测试
    echo -e "${YELLOW}[3] 基础带宽下载速度检测:${NC}"
    if command -v speedtest-cli &>/dev/null; then
        speedtest-cli --simple
    else
        printf "    正在从全球 CDN 节点拉取测速文件 (10MB)... "
        # 使用 Cloudflare 边缘节点测速，更真实反映国际带宽
        local SPEED_INFO=$(curl -L -s -o /dev/null -w "%{speed_download}" --max-time 15 https://speed.cloudflare.com/__down?bytes=10485760)
        
        # 算力换算与着色优化
        if [ -n "$SPEED_INFO" ] && (( $(echo "$SPEED_INFO > 0" | bc -l) )); then
            local MB_PER_SEC=$(echo "scale=2; $SPEED_INFO / 1048576" | bc -l)
            local S_COLOR="${RED}"
            if (( $(echo "$MB_PER_SEC > 2" | bc -l) )); then S_COLOR="${YELLOW}"; fi
            if (( $(echo "$MB_PER_SEC > 10" | bc -l) )); then S_COLOR="${GREEN}"; fi
            echo -e "${S_COLOR}${MB_PER_SEC} MB/s${NC}"
        else
            echo -e "${RED}测速异常 (请检查链路或 DNS)${NC}"
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
    for cmd in traceroute mtr bc; do
        if ! command -v $cmd &>/dev/null; then
            echo -e "${YELLOW}正在安装缺失工具: $cmd...${NC}"
            [ -n "$PKG_MGR" ] && ${PKG_MGR} install -y $cmd &>/dev/null
        fi
    done

    read -p "请输入要测试的域名 (默认 ctest.cdn.nintendo.net): " TARGET < /dev/tty
    TARGET=${TARGET:-ctest.cdn.nintendo.net}
    # 提取纯域名/IP
    local DOMAIN=$(echo $TARGET | sed -e 's|^[^/]*//||' -e 's|/.*$||')

    # --- 第一部分：HTTP 响应时间拆解 ---
    echo -e "\n${YELLOW}[1] HTTP 链路响应拆解 (测算中...):${NC}"
    # 捕获 curl 数据
    local CURL_DATA=$(curl -L -o /dev/null -s -w "%{time_namelookup}|%{time_connect}|%{time_starttransfer}|%{time_total}" --max-time 10 "http://$DOMAIN")
    
    # 拆解变量
    IFS='|' read -r DNS_T TCP_T TTFB_T TOTAL_T <<< "$CURL_DATA"

    # 判定是否连接失败 (如果总时间 >= 10 且后续阶段为 0)
    if (( $(echo "$TOTAL_T >= 10" | bc -l 2>/dev/null || echo 0) )) && (( $(echo "$TCP_T == 0" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "    状态反馈:   ${RED}⚠ 目标连接超时或 80 端口未开放${NC}"
    else
        printf "    %-12s: ${CYAN}%s${NC} s\n" "DNS 解析" "${DNS_T}"
        printf "    %-12s: ${CYAN}%s${NC} s\n" "TCP 握手" "${TCP_T}"
        printf "    %-12s: ${CYAN}%s${NC} s\n" "首字节响应" "${TTFB_T}"
        printf "    %-12s: ${GREEN}%s${NC} s\n" "总计耗时" "${TOTAL_T}"
    fi

    # --- 第二部分：路由图 (Traceroute) ---
    echo -e "\n${YELLOW}[2] 路由追踪路径图 (Traceroute):${NC}"
    printf "  ${BLUE}%-4s  %-20s    %-15s${NC}\n" "跳数" "节点 IP" "节点延迟 (RTT)"
    echo -e "  ------------------------------------------------------"
    traceroute -q 1 -w 1 -n "$DOMAIN" 2>/dev/null | awk -v g="${GREEN}" -v y="${YELLOW}" -v r="${RED}" -v n="${NC}" '
        NR>1 {
            if ($2 == "*") {
                printf "  %-4s  %-20s    %s\n", $1, "* * *", "请求超时"
            } else {
                color=g; 
                if ($3 > 80) color=y;
                if ($3 > 160) color=r;
                printf "  %-4s  %-20s    %s%s ms%s\n", $1, $2, color, $3, n
            }
        }
    '
    echo -e "  ------------------------------------------------------"

    # --- 第三部分：动态链路稳定性测试 (MTR) ---
    echo -e "\n${YELLOW}[3] 稳定性深度扫描 (MTR 10轮):${NC}"
    printf "  ${BLUE}%-40s  %-10s  %-8s${NC}\n" "中继节点 (Gateway)" "丢包 (Loss)" "均值 (Avg)"
    mtr -rw -c 10 "$DOMAIN" 2>/dev/null | tail -n +2 | awk -v g="${GREEN}" -v y="${YELLOW}" -v r="${RED}" -v n="${NC}" '{
        loss_color=g; if($3 > 5) loss_color=y; if($3 > 20) loss_color=r;
        printf "  %-40s  %s%-6s%s  %-8s ms\n", $2, loss_color, $3"%", n, $6
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
    local WG_S="${RED}停止${NC}"
    systemctl is-active wg-quick@wg0 &>/dev/null && WG_S="${GREEN}运行中${NC}"
    
    local SB_S="${RED}停止${NC}"
    systemctl is-active sing-box &>/dev/null && SB_S="${GREEN}运行中${NC}"

    echo -e " 🛡  WireGuard 状态: $WG_S | Sing-Box 状态: $SB_S"
    echo -e "${GREEN}------------------------------------------------------${NC}"
    echo " 1. 部署/更新 WireGuard (极速 VPN)"
    echo " 2. 部署/更新 Xray-Reality (流量隐形代理)"
    echo " 3. 系统 BBR 加速自检与开启"
    echo " 4. 彻底卸载所有 VPN/代理组件"
    echo " 5. 运行游戏联机与网速诊断"
    echo " 6. 域名测速与路由链路分析"
    echo " 7. 部署 Sing-Box-Plus (18节点/WARP解锁) [推荐]"
    echo " 8. 运行 VPS 融合怪 (性能/带宽/流媒体全项测试)"
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
                
                echo -e "${YELLOW} [3/3] 正在清理 Sing-Box-Plus 部署遗迹...${NC}"
                systemctl stop sing-box &>/dev/null
                systemctl disable sing-box &>/dev/null
                rm -f /etc/systemd/system/sing-box.service
                rm -rf /opt/sing-box /var/lib/sing-box-plus /usr/local/bin/sing-box
                
                systemctl daemon-reload
                echo -e "${GREEN} 所有 VPN/Proxy 组件已从系统总线彻底移除。${NC}"
            fi
            read -p "按回车键返回..." < /dev/tty
            ;;
        5) network_diagnosis ;;
        6) domain_route_analysis ;;
        7) install_singbox_plus ;;
        8) vps_fusion_test ;;
        0) exit 0 ;;
        *) echo -e "${RED} 无效参数${NC}"; sleep 1 ;;
    esac
done
