#!/bin/bash
# =================================================================
# 脚本名称: install_docker.sh
# 描述: Docker \u0026 Docker Compose 智能管理与安装器 (v2.2)
# 功能: 版本自适应采集、下载校验、服务管理、一键全自动部署
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

# 基础环境变量环境探测
ARCH=$(uname -m)
DOCKER_ARCH="x86_64"
[ "$ARCH" = "aarch64" ] && DOCKER_ARCH="aarch64"

# ================================================================
# 私有辅助函数: 网络探测与镜像分配
# ================================================================
_get_gh_mirror() {
    if curl -Is -m 3 "https://github.com" | head -1 | grep -qE 'HTTP/.*(200|301|302)'; then
        echo "https://github.com"
    else
        echo "https://ghproxy.net/https://github.com"
    fi
}

# ================================================================
# 1. 检测 Docker 当前安装状态与配置
# ================================================================
check_docker_status() {
    clear
    echo -e "${CYAN}================ Docker 运行状态与配置详情 ================${NC}"
    
    # 检测 Docker 核心引擎
    if command -v docker &>/dev/null; then
        local D_VER=$(docker -v)
        local D_STATUS=$(systemctl is-active docker 2>/dev/null || echo "未启动")
        echo -e " 📦 ${GREEN}Docker 引擎:${NC}  已安装 ($D_VER)"
        echo -e " 🚀 ${GREEN}运行状态:${NC}    $D_STATUS"
    else
        echo -e " 📦 ${RED}Docker 引擎:${NC}  未安装"
    fi

    # 检测 Docker Compose 
    if command -v docker-compose &>/dev/null; then
        echo -e " 🛠  ${GREEN}Compose 状态:${NC} 已就绪 ($(docker-compose -v | head -1))"
    elif docker compose version &>/dev/null; then
        echo -e " 🛠  ${GREEN}Compose 状态:${NC} 已就绪 (Docker V2 Plugin)"
    else
        echo -e " 🛠  ${RED}Compose 状态:${NC} 未检测到二进制文件"
    fi

    # 读取镜像加速器配置
    if [ -f /etc/docker/daemon.json ]; then
        echo -e "\n ${YELLOW}--- 镜像加速器配置 (/etc/docker/daemon.json) ---${NC}"
        cat /etc/docker/daemon.json
    fi
    
    echo -e "\n${CYAN}=========================================================${NC}"
    read -p "按回车键返回菜单..."
}

# ================================================================
# 2. Docker 服务管理 (启动/停止/重启/自启控制)
# ================================================================
manage_docker_service() {
    while true; do
        clear
        local STATUS=$(systemctl is-active docker 2>/dev/null || echo "未安装或未启动")
        echo -e "${BLUE}================ Docker 管理指令集 (服务级) ================${NC}"
        echo -e " 当前 Docker 状态: ${YELLOW}$STATUS${NC}"
        echo " 1. 启动 Docker"
        echo " 2. 停止 Docker"
        echo " 3. 重启 Docker"
        echo " 4. 启用 开机自启"
        echo " 5. 禁用 开机自启"
        echo " 0. 返回上级"
        echo -e "${BLUE}=========================================================${NC}"
        read -p "选择指令 [0-5]: " cmd_choice
        case $cmd_choice in
            1) systemctl start docker && echo -e "${GREEN}启动指令已发出。${NC}" ;;
            2) systemctl stop docker && echo -e "${YELLOW}停止指令已发出。${NC}" ;;
            3) systemctl restart docker && echo -e "${GREEN}重启指令已发出。${NC}" ;;
            4) systemctl enable docker && echo -e "${GREEN}开机自启已设置。${NC}" ;;
            5) systemctl disable docker && echo -e "${YELLOW}开机自启已禁用。${NC}" ;;
            0) break ;;
        esac
        sleep 1
    done
}

