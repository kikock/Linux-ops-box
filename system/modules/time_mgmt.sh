#!/bin/bash

# =================================================================
# 模块名称: time_mgmt.sh
# 描述: 系统时间管理中心
#       - 硬件时钟 (RTC/hwclock) 检测与读写
#       - Docker NTP 服务器一键部署 (cturra/ntp)
#       - NTP 服务器健康状态检测
#       - 时间同步脚本生成与开机自启配置
# 适配: Ubuntu / Debian / CentOS / RHEL / Rocky / AlmaLinux /
#       Fedora / Alpine / 银河麒麟 / 统信UOS / openEuler / Anolis
# 制作人: kikock
# =================================================================

# ----------------------------------------------------------------
# 内部常量
# ----------------------------------------------------------------
_NTP_CONTAINER_NAME="ntp-server"
_NTP_SYNC_SCRIPT="/usr/local/bin/ntp-sync.sh"
_NTP_SERVICE_FILE="/etc/systemd/system/ntp-sync.service"
# 默认上游 NTP 服务器（国内优先）
_NTP_UPSTREAM_DEFAULT="ntp.aliyun.com,ntp.tencent.com,cn.ntp.org.cn,pool.ntp.org"

# ================================================================
# 辅助：打印带分隔线的标题块
# ================================================================
_time_header() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${CYAN}⏰${NC}  $1"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ================================================================
# 辅助：纯 Bash NTP UDP 探测（无需任何 NTP 客户端工具）
# 向目标主机 UDP 123 端口发送 48 字节 NTP 请求包并等待响应
# 返回 0=成功响应  1=超时/无响应
# ================================================================
_bash_ntp_probe() {
    local host="${1:-127.0.0.1}"
    local timeout=3
    # 48 字节 NTP v3 客户端请求（LI=0, VN=3, Mode=3）
    local ntp_pkt
    ntp_pkt=$(printf '\x1b\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00')
    # 尝试打开 UDP 套接字（/dev/udp 是 Bash 内置虚拟文件）
    exec 9<>/dev/udp/${host}/123 2>/dev/null || return 1
    # 发送请求
    printf '%s' "$ntp_pkt" >&9 2>/dev/null || { exec 9>&-; return 1; }
    # 等待响应（read -t 超时读 1 字节）
    local resp
    IFS= read -r -t "$timeout" -d '' -n 1 resp <&9 2>/dev/null
    local rc=$?
    exec 9>&-
    # rc=0 或 read 因有数据而提前退出（rc=1 but resp非空）表示有响应
    if [ $rc -eq 0 ] || [ -n "$resp" ]; then
        return 0
    fi
    return 1
}

