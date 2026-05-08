#!/bin/bash

# =================================================================
# 模块名称: docker_mgmt.sh
# 描述: Docker & Compose 管理中心 (Linux-ops-box 集成模块 v2.3)
# 职责: 作为 ck_sysinit TUI 菜单的 Docker 管理子模块
# 架构: install_docker.sh 已合并入 system_init.sh 体系，
#       本模块内嵌完整功能，不再依赖外部脚本
# 依赖: common.sh (全局颜色变量 GREEN/RED/YELLOW/CYAN/BLUE/NC)
# =================================================================

# ── 架构探测 ─────────────────────────────────────────────────────
_docker_detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)          DOCKER_ARCH="x86_64";  COMPOSE_ARCH="x86_64"  ;;
        aarch64|arm64)   DOCKER_ARCH="aarch64"; COMPOSE_ARCH="aarch64" ;;
        armv7l|armv7)    DOCKER_ARCH="armhf";   COMPOSE_ARCH="armv7"   ;;
        armv6l|armv6)    DOCKER_ARCH="armel";   COMPOSE_ARCH="armv6"   ;;
        ppc64le)         DOCKER_ARCH="ppc64le"; COMPOSE_ARCH="ppc64le" ;;
        s390x)           DOCKER_ARCH="s390x";   COMPOSE_ARCH="s390x"   ;;
        *)
            echo -e "${YELLOW}警告: 未知架构 $arch，默认使用 x86_64${NC}"
            DOCKER_ARCH="x86_64"; COMPOSE_ARCH="x86_64" ;;
    esac
}

# ── 实时获取版本状态 ─────────────────────────────────────────────
_docker_get_status() {
    DOCKER_VER_STR="未安装"
    COMPOSE_VER_STR="未安装"
    if command -v docker &>/dev/null; then
        DOCKER_VER_STR=$(docker -v 2>/dev/null | awk '{print $3}' | tr -d ',')
    fi
    if command -v docker-compose &>/dev/null; then
        COMPOSE_VER_STR=$(docker-compose -v 2>/dev/null | head -1 | awk '{print $NF}')
    elif docker compose version &>/dev/null 2>&1; then
        COMPOSE_VER_STR="V2 Plugin"
    fi
}

# ── 镜像源探测 ───────────────────────────────────────────────────
_docker_check_mirrors() {
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
        *aliyun*)   DOCKER_BASE_URL="https://mirrors.aliyun.com/docker-ce" ;;
        *azure.cn*) DOCKER_BASE_URL="https://mirror.azure.cn/docker-ce" ;;
        *ustc*)     DOCKER_BASE_URL="https://mirrors.ustc.edu.cn/docker-ce" ;;
        *tsinghua*) DOCKER_BASE_URL="https://mirrors.tuna.tsinghua.edu.cn/docker-ce" ;;
        *)          DOCKER_BASE_URL="https://download.docker.com" ;;
    esac
    echo -e "   ${GREEN}[OK]${NC} 已选源: ${GREEN}${DOCKER_BASE_URL}${NC}"
}

_docker_get_gh_mirror() {
    if curl -Is -m 3 "https://github.com" | head -1 | grep -qE 'HTTP/.*(200|301|302)'; then
        echo "https://github.com"
    else
        echo "https://ghproxy.net/https://github.com"
    fi
}

_docker_get_dist_info() {
    if [ -r /etc/os-release ]; then
        LSB_DIST=$(. /etc/os-release && echo "$ID" | tr '[:upper:]' '[:lower:]')
        DIST_VERSION=$(. /etc/os-release && echo "$VERSION_ID")
        DIST_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
    fi
}

# ── 带标题进度条的 curl 下载封装 ─────────────────────────────────
# 用法: _docker_curl_dl "标题" "URL" "目标路径"
_docker_curl_dl() {
    local label="$1" url="$2" dest="$3"
    echo ""
    echo -e "${CYAN}  +----------------------------------------------------------+${NC}"
    printf  "${CYAN}  |  %-56s|${NC}\n" "正在下载: $label"
    echo -e "${CYAN}  +----------------------------------------------------------+${NC}"
    echo -e "  ${YELLOW}来源:${NC} $url"
    echo ""
    if curl -L -f --progress-bar --stderr - -o "$dest" "$url"; then
        echo ""
        echo -e "  ${GREEN}[完成]${NC} $label  下载成功"
    else
        echo ""
        echo -e "  ${RED}[失败]${NC} $label  下载失败，请检查网络或版本号"
        return 1
    fi
}

