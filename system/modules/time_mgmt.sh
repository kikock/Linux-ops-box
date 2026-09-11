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
    local port="${2:-123}"
    local timeout="${3:-3}"
    # 尝试打开 UDP 套接字（/dev/udp 是 Bash 内置虚拟文件）
    exec 9<>/dev/udp/${host}/${port} 2>/dev/null || return 1
    # 直接写入 48 字节 NTP v3 客户端请求（LI=0, VN=3, Mode=3）
    printf '\x1b\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' >&9 2>/dev/null \
        || { exec 9>&-; return 1; }
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
    # ================================================================
    # 本地离线安装包探测 (system/packages)
    # ================================================================
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local base_pkg_dir="${script_dir}/../packages"
    [ ! -d "$base_pkg_dir" ] && base_pkg_dir="${script_dir}/packages"

    local offline_chrony=""
    local offline_ntpdate=""
    local has_offline=false

    if [ "$pkg_mgr_type" = "debian" ]; then
        offline_chrony=$(find "${base_pkg_dir}/deb" -name "chrony*.deb" 2>/dev/null | head -1)
        offline_ntpdate=$(find "${base_pkg_dir}/deb" -name "ntpdate*.deb" 2>/dev/null | head -1)
        [ -n "$offline_chrony" ] || [ -n "$offline_ntpdate" ] && has_offline=true
    elif [ "$pkg_mgr_type" = "rhel" ]; then
        offline_chrony=$(find "${base_pkg_dir}/rpm" -name "chrony*.rpm" 2>/dev/null | head -1)
        offline_ntpdate=$(find "${base_pkg_dir}/rpm" -name "ntpdate*.rpm" 2>/dev/null | head -1)
        [ -n "$offline_chrony" ] || [ -n "$offline_ntpdate" ] && has_offline=true
    fi

    if [ "$has_offline" = true ]; then
        echo -e "${GREEN}📦 检测到仓库内置离线包 (system/packages):${NC}"
        [ -n "$offline_chrony" ] && echo -e "  - chrony 离线包 : ${CYAN}$(basename "$offline_chrony")${NC}"
        [ -n "$offline_ntpdate" ] && echo -e "  - ntpdate 离线包: ${CYAN}$(basename "$offline_ntpdate")${NC}"
        echo ""
    fi

    # ================================================================
    # 显示安装方案（根据系统底座动态调整选项）
    # ================================================================
    echo -e "${YELLOW}请选择安装方案:${NC}"

    if [ "$kylin_is_rpm" = true ]; then
        # 麒麟 V10 Server RPM 底座 — chrony 优先，ntpdate 可能缺包
        echo -e " 1. ${GREEN}安装 chrony（含 chronyc，麒麟 RPM 在线首选 ★）${NC}"
        echo -e " 2. 尝试在线安装 ntpdate（可能不在默认仓库）"
        echo -e " 3. 安装 ntp（含 ntpq，注意会与 chrony 服务冲突）"
        echo -e " 4. ${GREEN}chrony + 尝试 ntpdate（在线完整组合）${NC}"
    else
        # Debian / Ubuntu / 麒麟 APT / Alpine — 三套工具均可安装
        echo -e " 1. 在线安装 ntpdate（单次同步工具，体积小，${GREEN}推荐${NC}）"
        echo -e " 2. 在线安装 ntp（含 ntpdate + ntpq，守护进程式服务）"
        echo -e " 3. ${GREEN}在线安装 chrony（含 chronyc，现代轻量 NTP 守护进程）${NC}"
        echo -e " 4. ${GREEN}全部在线安装（ntpdate + chrony，最完整）${NC}"
    fi
    if [ "$has_offline" = true ]; then
        echo -e " 5. ${CYAN}📦 纯内网/离线安装（使用本地 system/packages 离线包，无外网推荐 ★）${NC}"
    fi
    echo -e " 0. 取消返回"
    echo ""
    read -p "  请选择 [0-5]: " install_choice < /dev/tty

    [ "$install_choice" = "0" ] && return

    echo ""

    # ================================================================
    # 执行安装 — 麒麟 RPM 底座独立逻辑 / 其余通用逻辑 / 离线安装
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
        5)
            echo -e "${YELLOW}⏳ 正在使用本地 system/packages 离线包执行纯离线安装...${NC}"
            systemctl stop ntp ntpd 2>/dev/null || true
            if [ "$pkg_mgr_type" = "debian" ]; then
                local debs=()
                [ -n "$offline_chrony" ] && debs+=("$offline_chrony")
                [ -n "$offline_ntpdate" ] && debs+=("$offline_ntpdate")
                if [ ${#debs[@]} -gt 0 ]; then
                    dpkg -i "${debs[@]}" 2>/dev/null || apt-get install -f -y 2>/dev/null || true
                    systemctl enable --now chrony 2>/dev/null || true
                    echo -e "  ${GREEN}✓ Debian/Ubuntu 离线包安装执行完毕${NC}"
                else
                    echo -e "  ${RED}✗ 未找到 Debian 体系的离线安装包${NC}"
                fi
            elif [ "$pkg_mgr_type" = "rhel" ]; then
                local rpms=()
                [ -n "$offline_chrony" ] && rpms+=("$offline_chrony")
                [ -n "$offline_ntpdate" ] && rpms+=("$offline_ntpdate")
                if [ ${#rpms[@]} -gt 0 ]; then
                    rpm -Uvh --replacepkgs --nodeps "${rpms[@]}" 2>/dev/null || \
                        yum localinstall -y "${rpms[@]}" 2>/dev/null || true
                    systemctl enable --now chronyd 2>/dev/null || true
                    echo -e "  ${GREEN}✓ RHEL/CentOS/麒麟 离线包安装执行完毕${NC}"
                else
                    echo -e "  ${RED}✗ 未找到 RPM 体系的离线安装包${NC}"
                fi
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
# 辅助：一键生成纯内网/离线孤岛模式 chrony.conf 配置文件
# 注意: cturra/ntp 容器内部运行的是 chronyd，必须使用 chrony 格式
#       不能使用 ntpd 的 server 127.127.1.0 + fudge 语法
# ================================================================
_generate_ntp_offline_conf() {
    local target_dir="${1:-/etc/ntp-docker}"
    # 使用 chrony.conf 格式，对应容器内 chronyd 的配置
    local target_file="${target_dir}/chrony.conf"

    echo -ne "  ${CYAN}➜ 正在生成离线孤岛 chrony.conf [${target_file}]...${NC} "
    mkdir -p "$target_dir" 2>/dev/null
    cat > "$target_file" << 'NTP_CONF_EOF'
# chrony.conf - 纯内网/离线孤岛模式配置文件（chronyd 格式）
# 由 Linux-ops-box 自动生成
# 适配容器: cturra/ntp (内部使用 chronyd)

# ============================================================
# 关键配置: 以本机系统时钟作为独立时源（孤岛授时模式）
# local stratum 10: 宣告自身 stratum=10，允许内网客户端同步
# orphan: 支持多节点孤岛互选（可选，兼容性强）
# ============================================================
local stratum 10 orphan

# 允许全部内网客户端访问（包括所有私有地址段）
allow all

# driftfile: 记录时钟频率漂移，容器重启后更快收敛
driftfile /var/lib/chrony/chrony.drift

# 日志路径
logdir /var/log/chrony
NTP_CONF_EOF

    if [ -f "$target_file" ] && [ -s "$target_file" ]; then
        echo -e "${GREEN}✓ 生成成功！${NC}"
        return 0
    else
        echo -e "${RED}✗ 生成失败（请检查 root 权限）${NC}"
        return 1
    fi
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
            echo -e "  ${BLUE}  使用菜单 [4] 查看健康状态，或 [7] 先停止再重新配置。${NC}"
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

    # --- 2.3 宿主机端口配置与占用检测 ---
    echo -e "${BLUE}[3/5] 配置宿主机 UDP 监听端口与占用检测...${NC}"
    echo -e "  NTP 协议标准端口为 ${CYAN}123${NC}（默认推荐）。"
    echo -e "  若宿主机 123 端口已被其他服务占用或需端口隔离，可输入自定义端口（如 1123）。"
    read -p "  请输入宿主机 UDP 监听端口 [直接回车=123]: " custom_port < /dev/tty
    local ntp_host_port="${custom_port:-123}"
    if ! [[ "$ntp_host_port" =~ ^[0-9]+$ ]] || [ "$ntp_host_port" -lt 1 ] || [ "$ntp_host_port" -gt 65535 ]; then
        echo -e "  ${YELLOW}⚠ 端口输入无效，已重置为默认端口 123${NC}"
        ntp_host_port=123
    fi
    echo -e "  ${GREEN}✓ 宿主机监听端口: UDP ${ntp_host_port}${NC}"

    local port_used=false
    if command -v ss &>/dev/null; then
        ss -ulnp 2>/dev/null | grep -q ":${ntp_host_port} " && port_used=true
    elif command -v netstat &>/dev/null; then
        netstat -ulnp 2>/dev/null | grep -q ":${ntp_host_port} " && port_used=true
    fi

    if [ "$port_used" = true ]; then
        echo -e "  ${YELLOW}⚠ UDP ${ntp_host_port} 端口已被占用${NC}"
        if [ "$ntp_host_port" = "123" ]; then
            echo -e "  ${BLUE}  通常为系统已运行 ntpd/chrony 服务导致:${NC}"
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
            echo -e "  ${RED}✗ 自定义端口 ${ntp_host_port} 已被占用，请更换其他端口重试。${NC}"
            read -p "  按回车键返回..." -r < /dev/tty
            return 1
        fi
    else
        echo -e "  ${GREEN}✓ UDP ${ntp_host_port} 端口空闲，可以使用${NC}"
    fi
    echo ""

    # --- 2.4 配置 NTP 时间源与运行模式 ---
    echo -e "${BLUE}[4/5] 配置 NTP 时间源与运行模式...${NC}"
    echo -e "  ${YELLOW}请选择 NTP 服务器运行模式:${NC}"
    echo -e "  1. ${GREEN}联网授时模式${NC}（默认）— 从公网阿里云/腾讯云 NTP 源同步并向内网分发"
    echo -e "  2. ${CYAN}纯内网/离线孤岛模式${NC}   — 【一键自动生成 ntpd.conf】以本机硬件时钟(RTC)为根源授时"
    echo -e "  3. ${BLUE}自定义上游模式${NC}       — 手动指定上级 NTP 服务器（逗号分隔）"
    echo ""
    read -p "  请选择模式 [1-3，直接回车=1]: " ntp_mode_choice < /dev/tty
    ntp_mode_choice="${ntp_mode_choice:-1}"

    local ntp_upstream=""
    local offline_mode=false
    local ntp_conf_dir="/etc/ntp-docker"
    # chrony.conf: cturra/ntp 容器内部使用 chronyd，挂载到 /etc/chrony/chrony.conf
    local ntp_conf_file="${ntp_conf_dir}/chrony.conf"

    case "$ntp_mode_choice" in
        2)
            offline_mode=true
            echo ""
            echo -e "  ${CYAN}⏰ [离线孤岛模式] 正在检查本机时钟状态...${NC}"
            echo -e "  ${BLUE}  时钟继承链: RTC(硬件时钟) → 宿主机系统时钟 → 容器chronyd → 客户端${NC}"
            echo ""

            local sys_ts hw_ts hw_now sys_now
            sys_now=$(date '+%Y-%m-%d %H:%M:%S %Z')
            sys_ts=$(date +%s)
            echo -e "  ${CYAN}  系统时钟 : ${sys_now}${NC}"

            if hwclock --show &>/dev/null 2>&1; then
                hw_now=$(hwclock --show 2>/dev/null)
                echo -e "  ${GREEN}  硬件时钟 : ${hw_now}${NC}"
                # 计算 RTC 与系统时钟偏差
                hw_ts=$(hwclock --show 2>/dev/null | awk '{print $1,$2}' | \
                        xargs -I{} date -d "{}" +%s 2>/dev/null || echo "")
                if [ -n "$hw_ts" ]; then
                    local hw_diff=$(( sys_ts - hw_ts ))
                    local hw_abs=${hw_diff#-}
                    if [ "$hw_abs" -le 2 ]; then
                        echo -e "  ${GREEN}  ✓ RTC 与系统时钟偏差: ${hw_diff}s — 一致，授时基准可靠${NC}"
                    elif [ "$hw_abs" -le 60 ]; then
                        echo -e "  ${YELLOW}  ⚠ RTC 与系统时钟偏差: ${hw_diff}s — 轻微漂移${NC}"
                        echo -e "  ${YELLOW}    建议先执行 hwclock --hctosys 让系统时钟与 RTC 对齐${NC}"
                    else
                        echo -e "  ${RED}  ✗ RTC 与系统时钟偏差: ${hw_diff}s — 差异过大！${NC}"
                        echo -e "  ${RED}    强烈建议先手动校准 RTC 后再部署 NTP 服务:${NC}"
                        echo -e "  ${RED}    方法1: date -s 'YYYY-MM-DD HH:MM:SS' && hwclock --systohc${NC}"
                        echo -e "  ${RED}    方法2: ntpdate -u ntp.aliyun.com && hwclock --systohc${NC}"
                    fi
                fi
            else
                echo -e "  ${YELLOW}  ⚠ 无法读取硬件时钟（虚拟化/容器环境）${NC}"
                echo -e "  ${BLUE}    将直接以宿主机系统时钟为授时基准（chronyd local stratum 10）${NC}"
            fi
            echo ""
            _generate_ntp_offline_conf "$ntp_conf_dir"
            echo ""
            ;;
        3)
            echo ""
            read -p "  请输入自定义上游 NTP 服务器（如 192.168.1.1,ntp.aliyun.com）: " custom_upstream < /dev/tty
            if [ -n "$custom_upstream" ]; then
                ntp_upstream="$custom_upstream"
            else
                ntp_upstream="${_NTP_UPSTREAM_DEFAULT}"
            fi
            echo -e "  ${GREEN}✓ 使用上游: ${ntp_upstream}${NC}"
            echo ""
            ;;
        *)
            ntp_upstream="${_NTP_UPSTREAM_DEFAULT}"
            echo -e "  ${GREEN}✓ 使用默认国内公网 NTP 源 (${ntp_upstream})${NC}"
            echo ""
            ;;
    esac

    # --- 2.5 检查/拉取镜像并启动容器 ---
    echo -e "${BLUE}[5/5] 检查 NTP 镜像并启动容器...${NC}"

    local has_local_img=false
    if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q 'cturra/ntp'; then
        has_local_img=true
    fi

    if [ "$has_local_img" = true ]; then
        echo -e "  ${GREEN}✓ 本地已存在 cturra/ntp 镜像，直接启动${NC}"
    else
        if [ "$offline_mode" = true ]; then
            echo -e "  ${YELLOW}⚠ 本地未发现 cturra/ntp 镜像！${NC}"
            echo -e "  ${BLUE}  当前为离线孤岛模式，请选择获取镜像方式:${NC}"
            echo -e "  1. 尝试从网络拉取（如果临时具备外网通道）"
            echo -e "  2. 导入本地离线镜像包 (.tar 文件)"
            echo -e "  0. 取消退出"
            read -p "  请选择 [1-2, 0取消]: " img_choice < /dev/tty
            case "$img_choice" in
                2)
                    read -p "  请输入离线镜像 tar 文件路径 (如 /root/ntp-server-image.tar): " tar_path < /dev/tty
                    if [ -f "$tar_path" ]; then
                        echo -e "  ${CYAN}⏳ 正在导入镜像: ${tar_path}...${NC}"
                        docker load -i "$tar_path"
                    else
                        echo -e "  ${RED}✗ 文件不存在: ${tar_path}${NC}"
                        read -p "  按回车键返回..." -r < /dev/tty
                        return 1
                    fi
                    ;;
                1)
                    echo -e "  ${YELLOW}⏳ 正在尝试拉取镜像 cturra/ntp:latest...${NC}"
                    if ! docker pull cturra/ntp:latest 2>&1; then
                        echo -e "  ${RED}✗ 镜像拉取失败！${NC}"
                        read -p "  按回车键返回..." -r < /dev/tty
                        return 1
                    fi
                    ;;
                *)
                    echo -e "  ${BLUE}已取消。${NC}"
                    read -p "  按回车键返回..." -r < /dev/tty
                    return 0
                    ;;
            esac
        else
            echo -e "  ${YELLOW}⏳ 正在拉取镜像 cturra/ntp:latest（可能需要几分钟）...${NC}"
            if ! docker pull cturra/ntp:latest 2>&1; then
                echo -e "  ${RED}✗ 镜像拉取失败！请检查网络或 Docker 镜像加速配置。${NC}"
                echo -e "  ${BLUE}  提示: 可在 [9. Docker 管理中心] 配置镜像加速源后重试。${NC}"
                echo -e "  ${BLUE}  或手动导入本地 tar: docker load -i ntp.tar${NC}"
                read -p "  按回车键返回..." -r < /dev/tty
                return 1
            fi
        fi
    fi

    echo -e "  ${GREEN}✓ 镜像就绪，正在启动 NTP 容器...${NC}"
    echo ""

    if [ "$offline_mode" = true ]; then
        # 挂载 chrony.conf 到容器内 chronyd 实际读取的路径 /etc/chrony/chrony.conf
        # 原路径 /etc/ntpd.conf 为 ntpd 格式，chronyd 不会读取，导致 stratum 16 无法授时
        docker run -d \
            --name "$_NTP_CONTAINER_NAME" \
            --restart=always \
            --cap-add SYS_TIME \
            -p "${ntp_host_port}:123/udp" \
            -v "${ntp_conf_file}:/etc/chrony/chrony.conf:ro" \
            cturra/ntp:latest
    else
        docker run -d \
            --name "$_NTP_CONTAINER_NAME" \
            --restart=always \
            --cap-add SYS_TIME \
            -p "${ntp_host_port}:123/udp" \
            -e NTP_SERVERS="${ntp_upstream}" \
            cturra/ntp:latest
    fi

    if [ $? -eq 0 ]; then
        echo ""
        echo -e "  ${GREEN}🎉 NTP 服务器容器已成功启动！${NC}"
        echo -e "  ${CYAN}  容器名称: ${_NTP_CONTAINER_NAME}${NC}"
        echo -e "  ${CYAN}  监听端口: 宿主机 UDP ${ntp_host_port} -> 容器内部 UDP 123${NC}"
        if [ "$offline_mode" = true ]; then
            echo -e "  ${CYAN}  运行模式: 纯内网/离线孤岛模式 (chrony.conf: local stratum 10 orphan)${NC}"
            echo -e "  ${CYAN}  授时基准: 宿主机系统时钟（=RTC硬件时钟，容器与宿主机共享内核时钟）${NC}"
            echo -e "  ${CYAN}  对外宣告: Stratum 10（内网客户端可正常同步）${NC}"
        else
            echo -e "  ${CYAN}  上游服务: ${ntp_upstream}${NC}"
        fi
        echo -e "  ${CYAN}  重启策略: always（开机自启）${NC}"
        echo ""
        echo -e "  ${YELLOW}📌 防火墙放行提示 (若 A 端开启了防火墙，请执行以下命令放行):${NC}"
        echo -e "    UFW (Ubuntu/Debian)      : ${CYAN}sudo ufw allow ${ntp_host_port}/udp${NC}"
        echo -e "    Firewalld (RHEL/CentOS)  : ${CYAN}sudo firewall-cmd --permanent --add-port=${ntp_host_port}/udp && sudo firewall-cmd --reload${NC}"
        echo -e "    Iptables                 : ${CYAN}sudo iptables -A INPUT -p udp --dport ${ntp_host_port} -j ACCEPT${NC}"
        echo ""
        echo -e "  ${GREEN}💡 B 客户端连接提示:${NC}"
        if [ "$ntp_host_port" = "123" ]; then
            echo -e "    Chrony 配置语法: ${CYAN}server <A端主机IP> iburst${NC}"
        else
            echo -e "    Chrony 配置语法: ${CYAN}server <A端主机IP> port ${ntp_host_port} iburst${NC}"
        fi
        echo -e "    可在 B 机器直接运行本脚本，选择菜单 [2] 即可自动完成客户端安装、配置与即时同步！"
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

    echo -e "${YELLOW}请选择或输入要检测的 NTP 服务器目标:${NC}"
    echo -e "  1. 本机 NTP 服务 (127.0.0.1:123)"
    echo -e "  2. 自定义其他服务器 (可输入 IP 或 IP:端口)"
    echo ""
    read -p "  请选择模式 [1-2，直接回车=1]: " target_mode_choice < /dev/tty
    target_mode_choice="${target_mode_choice:-1}"

    local raw_target="127.0.0.1:123"
    if [ "$target_mode_choice" = "2" ]; then
        echo ""
        echo -e "  ${CYAN}请输入目标 NTP 服务器地址与端口（如: 192.168.1.100 或 192.168.1.100:123）:${NC}"
        read -p "  目标服务器 [直接回车=127.0.0.1:123]: " user_target < /dev/tty
        [ -n "$user_target" ] && raw_target="$user_target"
    fi

    # 去除空格并解析 IP/域名 与 端口
    raw_target=$(echo "$raw_target" | tr -d ' ')
    local ntp_target="127.0.0.1"
    local ntp_port="123"

    if [[ "$raw_target" == *":"* ]]; then
        ntp_target="${raw_target%%:*}"
        ntp_port="${raw_target##*:}"
    else
        ntp_target="$raw_target"
        ntp_port="123"
    fi
    ntp_target="${ntp_target:-127.0.0.1}"
    ntp_port="${ntp_port:-123}"

    # 判断是否为本机目标
    local is_local=false
    if [ "$ntp_target" = "127.0.0.1" ] || [ "$ntp_target" = "localhost" ] || [ "$ntp_target" = "::1" ]; then
        is_local=true
    else
        if command -v hostname &>/dev/null && hostname -I 2>/dev/null | grep -qw "$ntp_target"; then
            is_local=true
        elif command -v ip &>/dev/null && ip -o addr 2>/dev/null | grep -qw "$ntp_target"; then
            is_local=true
        fi
    fi

    echo ""
    echo -e "  ${BLUE}🎯 检测目标: ${CYAN}${ntp_target}:${ntp_port}${NC} $([ "$is_local" = true ] && echo -e "${GREEN}(本机)${NC}" || echo -e "${YELLOW}(远程服务器)${NC}")"
    echo -e "  ${CYAN}──────────────────────────────────────────────────${NC}"
    echo ""

    local overall_ok=true
    local udp_ok=false
    local ntp_proto_ok=false

    if [ "$is_local" = true ]; then
        # ============================================================
        # 模式 A：检测本机 NTP 服务
        # ============================================================

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

        # --- 3.2 UDP 端口连通性 ---
        echo -e "${BLUE}[2/4] 检测本机 UDP ${ntp_port} 端口连通性...${NC}"
        if command -v ss &>/dev/null; then
            if ss -ulnp 2>/dev/null | grep -q ":${ntp_port} "; then
                echo -e "  ${GREEN}✓ UDP ${ntp_port} 端口正在监听${NC}"
                udp_ok=true
            else
                echo -e "  ${RED}✗ UDP ${ntp_port} 端口未监听${NC}"
                overall_ok=false
            fi
        elif command -v netstat &>/dev/null; then
            if netstat -ulnp 2>/dev/null | grep -q ":${ntp_port} "; then
                echo -e "  ${GREEN}✓ UDP ${ntp_port} 端口正在监听${NC}"
                udp_ok=true
            else
                echo -e "  ${RED}✗ UDP ${ntp_port} 端口未监听${NC}"
                overall_ok=false
            fi
        else
            echo -e "  ${YELLOW}⚠ 无法检测（缺少 ss/netstat 命令）${NC}"
        fi
        echo ""

        # --- 3.3 NTP 协议层探测 ---
        echo -e "${BLUE}[3/4] NTP 协议层探测...${NC}"
        local _has_ntpdate _has_ntpq _has_chronyc
        command -v ntpdate &>/dev/null && _has_ntpdate=true || _has_ntpdate=false
        command -v ntpq    &>/dev/null && _has_ntpq=true    || _has_ntpq=false
        command -v chronyc &>/dev/null && _has_chronyc=true || _has_chronyc=false

        if [ "$ntp_port" = "123" ] && [ "$_has_ntpdate" = true ]; then
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
        elif [ "$ntp_port" = "123" ] && [ "$_has_ntpq" = true ]; then
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
        elif [ "$ntp_port" = "123" ] && [ "$_has_chronyc" = true ]; then
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
            if [ "$ntp_port" != "123" ]; then
                echo -e "  ${CYAN}ℹ 自定义端口 ${ntp_port}: 使用纯 Bash UDP 48字节 NTP 请求包探测...${NC}"
            else
                echo -e "  ${YELLOW}⚠ 未检测到 ntpdate / ntpq / chronyc${NC}"
                echo -e "  ${CYAN}▶ 使用纯 Bash UDP 探测（无需额外工具）...${NC}"
            fi
            if _bash_ntp_probe "$ntp_target" "$ntp_port"; then
                echo -e "  ${GREEN}✓ Bash UDP 探测成功：UDP ${ntp_port} 端口收到 NTP 协议有效响应！${NC}"
                ntp_proto_ok=true
            else
                echo -e "  ${RED}✗ Bash UDP 探测超时：端口无响应或服务未就绪${NC}"
            fi
        fi
        echo ""

        # --- 3.4 当前系统时间与时区（详细诊断） ---
        echo -e "${BLUE}[4/4] 当前系统时间状态...${NC}"
        echo -e "  ${CYAN}系统时间 : $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"

        if command -v timedatectl &>/dev/null; then
            local tz ntp_synced ntp_active timesyncd_server rtc_time
            tz=$(timedatectl show --property=Timezone --value 2>/dev/null)
            ntp_synced=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)
            ntp_active=$(timedatectl show --property=NTP --value 2>/dev/null)
            rtc_time=$(timedatectl show --property=RTCTimeUSec --value 2>/dev/null | \
                       awk -F'=' '{print $1}' 2>/dev/null || true)
            echo -e "  ${CYAN}时区       : ${tz}${NC}"

            # ── NTPSynchronized 含义说明 ──────────────────────────────
            # 该值由宿主机的 NTP 客户端守护进程（systemd-timesyncd/chronyd/ntpd）写入
            # 与 Docker NTP 容器无关：容器是【对外授时服务器】，不负责同步本机时钟
            # 若本机角色为纯 NTP 服务端，此处显示"未同步"属正常现象
            # ──────────────────────────────────────────────────────────
            if [ "$ntp_synced" = "yes" ]; then
                echo -e "  ${GREEN}✓ NTP同步状态: 已同步 (宿主机系统时钟已被某 NTP 守护进程同步)${NC}"
            else
                # 判断本机 NTP 服务是否已开启（服务端角色 or 客户端未启动）
                if [ "$ntp_active" = "yes" ]; then
                    echo -e "  ${YELLOW}⚠ NTP同步状态: NTP已启用但尚未完成同步 (守护进程正在收敛中)${NC}"
                else
                    echo -e "  ${YELLOW}⚠ NTP同步状态: 未同步${NC}"
                fi
                echo -e "  ${BLUE}  ┌─ 说明: 此状态反映的是【宿主机本身】是否被 NTP 客户端守护进程同步${NC}"
                echo -e "  ${BLUE}  │  与 Docker NTP 容器无关（容器是对外授时服务器，不同步本机）${NC}"
                echo -e "  ${BLUE}  │  若本机定位为纯 NTP 服务端，显示"未同步"属正常现象${NC}"
                echo -e "  ${BLUE}  └─ 若需同步宿主机时钟，可配置 chrony 客户端指向上游 NTP${NC}"
            fi

            # ── systemd-timesyncd 详情（若在运行）──────────────────
            if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
                local tsd_server tsd_poll tsd_offset tsd_delay tsd_last
                # timedatectl show-timesync 仅在较新版 systemd 可用
                if timedatectl show-timesync &>/dev/null 2>&1; then
                    tsd_server=$(timedatectl show-timesync --property=ServerName --value 2>/dev/null)
                    tsd_poll=$(timedatectl show-timesync --property=Poll --value 2>/dev/null)
                    tsd_offset=$(timedatectl show-timesync --property=NTPMessage --value 2>/dev/null | \
                                 grep -oP 'offset=\K[^,]+' 2>/dev/null | head -1)
                    tsd_delay=$(timedatectl show-timesync --property=NTPMessage --value 2>/dev/null | \
                                grep -oP 'delay=\K[^,]+' 2>/dev/null | head -1)
                    tsd_last=$(timedatectl show-timesync --property=ReferenceTime --value 2>/dev/null)
                    echo -e "  ${CYAN}  ┌─ [systemd-timesyncd 详情]${NC}"
                    [ -n "$tsd_server" ] && echo -e "  ${CYAN}  │  同步服务器 : ${tsd_server}${NC}"
                    [ -n "$tsd_poll" ]   && echo -e "  ${CYAN}  │  轮询间隔   : ${tsd_poll}s${NC}"
                    [ -n "$tsd_offset" ] && echo -e "  ${CYAN}  │  时钟偏移   : ${tsd_offset}ms${NC}"
                    [ -n "$tsd_delay" ]  && echo -e "  ${CYAN}  │  网络延迟   : ${tsd_delay}ms${NC}"
                    [ -n "$tsd_last" ]   && echo -e "  ${CYAN}  └─ 最后同步   : ${tsd_last}${NC}"
                else
                    # 旧版 systemd 用 journalctl 获取最近同步记录
                    local last_sync_log
                    last_sync_log=$(journalctl -u systemd-timesyncd --no-pager -n 5 \
                                    --output=short-iso 2>/dev/null | \
                                    grep -E 'Synchronized|synchronized|Syncing|offset' | tail -2)
                    if [ -n "$last_sync_log" ]; then
                        echo -e "  ${CYAN}  ┌─ [systemd-timesyncd 最近同步日志]${NC}"
                        echo "$last_sync_log" | while IFS= read -r line; do
                            echo -e "  ${CYAN}  │  $line${NC}"
                        done
                        echo -e "  ${CYAN}  └─${NC}"
                    fi
                fi
            fi

            # ── chrony 客户端详情（若在运行）──────────────────────
            if command -v chronyc &>/dev/null && \
               systemctl is-active --quiet chronyd 2>/dev/null || \
               systemctl is-active --quiet chrony 2>/dev/null; then
                local cr_ref cr_offset cr_rms cr_freq cr_last
                cr_ref=$(chronyc tracking 2>/dev/null | awk -F': ' '/Reference ID/{print $2}')
                cr_offset=$(chronyc tracking 2>/dev/null | awk -F': ' '/System time/{print $2}')
                cr_rms=$(chronyc tracking 2>/dev/null | awk -F': ' '/RMS offset/{print $2}')
                cr_freq=$(chronyc tracking 2>/dev/null | awk -F': ' '/Frequency/{print $2}')
                cr_last=$(chronyc tracking 2>/dev/null | awk -F': ' '/Last offset/{print $2}')
                if [ -n "$cr_ref" ]; then
                    echo -e "  ${GREEN}  ┌─ [chrony 客户端同步详情]${NC}"
                    echo -e "  ${GREEN}  │  上游时间源  : ${cr_ref}${NC}"
                    [ -n "$cr_offset" ] && echo -e "  ${GREEN}  │  系统时钟偏移: ${cr_offset}${NC}"
                    [ -n "$cr_rms" ]    && echo -e "  ${GREEN}  │  RMS 偏移    : ${cr_rms}${NC}"
                    [ -n "$cr_freq" ]   && echo -e "  ${GREEN}  │  频率误差    : ${cr_freq}${NC}"
                    [ -n "$cr_last" ]   && echo -e "  ${GREEN}  │  最近偏移    : ${cr_last}${NC}"
                    echo -e "  ${GREEN}  └─${NC}"
                fi
            fi
        fi

    else
        # ============================================================
        # 模式 B：检测远程 NTP 服务器 (例如 192.168.1.100:123)
        # ============================================================

        # --- 3.1 网络基础连通性探测 (Ping) ---
        echo -e "${BLUE}[1/4] 检测远程网络连通性 (ICMP Ping)...${NC}"
        if ping -c 2 -W 2 "$ntp_target" &>/dev/null; then
            echo -e "  ${GREEN}✓ 主机 ${ntp_target} 网络可达 (Ping 成功)${NC}"
        else
            echo -e "  ${YELLOW}⚠ Ping 无响应（可能目标主机禁 Ping，继续检测 UDP 端口）${NC}"
        fi
        echo ""

        # --- 3.2 远程 UDP 端口连通性探测 ---
        echo -e "${BLUE}[2/4] 检测远程 UDP ${ntp_port} 端口通信...${NC}"
        if command -v nc &>/dev/null; then
            if nc -z -u -w 2 "$ntp_target" "$ntp_port" &>/dev/null; then
                echo -e "  ${GREEN}✓ nc UDP 套接字通道建立正常${NC}"
                udp_ok=true
            else
                echo -e "  ${YELLOW}⚠ nc UDP 探测无返回（UDP无状态，转入 NTP 协议交互验证）${NC}"
                udp_ok=true
            fi
        else
            echo -e "  ${CYAN}ℹ 未安装 nc，直接进入 NTP 协议探测${NC}"
            udp_ok=true
        fi
        echo ""

        # --- 3.3 远程 NTP 协议层状态与偏差探测 ---
        echo -e "${BLUE}[3/4] 探测远程 NTP 协议与时钟质量...${NC}"
        if [ "$ntp_port" = "123" ] && command -v ntpdate &>/dev/null; then
            echo -e "  ${CYAN}▶ 使用 ntpdate -q 远程查询 ${ntp_target}:${NC}"
            local ntpout
            ntpout=$(ntpdate -q "$ntp_target" 2>&1)
            if echo "$ntpout" | grep -qE "server .*, stratum|offset"; then
                echo -e "  ${GREEN}✓ 成功获取远程 NTP 服务器时钟参数！${NC}"
                echo "$ntpout" | grep -E "server|offset" | while IFS= read -r line; do
                    echo -e "    ${BLUE}│${NC} $line"
                done
                ntp_proto_ok=true
            else
                echo -e "  ${RED}✗ ntpdate 查询失败: $(echo "$ntpout" | head -2)${NC}"
                echo -e "    ${YELLOW}原因可能是: 目标防火墙未放行 UDP 123、容器未启动或尚未收敛 (Stratum 16)${NC}"
            fi
        elif [ "$ntp_port" = "123" ] && command -v ntpq &>/dev/null; then
            echo -e "  ${CYAN}▶ 使用 ntpq -p 远程查询 ${ntp_target}:${NC}"
            local ntpq_out
            ntpq_out=$(ntpq -p "$ntp_target" 2>&1)
            if [ $? -eq 0 ]; then
                echo -e "  ${GREEN}✓ ntpq 远程查询成功${NC}"
                echo "$ntpq_out" | head -8 | while IFS= read -r line; do
                    echo -e "    ${BLUE}│${NC} $line"
                done
                ntp_proto_ok=true
            else
                echo -e "  ${RED}✗ ntpq 远程查询无响应${NC}"
            fi
        else
            if [ "$ntp_port" != "123" ]; then
                echo -e "  ${CYAN}ℹ 自定义端口 ${ntp_port}（非 123 端口）：使用原生 48 字节 NTP 请求包探测...${NC}"
            else
                echo -e "  ${CYAN}▶ 使用原生 UDP 48 字节 NTP 请求包探测...${NC}"
            fi
            if _bash_ntp_probe "$ntp_target" "$ntp_port"; then
                echo -e "  ${GREEN}✓ 远程 NTP 服务器 [${ntp_target}:${ntp_port}] 响应有效 NTP 报文！${NC}"
                ntp_proto_ok=true
            else
                echo -e "  ${RED}✗ 探测超时：远程目标 [${ntp_target}:${ntp_port}] 无 NTP 响应${NC}"
            fi
        fi
        echo ""

        # --- 3.4 远程目标诊断与时钟同步建议 ---
        echo -e "${BLUE}[4/4] 客户端同步建议与命令...${NC}"
        echo -e "  ${CYAN}目标服务器 : ${ntp_target}:${ntp_port}${NC}"
        if [ "$ntp_proto_ok" = true ]; then
            echo -e "  ${GREEN}✓ 状态评估 : 该服务器可作为时间同步源${NC}"
            echo -e "  ${BLUE}  单次同步命令: ${CYAN}ntpdate -u ${ntp_target}${NC}"
            echo -e "  ${BLUE}  Chrony 配置 : 在 /etc/chrony/chrony.conf 中添加 ${CYAN}server ${ntp_target} iburst${NC}"
        else
            echo -e "  ${RED}✗ 状态评估 : 远程服务暂不可达或未就绪${NC}"
            echo -e "  ${YELLOW}  排查建议: 1. 在远程主机检查 docker ps 确认容器运行${NC}"
            echo -e "  ${YELLOW}            2. 检查远程防火墙放行: firewall-cmd --add-port=${ntp_port}/udp --permanent${NC}"
            echo -e "  ${YELLOW}            3. 刚启动容器需等待 30-60 秒完成时钟源握手${NC}"
            overall_ok=false
        fi
    fi
    echo ""

    # --- 汇总状态 ---
    # 检测是否为 stratum 16 场景（ntpdate 有响应但拒绝同步）
    local stratum16_detected=false
    if [ "$udp_ok" = true ] && [ "$ntp_proto_ok" = false ]; then
        # 如果容器运行正常但 NTP 协议拒绝授时，大概率是 stratum 16 问题
        if docker inspect --format='{{.State.Status}}' "$_NTP_CONTAINER_NAME" 2>/dev/null | grep -q 'running'; then
            local recent_log
            recent_log=$(docker logs --tail 10 "$_NTP_CONTAINER_NAME" 2>&1)
            if echo "$recent_log" | grep -qi 'stratum 16\|no servers\|driftfile\|Can.t synchronise'; then
                stratum16_detected=true
            fi
        fi
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [ "$overall_ok" = true ] && [ "$ntp_proto_ok" = true ]; then
        echo -e " ${GREEN}🟢 总体状态: NTP 服务器 [${ntp_target}:${ntp_port}] 响应健康、通信正常！${NC}"
    elif [ "$stratum16_detected" = true ]; then
        echo -e " ${YELLOW}🟡 总体状态: NTP 服务器 [${ntp_target}:${ntp_port}] 响应健康、通信正常！${NC}  ${RED}NTP 服务器认为自己的时钟不可信，拒绝给客户端做时间同步${NC}"
        echo ""
        echo -e " ${RED}┌─── 🔴 Stratum 16 故障诊断 ─────────────────────────────────────────┐${NC}"
        echo -e " ${RED}│${NC} ${YELLOW}根因:${NC} 容器内 chronyd 无法连接公网 NTP 上游，时钟标记为不可信"
        echo -e " ${RED}│${NC} ${YELLOW}影响:${NC} 内网其他服务器无法从本机同步时间（RFC 5905 协议强制拒绝）"
        echo -e " ${RED}│${NC}"
        echo -e " ${RED}│${NC} ${GREEN}修复方案（内网/离线孤岛环境）:${NC}"
        echo -e " ${RED}│${NC}   ${CYAN}步骤1:${NC} 删除现有容器"
        echo -e " ${RED}│${NC}   ${CYAN}  docker rm -f ${_NTP_CONTAINER_NAME}${NC}"
        echo -e " ${RED}│${NC}   ${CYAN}步骤2:${NC} 生成正确的 chrony.conf 离线配置"
        echo -e " ${RED}│${NC}   ${CYAN}  mkdir -p /etc/ntp-docker${NC}"
        echo -e " ${RED}│${NC}   ${CYAN}  cat > /etc/ntp-docker/chrony.conf << 'EOF'${NC}"
        echo -e " ${RED}│${NC}   ${CYAN}  local stratum 10 orphan${NC}"
        echo -e " ${RED}│${NC}   ${CYAN}  allow all${NC}"
        echo -e " ${RED}│${NC}   ${CYAN}  driftfile /var/lib/chrony/chrony.drift${NC}"
        echo -e " ${RED}│${NC}   ${CYAN}  logdir /var/log/chrony${NC}"
        echo -e " ${RED}│${NC}   ${CYAN}  EOF${NC}"
        echo -e " ${RED}│${NC}   ${CYAN}步骤3:${NC} 重新启动容器（挂载 chrony.conf）"
        echo -e " ${RED}│${NC}   ${CYAN}  docker run -d --name ${_NTP_CONTAINER_NAME} --restart=always \\${NC}"
        echo -e " ${RED}│${NC}   ${CYAN}    --cap-add SYS_TIME -p 123:123/udp \\${NC}"
        echo -e " ${RED}│${NC}   ${CYAN}    -v /etc/ntp-docker/chrony.conf:/etc/chrony/chrony.conf:ro \\${NC}"
        echo -e " ${RED}│${NC}   ${CYAN}    cturra/ntp:latest${NC}"
        echo -e " ${RED}│${NC}"
        echo -e " ${RED}│${NC}   ${YELLOW}💡 或使用本脚本菜单: [7]停止容器 → [2]重新部署 → 选择模式2(离线孤岛)${NC}"
        echo -e " ${RED}└─────────────────────────────────────────────────────────────────────┘${NC}"
    elif [ "$udp_ok" = true ] && [ "$ntp_proto_ok" = false ]; then
        echo -e " ${YELLOW}🟡 总体状态: 网络通道可通，但 NTP 协议层未正常响应（可能正在收敛或被拦截）${NC}"
        echo -e "   ${BLUE}提示: 若容器刚启动，请等待 60 秒后重新检测；若持续出现请检查上游 NTP 连通性${NC}"
    else
        echo -e " ${RED}🔴 总体状态: NTP 探测失败，目标服务器无法连通${NC}"
    fi
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "  按回车键返回..." -r < /dev/tty
}

