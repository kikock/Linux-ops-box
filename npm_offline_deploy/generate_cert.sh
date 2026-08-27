#!/bin/bash

# =================================================================
# 脚本名称: generate_cert.sh
# 适用环境: 【完全离线 / 无网环境】
# 描述: 离线生成带 SAN (Subject Alternative Name) 的 SSL/TLS 自签证书
# =================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CERTS_OUT_DIR="$SCRIPT_DIR/certs"
mkdir -p "$CERTS_OUT_DIR"

echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}        🔒 离线 SSL/TLS 域名自签证书生成器            ${NC}"
echo -e "${CYAN}======================================================${NC}"

# 1. 检查 OpenSSL
if ! command -v openssl &>/dev/null; then
    echo -e "${RED}错误: 系统未检测到 openssl 命令，请确保已预装 OpenSSL。${NC}"
    exit 1
fi

# 2. 交互式获取域名/IP
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
SERVER_IP=${SERVER_IP:-"127.0.0.1"}

echo -e "${YELLOW}请输入需要配置证书的域名 (例如: xxx.kikock.com):${NC}"
read -p "> " DOMAIN < /dev/tty
DOMAIN=${DOMAIN:-"xxx.kikock.com"}

echo -e "\n${YELLOW}请输入需要绑定的服务器 IP 地址 (默认: ${SERVER_IP}):${NC}"
read -p "> " BIND_IP < /dev/tty
BIND_IP=${BIND_IP:-$SERVER_IP}

SAFE_NAME=$(echo "$DOMAIN" | sed 's/[^a-zA-Z0-9._-]/_/g')
TARGET_DIR="$CERTS_OUT_DIR/$SAFE_NAME"
mkdir -p "$TARGET_DIR"

KEY_FILE="$TARGET_DIR/${SAFE_NAME}.key"
CRT_FILE="$TARGET_DIR/${SAFE_NAME}.crt"
PEM_FILE="$TARGET_DIR/${SAFE_NAME}.pem"

# 3. 构造包含 SAN (Subject Alternative Name) 的 OpenSSL 配置文件
# 严格注入 DNS 与 IP，确保 Chrome / Edge / Firefox 80+ 不报 Common Name 无效错误
TMP_CNF="/tmp/npm_san_$$.cnf"
cat > "$TMP_CNF" <<EOF
[req]
default_bits        = 2048
distinguished_name  = req_distinguished_name
req_extensions      = v3_req
x509_extensions     = v3_req
prompt              = no

[req_distinguished_name]
C  = CN
ST = Beijing
L  = Beijing
O  = Kikock-Network
OU = DevOps
CN = ${DOMAIN}

[v3_req]
basicConstraints     = CA:FALSE
keyUsage             = nonRepudiation, digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage     = serverAuth, clientAuth
subjectAltName       = @alt_names

[alt_names]
DNS.1 = ${DOMAIN}
DNS.2 = localhost
IP.1  = ${BIND_IP}
IP.2  = 127.0.0.1
EOF

echo -e "\n⏳ 正在生成 RSA 2048 位私钥与带 SAN 扩展的自签证书 (有效期 10 年 / 3650 天)..."
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out "$CRT_FILE" \
    -config "$TMP_CNF" 2>/dev/null

rm -f "$TMP_CNF"

chmod 600 "$KEY_FILE"
chmod 644 "$CRT_FILE"
cat "$CRT_FILE" "$KEY_FILE" > "$PEM_FILE"
chmod 600 "$PEM_FILE"

echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}🎉 证书离线生成成功！                                 ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e " 📁 存储目录:   ${CYAN}${TARGET_DIR}${NC}"
echo -e " 📜 证书文件:   ${GREEN}${CRT_FILE}${NC}"
echo -e " 🔑 私钥文件:   ${YELLOW}${KEY_FILE}${NC}"
echo -e "${CYAN}------------------------------------------------------${NC}"
echo -e "${YELLOW}▌ 证书 SAN 扩展详情:${NC}"
openssl x509 -in "$CRT_FILE" -noout -ext subjectAltName 2>/dev/null | grep -v "X509v3" | xargs || true
echo -e "${CYAN}======================================================${NC}"
echo -e "${GREEN}💡 在 Nginx Proxy Manager 中使用该证书的方法:${NC}"
echo -e " 1. 登录 NPM 后台 -> 点击「SSL Certificates」 -> 「Add SSL Certificate」 -> 选择「Custom」"
echo -e " 2. Name 填写: ${CYAN}${DOMAIN}${NC}"
echo -e " 3. Certificate Key 项填入: ${YELLOW}${KEY_FILE}${NC} 的文本内容"
echo -e " 4. Certificate 项填入:     ${GREEN}${CRT_FILE}${NC} 的文本内容"
echo -e " 5. 点击 Save 保存后，在 Proxy Hosts 中绑定即可！"
echo -e "${GREEN}======================================================${NC}"
