#!/bin/bash
# =================================================================
# 脚本名称: install_docker.sh
# 描述: Docker & Docker Compose 智能管理与安装器 (v2.3)
# 功能: 版本自适应采集、进度可视化、服务管理、一键全自动部署
# =================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 该工具需要 root 权限，请使用 sudo 执行。${NC}"
   exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)          DOCKER_ARCH="x86_64";  COMPOSE_ARCH="x86_64" ;;
    aarch64|arm64)   DOCKER_ARCH="aarch64"; COMPOSE_ARCH="aarch64" ;;
    armv7l|armv7)    DOCKER_ARCH="armhf";   COMPOSE_ARCH="armv7" ;;
    armv6l|armv6)    DOCKER_ARCH="armel";   COMPOSE_ARCH="armv6" ;;
    ppc64le)         DOCKER_ARCH="ppc64le"; COMPOSE_ARCH="ppc64le" ;;
    s390x)           DOCKER_ARCH="s390x";   COMPOSE_ARCH="s390x" ;;
    *)
        echo -e "${YELLOW}警告: 未知架构 $ARCH，默认使用 x86_64。${NC}"
        DOCKER_ARCH="x86_64"; COMPOSE_ARCH="x86_64" ;;
esac

# ================================================================
# 辅助函数
# ================================================================
_get_gh_mirror() {
    if [ -n "$LINUX_OPS_BOX_PROXY" ]; then
        if [ "$LINUX_OPS_BOX_PROXY" = "https://github.com" ]; then
            echo "https://github.com"
        else
            echo "${LINUX_OPS_BOX_PROXY%/}/https://github.com"
        fi
    else
        # 1. 尝试直连 Github
        local is_direct_ok=false
        if command -v curl &>/dev/null; then
            if curl -Is -m 2 "https://github.com" | head -1 | grep -qE 'HTTP/.*(200|301|302)'; then
                is_direct_ok=true
            fi
        elif command -v wget &>/dev/null; then
            if wget --spider -q -T 2 "https://github.com" &>/dev/null; then
                is_direct_ok=true
            fi
        fi

        if [ "$is_direct_ok" = "true" ]; then
            echo "https://github.com"
        else
            # 2. 如果直连不通，智能测试并分配国内可用加速通道
            # 注意：此处因是子 shell 变量捕获调用，所有的进度交互提示 echo 必须重定向至标准错误 >&2
            echo -e "  ${YELLOW}⏳ GitHub 直连受阻，正在智能探测并分配国内可用加速通道...${NC}" >&2
            local candidates=(
                "https://ghproxy.net"
                "https://mirror.ghproxy.com"
                "https://gh-proxy.com"
            )
            local best_mirror="https://ghproxy.net/https://github.com" # 默认兜底
            local matched=false
            
            for candidate in "${candidates[@]}"; do
                echo -n "     ➜ 测试加速通道 [${candidate}] ... " >&2
                local check_url="${candidate}/https://github.com"
                local reachable=false
                if command -v curl &>/dev/null; then
                    if curl -Is -m 2 "$check_url" &>/dev/null; then
                        reachable=true
                    fi
                elif command -v wget &>/dev/null; then
                    if wget --spider -q -T 2 "$check_url" &>/dev/null; then
                        reachable=true
                    fi
                fi
                
                if [ "$reachable" = "true" ]; then
                    echo -e "${GREEN}正常可用${NC}" >&2
                    best_mirror="${candidate}/https://github.com"
                    matched=true
                    break
                else
                    echo -e "${RED}不可用${NC}" >&2
                fi
            done
            
            if [ "$matched" = "false" ]; then
                echo -e "  ${RED}❌ 警告: 所有内置加速源均无法连通，将回退至默认加速源进行尝试。${NC}" >&2
            fi
            
            echo "$best_mirror"
        fi
    fi
}