# ── 安装完成后的命令速查表 ───────────────────────────────────────
_docker_print_cheatsheet() {
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
# ck_sysinit 菜单入口（由 system_init.sh 调用）
# ================================================================
docker_management_center() {
    _docker_detect_arch
    _docker_main_menu
}

# ── 主菜单循环 ───────────────────────────────────────────────────
_docker_main_menu() {
    while true; do
        _docker_get_status
        clear
        echo -e "${GREEN}+======================================================+${NC}"
        echo -e "${GREEN}|       Docker & Compose 管理中心 (ck_sysinit)         |${NC}"
        echo -e "${GREEN}+------------------------------------------------------+${NC}"
        echo -e "  引擎: ${YELLOW}${DOCKER_VER_STR}${NC}   |   Compose: ${YELLOW}${COMPOSE_VER_STR}${NC}"
        echo -e "${GREEN}+------------------------------------------------------+${NC}"
        echo "  1. 查看监控/详细配置 (daemon.json)"
        echo "  2. Docker 服务指令管理 (启动/停止/重启/自启)"
        echo "  3. 执行安装 / 覆盖更新"
        echo "  4. 彻底卸载 Docker 及其组件"
        echo "  5. 配置私有镜像库 (Private Registry)"
        echo "  0. 返回主菜单"
        echo -e "${GREEN}+======================================================+${NC}"
        read -rp "请选择 [0-5]: " dc_choice < /dev/tty

        case "$dc_choice" in
            1) _docker_show_status ;;
            2) _docker_service_menu ;;
            3) _docker_install_menu ;;
            4) _docker_uninstall ;;
            5) _docker_config_private_registry ;;
            0) break ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

# ── 1. 状态详情 ──────────────────────────────────────────────────
_docker_show_status() {
    clear
    echo -e "${CYAN}+================ Docker 运行状态与配置详情 ================+${NC}"
    if command -v docker &>/dev/null; then
        echo -e "  Docker 引擎:  ${GREEN}已安装${NC} ($(docker -v))"
        echo -e "  运行状态:     ${GREEN}$(systemctl is-active docker 2>/dev/null || echo '未启动')${NC}"
    else
        echo -e "  Docker 引擎:  ${RED}未安装${NC}"
    fi
    if command -v docker-compose &>/dev/null; then
        echo -e "  Compose 状态: ${GREEN}已就绪${NC} ($(docker-compose -v | head -1))"
    elif docker compose version &>/dev/null 2>&1; then
        echo -e "  Compose 状态: ${GREEN}已就绪${NC} (V2 Plugin - $(docker compose version --short 2>/dev/null))"
    else
        echo -e "  Compose 状态: ${RED}未检测到${NC}"
    fi
    if [ -f /etc/docker/daemon.json ]; then
        echo -e "\n  ${YELLOW}--- /etc/docker/daemon.json ---${NC}"
        cat /etc/docker/daemon.json
    fi
    echo -e "${CYAN}+===========================================================+${NC}"
    read -rp "按回车键返回..." < /dev/tty
}