# ----------------------------------------------------------------
# 辅助：离线包优先安装 Chrony
# ----------------------------------------------------------------
_auto_install_chrony() {
    if command -v chronyd &>/dev/null || command -v chronyc &>/dev/null; then
        return 0
    fi

    echo -e "  ${BLUE}正在检测并安装 Chrony 客户端...${NC}"
    local base_dir
    base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local deb_dir="${base_dir}/system/packages/deb"
    local rpm_dir="${base_dir}/system/packages/rpm"

    # 1. 优先尝试本地离线 deb 包 (Debian/Ubuntu/麒麟桌面/统信UOS)
    if command -v dpkg &>/dev/null; then
        local deb_pkg
        deb_pkg=$(ls "${deb_dir}"/chrony*.deb 2>/dev/null | head -n 1)
        if [ -n "$deb_pkg" ] && [ -f "$deb_pkg" ]; then
            echo -e "  ${CYAN}📦 发现本地离线 deb 安装包: $(basename "$deb_pkg")${NC}"
            dpkg -i "$deb_pkg" &>/dev/null
            if command -v chronyd &>/dev/null || command -v chronyc &>/dev/null; then
                echo -e "  ${GREEN}✓ 离线安装 Chrony 成功！${NC}"
                return 0
            fi
        fi
    # 2. 优先尝试本地离线 rpm 包 (CentOS/RHEL/麒麟Server/Euler/Rocky)
    elif command -v rpm &>/dev/null; then
        local rpm_pkg
        rpm_pkg=$(ls "${rpm_dir}"/chrony*.rpm 2>/dev/null | head -n 1)
        if [ -n "$rpm_pkg" ] && [ -f "$rpm_pkg" ]; then
            echo -e "  ${CYAN}📦 发现本地离线 rpm 安装包: $(basename "$rpm_pkg")${NC}"
            rpm -ivh --nodeps "$rpm_pkg" &>/dev/null
            if command -v chronyd &>/dev/null || command -v chronyc &>/dev/null; then
                echo -e "  ${GREEN}✓ 离线安装 Chrony 成功！${NC}"
                return 0
            fi
        fi
    fi

    # 3. 回退到在线包管理器安装
    echo -e "  ${YELLOW}未发现有效本地离线包，尝试系统在线包管理器...${NC}"
    if command -v apt &>/dev/null; then
        apt update -qq 2>/dev/null
        apt install -y chrony &>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y chrony &>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y chrony &>/dev/null
    elif command -v apk &>/dev/null; then
        apk add chrony &>/dev/null
    fi

    if command -v chronyd &>/dev/null || command -v chronyc &>/dev/null; then
        echo -e "  ${GREEN}✓ 在线安装 Chrony 成功！${NC}"
        return 0
    fi

    echo -e "  ${RED}✗ 自动安装 Chrony 失败，请使用菜单 [7] 或系统包管理器手动安装。${NC}"
    return 1
}