_check_docker_mirrors() {
    echo -e "${CYAN}>> 正在选择最快的 Docker 下载源...${NC}"
    local names=("mirrors.ustc.edu.cn/docker-ce" "mirrors.tuna.tsinghua.edu.cn/docker-ce" \
                 "mirrors.aliyun.com/docker-ce" "mirror.azure.cn/docker-ce" "download.docker.com")
    local t1="/dev/shm/dk1.pl" t2="/dev/shm/dk2.pl"
    rm -f $t1 $t2; touch $t1 $t2
    for s in "${names[@]}"; do
        local chk=$(curl -k -s -m 5 -w "%{http_code} %{time_total}" "https://${s}" -o /dev/null)
        local st=$(echo $chk | awk '{print $1}')
        local rtt=$(echo $chk | awk '{print $2*1000}' | cut -d. -f1)
        if [[ "$st" =~ ^(200|301|403)$ ]]; then
            [[ $rtt -lt 200 ]] && echo "$s" >> $t1 || echo "$rtt $s" >> $t2
        fi
    done
    local best=$(head -n1 $t1)
    [[ -z "$best" ]] && best=$(sort -n $t2 | head -n1 | awk '{print $2}')
    [[ -z "$best" ]] && best="download.docker.com"
    rm -f $t1 $t2
    case "$best" in
        *aliyun*)      DOCKER_BASE_URL="https://mirrors.aliyun.com/docker-ce" ;;
        *azure.cn*)    DOCKER_BASE_URL="https://mirror.azure.cn/docker-ce" ;;
        *ustc*)        DOCKER_BASE_URL="https://mirrors.ustc.edu.cn/docker-ce" ;;
        *tsinghua*)    DOCKER_BASE_URL="https://mirrors.tuna.tsinghua.edu.cn/docker-ce" ;;
        *)             DOCKER_BASE_URL="https://download.docker.com" ;;
    esac
    echo -e "   ${GREEN}[OK]${NC} 已选源: ${GREEN}${DOCKER_BASE_URL}${NC}"
}

_get_dist_info() {
    if [ -r /etc/os-release ]; then
        LSB_DIST=$(. /etc/os-release && echo "$ID" | tr '[:upper:]' '[:lower:]')
        DIST_VERSION=$(. /etc/os-release && echo "$VERSION_ID")
        DIST_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
    fi
}

# 带标题进度条的 curl 下载封装
# 用法: _curl_dl "标题" "URL" "目标路径"
_curl_dl() {
    local label="$1" url="$2" dest="$3"
    echo ""
    echo -e "${BOLD}${CYAN}  +----------------------------------------------------------+${NC}"
    printf  "${BOLD}${CYAN}  |  %-56s|${NC}\n" "正在下载: $label"
    echo -e "${BOLD}${CYAN}  +----------------------------------------------------------+${NC}"
    echo -e "  ${YELLOW}来源:${NC} $url"
    echo ""
    if curl -L -f --progress-bar --stderr - -o "$dest" "$url"; then
        echo ""
        echo -e "  ${GREEN}[完成]${NC} $label  下载成功 ✓"
    else
        echo ""
        echo -e "  ${RED}[失败]${NC} $label  下载失败，请检查网络或版本号"
        return 1
    fi
}