# ================================================================
# 功能 7：一键安装 NTP 客户端工具（麒麟/信创全适配）
# ================================================================
_install_ntp_tools() {
    clear
    _time_header "安装 NTP 客户端工具"
    echo ""

    echo -e "${BLUE}工具说明:${NC}"
    echo -e "  ${CYAN}ntpdate${NC}  — 手动触发单次时间同步（最常用，推荐安装）"
    echo -e "  ${CYAN}ntpq${NC}     — NTP 服务器状态查询工具（随 ntp 包附带）"
    echo -e "  ${CYAN}chronyc${NC}  — chrony NTP 客户端控制台（适合长期守护进程同步）"
    echo ""

    # 检测当前已有哪些工具
    echo -e "${BLUE}当前工具状态:${NC}"
    local has_ntpdate=false has_ntpq=false has_chronyc=false
    command -v ntpdate &>/dev/null && has_ntpdate=true && echo -e "  ${GREEN}✓ ntpdate  : 已安装${NC}" || echo -e "  ${RED}✗ ntpdate  : 未安装${NC}"
    command -v ntpq    &>/dev/null && has_ntpq=true    && echo -e "  ${GREEN}✓ ntpq     : 已安装${NC}" || echo -e "  ${RED}✗ ntpq     : 未安装${NC}"
    command -v chronyc &>/dev/null && has_chronyc=true && echo -e "  ${GREEN}✓ chronyc  : 已安装${NC}" || echo -e "  ${RED}✗ chronyc  : 未安装${NC}"
    echo ""

    if [ "$has_ntpdate" = true ] && [ "$has_ntpq" = true ] && [ "$has_chronyc" = true ]; then
        echo -e "${GREEN}✅ 所有 NTP 工具均已安装，无需重复安装。${NC}"
        echo ""
        read -p "  按回车键返回..." -r < /dev/tty
        return 0
    fi

    # ================================================================
    # 检测包管理器 + 判断系统底座类型
    # ================================================================
    local pkg_install_cmd="${PKG_INSTALL:-}"
    local pkg_mgr_type="unknown"

    if [ -z "$pkg_install_cmd" ]; then
        if   command -v apt &>/dev/null; then
            pkg_install_cmd="apt install -y"; pkg_mgr_type="debian"
            apt update -qq 2>/dev/null
        elif command -v dnf &>/dev/null; then
            pkg_install_cmd="dnf install -y"; pkg_mgr_type="rhel"
        elif command -v yum &>/dev/null; then
            pkg_install_cmd="yum install -y"; pkg_mgr_type="rhel"
        elif command -v apk &>/dev/null; then
            pkg_install_cmd="apk add"; pkg_mgr_type="alpine"
        else
            echo -e "${RED}✗ 未检测到支持的包管理器，无法自动安装。${NC}"
            read -p "  按回车键返回..." -r < /dev/tty
            return 1
        fi
    else
        case "${PKG_MGR:-}" in
            apt)     pkg_mgr_type="debian" ;;
            dnf|yum) pkg_mgr_type="rhel"   ;;
            apk)     pkg_mgr_type="alpine" ;;
        esac
    fi

    # ================================================================
    # 麒麟 / 信创系统识别
    # 银河麒麟 V10 Desktop / Ubuntu Kylin / 中标麒麟 → APT 底座
    # 银河麒麟 V10 Server（龙芯/鲲鹏/飞腾/x86）     → RPM 底座
    # ================================================================
    local is_kylin=false
    local kylin_is_rpm=false

    if [ -f /etc/kylin-release ] || \
       grep -qi "kylin\|银河麒麟\|中标麒麟" /etc/os-release 2>/dev/null; then
        is_kylin=true
        [ "$pkg_mgr_type" = "rhel" ] && kylin_is_rpm=true
    fi

    if [ "$is_kylin" = true ]; then
        echo -e "${CYAN}┌──────────────────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│${NC} ${YELLOW}⚑ 检测到 银河麒麟 / 中标麒麟 系统${NC}"
        if [ "$kylin_is_rpm" = true ]; then
            echo -e "${CYAN}│${NC}   底座: ${YELLOW}RPM (DNF/YUM) — V10 Server 龙芯/鲲鹏/飞腾/x86${NC}"
            echo -e "${CYAN}│${NC}"
            echo -e "${CYAN}│${NC} ${YELLOW}⚠ 注意:${NC} 麒麟 V10 Server 默认 RPM 仓库中"
            echo -e "${CYAN}│${NC}   ntpdate 包${RED}可能不存在${NC}（上游 RHEL 8 已废弃）"
            echo -e "${CYAN}│${NC}   ${GREEN}推荐安装 chrony${NC}，官方仓库均有且稳定"
            echo -e "${CYAN}│${NC}   若装 ntpdate 失败 → 先换源: [主菜单 2 → 镜像源管理]"
        else
            echo -e "${CYAN}│${NC}   底座: ${GREEN}APT (Debian) — 桌面版/Ubuntu Kylin/中标麒麟${NC}"
            echo -e "${CYAN}│${NC}   ${GREEN}✓ ntpdate、ntp、chrony 均可从官方仓库直接安装${NC}"
        fi
        echo -e "${CYAN}└──────────────────────────────────────────────────────┘${NC}"
        echo ""
    fi

    # ================================================================
    # 显示安装方案（根据系统底座动态调整选项）
    # ================================================================
    echo -e "${YELLOW}请选择安装方案:${NC}"

    if [ "$kylin_is_rpm" = true ]; then
        # 麒麟 V10 Server RPM 底座 — chrony 优先，ntpdate 可能缺包
        echo -e " 1. ${GREEN}安装 chrony（含 chronyc，麒麟 RPM 首选 ★）${NC}"
        echo -e " 2. 尝试安装 ntpdate（可能不在默认仓库，失败属正常）"
        echo -e " 3. 安装 ntp（含 ntpq，注意会与 chrony 服务冲突）"
        echo -e " 4. ${GREEN}chrony + 尝试 ntpdate（推荐完整组合）${NC}"
    else
        # Debian / Ubuntu / 麒麟 APT / Alpine — 三套工具均可安装
        echo -e " 1. 安装 ntpdate（单次同步工具，体积小，${GREEN}推荐${NC}）"
        echo -e " 2. 安装 ntp（含 ntpdate + ntpq，守护进程式服务）"
        echo -e " 3. ${GREEN}安装 chrony（含 chronyc，现代轻量 NTP 守护进程）${NC}"
        echo -e " 4. ${GREEN}全部安装（ntpdate + chrony，最完整）${NC}"
    fi
    echo -e " 0. 取消返回"
    echo ""
    read -p "  请选择 [0-4]: " install_choice < /dev/tty

    [ "$install_choice" = "0" ] && return

    echo ""

    # ================================================================
    # 执行安装 — 麒麟 RPM 底座独立逻辑 / 其余通用逻辑
    # ================================================================
    case "$install_choice" in
        1)
            if [ "$kylin_is_rpm" = true ]; then
                echo -e "${YELLOW}⏳ [麒麟 RPM] 正在安装 chrony...${NC}"
                systemctl stop ntp ntpd 2>/dev/null || true
                $pkg_install_cmd chrony
                systemctl enable --now chronyd 2>/dev/null || \
                    systemctl enable --now chrony 2>/dev/null || true
            else
                echo -e "${YELLOW}⏳ 正在安装 ntpdate...${NC}"
                $pkg_install_cmd ntpdate
            fi
            ;;
        2)
            if [ "$kylin_is_rpm" = true ]; then
                echo -e "${YELLOW}⏳ [麒麟 RPM] 尝试安装 ntpdate...${NC}"
                echo -e "${BLUE}  提示: 若安装失败，请先进入 [主菜单 2 → 镜像源管理]${NC}"
                echo -e "${BLUE}  切换至麒麟官方源(archive.kylinos.cn)或华为云源后重试${NC}"
                if ! $pkg_install_cmd ntpdate; then
                    echo -e "${RED}  ✗ ntpdate 安装失败（不在当前仓库）${NC}"
                    echo -e "${YELLOW}  建议改装 chrony（选项 1），功能完全覆盖 ntpdate${NC}"
                fi
            else
                echo -e "${YELLOW}⏳ 正在安装 ntp（含 ntpdate + ntpq）...${NC}"
                systemctl stop chronyd chrony 2>/dev/null || true
                $pkg_install_cmd ntp ntpdate 2>/dev/null || $pkg_install_cmd ntp
            fi
            ;;
        3)
            if [ "$kylin_is_rpm" = true ]; then
                echo -e "${YELLOW}⏳ [麒麟 RPM] 正在安装 ntp（注意：会与 chrony 服务冲突）...${NC}"
                systemctl stop chronyd chrony 2>/dev/null || true
                $pkg_install_cmd ntp
            else
                echo -e "${YELLOW}⏳ 正在安装 chrony（含 chronyc）...${NC}"
                systemctl stop ntp ntpd 2>/dev/null || true
                $pkg_install_cmd chrony
            fi
            ;;
        4)
            if [ "$kylin_is_rpm" = true ]; then
                echo -e "${YELLOW}⏳ [麒麟 RPM] 安装 chrony + 尝试安装 ntpdate...${NC}"
                echo -e "  ${CYAN}步骤 1/2: 安装 chrony（主力工具）${NC}"
                systemctl stop ntp ntpd 2>/dev/null || true
                $pkg_install_cmd chrony
                systemctl enable --now chronyd 2>/dev/null || \
                    systemctl enable --now chrony 2>/dev/null || true
                echo -e "  ${CYAN}步骤 2/2: 尝试安装 ntpdate（失败则跳过）${NC}"
                $pkg_install_cmd ntpdate 2>/dev/null || \
                    echo -e "  ${YELLOW}  ⚠ ntpdate 跳过（不在默认仓库，chrony 可完全替代）${NC}"
            else
                echo -e "${YELLOW}⏳ 正在安装完整 NTP 工具集...${NC}"
                echo -e "  ${CYAN}步骤 1/2: 安装 ntpdate${NC}"
                $pkg_install_cmd ntpdate 2>/dev/null || true
                echo -e "  ${CYAN}步骤 2/2: 安装 chrony${NC}"
                systemctl stop ntp ntpd 2>/dev/null || true
                $pkg_install_cmd chrony 2>/dev/null || true
            fi
            ;;
        *)
            echo -e "${RED}无效输入。${NC}"
            sleep 1
            return
            ;;
    esac

    echo ""
    echo -e "${BLUE}安装后工具验证:${NC}"
    command -v ntpdate &>/dev/null && \
        echo -e "  ${GREEN}✓ ntpdate  : $(ntpdate --version 2>&1 | head -1)${NC}" || \
        echo -e "  ${YELLOW}⚠ ntpdate  : 未安装${NC}"
    command -v ntpq    &>/dev/null && \
        echo -e "  ${GREEN}✓ ntpq     : $(ntpq --version 2>&1 | head -1)${NC}" || \
        echo -e "  ${YELLOW}⚠ ntpq     : 未安装${NC}"
    command -v chronyc &>/dev/null && \
        echo -e "  ${GREEN}✓ chronyc  : $(chronyc --version 2>&1 | head -1)${NC}" || \
        echo -e "  ${YELLOW}⚠ chronyc  : 未安装${NC}"

    echo ""
    read -p "  按回车键返回..." -r < /dev/tty
}