# ----------------------------------------------------------------
# B 客户端实现 1: Chrony 守护进程配置、立即同步与状态自检
# ----------------------------------------------------------------
_setup_chrony_client() {
    local target_ip="$1"
    local target_port="${2:-123}"

    echo -e "${BLUE}[3/5] 检测并准备 Chrony 环境...${NC}"
    if ! command -v chronyc &>/dev/null; then
        _auto_install_chrony
        if ! command -v chronyc &>/dev/null; then
            echo -e "  ${RED}✗ 未找到 chronyc 工具，无法继续配置 Chrony 模式${NC}"
            read -p "  按回车键返回..." -r < /dev/tty
            return 1
        fi
    else
        echo -e "  ${GREEN}✓ Chrony 工具已就绪${NC}"
    fi
    echo ""

    echo -e "${BLUE}[4/5] 生成 Chrony 配置文件并启动服务...${NC}"
    local conf_file="/etc/chrony/chrony.conf"
    if [ -f "/etc/chrony.conf" ] || [ ! -d "/etc/chrony" ]; then
        conf_file="/etc/chrony.conf"
    fi

    # 备份现有配置
    if [ -f "$conf_file" ]; then
        cp "$conf_file" "${conf_file}.bak_$(date +%Y%m%d%H%M%S)" 2>/dev/null
        echo -e "  ${CYAN}已备份原配置: ${conf_file}.bak_*${NC}"
    fi

    # 确定 driftfile 目录
    local drift_file="/var/lib/chrony/drift"
    if [ -d "/var/lib/chrony" ]; then
        drift_file="/var/lib/chrony/drift"
    elif [ -d "/var/lib/ntp" ]; then
        drift_file="/var/lib/ntp/drift"
    fi
    mkdir -p "$(dirname "$drift_file")" /var/log/chrony 2>/dev/null

    local server_line="server ${target_ip} iburst"
    if [ "$target_port" != "123" ]; then
        server_line="server ${target_ip} port ${target_port} iburst"
    fi

    cat > "$conf_file" << CHRONY_CONF_EOF
# ============================================================
# Chrony 客户端同步配置 (由 Linux-ops-box 自动生成)
# 目标服务端 (A端): ${target_ip}:${target_port}
# ============================================================

${server_line}

# 允许前 3 次时钟更新使用步进(step)快速消除大偏差，阈值 1 秒
makestep 1.0 3

# 自动将系统时间写回内核硬件时钟 (RTC)
rtcsync

# 时钟漂移记录
driftfile ${drift_file}

# 日志输出目录
logdir /var/log/chrony
CHRONY_CONF_EOF

    echo -e "  ${GREEN}✓ 客户端配置已写入: ${conf_file}${NC}"

    local srv_name="chrony"
    if command -v systemctl &>/dev/null; then
        for candidate in chrony chronyd; do
            if systemctl cat "$candidate" &>/dev/null 2>&1 || \
               [ -f "/lib/systemd/system/${candidate}.service" ] || \
               [ -f "/usr/lib/systemd/system/${candidate}.service" ] || \
               [ -f "/etc/systemd/system/${candidate}.service" ]; then
                srv_name="$candidate"
                break
            fi
        done

        # 若系统无现成 unit 文件（如直接下载的离线包或静态编译），自动生成标准服务单元
        if ! systemctl cat "$srv_name" &>/dev/null 2>&1; then
            local chronyd_bin
            chronyd_bin=$(command -v chronyd 2>/dev/null || echo "/usr/sbin/chronyd")
            cat > /etc/systemd/system/chrony.service << UNIT_EOF
[Unit]
Description=chrony, an NTP client/server
Documentation=man:chronyd(8) man:chrony.conf(5)
After=network.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=${chronyd_bin}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF
            srv_name="chrony"
            systemctl daemon-reload 2>/dev/null
        fi

        systemctl daemon-reload 2>/dev/null
        systemctl unmask "$srv_name" 2>/dev/null
        systemctl enable "$srv_name" 2>/dev/null

        # 杀掉可能存在的冲突或孤儿进程以确保 systemd 干净接管
        pkill -9 chronyd 2>/dev/null || true
        rm -f /var/run/chrony/chronyd.pid /var/run/chronyd.pid 2>/dev/null
        systemctl restart "$srv_name" 2>/dev/null

        if systemctl is-active "$srv_name" &>/dev/null; then
            echo -e "  ${GREEN}✓ ${srv_name} 服务已启动并设置开机自启${NC}"
        elif pgrep -x chronyd &>/dev/null; then
            echo -e "  ${GREEN}✓ chronyd 守护进程运行中${NC}"
        else
            echo -e "  ${YELLOW}⚠ 尝试启动 chronyd 进程...${NC}"
            chronyd 2>/dev/null || true
        fi
    elif command -v service &>/dev/null; then
        service chrony restart 2>/dev/null || service chronyd restart 2>/dev/null
        echo -e "  ${GREEN}✓ Chrony 服务已重启${NC}"
    fi
    echo ""

    echo -e "${BLUE}[5/5] 立即强制步进对齐大偏差 + 状态自检...${NC}"
    echo ""

    # ──────────────────────────────────────────────────────────────
    # 阶段 A: chronyd -q 单次模式 — 先暴力矫正大偏差
    # ──────────────────────────────────────────────────────────────
    # 原理: -q 模式让 chronyd 独立采样 NTP 包后立即 step 系统时钟并退出
    #       无论偏差多大（3分钟/1小时均可瞬间矫正），不受 makestep 策略限制
    #       必须先停掉守护进程，否则两个 chronyd 实例冲突
    # ──────────────────────────────────────────────────────────────
    echo -e "  ${CYAN}▶ 阶段 A: chronyd -q 单次强制矫正模式（处理大偏差 > 1 秒）${NC}"

    local chrony_srv_expr
    if [ "$target_port" = "123" ]; then
        chrony_srv_expr="server ${target_ip} iburst"
    else
        chrony_srv_expr="server ${target_ip} port ${target_port} iburst"
    fi

    # 临时停掉守护进程以释放套接字，-q 完成后再重启
    local _srv_was_active=false
    if command -v systemctl &>/dev/null && systemctl is-active "$srv_name" &>/dev/null; then
        _srv_was_active=true
        systemctl stop "$srv_name" 2>/dev/null
        pkill -9 chronyd 2>/dev/null || true
        sleep 1
    fi

    echo -ne "  ${BLUE}  ⏳ 正在单次采样 A 端 [${target_ip}:${target_port}]...${NC}  "
    local q_out q_rc
    q_out=$(chronyd -q "$chrony_srv_expr" 2>&1)
    q_rc=$?

    if [ $q_rc -eq 0 ] || echo "$q_out" | grep -qiE "System clock|offset|stepped|adjust"; then
        echo -e "${GREEN}✓ 大偏差矫正成功！${NC}"
        # 显示矫正量
        local step_line
        step_line=$(echo "$q_out" | grep -iE "System clock|offset|step" | head -2)
        [ -n "$step_line" ] && echo -e "    ${CYAN}└─ $(echo "$step_line" | tr '\n' '|' | sed 's/|$//')${NC}"
    else
        echo -e "${YELLOW}⚠ 单次模式未确认矫正（可能 A 端尚在收敛中）${NC}"
        echo -e "    ${BLUE}输出: $(echo "$q_out" | tail -2)${NC}"
    fi
    echo ""

    # ──────────────────────────────────────────────────────────────
    # 阶段 B: 重启守护进程做持续精细跟踪
    # ──────────────────────────────────────────────────────────────
    echo -e "  ${CYAN}▶ 阶段 B: 重启 Chrony 守护进程做持续精细校准...${NC}"
    pkill -9 chronyd 2>/dev/null || true
    rm -f /var/run/chrony/chronyd.pid /var/run/chronyd.pid 2>/dev/null
    sleep 1

    if command -v systemctl &>/dev/null; then
        systemctl start "$srv_name" 2>/dev/null || chronyd 2>/dev/null || true
    elif command -v service &>/dev/null; then
        service "$srv_name" start 2>/dev/null || chronyd 2>/dev/null || true
    else
        chronyd 2>/dev/null || true
    fi

    # ──────────────────────────────────────────────────────────────
    # 阶段 C: 轮询等待守护进程真正锁定时钟源（最多等 30 秒）
    # ──────────────────────────────────────────────────────────────
    echo -ne "  ${CYAN}▶ 阶段 C: 等待守护进程锁定时钟源 (最多 30s)...${NC}"
    local wait_sec=0
    local locked=false
    while [ $wait_sec -lt 30 ]; do
        sleep 2
        wait_sec=$(( wait_sec + 2 ))
        # ^* 标记表示已选定主时钟源
        if chronyc sources 2>/dev/null | grep -q '^\^\*'; then
            locked=true
            break
        fi
        echo -ne "."
    done
    echo ""

    if [ "$locked" = true ]; then
        echo -e "  ${GREEN}✓ 时钟源已锁定 (^*)！${NC}"
    else
        echo -e "  ${YELLOW}⚠ 30 秒内未锁定（正常：守护进程继续后台采样，约 60 秒自动锁定）${NC}"
    fi
    echo ""

    # ──────────────────────────────────────────────────────────────
    # 阶段 D: makestep 再触发一次精细步进（消除采样抖动残差）
    # ──────────────────────────────────────────────────────────────
    echo -ne "  ${CYAN}▶ 阶段 D: chronyc makestep 精细步进残差...${NC}  "
    local step_res
    step_res=$(chronyc makestep 2>&1)
    if echo "$step_res" | grep -qiE "200 OK|Clock was stepped|stepped"; then
        echo -e "${GREEN}✓ 精细步进完成${NC}"
    else
        echo -e "${BLUE}─ 已在公差内无需步进${NC}"
    fi
    echo ""

    # 写回硬件时钟
    echo -ne "  ${CYAN}▶ 写回硬件时钟 (hwclock --systohc)...${NC}  "
    hwclock --systohc 2>/dev/null \
        && echo -e "${GREEN}✓ 已更新${NC}" \
        || echo -e "${YELLOW}⚠ 跳过（虚拟化/容器环境正常）${NC}"
    echo ""

    echo -e "${GREEN}══════════════ 📊 B 客户端同步状态报告 ══════════════${NC}"
    echo -e "  ${CYAN}当前系统时间: $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
    echo ""
    echo -e "  ${BLUE}1. 时钟源同步状态 (chronyc sources -v):${NC}"
    chronyc sources -v 2>/dev/null || echo -e "  ${YELLOW}暂无法获取 sources 详情${NC}"
    echo ""
    echo -e "  ${BLUE}2. 时钟跟踪与偏差详情 (chronyc tracking):${NC}"
    chronyc tracking 2>/dev/null || echo -e "  ${YELLOW}暂无法获取 tracking 详情${NC}"
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
    if [ "$locked" = true ]; then
        echo -e "  ${GREEN}🎉 B 客户端 Chrony 部署完成，时钟已与 A 端对齐！${NC}"
    else
        echo -e "  ${YELLOW}⚡ B 客户端 Chrony 部署完成，守护进程正在后台持续对齐，约 60s 内完全锁定。${NC}"
    fi
    echo -e "  ${CYAN}  • Chrony 标记 '^*' = 已锁定主时钟源  '^?' = 采样中（正常过渡态）${NC}"
    echo -e "  ${CYAN}  • 后续可用菜单 [3] 随时查验 B 端同步状态与偏差值${NC}"
    echo ""
    read -p "  按回车键返回..." -r < /dev/tty
}

