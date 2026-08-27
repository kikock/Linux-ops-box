#!/bin/bash

# =================================================================
# 脚本名称: prepare_offline_image.sh
# 适用环境: 【有互联网连接的机器】
# 描述: 自动拉取 Nginx Proxy Manager 官方最新镜像并导出为 tar 离线包
# =================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

NPM_IMAGE="jc21/nginx-proxy-manager:latest"
OUTPUT_TAR="$(dirname "$(readlink -f "$0")")/npm_image.tar"

echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}   🚀 Nginx Proxy Manager 离线镜像导出工具            ${NC}"
echo -e "${CYAN}======================================================${NC}"

if ! command -v docker &>/dev/null; then
    echo -e "${RED}错误: 当前系统未安装 Docker，无法拉取镜像！${NC}"
    exit 1
fi

echo -e "⏳ [1/2] 正在拉取官方最新镜像: ${YELLOW}${NPM_IMAGE}${NC} ..."
docker pull "${NPM_IMAGE}"

echo -e "⏳ [2/2] 正在将镜像打包保存至: ${CYAN}${OUTPUT_TAR}${NC} ..."
docker save -o "${OUTPUT_TAR}" "${NPM_IMAGE}"

if [ -f "${OUTPUT_TAR}" ]; then
    TAR_SIZE=$(du -h "${OUTPUT_TAR}" | awk '{print $1}')
    echo ""
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}🎉 离线镜像包导出成功！${NC}"
    echo -e " 📦 离线文件: ${CYAN}${OUTPUT_TAR}${NC} (大小: ${YELLOW}${TAR_SIZE}${NC})"
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${YELLOW}下一步操作:${NC}"
    echo -e " 1. 将整个 ${CYAN}npm_offline_deploy${NC} 文件夹整体拷贝到目标无网服务器；"
    echo -e " 2. 在无网服务器上运行: ${CYAN}bash deploy_npm.sh${NC}"
    echo -e "${GREEN}======================================================${NC}"
else
    echo -e "${RED}❌ 导出失败，请检查磁盘空间！${NC}"
    exit 1
fi