# ================================================================
# 功能 1：硬件时钟 (RTC/hwclock) 检测
# ================================================================
_check_hwclock() {
    clear
    _time_header "硬件时钟 (RTC) 状态检测"
    echo ""

    # --- 1.1 检测 RTC 设备节点 ---
    echo -e "${BLUE}[1/4] 检测 RTC 设备节点...${NC}"
    local rtc_found=false
    for rtc_dev in /dev/rtc0 /dev/rtc1 /dev/rtc; do
        if [ -e "$rtc_dev" ]; then
            echo -e "  ${GREEN}✓ 发现 RTC 设备: ${rtc_dev}${NC}"
            rtc_found=true
        fi
    done
    if [ "$rtc_found" = false ]; then
        echo -e "  ${YELLOW}⚠ 未发现 RTC 设备节点 (/dev/rtc0 等)${NC}"
        echo -e "  ${BLUE}  说明: 当前环境可能是纯容器/某些虚拟机，无物理硬件时钟。${NC}"
    fi
    echo ""

    # --- 1.2 检测 hwclock 命令 ---
    echo -e "${BLUE}[2/4] 检测 hwclock 命令...${NC}"
    if ! command -v hwclock &>/dev/null; then
        echo -e "  ${YELLOW}⚠ hwclock 命令不存在${NC}"
        echo -e "  ${BLUE}  安装方式: apt install util-linux  /  yum install util-linux${NC}"
    else
        echo -e "  ${GREEN}✓ hwclock 命令可用${NC}"
        echo ""

        # --- 1.3 读取硬件时钟时间 ---
        echo -e "${BLUE}[3/4] 读取硬件时钟时间...${NC}"
        local hw_time
        hw_time=$(hwclock --show 2>&1)
        local hw_exit=$?
        if [ $hw_exit -eq 0 ]; then
            echo -e "  ${GREEN}硬件时钟 (RTC): ${hw_time}${NC}"
        else
            echo -e "  ${YELLOW}⚠ 无法读取硬件时钟: ${hw_time}${NC}"
            echo -e "  ${BLUE}  (可能为虚拟机环境或权限不足)${NC}"
        fi
        echo ""

        # --- 1.4 计算与系统时钟的偏差 ---
        echo -e "${BLUE}[4/4] 比对系统时间与硬件时钟偏差...${NC}"
        local sys_ts
        local hw_ts
        sys_ts=$(date +%s)
        hw_ts=$(hwclock --show 2>/dev/null | awk '{print $1, $2}' | xargs -I{} date -d "{}" +%s 2>/dev/null)

        local sys_now
        sys_now=$(date '+%Y-%m-%d %H:%M:%S %Z')
        echo -e "  ${CYAN}系统时间  : ${sys_now}${NC}"
        echo -e "  ${CYAN}硬件时钟  : ${hw_time:-无法获取}${NC}"

        if [ -n "$hw_ts" ] && [ -n "$sys_ts" ]; then
            local diff=$(( sys_ts - hw_ts ))
            local abs_diff=${diff#-}
            if [ "$abs_diff" -le 2 ]; then
                echo -e "  ${GREEN}✓ 偏差: ${diff} 秒 — 时间同步正常${NC}"
            elif [ "$abs_diff" -le 60 ]; then
                echo -e "  ${YELLOW}⚠ 偏差: ${diff} 秒 — 轻微漂移，建议同步${NC}"
            else
                echo -e "  ${RED}✗ 偏差: ${diff} 秒 — 严重漂移，请立即同步！${NC}"
            fi
        fi
    fi

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${YELLOW}提示:${NC} 可通过菜单选项同步时间并写回硬件时钟"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "  按回车键返回..." -r < /dev/tty
}

# ================================================================
# 功能 2：Docker NTP 服务器部署
# ================================================================
_setup_ntp_docker() {
    clear
    _time_header "Docker NTP 服务器部署"
    echo ""

    # --- 2.1 检查 Docker 是否可用 ---
    echo -e "${BLUE}[1/5] 检测 Docker 环境...${NC}"
    if ! command -v docker &>/dev/null; then
        echo -e "  ${RED}✗ Docker 未安装！${NC}"
        echo -e "  ${YELLOW}请先进入主菜单 [9. Docker 管理中心] 安装 Docker，再重试。${NC}"
        read -p "  按回车键返回..." -r < /dev/tty
        return 1
    fi
    if ! docker info &>/dev/null; then
        echo -e "  ${RED}✗ Docker 守护进程未运行！${NC}"
        echo -e "  ${YELLOW}尝试启动 Docker: systemctl start docker${NC}"
        systemctl start docker 2>/dev/null
        sleep 2
        if ! docker info &>/dev/null; then
            echo -e "  ${RED}✗ Docker 启动失败，请手动检查。${NC}"
            read -p "  按回车键返回..." -r < /dev/tty
            return 1
        fi
    fi
    echo -e "  ${GREEN}✓ Docker 运行正常${NC}"
    echo ""

    # --- 2.2 检查容器是否已存在 ---
    echo -e "${BLUE}[2/5] 检查 NTP 容器状态...${NC}"
    local container_status
    container_status=$(docker inspect --format='{{.State.Status}}' "$_NTP_CONTAINER_NAME" 2>/dev/null)
    if [ -n "$container_status" ]; then
        if [ "$container_status" = "running" ]; then
            echo -e "  ${GREEN}✓ NTP 容器 [${_NTP_CONTAINER_NAME}] 已在运行中！${NC}"
            echo -e "  ${BLUE}  使用菜单 [3] 查看健康状态，或 [5] 先停止再重新配置。${NC}"
            read -p "  按回车键返回..." -r < /dev/tty
            return 0
        else
            echo -e "  ${YELLOW}⚠ NTP 容器存在但状态为: ${container_status}，正在清理旧容器...${NC}"
            docker rm -f "$_NTP_CONTAINER_NAME" &>/dev/null
        fi
    else
        echo -e "  ${BLUE}  未发现现有 NTP 容器，将创建新容器。${NC}"
    fi
    echo ""

    # --- 2.3 检查 UDP 123 端口占用 ---
    echo -e "${BLUE}[3/5] 检测 UDP 123 端口占用...${NC}"
    local port_used=false
    if command -v ss &>/dev/null; then
        ss -ulnp 2>/dev/null | grep -q ':123 ' && port_used=true
    elif command -v netstat &>/dev/null; then
        netstat -ulnp 2>/dev/null | grep -q ':123 ' && port_used=true
    fi

    if [ "$port_used" = true ]; then
        echo -e "  ${YELLOW}⚠ UDP 123 端口已被占用（系统可能已运行 ntpd/chrony）${NC}"
        echo -e "  ${BLUE}  请先停止系统 NTP 服务:${NC}"
        echo -e "  ${CYAN}  systemctl stop ntp ntpd chrony chronyd 2>/dev/null${NC}"
        echo ""
        read -p "  是否尝试自动停止系统 NTP 服务并继续? [y/N]: " stop_sys_ntp < /dev/tty
        if [[ "$stop_sys_ntp" =~ ^[Yy]$ ]]; then
            systemctl stop ntp ntpd chrony chronyd 2>/dev/null || true
            systemctl disable ntp ntpd chrony chronyd 2>/dev/null || true
            echo -e "  ${GREEN}✓ 已尝试停止系统 NTP 服务${NC}"
        else
            echo -e "  ${YELLOW}已取消，请手动处理端口冲突后重试。${NC}"
            read -p "  按回车键返回..." -r < /dev/tty
            return 1
        fi
    else
        echo -e "  ${GREEN}✓ UDP 123 端口空闲，可以使用${NC}"
    fi
    echo ""

    # --- 2.4 配置 NTP 上游服务器 ---
    echo -e "${BLUE}[4/5] 配置 NTP 上游服务器...${NC}"
    echo -e "  默认上游: ${CYAN}${_NTP_UPSTREAM_DEFAULT}${NC}"
    read -p "  是否使用默认上游？直接回车=是，或输入自定义（逗号分隔）: " custom_upstream < /dev/tty
    local ntp_upstream="${_NTP_UPSTREAM_DEFAULT}"
    if [ -n "$custom_upstream" ]; then
        ntp_upstream="$custom_upstream"
        echo -e "  ${GREEN}✓ 使用自定义上游: ${ntp_upstream}${NC}"
    else
        echo -e "  ${GREEN}✓ 使用默认国内上游 NTP 源${NC}"
    fi
    echo ""

    # --- 2.5 拉取镜像并启动容器 ---
    echo -e "${BLUE}[5/5] 拉取 NTP 镜像并启动容器...${NC}"
    echo -e "  ${YELLOW}⏳ 正在拉取镜像 cturra/ntp:latest（可能需要几分钟）...${NC}"

    # 尝试拉取（带超时）
    if ! docker pull cturra/ntp:latest 2>&1; then
        echo -e "  ${RED}✗ 镜像拉取失败！请检查网络或 Docker 镜像加速配置。${NC}"
        echo -e "  ${BLUE}  提示: 可在 [9. Docker 管理中心] 配置镜像加速源后重试。${NC}"
        echo -e "  ${BLUE}  或手动导入本地 tar: docker load -i ntp.tar${NC}"
        read -p "  按回车键返回..." -r < /dev/tty
        return 1
    fi

    echo -e "  ${GREEN}✓ 镜像拉取成功，正在启动 NTP 容器...${NC}"
    echo ""

    docker run -d \
        --name "$_NTP_CONTAINER_NAME" \
        --restart=always \
        --cap-add SYS_TIME \
        -p 123:123/udp \
        -e NTP_SERVERS="${ntp_upstream}" \
        cturra/ntp:latest

    if [ $? -eq 0 ]; then
        echo ""
        echo -e "  ${GREEN}🎉 NTP 服务器容器已成功启动！${NC}"
        echo -e "  ${CYAN}  容器名称: ${_NTP_CONTAINER_NAME}${NC}"
        echo -e "  ${CYAN}  监听端口: UDP 123${NC}"
        echo -e "  ${CYAN}  上游服务: ${ntp_upstream}${NC}"
        echo -e "  ${CYAN}  重启策略: always（开机自启）${NC}"
        echo ""
        echo -e "  ${YELLOW}⏳ 等待 NTP 服务初始化（约 30 秒后可进行健康检测）...${NC}"
    else
        echo -e "  ${RED}✗ 容器启动失败，请查看 Docker 日志: docker logs ${_NTP_CONTAINER_NAME}${NC}"
    fi

    echo ""
    read -p "  按回车键返回..." -r < /dev/tty
}

# ================================================================
# 功能 3：NTP 服务器健康状态检测
# ================================================================
_check_ntp_health() {
    clear
    _time_header "NTP 服务器健康状态检测"
    echo ""

    local ntp_target="127.0.0.1"
    local overall_ok=true

    # --- 3.1 Docker 容器状态 ---
    echo -e "${BLUE}[1/4] 检查 Docker NTP 容器状态...${NC}"
    if ! command -v docker &>/dev/null; then
        echo -e "  ${YELLOW}⚠ Docker 未安装，跳过容器状态检查${NC}"
    else
        local cstatus
        cstatus=$(docker inspect --format='{{.State.Status}}' "$_NTP_CONTAINER_NAME" 2>/dev/null)
        if [ -z "$cstatus" ]; then
            echo -e "  ${YELLOW}⚠ NTP 容器 [${_NTP_CONTAINER_NAME}] 不存在（尚未部署）${NC}"
            overall_ok=false
        elif [ "$cstatus" = "running" ]; then
            local cstart cimage cup
            cstart=$(docker inspect --format='{{.State.StartedAt}}' "$_NTP_CONTAINER_NAME" 2>/dev/null | cut -c1-19 | tr 'T' ' ')
            cimage=$(docker inspect --format='{{.Config.Image}}' "$_NTP_CONTAINER_NAME" 2>/dev/null)
            echo -e "  ${GREEN}✓ 容器状态: running${NC}"
            echo -e "  ${CYAN}  镜像: ${cimage}${NC}"
            echo -e "  ${CYAN}  启动时间: ${cstart} UTC${NC}"
            # 最后 5 行日志
            echo -e "  ${CYAN}  最新日志:${NC}"
            docker logs --tail 5 "$_NTP_CONTAINER_NAME" 2>&1 | while IFS= read -r line; do
                echo -e "    ${BLUE}│${NC} $line"
            done
        else
            echo -e "  ${RED}✗ 容器状态: ${cstatus}（异常）${NC}"
            overall_ok=false
        fi
    fi
    echo ""

    # --- 3.2 UDP 123 端口连通性 ---
    echo -e "${BLUE}[2/4] 检测 UDP 123 端口连通性...${NC}"
    local udp_ok=false
    if command -v ss &>/dev/null; then
        if ss -ulnp 2>/dev/null | grep -q ':123 '; then
            echo -e "  ${GREEN}✓ UDP 123 端口正在监听${NC}"
            udp_ok=true
        else
            echo -e "  ${RED}✗ UDP 123 端口未监听${NC}"
            overall_ok=false
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -ulnp 2>/dev/null | grep -q ':123 '; then
            echo -e "  ${GREEN}✓ UDP 123 端口正在监听${NC}"
            udp_ok=true
        else
            echo -e "  ${RED}✗ UDP 123 端口未监听${NC}"
            overall_ok=false
        fi
    else
        echo -e "  ${YELLOW}⚠ 无法检测（缺少 ss/netstat 命令）${NC}"
    fi
    echo ""

    # --- 3.3 NTP 协议层探测 ---
    echo -e "${BLUE}[3/4] NTP 协议层探测...${NC}"
    local ntp_proto_ok=false

    # 检测可用工具
    local _has_ntpdate _has_ntpq _has_chronyc
    command -v ntpdate &>/dev/null && _has_ntpdate=true || _has_ntpdate=false
    command -v ntpq    &>/dev/null && _has_ntpq=true    || _has_ntpq=false
    command -v chronyc &>/dev/null && _has_chronyc=true || _has_chronyc=false

    if [ "$_has_ntpdate" = true ]; then
        echo -e "  ${CYAN}▶ 使用 ntpdate -q 探测 ${ntp_target}:${NC}"
        local ntpout
        ntpout=$(ntpdate -q "$ntp_target" 2>&1)
        if echo "$ntpout" | grep -qE "server .*, stratum|offset"; then
            echo -e "  ${GREEN}✓ ntpdate 协议探测成功${NC}"
            echo "$ntpout" | grep -E "server|offset" | head -3 | while IFS= read -r line; do
                echo -e "    ${BLUE}│${NC} $line"
            done
            ntp_proto_ok=true
        else
            echo -e "  ${YELLOW}⚠ ntpdate 响应: $(echo "$ntpout" | head -2)${NC}"
        fi

    elif [ "$_has_ntpq" = true ]; then
        echo -e "  ${CYAN}▶ 使用 ntpq -p 探测 ${ntp_target}:${NC}"
        local ntpq_out
        ntpq_out=$(ntpq -p "$ntp_target" 2>&1)
        if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}✓ ntpq 响应正常${NC}"
            echo "$ntpq_out" | head -8 | while IFS= read -r line; do
                echo -e "    ${BLUE}│${NC} $line"
            done
            ntp_proto_ok=true
        else
            echo -e "  ${YELLOW}⚠ ntpq 无响应: ${ntpq_out}${NC}"
        fi

    elif [ "$_has_chronyc" = true ]; then
        echo -e "  ${CYAN}▶ 使用 chronyc tracking 检测本机同步:${NC}"
        local chrony_out
        chrony_out=$(chronyc tracking 2>&1)
        if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}✓ chronyc 响应正常${NC}"
            echo "$chrony_out" | head -6 | while IFS= read -r line; do
                echo -e "    ${BLUE}│${NC} $line"
            done
            ntp_proto_ok=true
        else
            echo -e "  ${YELLOW}⚠ chronyc 无响应: ${chrony_out}${NC}"
        fi

    else
        # 无任何 NTP 客户端工具 → 纯 Bash UDP 探测兜底
        echo -e "  ${YELLOW}⚠ 未检测到 ntpdate / ntpq / chronyc${NC}"
        echo -e "  ${CYAN}▶ 使用纯 Bash UDP 探测（无需额外工具）...${NC}"
        if _bash_ntp_probe "$ntp_target"; then
            echo -e "  ${GREEN}✓ Bash UDP 探测成功：NTP 端口有响应！${NC}"
            ntp_proto_ok=true
        else
            echo -e "  ${RED}✗ Bash UDP 探测超时：端口无响应或服务未就绪${NC}"
        fi
        echo ""
        echo -e "  ${BLUE}💡 建议安装 NTP 工具以获得更详细的诊断信息:${NC}"
        echo -e "  ${CYAN}   菜单选项 [7] → 一键安装 NTP 客户端工具${NC}"
    fi
    echo ""

    # --- 3.4 当前系统时间与时区 ---
    echo -e "${BLUE}[4/4] 当前系统时间状态...${NC}"
    echo -e "  ${CYAN}系统时间 : $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
    if command -v timedatectl &>/dev/null; then
        local sync_status
        sync_status=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)
        if [ "$sync_status" = "yes" ]; then
            echo -e "  ${GREEN}✓ NTP 同步状态: 已同步${NC}"
        else
            echo -e "  ${YELLOW}⚠ NTP 同步状态: 未同步 (timedatectl)${NC}"
        fi
        echo -e "  ${CYAN}时区     : $(timedatectl show --property=Timezone --value 2>/dev/null)${NC}"
    fi
    echo ""

    # --- 汇总状态 ---
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [ "$overall_ok" = true ] && [ "$ntp_proto_ok" = true ]; then
        echo -e " ${GREEN}🟢 总体状态: NTP 服务器运行正常！${NC}"
    elif [ "$udp_ok" = true ]; then
        echo -e " ${YELLOW}🟡 总体状态: 端口已监听，NTP 协议层需进一步确认${NC}"
    else
        echo -e " ${RED}🔴 总体状态: NTP 服务异常，请检查容器或服务配置${NC}"
    fi
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "  按回车键返回..." -r < /dev/tty
}