# ----------------------------------------------------------------
# B 客户端实现 2: Systemd 定时/开机同步脚本方式
# ----------------------------------------------------------------
_setup_script_client() {
    local target_ip="$1"
    local target_port="${2:-123}"

    echo -e "${BLUE}[3/5] 检测 Systemd 与同步工具环境...${NC}"
    if ! command -v systemctl &>/dev/null; then
        echo -e "  ${YELLOW}⚠ 当前系统不支持 Systemd，转为 cron 方式配置${NC}"
        _setup_ntp_sync_cron
        return
    fi
    echo -e "  ${GREEN}✓ Systemd 可用${NC}"
    echo ""

    echo -e "${BLUE}[4/5] 生成同步脚本: ${_NTP_SYNC_SCRIPT}...${NC}"
    cat > "$_NTP_SYNC_SCRIPT" << SCRIPT_EOF
#!/bin/bash
# ============================================================
# NTP 时间同步脚本 (由 Linux-ops-box 自动生成)
# 目标服务端: ${target_ip}:${target_port}
# ============================================================

TARGET_IP="${target_ip}"
TARGET_PORT="${target_port}"
LOG_FILE="/var/log/ntp-sync.log"
LOCK_FILE="/var/run/ntp-sync.lock"

[ -f "\$LOCK_FILE" ] && exit 0
touch "\$LOCK_FILE"
trap 'rm -f "\$LOCK_FILE"' EXIT

_log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" >> "\$LOG_FILE"
}