# 安装完成命令速查表
_print_cheatsheet() {
    local dv="${1:-未知}" cv="${2:-未知}"
    echo ""
    echo -e "${GREEN}+======================================================+${NC}"
    echo -e "${GREEN}|           [OK]  Docker 部署完成！                   |${NC}"
    echo -e "${GREEN}+------------------------------------------------------+${NC}"
    printf  "${GREEN}|  Engine : %-42s|${NC}\n" "$dv"
    printf  "${GREEN}|  Compose: %-42s|${NC}\n" "$cv"
    echo -e "${GREEN}+======================================================+${NC}"
    echo ""
    echo -e "${CYAN}+=================== Docker & Compose 常用命令速查 ===================+${NC}"
    echo -e "${YELLOW}  [ 服务管理 ]${NC}"
    echo    "   systemctl start   docker        # 启动 Docker 服务"
    echo    "   systemctl stop    docker        # 停止 Docker 服务"
    echo    "   systemctl restart docker        # 重启 Docker 服务"
    echo    "   systemctl status  docker        # 查看服务运行状态"
    echo    "   systemctl enable  docker        # 设置开机自启"
    echo ""
    echo -e "${YELLOW}  [ 镜像管理 ]${NC}"
    echo    "   docker pull  <image>            # 拉取镜像"
    echo    "   docker images                   # 列出本地镜像"
    echo    "   docker rmi   <image>            # 删除镜像"
    echo    "   docker save  <image> -o f.tar   # 导出镜像到文件"
    echo    "   docker load  -i f.tar           # 从文件导入镜像"
    echo ""
    echo -e "${YELLOW}  [ 容器管理 ]${NC}"
    echo    "   docker run -d -p 80:80 <image>  # 后台运行容器并映射端口"
    echo    "   docker ps                        # 查看运行中的容器"
    echo    "   docker ps -a                     # 查看所有容器（含已停止）"
    echo    "   docker exec -it <id> /bin/bash   # 进入运行中的容器"
    echo    "   docker logs -f <id>              # 实时跟踪容器日志"
    echo    "   docker inspect <id>              # 查看容器详细信息"
    echo    "   docker stop  <id>                # 停止容器"
    echo    "   docker rm    <id>                # 删除已停止的容器"
    echo    "   docker rm -f <id>                # 强制删除运行中的容器"
    echo ""
    echo -e "${YELLOW}  [ Compose 编排 ]${NC}"
    echo    "   docker compose up -d             # 后台启动所有服务"
    echo    "   docker compose down              # 停止并移除容器/网络"
    echo    "   docker compose down -v           # 同上并删除数据卷"
    echo    "   docker compose restart           # 重启所有服务"
    echo    "   docker compose logs -f           # 实时查看编排日志"
    echo    "   docker compose ps                # 查看服务状态"
    echo    "   docker compose pull              # 更新所有服务镜像"
    echo    "   docker compose exec <svc> sh     # 进入指定服务容器"
    echo    "   docker-compose <cmd>             # 兼容旧版 v1 命令"
    echo ""
    echo -e "${YELLOW}  [ 系统清理 ]${NC}"
    echo    "   docker system df                 # 查看磁盘占用"
    echo    "   docker system prune -af          # 清理所有未使用资源"
    echo    "   docker volume prune              # 清理未挂载数据卷"
    echo    "   docker image  prune -af          # 清理悬空镜像"
    echo -e "${CYAN}+=====================================================================+${NC}"
    echo ""
    read -p "  安装已就绪，按回车返回菜单..." < /dev/tty
}

# ================================================================
# 1. 检查 Docker 状态与配置
# ================================================================
check_docker_status() {
    clear
    echo -e "${CYAN}+================ Docker 运行状态与配置详情 ================+${NC}"
    if command -v docker &>/dev/null; then
        local dv=$(docker -v)
        local ds=$(systemctl is-active docker 2>/dev/null || echo "未启动")
        echo -e "  Docker 引擎:  ${GREEN}已安装${NC} ($dv)"
        echo -e "  运行状态:     ${GREEN}$ds${NC}"
    else
        echo -e "  Docker 引擎:  ${RED}未安装${NC}"
    fi
    if command -v docker-compose &>/dev/null; then
        echo -e "  Compose 状态: ${GREEN}已就绪${NC} ($(docker-compose -v | head -1))"
    elif docker compose version &>/dev/null 2>&1; then
        echo -e "  Compose 状态: ${GREEN}已就绪${NC} (Docker V2 Plugin)"
    else
        echo -e "  Compose 状态: ${RED}未检测到${NC}"
    fi
    if [ -f /etc/docker/daemon.json ]; then
        echo -e "\n  ${YELLOW}--- /etc/docker/daemon.json ---${NC}"
        cat /etc/docker/daemon.json
    fi
    echo -e "${CYAN}+===========================================================+${NC}"
    read -p "按回车键返回菜单..." < /dev/tty
}