# ── 5. 私有库配置 ────────────────────────────────────────────────
# 用法: _docker_select_cn_mirrors <结果数组名引用>
_docker_select_cn_mirrors() {
    local -n _result_ref=$1
    # 预置国内加速源 (纯 HTTPS，可安全放入 registry-mirrors)
    local cn_names=(
        "阿里云 (杭州)"
        "腾讯云"
        "DaoCloud"
        "网易云"
        "百度云"
        "中科大 (USTC)"
        "华为云"
    )
    local cn_urls=(
        "https://registry.cn-hangzhou.aliyuncs.com"
        "https://mirror.ccs.tencentyun.com"
        "https://docker.m.daocloud.io"
        "https://hub-mirror.c.163.com"
        "https://mirror.baidubce.com"
        "https://docker.mirrors.ustc.edu.cn"
        "https://b9pmyelo.mirror.aliyuncs.com"
    )
    clear
    echo -e "${CYAN}+================ 选择国内镜像加速源 ================+${NC}"
    echo -e "  说明: 所选源写入 registry-mirrors（均为 HTTPS，不会出现 HTTP 降级问题）"
    echo -e "${CYAN}+----------------------------------------------------+${NC}"
    local idx
    for idx in "${!cn_names[@]}"; do
        printf "  %d. %-20s  %s\n" "$((idx+1))" "${cn_names[$idx]}" "${cn_urls[$idx]}"
    done
    echo ""
    echo "  A. 全选所有加速源"
    echo "  C. 自定义输入加速源 URL"
    echo "  0. 跳过（不添加公共加速源）"
    echo -e "${CYAN}+----------------------------------------------------+${NC}"
    echo -e "  ${YELLOW}提示:${NC} 多选请用空格分隔编号，例如: 1 3 5"
    read -rp "  请选择 [0/A/C/编号]: " sel < /dev/tty
    if [[ "${sel,,}" == "0" ]]; then
        echo -e "  ${YELLOW}[跳过]${NC} 不添加公共加速源"
        return
    elif [[ "${sel,,}" == "a" ]]; then
        for url in "${cn_urls[@]}"; do
            _result_ref+=("\"${url}\"")
        done
        echo -e "  ${GREEN}[OK]${NC} 已添加全部 ${#cn_urls[@]} 个加速源"
    elif [[ "${sel,,}" == "c" ]]; then
        while true; do
            read -rp "  输入自定义加速源 URL (留空结束): " custom_url < /dev/tty
            [ -z "$custom_url" ] && break
            # 强制确保使用 HTTPS
            custom_url="${custom_url#http://}"
            custom_url="https://${custom_url#https://}"
            _result_ref+=("\"${custom_url}\"")
            echo -e "  ${GREEN}[已添加]${NC} ${custom_url}"
        done
    else
        local added=0
        for num in $sel; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#cn_names[@]}" ]; then
                local url="${cn_urls[$((num-1))]}"
                _result_ref+=("\"${url}\"")
                echo -e "  ${GREEN}[已添加]${NC} ${cn_names[$((num-1))]}: ${url}"
                ((added++))
            else
                echo -e "  ${YELLOW}[忽略]${NC} 无效编号: $num"
            fi
        done
        [ $added -eq 0 ] && echo -e "  ${YELLOW}[提示]${NC} 未选择任何加速源"
    fi
    echo ""
}