_log "=== 开始时间同步 (目标: \${TARGET_IP}:\${TARGET_PORT}) ==="
synced=false

if [ "\$TARGET_PORT" = "123" ] && command -v ntpdate &>/dev/null; then
    if ntpdate -u -t 5 "\$TARGET_IP" >> "\$LOG_FILE" 2>&1; then
        _log "ntpdate 同步成功"
        synced=true
    fi
fi

if [ "\$synced" = false ] && command -v chronyc &>/dev/null; then
    if chronyc makestep >> "\$LOG_FILE" 2>&1; then
        _log "chronyc makestep 同步成功"
        synced=true
    fi
fi

if [ "\$synced" = true ]; then
    hwclock --systohc >> "\$LOG_FILE" 2>&1 || true
    _log "=== 同步完成并已写回硬件时钟 ==="
    exit 0
else
    _log "=== 同步尝试失败 ==="
    exit 1
fi
SCRIPT_EOF

    chmod +x "$_NTP_SYNC_SCRIPT"
    echo -e "  ${GREEN}✓ 同步脚本已生成: ${_NTP_SYNC_SCRIPT}${NC}"

    cat > "$_NTP_SERVICE_FILE" << SERVICE_EOF
[Unit]
Description=NTP Time Sync Service (Linux-ops-box)
Documentation=https://github.com/kikock/Linux-ops-box
After=network-online.target
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
    systemctl enable ntp-sync.service &>/dev/null
    echo -e "  ${GREEN}✓ Systemd 服务已注册并启用开机自启${NC}"
    echo ""

    echo -e "${BLUE}[5/5] 立即执行测试同步与状态自检...${NC}"
    bash "$_NTP_SYNC_SCRIPT"
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}✓ 脚本执行同步成功！当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
    else
        echo -e "  ${YELLOW}⚠ 初次同步未成功或无输出，请检查 /var/log/ntp-sync.log 日志${NC}"
    fi

    echo ""
    read -p "  按回车键返回..." -r < /dev/tty
}

