#!/bin/bash

# =================================================================
# 脚本名称: deploy_npm.sh
# 适用环境: 【无网/内网目标服务器】
# 描述: 自动导入离线 NPM 镜像并启动 Nginx Proxy Manager 容器
# =================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
cd "$SCRIPT_DIR"

echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}      📦 Nginx Proxy Manager 离线一键部署程序         ${NC}"
echo -e "${CYAN}======================================================${NC}"

# 1. 检查 Docker 环境
if ! command -v docker &>/dev/null; then
    echo -e "${RED}错误: 未检测到 Docker 环境！请先安装 Docker。${NC}"
    exit 1
fi

# 2. 检查并导入离线镜像包
IMAGE_NAME="jc21/nginx-proxy-manager:latest"
TAR_FILE="$SCRIPT_DIR/npm_image.tar"

if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^jc21/nginx-proxy-manager:latest"; then
    if [ -f "$TAR_FILE" ]; then
        echo -e "⏳ 发现离线镜像包: ${YELLOW}${TAR_FILE}${NC}，正在执行 docker load ..."
        docker load -i "$TAR_FILE"
        echo -e "${GREEN}✓ 离线镜像加载成功！${NC}"
    else
        echo -e "${RED}错误: 未找到本地镜像 ${IMAGE_NAME}，且未在当前目录下发现 ${TAR_FILE}${NC}"
        echo -e "请在有网电脑运行 prepare_offline_image.sh 导出 npm_image.tar 后拷贝至本目录。"
        exit 1
    fi
else
    echo -e "${GREEN}✓ 检测到系统中已存在 NPM 镜像: ${IMAGE_NAME}${NC}"
fi

# 3. 创建数据与证书挂载目录
mkdir -p "$SCRIPT_DIR/data"
mkdir -p "$SCRIPT_DIR/letsencrypt"
mkdir -p "$SCRIPT_DIR/certs"

# 4. 检查 80 / 443 / 81 端口占用
for port in 80 443 81; do
    if ss -tlpn 2>/dev/null | grep -q ":${port} "; then
        echo -e "${YELLOW}警告: 宿主机端口 ${port} 疑似已被占用，可能导致 NPM 启动冲突！${NC}"
    fi
done

# 5. 启动容器
echo -e "\n⏳ 正在启动 Nginx Proxy Manager 容器..."
if command -v docker-compose &>/dev/null; then
    docker-compose down 2>/dev/null || true
    docker-compose up -d
elif docker compose version &>/dev/null; then
    docker compose down 2>/dev/null || true
    docker compose up -d
else
    # 纯 Docker 启动兼容
    docker stop nginx-proxy 2>/dev/null || true
    docker rm nginx-proxy 2>/dev/null || true
    docker run -d \
      --name nginx-proxy \
      --restart unless-stopped \
      --add-host host.docker.internal:host-gateway \
      -p 80:80 \
      -p 443:443 \
      -p 81:81 \
      -v "$SCRIPT_DIR/data:/data" \
      -v "$SCRIPT_DIR/letsencrypt:/etc/letsencrypt" \
      -v "$SCRIPT_DIR/certs:/certs:ro" \
      jc21/nginx-proxy-manager:latest
fi

echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}🎉 Nginx Proxy Manager 离线部署完成！                 ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e " 🌐 管理后台地址: ${CYAN}http://<服务器IP>:81${NC}"
echo -e " 👤 默认登录账号: ${YELLOW}admin@example.com${NC}"
echo -e " 🔑 默认初始密码: ${YELLOW}changeme${NC}"
echo -e "${CYAN}------------------------------------------------------${NC}"
echo -e "${YELLOW}下一步:${NC}"
echo -e " 1. 运行 ${CYAN}bash generate_cert.sh${NC} 离线生成自签证书；"
echo -e " 2. 登录 NPM 后台在「SSL Certificates」中录入证书；"
echo -e " 3. 在「Proxy Hosts」中配置将域名反代到 8080 端口。"
echo -e "${GREEN}======================================================${NC}"
