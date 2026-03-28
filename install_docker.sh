#!/bin/bash
# =================================================================
# 脚本名称: install_docker.sh
# 描述: Docker \u0026 Docker Compose 动态在线安装器 (剥离重构版)
# 特性: 自动爬取官方可用版本列表，自适应网络代理，纯净静态编译版注入
# =================================================================

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 安装向导需要 root 权限，请使用 sudo 执行。${NC}"
   exit 1
fi

clear
echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}      Docker 引擎及 Compose 终端快捷安装向导          ${NC}"
echo -e "${CYAN}======================================================${NC}"

# 架构判定
ARCH=$(uname -m)
DOCKER_ARCH=""
COMPOSE_ARCH=""
if [ "$ARCH" = "x86_64" ]; then
    DOCKER_ARCH="x86_64"
    COMPOSE_ARCH="x86_64"
elif [ "$ARCH" = "aarch64" ]; then
    DOCKER_ARCH="aarch64"
    COMPOSE_ARCH="aarch64"
else
    echo -e "${RED}致命错误: 当前架构 ${ARCH} 不受此静态化脚本支持！${NC}"
    exit 1
fi

# 网络访问判定及版本爬取
GH_MIRROR="https://github.com"
API_MIRROR="https://api.github.com"

echo -e "  ⏳ 正在探测中美线路延迟，以决定是否启用加速镜像池..."
if ! curl -Is -m 3 "https://github.com/docker" | head -1 | grep -qE 'HTTP/.*(200|301|302)'; then
    echo -e "${YELLOW}  ⚠ Github 直连状态不佳，启用国内代理加速通道 (ghproxy.net)...${NC}"
    GH_MIRROR="https://ghproxy.net/https://github.com"
fi

echo -e "  ⏳ 正在连线拉取可用版本列表..."

# 爬取 Docker 官方库静态包列表
DOCKER_URL="https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/"
DOCKER_TAGS=$(curl -sL -m 5 "$DOCKER_URL" 2>/dev/null | grep -o 'docker-[0-9\.]*\.tgz' | sed 's/docker-//;s/\.tgz//' | sort -uV | tail -n 6)
if [ -z "$DOCKER_TAGS" ]; then
    echo -e "${RED}警告: 无法获取 Docker 官方版本库，将提供通用兜底版本。${NC}"
    DOCKER_VERSIONS=("26.1.3" "25.0.3" "24.0.9")
else
    DOCKER_VERSIONS=($DOCKER_TAGS)
fi

# 爬取 Github Release 抓取 Docker Compose 列表
# 解决 Github API 次数限制，如果报错直接使用内置列表
COMPOSE_RES=$(curl -sL -m 5 "https://api.github.com/repos/docker/compose/releases" 2>/dev/null)
if echo "$COMPOSE_RES" | grep -q '"tag_name":'; then
    COMPOSE_TAGS=$(echo "$COMPOSE_RES" | grep '"tag_name":' | head -n 6 | cut -d '"' -f 4)
    COMPOSE_VERSIONS=($COMPOSE_TAGS)
else
    echo -e "${YELLOW}警告: Github API 抓取受限，载入已知推荐版本。${NC}"
    COMPOSE_VERSIONS=("v2.28.1" "v2.27.0" "v2.26.1" "v2.24.0")
fi

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${GREEN}   近期稳定可用版本 (由引擎动态计算得出) ${NC}"
echo -e "   -> Docker 引擎推荐: ${YELLOW}${DOCKER_VERSIONS[@]}${NC}"
echo -e "   -> Docker Compose: ${YELLOW}${COMPOSE_VERSIONS[@]}${NC}"
echo -e "${BLUE}======================================================${NC}\n"

DEFAULT_DOCKER="${DOCKER_VERSIONS[${#DOCKER_VERSIONS[@]}-1]}"
read -p "请输入您想要的 Docker 引擎版本 (直接回车默认: $DEFAULT_DOCKER): " CHOSEN_DOCKER
CHOSEN_DOCKER=${CHOSEN_DOCKER:-$DEFAULT_DOCKER}

DEFAULT_COMPOSE="${COMPOSE_VERSIONS[0]}"
read -p "请输入您想要的 Compose 版本 (直接回车默认: $DEFAULT_COMPOSE): " CHOSEN_COMPOSE
CHOSEN_COMPOSE=${CHOSEN_COMPOSE:-$DEFAULT_COMPOSE}

echo -e "\n${BLUE}👉 即将开始注入 Docker $CHOSEN_DOCKER 及 Compose $CHOSEN_COMPOSE ...${NC}"

# =================
# 下载与安装 Docker
# =================
echo -e "${YELLOW}[1/4] 拉取 Docker 静态核心压缩包 (${CHOSEN_DOCKER})...${NC}"
DL_DOCKER="https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/docker-${CHOSEN_DOCKER}.tgz"
rm -f /tmp/docker-latest.tgz /tmp/docker -rf
curl -L -# -o /tmp/docker-latest.tgz "$DL_DOCKER"

echo -e "${YELLOW}[2/4] 释放二进制引擎到系统全局池...${NC}"
tar -xzf /tmp/docker-latest.tgz -C /tmp/
cp -f /tmp/docker/* /usr/bin/

echo -e "${YELLOW}构建系统级守护进程配置 (docker.service)...${NC}"
cat > /etc/systemd/system/docker.service << 'EOF'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TimeoutStartSec=0
Delegate=yes
KillMode=process
Restart=on-failure
StartLimitBurst=3
StartLimitInterval=60s

[Install]
WantedBy=multi-user.target
EOF

# =================
# 下载与安装 Compose
# =================
echo -e "${YELLOW}[3/4] 拉取 Docker Compose 容器编排系统 (${CHOSEN_COMPOSE})...${NC}"
DL_COMPOSE="${GH_MIRROR}/docker/compose/releases/download/${CHOSEN_COMPOSE}/docker-compose-linux-${COMPOSE_ARCH}"
curl -L -# -o /usr/local/bin/docker-compose "$DL_COMPOSE"

echo -e "${YELLOW}创建 Compose 全局桥接软链接...${NC}"
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

# =================
# 启动自检
# =================
echo -e "${YELLOW}[4/4] 正在重载 systemd 守护兵团并激发内核...${NC}"
systemctl daemon-reload
systemctl enable --now docker

echo -e "\n${GREEN}================ 安装验证报告 ========================${NC}"
docker -v || echo -e "${RED}Docker 引擎启动存在异常，请检查 systemctl status docker${NC}"
docker-compose -v || echo -e "${RED}Docker Compose 链接异常。${NC}"
echo -e "${GREEN}======================================================${NC}"

# 垃圾回收
rm -f /tmp/docker-latest.tgz
rm -rf /tmp/docker
echo -e "${CYAN}🎉 Docker 平台总线架设完毕！${NC}"
exit 0