_docker_config_private_registry() {
    clear
    echo -e "${BLUE}+================ 配置私有镜像库 ================+${NC}"
    echo -e "  说明: 用于添加内网或私有 Docker 仓库。"
    echo -e "  HTTP 私有库 → 写入 insecure-registries（不进 registry-mirrors）"
    echo -e "  HTTPS 私有库 → 写入 registry-mirrors"
    echo -e "${BLUE}+--------------------------------------------------+${NC}"

    # ── Step 1: 选择国内公共加速源 ─────────────────────────────
    local public_mirrors=()
    _docker_select_cn_mirrors public_mirrors

    # ── Step 2: 循环采集私有库 ─────────────────────────────────
    local priv_https=()   # HTTPS 私有库 → 进 registry-mirrors
    local insecure=()     # HTTP  私有库 → 进 insecure-registries（裸地址）

    echo -e "${BLUE}+--------------------------------------------------+${NC}"
    echo -e "  开始添加私有库（直接回车跳过）:"
    while true; do
        read -rp "  请输入私有库地址 (例如 192.168.1.100:5000): " priv_addr < /dev/tty
        [ -z "$priv_addr" ] && break

        # 去掉用户误带的协议头，由程序统一处理
        priv_addr="${priv_addr#http://}"
        priv_addr="${priv_addr#https://}"

        read -rp "  该地址是否使用 HTTP 协议 (非 HTTPS)？[y/N]: " is_http < /dev/tty

        if [[ "${is_http,,}" == "y" ]]; then
            # !! 核心修复: HTTP地址只进 insecure-registries，绝不写入 registry-mirrors
            # registry-mirrors 中的条目 Docker 总以 HTTPS 连接，写入 http:// 反而更糟
            insecure+=("\"${priv_addr}\"")
            echo -e "  ${YELLOW}[HTTP]${NC}  已添加到 insecure-registries: ${priv_addr}"
        else
            priv_https+=("\"https://${priv_addr}\"")
            echo -e "  ${GREEN}[HTTPS]${NC} 已添加到 registry-mirrors: ${priv_addr}"
        fi

        read -rp "  继续添加下一个私有库？[y/N]: " next < /dev/tty
        [[ "${next,,}" != "y" ]] && break
    done

    # 检查: 至少选了加速源或添加了私有库
    if [ ${#public_mirrors[@]} -eq 0 ] && [ ${#priv_https[@]} -eq 0 ] && [ ${#insecure[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}[提示]${NC} 未选择任何配置，操作取消。"
        sleep 1
        return
    fi

    # ── Step 3: 合并 registry-mirrors = 公共源 + HTTPS私有库 ───
    local all_mirrors=("${public_mirrors[@]}" "${priv_https[@]}")

    # ── Step 4: 备份旧配置 ──────────────────────────────────────
    mkdir -p /etc/docker
    if [ -f /etc/docker/daemon.json ]; then
        local bak_file="/etc/docker/daemon.json.bak_$(date +%Y%m%d_%H%M%S)"
        cp /etc/docker/daemon.json "${bak_file}"
        echo -e "  ${YELLOW}[备份]${NC} 旧配置已备份至: ${bak_file}"
    fi

    # ── Step 5: 生成 daemon.json (无 jq 依赖的纯 bash 拼接) ────
    {
        echo "{"
        # registry-mirrors: 仅写入 HTTPS 地址
        echo "  \"registry-mirrors\": ["
        local m_len=${#all_mirrors[@]}
        for ((i=0; i<m_len; i++)); do
            local comma=","
            [ $((i+1)) -eq $m_len ] && comma=""
            echo "    ${all_mirrors[i]}${comma}"
        done
        echo "  ],"

        # insecure-registries: 仅写入 HTTP 私有库的裸地址（host:port 格式）
        echo "  \"insecure-registries\": ["
        local i_len=${#insecure[@]}
        for ((i=0; i<i_len; i++)); do
            local comma=","
            [ $((i+1)) -eq $i_len ] && comma=""
            echo "    ${insecure[i]}${comma}"
        done
        echo "  ],"

        # 通用性能配置（生产环境推荐值）
        echo "  \"exec-opts\": [\"native.cgroupdriver=systemd\"],"
        echo "  \"log-driver\": \"json-file\","
        echo "  \"log-opts\": { \"max-size\": \"100m\" },"
        echo "  \"storage-driver\": \"overlay2\""
        echo "}"
    } > /etc/docker/daemon.json

    # ── Step 6: 预览生成结果 ────────────────────────────────────
    echo ""
    echo -e "${GREEN}+================ 配置生成完成 ================+${NC}"
    echo -e "  ${GREEN}[OK]${NC} 配置已写入: /etc/docker/daemon.json"
    echo -e "  ${CYAN}--- 配置内容预览 ---${NC}"
    cat /etc/docker/daemon.json
    echo -e "${GREEN}+----------------------------------------------+${NC}"
    echo -e "  ${YELLOW}[防误提示]${NC}"
    echo -e "   - HTTP 私有库已写入 insecure-registries（裸 host:port）"
    echo -e "   - 不会因 HTTP→HTTPS 自动转换导致连接失败"
    echo -e "   - HTTPS 私有库正常写入 registry-mirrors"
    echo -e "${GREEN}+----------------------------------------------+${NC}"

    # ── Step 7: 询问是否立即重启 ────────────────────────────────
    echo ""
    read -rp "  是否立即重启 Docker 以使配置生效？[y/N]: " do_restart < /dev/tty
    if [[ "${do_restart,,}" == "y" ]]; then
        echo -e "  >> 正在重载 systemd 并重启 Docker..."
        systemctl daemon-reload
        systemctl restart docker
        sleep 2
        local status
        status=$(systemctl is-active docker 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            echo -e "  ${GREEN}[OK]${NC} Docker 重启成功，当前状态: ${GREEN}active${NC}"
        else
            echo -e "  ${RED}[FAIL]${NC} Docker 状态异常: ${RED}${status}${NC}"
            echo -e "  排查命令: journalctl -u docker -n 30 --no-pager"
        fi
    else
        echo -e "  ${YELLOW}请手动执行:${NC}"
        echo -e "   systemctl daemon-reload && systemctl restart docker"
    fi
    echo ""
    read -rp "按回车键返回菜单..." < /dev/tty
}

# ── 2. 服务管理 ──────────────────────────────────────────────────
_docker_service_menu() {
    while true; do
        clear
        local STATUS
        STATUS=$(systemctl is-active docker 2>/dev/null || echo "未安装/未启动")
        echo -e "${BLUE}+================ Docker 服务指令管理 ================+${NC}"
        echo -e "  当前状态: ${YELLOW}${STATUS}${NC}"
        echo -e "${BLUE}+-----------------------------------------------------+${NC}"
        echo "  1. 启动 Docker"
        echo "  2. 停止 Docker"
        echo "  3. 重启 Docker"
        echo "  4. 启用开机自启"
        echo "  5. 禁用开机自启"
        echo "  0. 返回上级"
        echo -e "${BLUE}+=====================================================+${NC}"
        read -rp "选择指令 [0-5]: " svc_choice < /dev/tty
        case "$svc_choice" in
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

# ── 3. 安装模式选择 ──────────────────────────────────────────────
_docker_install_menu() {
    clear
    _docker_get_dist_info
    _docker_check_mirrors
    echo ""
    echo -e "${BLUE}+================ 安装模式选择 ================+${NC}"
    echo "  1. [推荐] 软件包模式  (Repo 自动管理依赖)"
    echo "  2. [兼容] 静态编译模式 (解压即用，适合全发行版)"
    echo -e "${BLUE}+===============================================+${NC}"
    read -rp "请选择 [1-2, 默认2]: " mode < /dev/tty
    mode=${mode:-2}
    [ "$mode" == "1" ] && _docker_install_via_repo || _docker_install_via_binary
}

# ── 3a. 软件包模式 ───────────────────────────────────────────────
_docker_install_via_repo() {
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
    _docker_print_cheatsheet "$dv" "docker compose $cv (plugin)"
}

# ── 3b. 静态编译模式（进度可视化版）────────────────────────────
_docker_install_via_binary() {
    clear
    echo -e "${CYAN}+======================================================+${NC}"
    echo -e "${CYAN}|     静态编译模式 — 自动化版本检索与部署             |${NC}"
    echo -e "${CYAN}+======================================================+${NC}"

    local MIRROR
    MIRROR=$(_docker_get_gh_mirror)
    echo -e "  GitHub 代理: ${GREEN}${MIRROR}${NC}"

    local STATIC_URL="https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/"
    [[ "$DOCKER_BASE_URL" != *"download.docker.com"* ]] && \
        STATIC_URL="${DOCKER_BASE_URL}/linux/static/stable/${DOCKER_ARCH}/"

    echo -e "\n  >> 采集 Docker Engine 版本列表..."
    local RAW_D
    RAW_D=$(curl -sL --connect-timeout 8 "$STATIC_URL" | \
        grep -oE 'docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz' | \
        sed 's/docker-//;s/\.tgz//' | sort -uV | tail -n 8)
    IFS=$'\n' read -rd '' -a D_VERS <<< "$RAW_D"
    if [ ${#D_VERS[@]} -eq 0 ]; then
        D_VERS=("24.0.9" "25.0.3" "26.1.3" "27.0.3")
        echo -e "  ${YELLOW}>> 使用内置推荐版本${NC}"
    fi

    echo -e "  >> 采集 Docker Compose 版本列表..."
    local RAW_C
    RAW_C=$(curl -sL --connect-timeout 8 "${MIRROR}/docker/compose/releases" | \
        grep -oE 'v2\.[0-9]+\.[0-9]+' | sort -ur | head -n 6)
    IFS=$'\n' read -rd '' -a C_VERS <<< "$RAW_C"
    [ ${#C_VERS[@]} -eq 0 ] && C_VERS=("v2.26.1" "v2.27.0" "v2.28.1")

    local DEF_D="${D_VERS[-1]}" DEF_C="${C_VERS[0]}"
    echo ""
    echo -e "  可用 Engine 版本:  ${YELLOW}${D_VERS[*]}${NC}"
    read -rp "  Docker Engine 版本 [默认 $DEF_D]: " CHOSEN_D < /dev/tty
    CHOSEN_D=${CHOSEN_D:-$DEF_D}

    echo ""
    echo -e "  可用 Compose 版本: ${YELLOW}${C_VERS[*]}${NC}"
    read -rp "  Docker Compose 版本 [默认 $DEF_C]: " CHOSEN_C < /dev/tty
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
    _docker_curl_dl "Docker Engine v${CHOSEN_D} (${DOCKER_ARCH})" "$D_URL" "/tmp/docker_bin.tgz" || return 1

    # [2/4] 下载 Docker Compose
    echo ""
    echo -e "${GREEN}[2/4]${NC} 下载 Docker Compose ${YELLOW}${CHOSEN_C}${NC}"
    _docker_curl_dl "Docker Compose ${CHOSEN_C} (${COMPOSE_ARCH})" "$C_URL" "/usr/local/bin/docker-compose" || return 1

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

    local DV CV
    DV=$(docker -v 2>/dev/null || echo "读取失败")
    CV=$(docker-compose -v 2>/dev/null | head -1 || echo "读取失败")
    _docker_print_cheatsheet "$DV" "$CV"
}

# ── 4. 彻底卸载 ──────────────────────────────────────────────────
_docker_uninstall() {
    clear
    echo -e "${RED}+=============== 危险: 彻底卸载 Docker ===============+${NC}"
    echo -e "  此操作将停止所有容器并清除所有 Docker 相关文件。"
    read -rp "  确认彻底卸载? (y/N): " yn < /dev/tty
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
    read -rp "按回车键返回..." < /dev/tty
}