# ================================================================
# 3. 核心安装逻辑 (含版本抓取与下载校验)
# ================================================================
perform_install() {
    clear
    echo -e "${CYAN}--- 自动化版本检索机制启动 ---${NC}"
    
    local MIRROR=$(_get_gh_mirror)
    echo -e "  🌐 镜像采集线路: ${MIRROR}"

    # 精准抓取 Docker 静态版三段式版号 (如 27.x.x)
    echo -e "  ⏳ 正在采集 Docker 官方静态离线源列表..."
    local DOCKER_URL="https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/"
    local RAW_D_TAGS=$(curl -sL --connect-timeout 5 "$DOCKER_URL" | grep -oE 'docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz' | sed 's/docker-//;s/\.tgz//' | sort -uV | tail -n 8)
    
    # 填充数组 
    IFS=$'\n' read -rd '' -a D_VERSIONS <<<"$RAW_D_TAGS"
    
    if [ ${#D_VERSIONS[@]} -eq 0 ]; then
        echo -e "${YELLOW}⚠ 无法动态解析官网版本，启用默认推荐版 (26.1.3)${NC}"
        D_VERSIONS=("24.0.9" "25.0.3" "26.1.3")
    fi

    # 精准抓取 Compose V2.x 的稳定发行版 (过滤 alpha/rc)
    echo -e "  ⏳ 正在采集 Docker Compose 发布记录 (GitHub API)..."
    local RAW_C_TAGS=$(curl -sL --connect-timeout 5 "https://api.github.com/repos/docker/compose/releases" | grep '"tag_name":' | grep -oE 'v2\.[0-9]+\.[0-9]+' | sort -ur | head -n 6)
    IFS=$'\n' read -rd '' -a C_VERSIONS <<<"$RAW_C_TAGS"
    
    if [ ${#C_VERSIONS[@]} -eq 0 ]; then
        echo -e "${YELLOW}⚠ GitHub 抓取受阻，启用默认推荐版 (v2.28.1)${NC}"
        C_VERSIONS=("v2.26.1" "v2.27.0" "v2.28.1")
    fi

    echo -e "\n${BLUE}--- 可供安装的版本对齐如下 ---${NC}"
    echo -e " [Docker 推荐]: ${YELLOW}${D_VERSIONS[*]}${NC}"
    echo -e " [Compose 推荐]: ${YELLOW}${C_VERSIONS[*]}${NC}"
    echo -e "${BLUE}---------------------------------${NC}"

    local DEFAULT_D="${D_VERSIONS[-1]}"
    local DEFAULT_C="${C_VERSIONS[0]}"

    read -p "请输入 Docker 版本 (默认 $DEFAULT_D): " CHOSEN_D
    CHOSEN_D=${CHOSEN_D:-$DEFAULT_D}
    read -p "请输入 Compose 版本 (默认 $DEFAULT_C): " CHOSEN_C
    CHOSEN_C=${CHOSEN_C:-$DEFAULT_C}

    echo -e "\n🚀 ${GREEN}任务开始: 安装 Docker $CHOSEN_D \u0026 Compose $CHOSEN_C${NC}"

    # 1. 下载 Docker 并校验文件格式
    local D_DL_URL="https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/docker-${CHOSEN_D}.tgz"
    echo -e "${YELLOW} -> 正在拉取 Docker 核心镜像包...${NC}"
    rm -f /tmp/docker_bin.tgz /tmp/docker -rf
    if ! curl -L -f -# -o /tmp/docker_bin.tgz "$D_DL_URL"; then
        echo -e "${RED}致命错误: Docker 版本包下载失败 (404)，该版本可能已官方下架。${NC}"
        return 1
    fi
    
    # 2. 下载 Compose 
    local C_DL_URL="${MIRROR}/docker/compose/releases/download/${CHOSEN_C}/docker-compose-linux-${DOCKER_ARCH}"
    echo -e "${YELLOW} -> 正在拉取 Docker Compose 工具包...${NC}"
    if ! curl -L -f -# -o /usr/local/bin/docker-compose "$C_DL_URL"; then
         echo -e "${RED}致命错误: Compose 版本下载失败 (404)。${NC}"
         return 1
    fi

    # 执行解压注入
    echo -e "${YELLOW} -> 正在解压并挂载系统调令...${NC}"
    tar -xzf /tmp/docker_bin.tgz -C /tmp/
    cp -f /tmp/docker/* /usr/bin/
    chmod +x /usr/local/bin/docker-compose
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

    # 构建并注册服务 (Daemon Config)
    if [ ! -f /etc/systemd/system/docker.service ]; then
        cat > /etc/systemd/system/docker.service << 'EOF'
[Unit]
Description=Docker Application Container Engine
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
    fi

    systemctl daemon-reload
    systemctl enable --now docker
    
    echo -e "\n${GREEN}🎉 部署完成! 当前系统响应:${NC}"
    docker -v
    docker-compose -v
    read -p "安装工作已就绪，按回车返回菜单..."
}

# ================================================================
# 4. 彻底卸载 Docker 及其组件
# ================================================================
perform_uninstall() {
    clear
    echo -e "${RED}==================== 危险: 彻底卸载 Docker ====================${NC}"
    echo -e " 该操作将停止所有正运行容器，并清除所有二进制程序与配置文件。"
    read -p " 是否确认彻底清除系统中的 Docker? (y/N): " confirm_un
    if [[ "$confirm_un" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW} [1/3] 停止并禁用 Docker 服务层...${NC}"
        systemctl stop docker 2>/dev/null
        systemctl disable docker 2>/dev/null
        
        echo -e "${YELLOW} [2/3] 清除核心二进制文件与快捷方式...${NC}"
        rm -f /usr/bin/docker* /usr/bin/containerd* /usr/bin/runc /usr/bin/ctr
        rm -f /usr/local/bin/docker-compose /usr/bin/docker-compose
        rm -f /etc/systemd/system/docker.service
        
        echo -e "${YELLOW} [3/3] 重刷系统总线配置...${NC}"
        systemctl daemon-reload
        echo -e "${GREEN} 卸载任务圆满终止。${NC}"
    else
        echo -e " 已取消操作。"
    fi
    read -p "按回车键返回菜单..."
}

# ================================================================
# 0. 主逻辑循环 (TUI 结构)
# ================================================================
while true; do
    clear
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}       Docker \u0026 Compose 管理中心 (ck_sysinit)   ${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo " 1. 查看监控/状态与配置"
    echo " 2. Docker 服务指令管理 (启动/停止/重启)"
    echo " 3. 执行在线安装/更新任务"
    echo " 4. 彻底卸载 Docker 套件"
    echo " 0. 退出管理窗口"
    echo -e "${GREEN}==============================================${NC}"
    read -p "请选择交互选项 [0-4]: " main_choice

    case "$main_choice" in
        1) check_docker_status ;;
        2) manage_docker_service ;;
        3) perform_install ;;
        4) perform_uninstall ;;
        0) echo -e " 退出中..."; exit 0 ;;
        *) echo -e "${RED} 无效参数${NC}"; sleep 1 ;;
    esac
done