# ================================================================
# 功能 4：生成时间同步脚本并配置开机自启
# ================================================================
_setup_ntp_sync_service() {
    clear
    _time_header "配置时间同步脚本 + 开机自启"
    echo ""

    # --- 4.1 确认 Systemd 环境 ---
    echo -e "${BLUE}[1/4] 检测 Systemd 环境...${NC}"
    if ! command -v systemctl &>/dev/null; then
        echo -e "  ${YELLOW}⚠ 当前系统不支持 Systemd，将尝试 cron 方式配置开机同步${NC}"
        _setup_ntp_sync_cron
        return
    fi
    echo -e "  ${GREEN}✓ Systemd 可用${NC}"
    echo ""

    # --- 4.2 配置 NTP 服务器列表 ---
    echo -e "${BLUE}[2/4] 配置同步目标 NTP 服务器...${NC}"
    echo -e "  优先顺序: 本机 Docker NTP → 阿里云 → 腾讯云 → 国内公共 NTP"
    echo -e "  默认列表: ${CYAN}127.0.0.1 ntp.aliyun.com ntp.tencent.com cn.ntp.org.cn${NC}"
    read -p "  直接回车使用默认，或输入自定义（空格分隔）: " custom_ntp_list < /dev/tty
    local ntp_list="127.0.0.1 ntp.aliyun.com ntp.tencent.com cn.ntp.org.cn"
    if [ -n "$custom_ntp_list" ]; then
        ntp_list="$custom_ntp_list"
    fi
    echo -e "  ${GREEN}✓ NTP 服务器列表: ${ntp_list}${NC}"
    echo ""

    # --- 4.3 生成同步脚本 ---
    echo -e "${BLUE}[3/4] 生成同步脚本: ${_NTP_SYNC_SCRIPT}...${NC}"

    cat > "$_NTP_SYNC_SCRIPT" << SCRIPT_EOF
#!/bin/bash
# ============================================================
# NTP 时间同步脚本 (由 Linux-ops-box 自动生成)
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 优先使用本机 Docker NTP 容器，逐级回退到公网 NTP
# ============================================================

NTP_SERVERS=(${ntp_list})
LOG_FILE="/var/log/ntp-sync.log"
LOCK_FILE="/var/run/ntp-sync.lock"

# 防止重复运行
[ -f "\$LOCK_FILE" ] && exit 0
touch "\$LOCK_FILE"
trap 'rm -f "\$LOCK_FILE"' EXIT

_log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" >> "\$LOG_FILE"
}