# ================================================================
# 2. Docker 服务管理
# ================================================================
manage_docker_service() {
    while true; do
        clear
        local st=$(systemctl is-active docker 2>/dev/null || echo "未安装/未启动")
        echo -e "${BLUE}+================ Docker 服务指令管理 ================+${NC}"
        echo -e "  当前状态: ${YELLOW}$st${NC}"
        echo -e "${BLUE}+-----------------------------------------------------+${NC}"
        echo "  1. 启动 Docker"
        echo "  2. 停止 Docker"
        echo "  3. 重启 Docker"
        echo "  4. 启用开机自启"
        echo "  5. 禁用开机自启"
        echo "  0. 返回上级"
        echo -e "${BLUE}+=====================================================+${NC}"
        read -p "选择指令 [0-5]: " c < /dev/tty
        case $c in
            1) systemctl start   docker && echo -e "${GREEN}启动成功。${NC}" ;;
            2) systemctl stop    docker && echo -e "${YELLOW}已停止。${NC}" ;;
            3) systemctl restart docker && echo -e "${GREEN}重启成功。${NC}" ;;
            4) systemctl enable  docker && echo -e "${GREEN}开机自启已启用。${NC}" ;;
            5) systemctl disable docker && echo -e "${YELLOW}开机自启已禁用。${NC}" ;;
            0) break ;;
        esac
        sleep 1
    done
}

# ================================================================
# 3. 安装模式选择
# ================================================================
perform_install() {
    clear
    _get_dist_info
    _check_docker_mirrors
    echo ""
    echo -e "${BLUE}+================ 安装模式选择 ================+${NC}"
    echo "  1. [推荐] 软件包模式  (Repo 自动管理依赖)"
    echo "  2. [兼容] 静态编译模式 (解压即用，适合全发行版)"
    echo -e "${BLUE}+===============================================+${NC}"
    read -p "请选择 [1-2, 默认2]: " mode < /dev/tty
    mode=${mode:-2}
    [ "$mode" == "1" ] && install_via_repo || install_via_binary
}

# ================================================================
# 3a. 软件包模式
# ================================================================
install_via_repo() {
    echo -e "\n${CYAN}>> 软件包模式安装 Docker...${NC}"
    case "$LSB_DIST" in
        ubuntu|debian|raspbian)
            apt-get update -qq
            apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
            mkdir -p /etc/apt/keyrings
            curl -fsSL "${DOCKER_BASE_URL}/linux/${LSB_DIST}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_BASE_URL}/linux/${LSB_DIST} ${DIST_CODENAME:-$DIST_VERSION} stable" > /etc/apt/sources.list.d/docker.list
            apt-get update -qq
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        centos|rhel|ol|tencentos|alinux|anolis|rocky|almalinux|opencloudos|openeuler|hce|uos|amzn)
            yum install -y yum-utils
            local rd=$LSB_DIST
            [[ "$LSB_DIST" =~ ^(ol|tencentos|alinux|anolis|opencloudos|openeuler|hce|uos|amzn|rocky|almalinux)$ ]] && rd="centos"
            yum-config-manager --add-repo "${DOCKER_BASE_URL}/linux/${rd}/docker-ce.repo"
            sed -i "s|https://download.docker.com|${DOCKER_BASE_URL}|g" /etc/yum.repos.d/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            ;;
        *)
            echo -e "${RED}不支持的发行版: $LSB_DIST，请使用静态编译模式。${NC}"
            return 1 ;;
    esac
    systemctl daemon-reload
    systemctl enable --now docker
    local dv=$(docker -v 2>/dev/null || echo "读取失败")
    local cv="Plugin"
    docker compose version &>/dev/null 2>&1 && cv=$(docker compose version --short 2>/dev/null)
    _print_cheatsheet "$dv" "docker compose $cv (plugin)"
}

