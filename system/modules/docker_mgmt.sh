#!/bin/bash

# =================================================================
# 模块名称: docker_mgmt.sh
# 描述: Docker & Compose 管理中心 (Linux-ops-box 集成模块)
# 职责: 将 install_docker.sh 的完整功能接入 ck_sysinit TUI 菜单
# 依赖: common.sh (全局颜色变量), install_docker.sh (核心逻辑)
# =================================================================

# ── 定位外部脚本路径 ──────────────────────────────────────────────
# 安装后目录结构: /opt/ck_sysinit/install_docker.sh
#                /opt/ck_sysinit/system_init.sh   ← BASE_DIR 指向此处
# BASE_DIR 由 system_init.sh 在 source common.sh 时已确立
DOCKER_INSTALL_SCRIPT="${BASE_DIR}/install_docker.sh"

# ── 架构探测 (独立于 install_docker.sh，避免重复探测) ────────────
_docker_detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)              DOCKER_ARCH="x86_64";  COMPOSE_ARCH="x86_64"  ;;
        aarch64|arm64)       DOCKER_ARCH="aarch64"; COMPOSE_ARCH="aarch64" ;;
        armv7l|armv7)        DOCKER_ARCH="armhf";   COMPOSE_ARCH="armv7"   ;;
        armv6l|armv6)        DOCKER_ARCH="armel";   COMPOSE_ARCH="armv6"   ;;
        ppc64le)             DOCKER_ARCH="ppc64le"; COMPOSE_ARCH="ppc64le" ;;
        s390x)               DOCKER_ARCH="s390x";   COMPOSE_ARCH="s390x"   ;;
        *)
            _log_warn "未知架构 $arch，默认使用 x86_64"
            DOCKER_ARCH="x86_64"; COMPOSE_ARCH="x86_64"
            ;;
    esac
}

# ── 内部: 实时获取 Docker/Compose 版本状态 ───────────────────────
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

# ── ck_sysinit 菜单入口 ───────────────────────────────────────────
docker_management_center() {
    # 优先尝试调用外部独立脚本（保持功能完整性）
    if [ -f "$DOCKER_INSTALL_SCRIPT" ]; then
        _log_info "正在载入 Docker 管理中心..."
        bash "$DOCKER_INSTALL_SCRIPT"
        return
    fi

    # 回退: 使用内嵌精简版菜单（脚本不存在时的降级方案）
    _log_warn "未找到 install_docker.sh，启用内嵌精简模式"
    _docker_detect_arch
    _docker_inline_menu
}

# ── 内嵌精简菜单 (降级方案) ──────────────────────────────────────
_docker_inline_menu() {
    while true; do
        _docker_get_status
        clear
        echo -e "${GREEN}======================================================${NC}"
        echo -e "${GREEN}        Docker & Compose 管理中心 (ck_sysinit)        ${NC}"
        echo -e "${GREEN}======================================================${NC}"
        echo -e " ⚓ 引擎版本: ${YELLOW}${DOCKER_VER_STR}${NC}  |  编排工具: ${YELLOW}${COMPOSE_VER_STR}${NC}"
        echo -e "${GREEN}------------------------------------------------------${NC}"
        echo " 1. 查看详细状态与 daemon.json 配置"
        echo " 2. Docker 服务管理 (启动/停止/重启/自启)"
        echo " 3. 在线安装 / 覆盖更新 Docker"
        echo " 4. 彻底卸载 Docker 及其组件"
        echo " 0. 返回主菜单"
        echo -e "${GREEN}======================================================${NC}"
        read -rp "请选择 [0-4]: " dc_choice < /dev/tty

        case "$dc_choice" in
            1) _docker_show_status ;;
            2) _docker_service_menu ;;
            3) _docker_install ;;
            4) _docker_uninstall ;;
            0) break ;;
            *) echo -e "${RED}无效选项，请重新输入${NC}"; sleep 1 ;;
        esac
    done
}

_docker_show_status() {
    clear
    echo -e "${CYAN}================ Docker 运行状态 ================${NC}"
    if command -v docker &>/dev/null; then
        echo -e " 📦 ${GREEN}Docker:${NC}  $(docker -v)"
        echo -e " 🚀 ${GREEN}服务状态:${NC} $(systemctl is-active docker 2>/dev/null || echo '未启动')"
    else
        echo -e " 📦 ${RED}Docker 未安装${NC}"
    fi
    if command -v docker-compose &>/dev/null; then
        echo -e " 🛠  ${GREEN}Compose:${NC} $(docker-compose -v | head -1)"
    elif docker compose version &>/dev/null 2>&1; then
        echo -e " 🛠  ${GREEN}Compose:${NC} V2 Plugin ($(docker compose version --short 2>/dev/null))"
    else
        echo -e " 🛠  ${RED}Compose 未安装${NC}"
    fi
    if [ -f /etc/docker/daemon.json ]; then
        echo -e "\n ${YELLOW}--- /etc/docker/daemon.json ---${NC}"
        cat /etc/docker/daemon.json
    fi
    echo -e "${CYAN}=================================================${NC}"
    read -rp "按回车键返回..." < /dev/tty
}

_docker_service_menu() {
    while true; do
        clear
        local STATUS
        STATUS=$(systemctl is-active docker 2>/dev/null || echo "未运行")
        echo -e "${BLUE}================ Docker 服务管理 ================${NC}"
        echo -e " 当前状态: ${YELLOW}${STATUS}${NC}"
        echo " 1. 启动 Docker"
        echo " 2. 停止 Docker"
        echo " 3. 重启 Docker"
        echo " 4. 启用开机自启"
        echo " 5. 禁用开机自启"
        echo " 0. 返回上级"
        echo -e "${BLUE}=================================================${NC}"
        read -rp "选择 [0-5]: " svc_choice < /dev/tty
        case "$svc_choice" in
            1) systemctl start   docker && echo -e "${GREEN}已启动${NC}" ;;
            2) systemctl stop    docker && echo -e "${YELLOW}已停止${NC}" ;;
            3) systemctl restart docker && echo -e "${GREEN}已重启${NC}" ;;
            4) systemctl enable  docker && echo -e "${GREEN}自启已启用${NC}" ;;
            5) systemctl disable docker && echo -e "${YELLOW}自启已禁用${NC}" ;;
            0) break ;;
        esac
        sleep 1
    done
}

_docker_install() {
    _log_warn "内嵌精简模式不含完整安装逻辑，请将 install_docker.sh 放至项目根目录后重试"
    _log_info "路径: ${DOCKER_INSTALL_SCRIPT}"
    read -rp "按回车返回..." < /dev/tty
}

_docker_uninstall() {
    clear
    echo -e "${RED}==================== 危险: 彻底卸载 Docker ====================${NC}"
    read -rp "确认清除? (y/N): " confirm_un < /dev/tty
    if [[ "$confirm_un" =~ ^[Yy]$ ]]; then
        systemctl stop    docker 2>/dev/null
        systemctl disable docker 2>/dev/null
        rm -f /usr/bin/docker* /usr/bin/containerd* /usr/bin/runc /usr/bin/ctr
        rm -f /usr/local/bin/docker-compose /usr/bin/docker-compose
        rm -f /etc/systemd/system/docker.service
        systemctl daemon-reload
        echo -e "${GREEN}✅ 卸载完成${NC}"
    else
        echo " 已取消"
    fi
    read -rp "按回车返回..." < /dev/tty
}