_sync_with_ntpdate() {
    local server="\$1"
    if ntpdate -u -t 5 "\$server" >> "\$LOG_FILE" 2>&1; then
        _log "ntpdate 同步成功 via \$server"
        return 0
    fi
    return 1
}

_sync_with_chrony() {
    if chronyc makestep >> "\$LOG_FILE" 2>&1; then
        _log "chronyc makestep 同步成功"
        return 0
    fi
    return 1
}

_sync_with_timedatectl() {
    if timedatectl set-ntp true >> "\$LOG_FILE" 2>&1; then
        _log "timedatectl NTP 已启用"
        return 0
    fi
    return 1
}

# === 主同步逻辑 ===
_log "=== 开始 NTP 时间同步 ==="

synced=false

# 方式1: ntpdate 逐服务器尝试
if command -v ntpdate &>/dev/null; then
    for srv in "\${NTP_SERVERS[@]}"; do
        if _sync_with_ntpdate "\$srv"; then
            synced=true
            break
        fi
        _log "ntpdate via \$srv 失败，尝试下一个..."
    done
fi

# 方式2: chronyc fallback
if [ "\$synced" = false ] && command -v chronyc &>/dev/null; then
    _sync_with_chrony && synced=true
fi

# 方式3: timedatectl fallback
if [ "\$synced" = false ] && command -v timedatectl &>/dev/null; then
    _sync_with_timedatectl && synced=true
