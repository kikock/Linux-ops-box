#!/bin/bash

# NaiveProxy 一键安装脚本 (CentOS/AlmaLinux/RockyLinux 示例)
# 基于教程：VPN完美方案-自建NaiveProxy.md

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}    NaiveProxy 自动化安装脚本 (Caddy补丁版)    ${NC}"
echo -e "${GREEN}==============================================${NC}"

# 1. 交互式获取配置信息
read -p "请输入你的二级域名 (例如: cdn.example.com): " DOMAIN
read -p "请输入你的邮箱 (用于申请 SSL 证书): " EMAIL
read -p "请输入 NaiveProxy 用户名: " USERNAME
read -p "请输入 NaiveProxy 密码: " PASSWORD
read -p "是否同时开启标准 HTTP 代理? (y/n, 默认 n): " ENABLE_HTTP
read -p "请输入 HTTP 代理端口 (默认 8080): " HTTP_PORT
HTTP_PORT=${HTTP_PORT:-8080}

if [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$USERNAME" || -z "$PASSWORD" ]]; then
    echo -e "${RED}错误: 所有输入项均不能为空！${NC}"
    exit 1
fi

# 2. 系统初始化与必备工具
echo -e "${YELLOW}>>> 正在初始化系统并安装必要工具...${NC}"
dnf update -y
dnf install -y curl wget vim tar firewalld

# 3. 防火墙配置
echo -e "${YELLOW}>>> 正在配置防火墙...${NC}"
systemctl start --now firewalld
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
if [[ "$ENABLE_HTTP" =~ ^[Yy]$ ]]; then
    firewall-cmd --permanent --add-port=$HTTP_PORT/tcp
fi
firewall-cmd --reload

# 4. 关闭 SELinux
echo -e "${YELLOW}>>> 正在关闭 SELinux...${NC}"
setenforce 0 || true
sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config || true

# 5. 启用 BBR 加速
echo -e "${YELLOW}>>> 正在启用 BBR 加速...${NC}"
if ! lsmod | grep -q bbr; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
fi

# 6. 安装 Go 环境 (最新版)
GO_VERSION="1.21.5" # 教程中是 1.25.5，但目前稳定版为 1.21.x，改为脚本环境兼容
echo -e "${YELLOW}>>> 正在安装 Go $GO_VERSION 环境...${NC}"
wget https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
rm -rf /usr/local/go && tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
rm -f go${GO_VERSION}.linux-amd64.tar.gz

# 7. 安装 xcaddy 并编译 Caddy
echo -e "${YELLOW}>>> 正在安装 xcaddy 并编译带补丁的 Caddy...${NC}"
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
cp ~/go/bin/xcaddy /usr/local/bin/

mkdir -p /opt/naive && cd /opt/naive
xcaddy build --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive
mv caddy /usr/local/bin/caddy
chmod +x /usr/local/bin/caddy
setcap cap_net_bind_service=+ep /usr/local/bin/caddy

# 8. 创建配置与伪装站点
echo -e "${YELLOW}>>> 正在创建 Caddy 配置与伪装站点...${NC}"
mkdir -p /etc/caddy
# 生成 Caddyfile
cat > /etc/caddy/Caddyfile << EOF
{
    order forward_proxy before file_server
    admin off
    log {
        output file /var/log/caddy/access.log
        level ERROR
    }
    servers :443 {
        protocols h1 h2
    }
}

:443, $DOMAIN {
    tls $EMAIL

    forward_proxy {
        basic_auth $USERNAME $PASSWORD
        hide_ip
        hide_via
        probe_resistance
    }

    file_server {
        root /var/www/html
    }
}
EOF

# 如果开启了 HTTP 代理，追加配置块
if [[ "$ENABLE_HTTP" =~ ^[Yy]$ ]]; then
    cat >> /etc/caddy/Caddyfile << EOF
:$HTTP_PORT {
    forward_proxy {
        basic_auth $USERNAME $PASSWORD
        hide_ip
        hide_via
    }
}
EOF
fi

mkdir -p /var/www/html
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head><title>CDN Content Delivery Network</title></head>
<body><h1>Successful Node Status: Active</h1><p>Relay mode enabled.</p></body>
</html>
EOF

mkdir -p /var/log/caddy

# 9. 创建 Systemd 服务
echo -e "${YELLOW}>>> 正在创建 Systemd 服务...${NC}"
cat > /etc/systemd/system/caddy.service << 'EOF'
[Unit]
Description=Caddy with Naive
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

# 10. 启动服务
echo -e "${YELLOW}>>> 正在启动 Caddy 服务...${NC}"
systemctl daemon-reload
systemctl enable --now caddy

# 完成输出
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}    NaiveProxy 安装完成！                      ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "你的域名: $DOMAIN"
echo -e "用户名: $USERNAME"
echo -e "密码: $PASSWORD"
if [[ "$ENABLE_HTTP" =~ ^[Yy]$ ]]; then
    echo -e "HTTP 代理端口: $HTTP_PORT"
    echo -e "HTTP 代理链接: ${CYAN}http://$USERNAME:$PASSWORD@$DOMAIN:$HTTP_PORT${NC} (明文传输)"
fi
echo -e ""
echo -e "${YELLOW}客户端 (naive.json) 配置参考:${NC}"
cat << EOF
{
  "listen": "socks://127.0.0.1:10801",
  "proxy": "https://$USERNAME:$PASSWORD@$DOMAIN"
}
EOF
echo -e "${GREEN}==============================================${NC}"