# ================================================================
# 3b. 静态编译模式（进度优化版）
# ================================================================
install_via_binary() {
    clear
    echo -e "${CYAN}+======================================================+${NC}"
    echo -e "${CYAN}|     静态编译模式 — 自动化版本检索与部署             |${NC}"
    echo -e "${CYAN}+======================================================+${NC}"

    local MIRROR=$(_get_gh_mirror)
    echo -e "  GitHub 代理: ${GREEN}${MIRROR}${NC}"

    local STATIC_URL="https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/"
    [[ "$DOCKER_BASE_URL" != *"download.docker.com"* ]] && \
        STATIC_URL="${DOCKER_BASE_URL}/linux/static/stable/${DOCKER_ARCH}/"

    echo -e "\n  >> 采集 Docker Engine 版本列表..."
    local RAW_D=$(curl -sL --connect-timeout 8 "$STATIC_URL" | \
        grep -oE 'docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz' | \
        sed 's/docker-//;s/\.tgz//' | sort -uV | tail -n 8)
    IFS=$'\n' read -rd '' -a D_VERS <<< "$RAW_D"
    [ ${#D_VERS[@]} -eq 0 ] && D_VERS=("24.0.9" "25.0.3" "26.1.3" "27.0.3") && \
        echo -e "  ${YELLOW}>> 使用内置推荐版本${NC}"

    echo -e "  >> 采集 Docker Compose 版本列表..."
    local RAW_C=$(curl -sL --connect-timeout 8 "${MIRROR}/docker/compose/releases" | \
        grep -oE 'v2\.[0-9]+\.[0-9]+' | sort -ur | head -n 6)
    IFS=$'\n' read -rd '' -a C_VERS <<< "$RAW_C"
    [ ${#C_VERS[@]} -eq 0 ] && C_VERS=("v2.26.1" "v2.27.0" "v2.28.1")

    local DEF_D="${D_VERS[-1]}" DEF_C="${C_VERS[0]}"
    echo ""
    echo -e "  可用 Engine 版本:  ${YELLOW}${D_VERS[*]}${NC}"
    read -p "  Docker Engine 版本 [默认 $DEF_D]: " CHOSEN_D < /dev/tty
    CHOSEN_D=${CHOSEN_D:-$DEF_D}

    echo ""
    echo -e "  可用 Compose 版本: ${YELLOW}${C_VERS[*]}${NC}"
    read -p "  Docker Compose 版本 [默认 $DEF_C]: " CHOSEN_C < /dev/tty
    CHOSEN_C=${CHOSEN_C:-$DEF_C}

    echo ""
    echo -e "${CYAN}+======================================================+${NC}"
    echo -e "${CYAN}|             部署计划确认                             |${NC}"
    echo -e "${CYAN}+------------------------------------------------------+${NC}"
    printf  "${CYAN}|  Docker Engine : ${GREEN}%-36s${CYAN}|${NC}\n" "$CHOSEN_D"
    printf  "${CYAN}|  Docker Compose: ${GREEN}%-36s${CYAN}|${NC}\n" "$CHOSEN_C"
    printf  "${CYAN}|  目标架构      : ${GREEN}%-36s${CYAN}|${NC}\n" "$DOCKER_ARCH"
    echo -e "${CYAN}+======================================================+${NC}"
    echo ""

    local D_URL="${STATIC_URL}docker-${CHOSEN_D}.tgz"
    local C_URL="${MIRROR}/docker/compose/releases/download/${CHOSEN_C}/docker-compose-linux-${COMPOSE_ARCH}"

    # [1/4] 下载 Docker Engine
    echo -e "${GREEN}[1/4]${NC} 下载 Docker Engine  ${YELLOW}${CHOSEN_D}${NC}"
    rm -rf /tmp/docker_bin.tgz /tmp/docker
    _curl_dl "Docker Engine v${CHOSEN_D} (${DOCKER_ARCH})" "$D_URL" "/tmp/docker_bin.tgz" || return 1

    # [2/4] 下载 Docker Compose
    echo ""
    echo -e "${GREEN}[2/4]${NC} 下载 Docker Compose ${YELLOW}${CHOSEN_C}${NC}"
    _curl_dl "Docker Compose ${CHOSEN_C} (${COMPOSE_ARCH})" "$C_URL" "/usr/local/bin/docker-compose" || return 1

    # [3/4] 解压部署
    echo ""
    echo -e "${GREEN}[3/4]${NC} 解压并部署二进制文件..."
    tar -xzf /tmp/docker_bin.tgz -C /tmp/
    cp -f /tmp/docker/* /usr/bin/
    chmod +x /usr/local/bin/docker-compose
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    echo -e "  ${GREEN}[OK]${NC} 二进制文件已部署至 /usr/bin/"

    if [ ! -f /etc/systemd/system/docker.service ]; then
        cat > /etc/systemd/system/docker.service << 'SVCEOF'
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
SVCEOF
        echo -e "  ${GREEN}[OK]${NC} systemd 服务单元已写入"
    fi

    # [4/4] 启动服务
    echo ""
    echo -e "${GREEN}[4/4]${NC} 启动并注册 Docker 服务..."
    systemctl daemon-reload
    systemctl enable --now docker
    sleep 2
    echo -e "  ${GREEN}[OK]${NC} Docker 服务已启动"

    local DV=$(docker -v 2>/dev/null || echo "读取失败")
    local CV=$(docker-compose -v 2>/dev/null | head -1 || echo "读取失败")
    _print_cheatsheet "$DV" "$CV"
}

# ================================================================
# 4. 彻底卸载
# ================================================================
perform_uninstall() {
    clear
    echo -e "${RED}+=============== 危险: 彻底卸载 Docker ===============+${NC}"
    echo -e "  此操作将停止所有容器并清除所有 Docker 相关文件。"
    read -p "  确认彻底卸载? (y/N): " yn < /dev/tty
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}  [1/3] 停止并禁用服务...${NC}"
        systemctl stop    docker 2>/dev/null
        systemctl disable docker 2>/dev/null
        echo -e "${YELLOW}  [2/3] 清除二进制文件...${NC}"
        rm -f /usr/bin/docker* /usr/bin/containerd* /usr/bin/runc /usr/bin/ctr
        rm -f /usr/local/bin/docker-compose /usr/bin/docker-compose
        rm -f /etc/systemd/system/docker.service
        echo -e "${YELLOW}  [3/3] 重刷 systemd 配置...${NC}"
        systemctl daemon-reload
        echo -e "${GREEN}  [OK] 卸载完成。${NC}"
    else
        echo -e "  已取消。"
    fi
    read -p "按回车键返回菜单..." < /dev/tty
}

# ================================================================
# 主循环 (TUI)
# ================================================================
while true; do
    D_SHORT="未安装"
    command -v docker &>/dev/null && D_SHORT=$(docker -v | awk '{print $3}' | tr -d ',')
    C_SHORT="未安装"
    if command -v docker-compose &>/dev/null; then
        C_SHORT="已就绪"
    elif docker compose version &>/dev/null 2>&1; then
        C_SHORT="V2(Plugin)"
    fi

    clear
    echo -e "${GREEN}+======================================================+${NC}"
    echo -e "${GREEN}|       Docker & Compose 管理中心 (ck_sysinit)         |${NC}"
    echo -e "${GREEN}+------------------------------------------------------+${NC}"
    echo -e "  引擎: ${YELLOW}${D_SHORT}${NC}   |   Compose: ${YELLOW}${C_SHORT}${NC}"
    echo -e "${GREEN}+------------------------------------------------------+${NC}"
    echo "  1. 查看监控/详细配置 (daemon.json)"
    echo "  2. Docker 服务指令管理 (启动/停止/重启/自启)"
    echo "  3. 执行安装 / 覆盖更新"
    echo "  4. 彻底卸载 Docker 及其组件"
    echo "  0. 退出"
    echo -e "${GREEN}+======================================================+${NC}"
    read -p "请选择 [0-4]: " ch < /dev/tty
    case "$ch" in
        1) check_docker_status ;;
        2) manage_docker_service ;;
        3) perform_install ;;
        4) perform_uninstall ;;
        0) echo "  退出中..."; exit 0 ;;
        *) echo -e "${RED}  无效参数${NC}"; sleep 1 ;;
    esac
done