# ================================================================
# 功能 4：配置客户端时间同步 + 开机自启 (B端/客户端)
# ================================================================
_setup_ntp_sync_service() {
    clear
    _time_header "配置客户端时间同步 (B端/客户端)"
    echo ""

    echo -e "${BLUE}[1/5] 配置目标 NTP 服务器地址与端口 (A端服务端)...${NC}"
    echo -e "  说明: 请输入 A 端 NTP 服务器的 IP 地址以及 UDP 端口（默认 123）。"
    read -p "  请输入 A 端 NTP 服务器 IP 地址 [默认: 127.0.0.1]: " target_ip < /dev/tty
    target_ip="${target_ip:-127.0.0.1}"
    read -p "  请输入 A 端 NTP 服务 UDP 端口 [直接回车=123]: " target_port < /dev/tty
    target_port="${target_port:-123}"
    if ! [[ "$target_port" =~ ^[0-9]+$ ]] || [ "$target_port" -lt 1 ] || [ "$target_port" -gt 65535 ]; then
        target_port=123
    fi
    echo -e "  ${GREEN}✓ 目标 NTP 服务: ${target_ip}:${target_port}${NC}"
    echo ""

    echo -e "${BLUE}[2/5] 选择客户端同步方式...${NC}"
    echo -e "  1. ${GREEN}Chrony 守护进程模式${NC} (强烈推荐) — 支持任意自定义端口，精度高，平滑时钟微调，开机自动步进"
    echo -e "  2. ${CYAN}Systemd 单次/定时同步脚本模式${NC} — 基于脚本轻量执行，适合资源严苛环境"
    echo ""
    read -p "  请选择同步方式 [1-2，直接回车=1]: " sync_mode_choice < /dev/tty
    sync_mode_choice="${sync_mode_choice:-1}"
    echo ""

    if [ "$sync_mode_choice" = "1" ]; then
        _setup_chrony_client "$target_ip" "$target_port"
    else
        _setup_script_client "$target_ip" "$target_port"
    fi
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

# ----------------------------------------------------------------
# 内部辅助：执行单次 NTP 同步（指定服务器+端口，自动选择工具）
# 参数: $1=NTP服务器IP/域名  $2=UDP端口(默认123)
# 返回: 0=同步成功  1=失败
# ----------------------------------------------------------------
_do_ntp_sync_once() {
    local target_host="${1:-127.0.0.1}"
    local target_port="${2:-123}"
    local synced=false

    echo -e "  ${CYAN}⏳ 正在向 [${target_host}:${target_port}] 发起时间同步...${NC}"
    echo ""

    # ── 方式 1: ntpdate（最简单直接）──
    if command -v ntpdate &>/dev/null; then
        echo -ne "  ${BLUE}▶ 方式1 ntpdate -u -t 8 ${target_host}...${NC}  "
        local ntpdate_out
        if [ "$target_port" = "123" ]; then
            ntpdate_out=$(ntpdate -u -t 8 "$target_host" 2>&1)
        else
            # ntpdate 不支持自定义端口，跳过
            echo -e "${YELLOW}⚠ ntpdate 不支持非 123 端口，跳过${NC}"
            ntpdate_out=""
        fi
        if [ -n "$ntpdate_out" ] && echo "$ntpdate_out" | grep -qiE "adjust|step|offset"; then
            echo -e "${GREEN}✓ 同步成功${NC}"
            echo -e "    ${CYAN}${ntpdate_out}${NC}"
            synced=true
        elif [ "$target_port" = "123" ]; then
            echo -e "${RED}✗ 失败: $(echo "$ntpdate_out" | head -1)${NC}"
        fi
    fi

    # ── 方式 2: chronyd 单次查询模式（支持自定义端口，无需守护进程，可修正任意大偏差）──
    if [ "$synced" = false ] && command -v chronyd &>/dev/null; then
        echo -ne "  ${BLUE}▶ 方式2 chronyd -q 单次模式 [${target_host}:${target_port}]...${NC}  "
        local chrony_srv_expr
        if [ "$target_port" = "123" ]; then
            chrony_srv_expr="server ${target_host} iburst"
        else
            chrony_srv_expr="server ${target_host} port ${target_port} iburst"
        fi

        # ── 关键: -q 模式需要独占 UDP 套接字，必须先停守护进程 ──
        local _daemon_was_running=false
        local _daemon_srv=""
        for _s in chrony chronyd; do
            if command -v systemctl &>/dev/null && systemctl is-active "$_s" &>/dev/null; then
                _daemon_was_running=true
                _daemon_srv="$_s"
                systemctl stop "$_s" 2>/dev/null
                pkill -9 chronyd 2>/dev/null || true
                sleep 1
                break
            elif pgrep -x chronyd &>/dev/null; then
                _daemon_was_running=true
                pkill -9 chronyd 2>/dev/null || true
                sleep 1
                break
            fi
        done

        local chrony_out
        chrony_out=$(chronyd -q "$chrony_srv_expr" 2>&1)
        local chrony_rc=$?

        # ── 单次同步完成后，恢复守护进程 ──
        if [ "$_daemon_was_running" = true ]; then
            if [ -n "$_daemon_srv" ] && command -v systemctl &>/dev/null; then
                systemctl start "$_daemon_srv" 2>/dev/null || chronyd 2>/dev/null || true
            else
                chronyd 2>/dev/null || true
            fi
        fi

        if [ $chrony_rc -eq 0 ] || echo "$chrony_out" | grep -qiE "System clock|offset|stepped"; then
            echo -e "${GREEN}✓ 同步成功${NC}"
            echo "$chrony_out" | grep -iE "offset|clock|step" | head -3 | while IFS= read -r line; do
                echo -e "    ${CYAN}│ ${line}${NC}"
            done
            synced=true
        else
            echo -e "${RED}✗ 失败: $(echo "$chrony_out" | tail -1)${NC}"
        fi
    fi

    # ── 方式 3: chronyc makestep（仅适用已配置守护进程的情况）──
    if [ "$synced" = false ] && command -v chronyc &>/dev/null; then
        echo -ne "  ${BLUE}▶ 方式3 chronyc makestep（触发守护进程步进）...${NC}  "
        local step_out
        step_out=$(chronyc makestep 2>&1)
        if echo "$step_out" | grep -qiE "200 OK|Clock was stepped|done"; then
            echo -e "${GREEN}✓ 步进触发成功${NC}"
            synced=true
        else
            echo -e "${YELLOW}⚠ 跳过: $(echo "$step_out" | head -1)${NC}"
        fi
    fi

    # ── 方式 4: timedatectl（开启系统 NTP，不指定特定服务器）──
    if [ "$synced" = false ] && command -v timedatectl &>/dev/null && [ "$target_host" = "127.0.0.1" ]; then
        echo -ne "  ${BLUE}▶ 方式4 timedatectl set-ntp true...${NC}  "
        timedatectl set-ntp true &>/dev/null
        echo -e "${GREEN}✓ 系统 NTP 已启用${NC}"
        synced=true
    fi

    echo ""
    if [ "$synced" = true ]; then
        # 写回硬件时钟
        echo -ne "  ${CYAN}➜ 写回硬件时钟 (hwclock --systohc)...${NC}  "
        hwclock --systohc 2>/dev/null \
            && echo -e "${GREEN}✓ 已更新${NC}" \
            || echo -e "${YELLOW}⚠ 跳过（虚拟化/容器环境正常）${NC}"
        echo ""
        echo -e "  ${GREEN}✅ 同步完成！当前系统时间: ${CYAN}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
        return 0
    else
        echo -e "  ${RED}✗ 所有同步方式均失败，请检查网络/工具/服务状态。${NC}"
        return 1
    fi
}

# ----------------------------------------------------------------
# 选项 1: 手动指定 NTP 服务器进行同步
# ----------------------------------------------------------------
_sync_manual_ntp_server() {
    clear
    _time_header "立即手动同步 ▸ 指定 NTP 服务器"
    echo ""

    echo -e "${BLUE}请输入目标 NTP 服务器地址（支持 IP 或域名，可含端口）${NC}"
    echo -e "  示例: ${CYAN}ntp.aliyun.com${NC}   ${CYAN}192.168.1.100${NC}   ${CYAN}192.168.1.100:1123${NC}"
    echo -e "  常用公网服务器:"
    echo -e "    ${CYAN}ntp.aliyun.com${NC}    (阿里云，国内推荐 ★)"
    echo -e "    ${CYAN}ntp.tencent.com${NC}   (腾讯云)"
    echo -e "    ${CYAN}cn.ntp.org.cn${NC}     (中国 NTP 池)"
    echo -e "    ${CYAN}pool.ntp.org${NC}      (全球 NTP 池)"
    echo ""
    read -p "  请输入 NTP 服务器 [直接回车=ntp.aliyun.com]: " user_input < /dev/tty
    user_input="${user_input:-ntp.aliyun.com}"

    # 解析 host:port
    local sync_host sync_port
    user_input=$(echo "$user_input" | tr -d ' ')
    if [[ "$user_input" == *":"* ]]; then
        sync_host="${user_input%%:*}"
        sync_port="${user_input##*:}"
    else
        sync_host="$user_input"
        sync_port="123"
    fi

    # 端口合法性检查
    if ! [[ "$sync_port" =~ ^[0-9]+$ ]] || [ "$sync_port" -lt 1 ] || [ "$sync_port" -gt 65535 ]; then
        echo -e "  ${YELLOW}⚠ 端口无效，已重置为 123${NC}"
        sync_port="123"
    fi

    echo ""
    echo -e "  ${GREEN}✓ 目标服务器: ${CYAN}${sync_host}:${sync_port}${NC}"
    echo ""

    # 检查工具可用性
    local has_tool=false
    command -v ntpdate &>/dev/null && has_tool=true
    command -v chronyd  &>/dev/null && has_tool=true
    command -v chronyc  &>/dev/null && has_tool=true
    if [ "$has_tool" = false ]; then
        echo -e "  ${RED}✗ 未检测到任何 NTP 客户端工具 (ntpdate / chronyd / chronyc)${NC}"
        echo -e "  ${YELLOW}  请先进入菜单 [8] 安装 NTP 工具后再重试。${NC}"
        echo ""
        read -p "  按回车键返回..." -r < /dev/tty
        return 1
    fi

    _do_ntp_sync_once "$sync_host" "$sync_port"
    echo ""
    read -p "  按回车键返回..." -r < /dev/tty
}

# ----------------------------------------------------------------
# 选项 2: 与本机已部署的 Docker NTP 服务器进行同步
# ----------------------------------------------------------------
_sync_with_docker_ntp() {
    clear
    _time_header "立即手动同步 ▸ 与 Docker NTP 服务器同步"
    echo ""

    # --- 2.1 检查 Docker 可用性 ---
    echo -e "${BLUE}[1/3] 检查 Docker 环境与 NTP 容器状态...${NC}"
    if ! command -v docker &>/dev/null; then
        echo -e "  ${RED}✗ Docker 未安装！${NC}"
        echo -e "  ${YELLOW}请先在 [主菜单 → Docker 管理中心] 安装 Docker 后重试。${NC}"
        echo ""
        read -p "  按回车键返回..." -r < /dev/tty
        return 1
    fi

    if ! docker info &>/dev/null; then
        echo -e "  ${YELLOW}⚠ Docker 守护进程未运行，尝试启动...${NC}"
        systemctl start docker 2>/dev/null
        sleep 2
        if ! docker info &>/dev/null; then
            echo -e "  ${RED}✗ Docker 启动失败，请手动检查。${NC}"
            echo ""
            read -p "  按回车键返回..." -r < /dev/tty
            return 1
        fi
    fi

    # --- 2.2 探测 NTP 容器与映射端口 ---
    local container_status
    container_status=$(docker inspect --format='{{.State.Status}}' "$_NTP_CONTAINER_NAME" 2>/dev/null)

    if [ -z "$container_status" ]; then
        echo -e "  ${RED}✗ 未找到 NTP 容器 [${_NTP_CONTAINER_NAME}]！${NC}"
        echo -e "  ${YELLOW}请先进入菜单 [1] 部署 Docker NTP 服务器后再使用此功能。${NC}"
        echo ""
        read -p "  按回车键返回..." -r < /dev/tty
        return 1
    fi

    if [ "$container_status" != "running" ]; then
        echo -e "  ${RED}✗ NTP 容器状态为 [${container_status}]，未在运行！${NC}"
        echo -e "  ${YELLOW}请检查容器状态: docker ps -a | grep ${_NTP_CONTAINER_NAME}${NC}"
        echo -e "  ${YELLOW}或使用菜单 [1] 重新部署。${NC}"
        echo ""
        read -p "  按回车键返回..." -r < /dev/tty
        return 1
    fi

    # 解析宿主机映射端口（UDP 123 内部端口对应的宿主机端口）
    local host_port
    host_port=$(docker inspect --format='{{range $p, $b := .NetworkSettings.Ports}}{{if $b}}{{(index $b 0).HostPort}}{{end}}{{end}}' \
        "$_NTP_CONTAINER_NAME" 2>/dev/null | tr -s ' \n' '\n' | head -1)

    # 备用解析方式
    if [ -z "$host_port" ]; then
        host_port=$(docker port "$_NTP_CONTAINER_NAME" 123/udp 2>/dev/null | awk -F: '{print $2}' | head -1)
    fi

    # 若仍为空，默认 123
    host_port="${host_port:-123}"

    # 获取容器镜像与启动时间
    local c_image c_start
    c_image=$(docker inspect --format='{{.Config.Image}}' "$_NTP_CONTAINER_NAME" 2>/dev/null)
    c_start=$(docker inspect --format='{{.State.StartedAt}}' "$_NTP_CONTAINER_NAME" 2>/dev/null | cut -c1-19 | tr 'T' ' ')

    echo -e "  ${GREEN}✓ NTP 容器 [${_NTP_CONTAINER_NAME}] 运行正常${NC}"
    echo -e "  ${CYAN}  镜像      : ${c_image}${NC}"
    echo -e "  ${CYAN}  启动时间  : ${c_start} UTC${NC}"
    echo -e "  ${CYAN}  宿主机端口: UDP ${host_port} → 容器内 UDP 123${NC}"
    echo ""

    # --- 2.3 先做 NTP 协议连通探测 ---
    echo -e "${BLUE}[2/3] 验证 Docker NTP 服务可达性（NTP 协议探测）...${NC}"
    if _bash_ntp_probe "127.0.0.1" "$host_port" 3; then
        echo -e "  ${GREEN}✓ NTP 协议探测成功！服务已就绪，可以同步。${NC}"
    else
        echo -e "  ${YELLOW}⚠ NTP 协议探测超时（容器可能仍在初始化，约 30 秒收敛）${NC}"
        echo -e "  ${YELLOW}  建议等待后重试，或先在菜单 [4] 执行健康检测。${NC}"
        echo ""
        read -p "  是否仍然强制尝试同步? [y/N]: " force_sync < /dev/tty
        if [[ ! "$force_sync" =~ ^[Yy]$ ]]; then
            echo -e "  ${BLUE}已取消。${NC}"
            echo ""
            read -p "  按回车键返回..." -r < /dev/tty
            return 1
        fi
    fi
    echo ""

    # --- 2.4 执行同步 ---
    echo -e "${BLUE}[3/3] 执行时间同步...${NC}"

    # 检查工具可用性
    local has_tool=false
    command -v ntpdate &>/dev/null && has_tool=true
    command -v chronyd  &>/dev/null && has_tool=true
    command -v chronyc  &>/dev/null && has_tool=true

    if [ "$has_tool" = false ]; then
        echo -e "  ${RED}✗ 未检测到任何 NTP 客户端工具 (ntpdate / chronyd / chronyc)${NC}"
        echo -e "  ${YELLOW}  请先进入菜单 [8] 安装 NTP 工具后再重试。${NC}"
        echo ""
        read -p "  按回车键返回..." -r < /dev/tty
        return 1
    fi

    _do_ntp_sync_once "127.0.0.1" "$host_port"

    # 显示容器最新日志（同步后参考）
    echo ""
    echo -e "  ${BLUE}📋 Docker NTP 容器近期日志 (最新 5 条):${NC}"
    docker logs --tail 5 "$_NTP_CONTAINER_NAME" 2>&1 | while IFS= read -r line; do
        echo -e "    ${CYAN}│${NC} $line"
    done

    echo ""
    read -p "  按回车键返回..." -r < /dev/tty
}

# ----------------------------------------------------------------
# 主函数: 手动同步时间 — 子菜单入口
# ----------------------------------------------------------------
_manual_sync_time() {
    clear
    _time_header "立即手动同步系统时间"
    echo ""

    echo -e "${BLUE}请选择同步方式:${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} 指定 NTP 服务器同步"
    echo -e "     ${BLUE}│${NC} 手动输入任意 NTP 服务器地址（支持 IP/域名/自定义端口）"
    echo -e "     ${BLUE}│${NC} 适用场景: 公网同步、局域网指定服务器同步"
    echo ""
    echo -e "  ${CYAN}2.${NC} 与本机 Docker NTP 服务器同步"
    echo -e "     ${BLUE}│${NC} 自动探测已部署的 [${_NTP_CONTAINER_NAME}] 容器端口"
    echo -e "     ${BLUE}│${NC} 适用场景: 本机已运行 Docker NTP 容器（菜单 [1] 已部署）"
    echo ""
    echo -e "  ${YELLOW}3.${NC} 自动同步（快速模式）"
    echo -e "     ${BLUE}│${NC} 自动按顺序尝试已配置脚本 → 公网 NTP 源"
    echo ""
    echo -e "  0. 返回"
    echo ""
    read -p "  请选择 [0-3，直接回车=1]: " sync_choice < /dev/tty
    sync_choice="${sync_choice:-1}"

    case "$sync_choice" in
        1)
            _sync_manual_ntp_server
            ;;
        2)
            _sync_with_docker_ntp
            ;;
        3)
            # ── 原有自动快速同步逻辑 ──
            clear
            _time_header "立即手动同步系统时间 ▸ 自动模式"
            echo ""

            # 检查是否已有同步脚本
            if [ -f "$_NTP_SYNC_SCRIPT" ]; then
                echo -e "${BLUE}检测到已配置同步脚本，正在执行...${NC}"
                bash "$_NTP_SYNC_SCRIPT"
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ 时间同步成功！当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
                else
                    echo -e "${YELLOW}⚠ 同步脚本执行失败，继续尝试直接同步...${NC}"
                fi
            else
                echo -e "${YELLOW}未找到已配置的同步脚本，直接尝试公网 NTP 源...${NC}"
            fi

            echo ""
            local synced=false
            local servers=("ntp.aliyun.com" "ntp.tencent.com" "cn.ntp.org.cn" "pool.ntp.org")

            for srv in "${servers[@]}"; do
                echo -ne "  ${CYAN}尝试 ${srv}...${NC}  "
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
                    else
                        echo -e "${YELLOW}⚠ 跳过${NC}"
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
                echo -ne "  ${CYAN}➜ 写回硬件时钟...${NC}  "
                hwclock --systohc 2>/dev/null \
                    && echo -e "${GREEN}✓ 硬件时钟已更新${NC}" \
                    || echo -e "${YELLOW}⚠ hwclock 写入跳过（容器/虚拟机环境正常）${NC}"
                echo -e "  ${CYAN}当前系统时间: $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
            else
                echo ""
                echo -e "  ${RED}✗ 所有 NTP 服务器同步失败。${NC}"
                echo -e "  ${YELLOW}  提示: 可选择菜单选项 [1] 手动指定内网 NTP 服务器，或 [8] 安装同步工具。${NC}"
            fi

            echo ""
            read -p "  按回车键返回..." -r < /dev/tty
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}输入无效。${NC}"
            sleep 1
            ;;
    esac
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
# 功能：校验客户端时间同步与开机自启状态 (B端专属检测)
# ================================================================
_check_client_sync_status() {
    clear
    _time_header "客户端时间同步与开机自启状态校验 (B端)"
    echo ""

    echo -e "${BLUE}正在对当前主机进行客户端时间同步体系全项体检...${NC}"
    echo ""

    local srv_name=""
    local srv_active=false
    local srv_enabled=false
    local mode_desc="未知"

    # 1. 深度探测 Chrony 服务与进程
    if command -v chronyd &>/dev/null || command -v chronyc &>/dev/null || pgrep -x chronyd &>/dev/null; then
        mode_desc="Chrony 守护进程模式"
        for candidate in chrony chronyd; do
            if systemctl cat "$candidate" &>/dev/null 2>&1 || \
               [ -f "/lib/systemd/system/${candidate}.service" ] || \
               [ -f "/usr/lib/systemd/system/${candidate}.service" ] || \
               [ -f "/etc/systemd/system/${candidate}.service" ] || \
               [ "$(systemctl is-enabled "$candidate" 2>/dev/null)" = "enabled" ] || \
               [ "$(systemctl is-active "$candidate" 2>/dev/null)" = "active" ]; then
                srv_name="$candidate"
                break
            fi
        done
        [ -z "$srv_name" ] && srv_name="chrony"
    fi

    # 2. 检测 Systemd 同步脚本模式
    if [ -z "$srv_name" ] && [ -f "$_NTP_SERVICE_FILE" ]; then
        mode_desc="Systemd 脚本自启模式"
        srv_name="ntp-sync.service"
    fi

    echo -e "${GREEN}══════════════ [1/4] 服务运行状态 ══════════════${NC}"
    if [ -n "$srv_name" ] && command -v systemctl &>/dev/null; then
        local srv_status
        srv_status=$(systemctl is-active "$srv_name" 2>/dev/null)
        if [ "$srv_status" = "active" ]; then
            srv_active=true
            echo -e "  服务名称: ${CYAN}${srv_name}${NC}"
            echo -e "  运行状态: ${GREEN}✓ 运行中 (active)${NC}"
            echo -e "  同步模式: ${CYAN}${mode_desc}${NC}"
        elif pgrep -x chronyd &>/dev/null; then
            srv_active=true
            echo -e "  服务名称: ${CYAN}${srv_name}${NC}"
            echo -e "  运行状态: ${GREEN}✓ chronyd 守护进程运行中 (PID: $(pgrep -x chronyd | head -1))${NC}"
            echo -e "  同步模式: ${CYAN}${mode_desc}${NC}"
        else
            echo -e "  服务名称: ${CYAN}${srv_name}${NC}"
            echo -e "  运行状态: ${RED}✗ 未运行 (${srv_status})${NC}"
        fi
    elif pgrep -x chronyd &>/dev/null; then
        srv_active=true
        echo -e "  运行状态: ${GREEN}✓ chronyd 进程运行中 (PID: $(pgrep -x chronyd | head -1))${NC}"
    else
        echo -e "  运行状态: ${YELLOW}⚠ 未检测到活跃的 Chrony 或 ntp-sync 客户端服务${NC}"
    fi
    echo ""

    echo -e "${GREEN}══════════════ [2/4] 开机自启状态 ══════════════${NC}"
    local detected_enabled=false
    local enabled_srv_name=""
    if command -v systemctl &>/dev/null; then
        for s in chrony chronyd "$srv_name"; do
            [ -z "$s" ] && continue
            local st
            st=$(systemctl is-enabled "$s" 2>/dev/null)
            if [ "$st" = "enabled" ] || [ "$st" = "enabled-runtime" ]; then
                detected_enabled=true
                enabled_srv_name="$s"
                break
            fi
        done

        if [ "$detected_enabled" = true ]; then
            srv_enabled=true
            srv_name="$enabled_srv_name"
            echo -e "  开机自启: ${GREEN}✓ 已启用 (enabled)${NC} — 服务 [${enabled_srv_name}] 开机将自动启动并同步"
        else
            local cur_st
            cur_st=$(systemctl is-enabled "$srv_name" 2>/dev/null)
            if [ "$cur_st" = "disabled" ]; then
                echo -e "  开机自启: ${YELLOW}⚠ 当前未开启 (disabled)${NC}"
            else
                echo -e "  开机自启: ${YELLOW}⚠ 尚未配置开机自启服务${NC}"
            fi
        fi
    elif [ -f /etc/rc.local ] && grep -q "ntp-sync" /etc/rc.local; then
        srv_enabled=true
        echo -e "  开机自启: ${GREEN}✓ 已配置在 /etc/rc.local${NC}"
    else
        echo -e "  开机自启: ${YELLOW}⚠ 未检测到开机自启配置${NC}"
    fi
    echo ""

    echo -e "${GREEN}══════════════ [3/4] 时钟源锁定与偏差详情 ══════════════${NC}"
    local is_synced=false
    local synced_ip=""
    local offset_val=""

    if command -v chronyc &>/dev/null; then
        echo -e "  ${BLUE}1. 时钟源同步列表 (chronyc sources -v):${NC}"
        local sources_output
        sources_output=$(chronyc sources -v 2>/dev/null)
        echo "$sources_output" | sed 's/^/    /'

        if echo "$sources_output" | grep -q '^\^\*'; then
            is_synced=true
            synced_ip=$(echo "$sources_output" | grep '^\^\*' | awk '{print $2}')
            offset_val=$(echo "$sources_output" | grep '^\^\*' | awk '{print $NF}')
        fi

        echo ""
        echo -e "  ${BLUE}2. 时钟跟踪详情 (chronyc tracking):${NC}"
        chronyc tracking 2>/dev/null | sed 's/^/    /'
    elif command -v timedatectl &>/dev/null; then
        echo -e "  ${BLUE}系统 timedatectl 状态:${NC}"
        timedatectl status 2>/dev/null | sed 's/^/    /'
        local ntp_stat
        ntp_stat=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)
        [ "$ntp_stat" = "yes" ] && is_synced=true
    fi
    echo ""

    echo -e "${GREEN}══════════════ [4/4] 硬件时钟 (RTC) 状态 ══════════════${NC}"
    local sys_now
    sys_now=$(date '+%Y-%m-%d %H:%M:%S %Z')
    echo -e "  当前系统时间: ${CYAN}${sys_now}${NC}"
    if hwclock --show &>/dev/null 2>&1; then
        local rtc_now
        rtc_now=$(hwclock --show 2>/dev/null)
        echo -e "  主板硬件时钟: ${GREEN}✓ 可用 (${rtc_now})${NC}"
    else
        echo -e "  主板硬件时钟: ${YELLOW}⚠ 无法直接读取（虚拟化/容器环境属于正常现象）${NC}"
    fi
    echo ""

    # 一键智能开启/修复自启交互
    if [ "$srv_enabled" = false ] && command -v systemctl &>/dev/null; then
        echo -e "${YELLOW}┌──────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}│ 💡 提示: 检测到开机自启尚未激活，工具箱支持一键自动修复配置！ │${NC}"
        echo -e "${YELLOW}└──────────────────────────────────────────────────────────────┘${NC}"
        read -p "  是否立即一键启用开机自启服务? [Y/n]: " fix_enable < /dev/tty
        if [[ ! "$fix_enable" =~ ^[Nn]$ ]]; then
            echo -ne "  ${CYAN}正在配置并启用开机自启...${NC} "
            local fix_target="$srv_name"
            [ -z "$fix_target" ] && fix_target="chrony"

            # 若系统中无任何 unit 文件，生成标准 unit 文件
            if ! systemctl cat "$fix_target" &>/dev/null 2>&1; then
                local cbin
                cbin=$(command -v chronyd 2>/dev/null || echo "/usr/sbin/chronyd")
                cat > /etc/systemd/system/chrony.service << AUTO_UNIT_EOF
