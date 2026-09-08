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
# 辅助：一键生成纯内网/离线孤岛模式 ntpd.conf 配置文件
# ================================================================
_generate_ntp_offline_conf() {
    local target_dir="${1:-/etc/ntp-docker}"
    local target_file="${target_dir}/ntpd.conf"

    echo -ne "  ${CYAN}➜ 正在一键生成离线孤岛配置文件 [${target_file}]...${NC} "
    mkdir -p "$target_dir" 2>/dev/null
    cat > "$target_file" << 'NTP_CONF_EOF'
# ntpd.conf - 纯内网/离线孤岛模式配置文件
# 由 Linux-ops-box 自动生成

# 127.127.1.0 本地系统时钟驱动 (LOCAL Clock)
# fudge 声明自身为 Stratum 10（确保断网孤岛时允许对局域网客户端授时）
server 127.127.1.0
fudge  127.127.1.0 stratum 10

# 访问控制权限
restrict default kod nomodify notrap nopeer
restrict 127.0.0.1
restrict -6 ::1

# 允许私有局域网所有私网段进行时间查询校准
restrict 10.0.0.0    mask 255.0.0.0 nomodify notrap
restrict 172.16.0.0  mask 255.240.0.0 nomodify notrap
restrict 192.168.0.0 mask 255.255.0.0 nomodify notrap

driftfile /var/lib/ntp/ntp.drift
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
    local ntp_conf_file="${ntp_conf_dir}/ntpd.conf"

    case "$ntp_mode_choice" in
        2)
            offline_mode=true
            echo ""
            echo -e "  ${CYAN}⏰ [离线孤岛模式] 正在检查本机硬件时钟 (RTC)...${NC}"
            if hwclock --show &>/dev/null 2>&1; then
                local hw_now
                hw_now=$(hwclock --show 2>/dev/null)
                echo -e "  ${GREEN}✓ 硬件时钟(RTC)可用: ${hw_now}${NC}"
            else
                echo -e "  ${YELLOW}⚠ 无法直接读取硬件时钟（虚拟化环境），将以内核系统时钟作为基准${NC}"
            fi
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
        docker run -d \
            --name "$_NTP_CONTAINER_NAME" \
            --restart=always \
            --cap-add SYS_TIME \
            -p "${ntp_host_port}:123/udp" \
            -v "${ntp_conf_file}:/etc/ntpd.conf:ro" \
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
            echo -e "  ${CYAN}  运行模式: 纯内网/离线孤岛模式 (自动挂载 ${ntp_conf_file})${NC}"
            echo -e "  ${CYAN}  授时基准: 本机硬件时钟 (RTC/Local Clock 127.127.1.0 stratum 10)${NC}"
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
        echo -e "    可在 B 机器直接运行本脚本，选择菜单 [4] 即可自动完成客户端安装、配置与即时同步！"
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
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [ "$overall_ok" = true ] && [ "$ntp_proto_ok" = true ]; then
        echo -e " ${GREEN}🟢 总体状态: NTP 服务器 [${ntp_target}:${ntp_port}] 响应健康、通信正常！${NC}"
    elif [ "$udp_ok" = true ] && [ "$ntp_proto_ok" = false ]; then
        echo -e " ${YELLOW}🟡 总体状态: 网络通道可通，但 NTP 协议层未正常响应（可能正在收敛或被拦截）${NC}"
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
        if systemctl list-unit-files chronyd.service &>/dev/null 2>&1 | grep -q chronyd; then
            srv_name="chronyd"
        fi
        systemctl daemon-reload 2>/dev/null
        systemctl unmask "$srv_name" 2>/dev/null
        systemctl enable "$srv_name" 2>/dev/null
        systemctl restart "$srv_name" 2>/dev/null
        if systemctl is-active "$srv_name" &>/dev/null; then
            echo -e "  ${GREEN}✓ ${srv_name} 服务已启动并设置开机自启${NC}"
        else
            echo -e "  ${YELLOW}⚠ 服务状态异常，尝试直接启动 chronyd 进程...${NC}"
            chronyd 2>/dev/null || true
        fi
    elif command -v service &>/dev/null; then
        service chrony restart 2>/dev/null || service chronyd restart 2>/dev/null
        echo -e "  ${GREEN}✓ Chrony 服务已重启${NC}"
    fi
    echo ""

    echo -e "${BLUE}[5/5] 立即执行强制步进同步与状态自检...${NC}"
    echo -e "  ${CYAN}⏳ 正在向 A 端 (${target_ip}:${target_port}) 发起同步请求 (chronyc makestep)...${NC}"
    sleep 2
    local step_res
    step_res=$(chronyc makestep 2>&1)
    echo -e "  ${CYAN}  步进结果: ${step_res}${NC}"

    # 写回硬件时钟
    hwclock --systohc 2>/dev/null && echo -e "  ${GREEN}✓ 系统时间已写回硬件时钟 (RTC)${NC}" || \
        echo -e "  ${YELLOW}⚠ hwclock 写入跳过（虚拟化/容器环境正常）${NC}"
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
    echo -e "  ${GREEN}🎉 B 客户端 Chrony 部署与同步配置完成！${NC}"
    echo -e "  ${CYAN}  说明: Chrony 标记 '^*' 代表已锁定为主时钟源；若显示 '^?' 表明正在采样，几十秒内自动锁定。${NC}"
    echo -e "  ${CYAN}  后续可随时在菜单 [3] 输入 ${target_ip}:${target_port} 进行健康连通性检测。${NC}"
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

    # 1. 检测 Chrony 守护进程
    if command -v chronyd &>/dev/null || command -v chronyc &>/dev/null; then
        mode_desc="Chrony 守护进程模式"
        if systemctl list-unit-files chrony.service &>/dev/null 2>&1 | grep -q chrony; then
            srv_name="chrony"
        elif systemctl list-unit-files chronyd.service &>/dev/null 2>&1 | grep -q chronyd; then
            srv_name="chronyd"
        fi
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
    if [ -n "$srv_name" ] && command -v systemctl &>/dev/null; then
        local enable_status
        enable_status=$(systemctl is-enabled "$srv_name" 2>/dev/null)
        if [ "$enable_status" = "enabled" ]; then
            srv_enabled=true
            echo -e "  开机自启: ${GREEN}✓ 已启用 (enabled)${NC} — 系统开机将自动启动并同步"
        elif [ "$enable_status" = "disabled" ]; then
            echo -e "  开机自启: ${YELLOW}⚠ 已禁用 (disabled)${NC} — 可通过 systemctl enable ${srv_name} 开启"
        else
            echo -e "  开机自启: ${YELLOW}⚠ ${enable_status:-未配置}${NC}"
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