fi

# 同步系统时间写入硬件时钟
if [ "\$synced" = true ]; then
    _log "同步成功，尝试将系统时间写回硬件时钟 (hwclock --systohc)..."
    hwclock --systohc >> "\$LOG_FILE" 2>&1 || _log "hwclock 写入跳过（容器/虚拟机环境）"
    _log "=== 同步完成 ==="
    exit 0
else
    _log "=== 所有 NTP 服务器均无法连接，同步失败 ==="
    exit 1
fi
SCRIPT_EOF

    chmod +x "$_NTP_SYNC_SCRIPT"
    echo -e "  ${GREEN}✓ 同步脚本已生成: ${_NTP_SYNC_SCRIPT}${NC}"
    echo ""

    # --- 4.4 注册 Systemd 服务 ---
    echo -e "${BLUE}[4/4] 注册 Systemd 开机自启服务...${NC}"

    cat > "$_NTP_SERVICE_FILE" << SERVICE_EOF
[Unit]
Description=NTP Time Sync Service (Linux-ops-box)
Documentation=https://github.com/kikock/Linux-ops-box
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${_NTP_SYNC_SCRIPT}
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable ntp-sync.service
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}✓ Systemd 服务已注册并启用开机自启${NC}"
    else
        echo -e "  ${RED}✗ 服务注册失败，请手动检查${NC}"
    fi

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${GREEN}🎉 配置完成！${NC}"
    echo -e "  ${CYAN}同步脚本 : ${_NTP_SYNC_SCRIPT}${NC}"
    echo -e "  ${CYAN}服务文件 : ${_NTP_SERVICE_FILE}${NC}"
    echo -e "  ${CYAN}同步日志 : /var/log/ntp-sync.log${NC}"
    echo -e "  ${YELLOW}立即测试 : systemctl start ntp-sync.service${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "  按回车键返回..." -r < /dev/tty
}