[Unit]
Description=chrony, an NTP client/server
Documentation=man:chronyd(8) man:chrony.conf(5)
After=network.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=${cbin}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
AUTO_UNIT_EOF
                fix_target="chrony"
                systemctl daemon-reload 2>/dev/null
            fi

            systemctl unmask "$fix_target" 2>/dev/null
            systemctl enable "$fix_target" 2>/dev/null
            local check_st
            check_st=$(systemctl is-enabled "$fix_target" 2>/dev/null)
            if [ "$check_st" = "enabled" ] || [ "$check_st" = "enabled-runtime" ]; then
                srv_enabled=true
                echo -e "${GREEN}✓ 开机自启已成功启用！(服务: ${fix_target})${NC}"
            else
                echo -e "${RED}✗ 配置失败，返回状态: ${check_st}${NC}"
            fi
        fi
        echo ""
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BLUE}📊 综合校验评估结论:${NC}"
    if [ "$srv_active" = true ] && [ "$srv_enabled" = true ] && [ "$is_synced" = true ]; then
        echo -e "  ${GREEN}🎉 【状态极佳】B 客户端运行正常，开机自启已生效，已成功锁定主时钟源！${NC}"
        [ -n "$synced_ip" ] && echo -e "     ${CYAN}• 锁定时间源 : ${synced_ip}${NC}"
        [ -n "$offset_val" ] && echo -e "     ${CYAN}• 最新时间误差: ${offset_val}${NC}"
    elif [ "$srv_active" = true ] && [ "$is_synced" = false ]; then
        echo -e "  ${YELLOW}⏳ 【正在采样收敛】客户端服务运行正常，正处于初次握手滤波阶段。${NC}"
        echo -e "     通常需几十秒（约 3~4 次心跳包）评估抖动后自动完全锁定为 ^*。"
    elif [ "$srv_active" = false ]; then
        echo -e "  ${RED}✗ 【服务未运行】请选择主菜单 [2] 重新配置并启动客户端。${NC}"
    else
        echo -e "  ${YELLOW}⚠ 【部分正常】建议核对上方各项详情。${NC}"
    fi
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -p "  按回车键返回..." -r < /dev/tty
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
        echo -e "${GREEN}══════════════ 🚀 部署与配置 ══════════════${NC}"
        echo -e " 1. 部署 Docker NTP 服务器 (A端/服务端，支持自定义端口与离线孤岛)"
        echo -e " 2. 配置客户端同步与开机自启 (B端/客户端，支持 Chrony/脚本、即时同步)"
        echo -e "${GREEN}══════════════ 🔍 检测与诊断 ══════════════${NC}"
        echo -e " 3. 校验客户端同步与开机自启状态 (B端，检测服务/自启/时钟源/偏差)"
        echo -e " 4. 检测 NTP 服务器健康状态 (可测本机或远程 A端 IP:端口)"
        echo -e " 5. 查看硬件时钟 (RTC/hwclock) 状态与对齐"
        echo -e "${GREEN}══════════════ ⚡ 运维与操作 ══════════════${NC}"
        echo -e " 6. 立即手动同步系统时间"
        echo -e " 7. 停止并清理 NTP 服务 (容器/自启服务/脚本)"
        echo -e "${GREEN}══════════════ 🔧 工具管理 ════════════════${NC}"
        echo -e " 8. 安装 NTP 客户端工具 (离线/在线一键安装 chrony / ntpdate)"
        echo -e "${GREEN}==============================================${NC}"
        echo -e " 0. 返回主菜单"
        echo -e "${GREEN}==============================================${NC}"
        read -p "请输入选项 [0-8]: " time_choice < /dev/tty

        case "$time_choice" in
            1) _setup_ntp_docker ;;
            2) _setup_ntp_sync_service ;;
            3) _check_client_sync_status ;;
            4) _check_ntp_health ;;
            5) _check_hwclock ;;
            6) _manual_sync_time ;;
            7) _remove_ntp_setup ;;
            8) _install_ntp_tools ;;
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