# ================================================================
# 功能 4B：cron 方式配置（Systemd 不可用时的回退方案）
# ================================================================
_setup_ntp_sync_cron() {
    echo -e "${BLUE}使用 cron 方式配置开机时间同步...${NC}"

    # 生成脚本（与 Systemd 版本相同逻辑，简化版）
    cat > "$_NTP_SYNC_SCRIPT" << 'CRON_SCRIPT_EOF'
#!/bin/bash
NTP_SERVERS=("127.0.0.1" "ntp.aliyun.com" "ntp.tencent.com" "cn.ntp.org.cn")
for srv in "${NTP_SERVERS[@]}"; do
    if command -v ntpdate &>/dev/null; then
        ntpdate -u -t 5 "$srv" &>/dev/null && hwclock --systohc 2>/dev/null && exit 0
    fi
done
exit 1
CRON_SCRIPT_EOF
    chmod +x "$_NTP_SYNC_SCRIPT"

    # 写入 /etc/rc.local
    if [ -f /etc/rc.local ]; then
        if ! grep -q "ntp-sync" /etc/rc.local; then
            sed -i '/^exit 0/i '"$_NTP_SYNC_SCRIPT"'' /etc/rc.local
            echo -e "  ${GREEN}✓ 已写入 /etc/rc.local 开机自启${NC}"
        else
            echo -e "  ${BLUE}  rc.local 中已存在 ntp-sync 配置${NC}"
        fi
    else
        echo -e "  ${YELLOW}⚠ 未找到 /etc/rc.local，尝试写入 cron @reboot...${NC}"
        (crontab -l 2>/dev/null | grep -v "ntp-sync"; echo "@reboot $_NTP_SYNC_SCRIPT") | crontab -
        echo -e "  ${GREEN}✓ 已写入 cron @reboot${NC}"
    fi

    echo ""
    read -p "  按回车键返回..." -r < /dev/tty
}

# ================================================================
# 功能 5：手动立即同步时间
# ================================================================
_manual_sync_time() {
    clear
    _time_header "立即手动同步时间"
    echo ""

    # 检查是否已有同步脚本
    if [ -f "$_NTP_SYNC_SCRIPT" ]; then
        echo -e "${BLUE}检测到已配置同步脚本，正在执行...${NC}"
        bash "$_NTP_SYNC_SCRIPT"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ 时间同步成功！当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
        else
            echo -e "${RED}✗ 同步脚本执行失败，尝试直接使用 ntpdate...${NC}"
        fi
    else
        echo -e "${YELLOW}未找到同步脚本，尝试直接同步...${NC}"
    fi

    # 直接尝试同步（无论脚本是否存在）
    local synced=false
    local servers=("127.0.0.1" "ntp.aliyun.com" "ntp.tencent.com" "cn.ntp.org.cn")

    for srv in "${servers[@]}"; do
        echo -ne "  ${CYAN}尝试 ${srv}...${NC} "
        if command -v ntpdate &>/dev/null; then
            if ntpdate -u -t 5 "$srv" &>/dev/null; then
                echo -e "${GREEN}✓ 同步成功${NC}"
                synced=true
                break
            else
                echo -e "${RED}✗ 超时/失败${NC}"
            fi
        elif command -v chronyc &>/dev/null; then
            if chronyc makestep &>/dev/null; then
                echo -e "${GREEN}✓ chronyc 同步成功${NC}"
                synced=true
                break
            fi
        elif command -v timedatectl &>/dev/null; then
            timedatectl set-ntp true &>/dev/null
            echo -e "${GREEN}✓ timedatectl NTP 已启用${NC}"
            synced=true
            break
        else
            echo -e "${YELLOW}⚠ 无可用的 NTP 同步工具${NC}"
            break
        fi
    done

    if [ "$synced" = true ]; then
        echo ""
        echo -e "${GREEN}✓ 同步完成，写入硬件时钟...${NC}"
        hwclock --systohc 2>/dev/null && echo -e "${GREEN}✓ 硬件时钟已更新${NC}" || \
            echo -e "${YELLOW}⚠ hwclock 写入跳过（容器/虚拟机环境正常）${NC}"
        echo -e "${CYAN}当前系统时间: $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
    fi

    echo ""
    read -p "  按回车键返回..." -r < /dev/tty
}

# ================================================================
# 功能 6：停止并清理 NTP 服务
# ================================================================
_remove_ntp_setup() {
    clear
    _time_header "停止并清理 NTP 服务"
    echo ""

    echo -e "${YELLOW}将执行以下清理操作:${NC}"
    echo -e "  1. 停止并删除 Docker NTP 容器 [${_NTP_CONTAINER_NAME}]"
    echo -e "  2. 禁用并删除 Systemd ntp-sync 服务"
    echo -e "  3. 删除同步脚本 ${_NTP_SYNC_SCRIPT}"
    echo ""
    read -p "  是否确认执行清理? [y/N]: " confirm_rm < /dev/tty
    if [[ ! "$confirm_rm" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}已取消。${NC}"
        sleep 1
        return
    fi

    echo ""

    # 停止 Docker 容器
    if command -v docker &>/dev/null; then
        if docker inspect "$_NTP_CONTAINER_NAME" &>/dev/null; then
            echo -ne "  ${CYAN}停止 Docker NTP 容器...${NC} "
            docker stop "$_NTP_CONTAINER_NAME" &>/dev/null
            docker rm "$_NTP_CONTAINER_NAME" &>/dev/null
            echo -e "${GREEN}✓ 已删除${NC}"
        else
            echo -e "  ${BLUE}  Docker NTP 容器不存在，跳过${NC}"
        fi
    fi

    # 停止 Systemd 服务
    if command -v systemctl &>/dev/null; then
        if systemctl list-unit-files ntp-sync.service &>/dev/null 2>&1 | grep -q ntp-sync; then
            echo -ne "  ${CYAN}禁用 ntp-sync.service...${NC} "
            systemctl stop ntp-sync.service &>/dev/null
            systemctl disable ntp-sync.service &>/dev/null
            rm -f "$_NTP_SERVICE_FILE"
            systemctl daemon-reload
            echo -e "${GREEN}✓ 已清除${NC}"
        else
            echo -e "  ${BLUE}  ntp-sync.service 不存在，跳过${NC}"
        fi
    fi

    # 删除同步脚本
    if [ -f "$_NTP_SYNC_SCRIPT" ]; then
        echo -ne "  ${CYAN}删除同步脚本...${NC} "
        rm -f "$_NTP_SYNC_SCRIPT"
        echo -e "${GREEN}✓ 已删除${NC}"
    else
        echo -e "  ${BLUE}  同步脚本不存在，跳过${NC}"
    fi

    echo ""
    echo -e "${GREEN}✅ NTP 服务清理完成。${NC}"
    echo ""
    read -p "  按回车键返回..." -r < /dev/tty
}

# ================================================================
# 状态栏：在菜单顶部显示实时时间状态摘要
# ================================================================
_draw_time_status_bar() {
    local sys_time ntp_container_status rtc_status sync_status

    sys_time=$(date '+%Y-%m-%d %H:%M:%S %Z')

    # RTC 状态简检
    if hwclock --show &>/dev/null 2>&1; then
        rtc_status="${GREEN}✓ 正常${NC}"
    elif [ -e /dev/rtc0 ] || [ -e /dev/rtc ]; then
        rtc_status="${YELLOW}⚠ 有设备/读取受限${NC}"
    else
        rtc_status="${YELLOW}⚠ 无RTC设备${NC}"
    fi

    # Docker NTP 容器状态简检
    if command -v docker &>/dev/null; then
        local cs
        cs=$(docker inspect --format='{{.State.Status}}' "$_NTP_CONTAINER_NAME" 2>/dev/null)
        if [ "$cs" = "running" ]; then
            ntp_container_status="${GREEN}✓ 运行中${NC}"
        elif [ -n "$cs" ]; then
            ntp_container_status="${RED}✗ ${cs}${NC}"
        else
            ntp_container_status="${YELLOW}─ 未部署${NC}"
        fi
    else
        ntp_container_status="${YELLOW}─ Docker未安装${NC}"
    fi

    # Systemd NTP 同步状态
    if command -v timedatectl &>/dev/null; then
        local ntp_synced
        ntp_synced=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)
        [ "$ntp_synced" = "yes" ] && sync_status="${GREEN}✓ 已同步${NC}" || sync_status="${YELLOW}⚠ 未同步${NC}"
    else
        sync_status="${BLUE}─ N/A${NC}"
    fi

    echo -e "${CYAN}┌──────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  系统时间  : ${CYAN}${sys_time}${NC}"
    echo -e "${CYAN}│${NC}  硬件时钟  : ${rtc_status}"
    echo -e "${CYAN}│${NC}  NTP 容器  : ${ntp_container_status}"
    echo -e "${CYAN}│${NC}  时间同步  : ${sync_status}"
    echo -e "${CYAN}└──────────────────────────────────────────────────┘${NC}"
}

# ================================================================
# 主入口：时间管理中心 TUI 菜单
# ================================================================
time_management_menu() {
    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}          ⏰  系统时间管理中心  ⏰                    ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        _draw_time_status_bar
        echo -e "${GREEN}══════════════ 🔍 检测与诊断 ══════════════${NC}"
        echo -e " 1. 查看硬件时钟 (RTC) 状态"
        echo -e " 3. 检测 NTP 服务器健康状态"
        echo -e "${GREEN}══════════════ 🚀 部署与配置 ══════════════${NC}"
        echo -e " 2. 部署 Docker NTP 服务器"
        echo -e " 4. 配置时间同步脚本 (开机自启)"
        echo -e "${GREEN}══════════════ ⚡ 操作 ════════════════════${NC}"
        echo -e " 6. 立即手动同步时间"
        echo -e " 5. 停止并清理 NTP 服务"
        echo -e "${GREEN}══════════════ 🔧 工具管理 ════════════════${NC}"
        echo -e " 7. 安装 NTP 客户端工具 (ntpdate / chrony)"
        echo -e "${GREEN}==============================================${NC}"
        echo -e " 0. 返回主菜单"
        echo -e "${GREEN}==============================================${NC}"
        read -p "请输入选项 [0-7]: " time_choice < /dev/tty

        case "$time_choice" in
            1) _check_hwclock ;;
            2) _setup_ntp_docker ;;
            3) _check_ntp_health ;;
            4) _setup_ntp_sync_service ;;
            5) _remove_ntp_setup ;;
            6) _manual_sync_time ;;
            7) _install_ntp_tools ;;
            0)
                echo -e "${BLUE}返回中...${NC}"
                break
                ;;
            *)
                echo -e "${RED}输入无效，请重新选择。${NC}"
                sleep 1
                ;;
        esac
    done
}
