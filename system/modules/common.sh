#!/bin/bash

# =================================================================
# 模块名称: common.sh
# 描述: 核心底座与全局组件流转库 (日志追踪、架构自检、平滑服务跨域控制)
# 适配: Ubuntu / Debian / Armbian / Raspberry Pi OS /
#       CentOS / RHEL / Rocky / AlmaLinux / Fedora /
#       Alpine Linux /
#       银河麒麟 (Kylin V10/KSVD) / 中标麒麟 (NeoKylin) /
#       统信 UOS (UnionTech OS) / Deepin /
#       openEuler / EulerOS / Anolis OS / TencentOS /
#       中科方德 / 普华 Linux / 龙信 / 华为 EulerOS
# 初始化时将被 main.sh 直接 source 汇入全局环境。
# =================================================================

# 控制台前端高亮配色规范
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export RED='\033[0;31m'
export YELLOW='\033[1;33m'
export CYAN='\033[0;36m'
export NC='\033[0m'

# 全局版本标识规范 (遵循 Semantic Versioning)
export OPSBOX_VERSION="2.6.0"

# 统一优雅的用户等待确认封装 (用户体验提升)
_press_any_key() {
    local prompt="${1:-按回车键继续...}"
    echo ""
    read -p "$prompt" -r < /dev/tty
}

# -----------------------------------------------------------------
# 企业级审计日志引擎 (所做即所写)
# -----------------------------------------------------------------
LOG_FILE="/var/log/ck_system_init.log"
# 确保日志文件拥有初始操作权限；如无权写入/var/log则安全降级至/tmp
if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/ck_system_init.log"
    touch "$LOG_FILE" 2>/dev/null || true
fi
export LOG_FILE

# 日志轮转保护机制：单文件超过 10MB 时自动归档为 .1，杜绝写满磁盘
_rotate_log_if_needed() {
    [ -f "$LOG_FILE" ] || return 0
    local max_size_bytes=10485760 # 10MB
    local cur_size
    cur_size=$(wc -c < "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$cur_size" -ge "$max_size_bytes" ]; then
        mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
        touch "$LOG_FILE" 2>/dev/null || true
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] [LogRotation] 历史日志体积已满 10MB，自动轮转至 ${LOG_FILE}.1" >> "$LOG_FILE"
    fi
}

_log_info() {
    local msg="$*"
    _rotate_log_if_needed
    echo -e "${GREEN}[INFO]${NC} $msg"
    # 脱敏ANSI特殊字符后落盘
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $(echo "$msg" | sed -r 's/\x1B\[[0-9;]*[mK]//g')" >> "$LOG_FILE"
}

_log_warn() {
    local msg="$*"
    _rotate_log_if_needed
    echo -e "${YELLOW}[WARN]${NC} $msg"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $(echo "$msg" | sed -r 's/\x1B\[[0-9;]*[mK]//g')" >> "$LOG_FILE"
}

_log_err() {
    local msg="$*"
    _rotate_log_if_needed
    echo -e "${RED}[ERROR]${NC} $msg"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $(echo "$msg" | sed -r 's/\x1B\[[0-9;]*[mK]//g')" >> "$LOG_FILE"
}

# -----------------------------------------------------------------
# 脚本与系统命令审计执行器 (所行即所记)
# 特性: 记录执行命令、实时双写控制台与日志文件、统计耗时与退出码
# -----------------------------------------------------------------
_log_exec() {
    local desc="$1"
    shift
    local cmd_str="$*"
    local start_ts
    start_ts=$(date +%s 2>/dev/null || echo 0)

    _rotate_log_if_needed
    _log_info "正在执行: ${desc} [命令: ${cmd_str}]"

    local tmp_out
    tmp_out=$(mktemp 2>/dev/null || echo "/tmp/opsbox_exec_$$.log")

    local exit_code=0
    # 执行命令并双写：交互终端既能实时看见输出，也能写入审计日志
    if [ -t 1 ]; then
        "$@" 2>&1 | tee "$tmp_out"
        exit_code=${PIPESTATUS[0]}
    else
        "$@" > "$tmp_out" 2>&1
        exit_code=$?
        cat "$tmp_out"
    fi

    local end_ts
    end_ts=$(date +%s 2>/dev/null || echo 0)
    local duration=$((end_ts - start_ts))

    # 去除终端 ANSI 颜色后双写持久化至全局日志
    if [ -f "$tmp_out" ]; then
        sed -r 's/\x1B\[[0-9;]*[mK]//g' "$tmp_out" >> "$LOG_FILE" 2>/dev/null
        rm -f "$tmp_out"
    fi

    if [ $exit_code -eq 0 ]; then
        _log_info "执行完成: ${desc} (耗时: ${duration}s, 退出码: 0)"
    else
        _log_err "执行异常: ${desc} (耗时: ${duration}s, 退出码: ${exit_code})"
    fi
    return $exit_code
}

# 别名包装，适应不同模块调用习惯
_run_cmd_log() {
    _log_exec "$@"
}

# ----------------------------------------------------------------
# 跨平台自检引擎层
# ----------------------------------------------------------------
_init_distro() {
    export DISTRO_ID="unknown"
    export DISTRO_NAME="未知系统"
    export DISTRO_CODENAME=""
    export DISTRO_VERSION_ID=""
    export DISTRO_MAJOR_VER=""
    export DISTRO_FAMILY="unknown"
    export PKG_MGR="unknown"
    export PKG_UPDATE=""
    export PKG_UPGRADE=""
    export PKG_INSTALL=""
    export SVC_SSH="ssh"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_NAME="${PRETTY_NAME:-$ID}"
        DISTRO_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
        DISTRO_VERSION_ID="${VERSION_ID:-}"
    fi

    # 针对部分无 VERSION_ID 或非标发行版进行版本号兜底提取
    if [ -z "$DISTRO_VERSION_ID" ]; then
        if [ -f /etc/redhat-release ]; then
            DISTRO_VERSION_ID=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/redhat-release 2>/dev/null | head -1)
        elif [ -f /etc/debian_version ]; then
            DISTRO_VERSION_ID=$(cat /etc/debian_version 2>/dev/null | tr -d '\r\n')
        elif [ -f /etc/alpine-release ]; then
            DISTRO_VERSION_ID=$(cat /etc/alpine-release 2>/dev/null | tr -d '\r\n')
        elif [ -f /etc/kylin-release ]; then
            DISTRO_VERSION_ID=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/kylin-release 2>/dev/null | head -1)
        elif [ -f /etc/openEuler-release ]; then
            DISTRO_VERSION_ID=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/openEuler-release 2>/dev/null | head -1)
        fi
    fi
    DISTRO_MAJOR_VER=$(echo "$DISTRO_VERSION_ID" | grep -oE '^[0-9]+' || echo "")

    case "$DISTRO_ID" in
        # ── Debian 族系 ──────────────────────────────────────────────
        ubuntu|debian|raspbian|armbian|linuxmint|pop|kali|parrot)
            DISTRO_FAMILY="debian"
            PKG_MGR="apt"
            PKG_UPDATE="apt update"
            PKG_UPGRADE="apt upgrade -y"
            PKG_INSTALL="apt install -y"
            SVC_SSH="ssh"
            ;;
        # ── Red Hat 族系 ─────────────────────────────────────────────
        centos|rhel|rocky|almalinux|ol|scientific)
            DISTRO_FAMILY="redhat"
            if command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
                PKG_UPDATE="dnf check-update"
                PKG_UPGRADE="dnf upgrade -y"
                PKG_INSTALL="dnf install -y"
            else
                PKG_MGR="yum"
                PKG_UPDATE="yum check-update"
                PKG_UPGRADE="yum upgrade -y"
                PKG_INSTALL="yum install -y"
            fi
            SVC_SSH="sshd"
            ;;
        fedora)
            DISTRO_FAMILY="redhat"
            PKG_MGR="dnf"
            PKG_UPDATE="dnf check-update"
            PKG_UPGRADE="dnf upgrade -y"
            PKG_INSTALL="dnf install -y"
            SVC_SSH="sshd"
            ;;
        # ── Alpine ───────────────────────────────────────────────────
        alpine)
            DISTRO_FAMILY="alpine"
            PKG_MGR="apk"
            PKG_UPDATE="apk update"
            PKG_UPGRADE="apk upgrade"
            PKG_INSTALL="apk add"
            SVC_SSH="sshd"
            ;;
        # ── Arch 族系 ────────────────────────────────────────────────
        arch|manjaro|endeavouros)
            DISTRO_FAMILY="arch"
            PKG_MGR="pacman"
            PKG_UPDATE="pacman -Sy"
            PKG_UPGRADE="pacman -Syu --noconfirm"
            PKG_INSTALL="pacman -S --noconfirm"
            SVC_SSH="sshd"
            ;;
        # ── openSUSE / SLES 族系 ─────────────────────────────────────
        opensuse*|sles)
            DISTRO_FAMILY="suse"
            PKG_MGR="zypper"
            PKG_UPDATE="zypper refresh"
            PKG_UPGRADE="zypper update -y"
            PKG_INSTALL="zypper install -y"
            SVC_SSH="sshd"
            ;;
        # ── 国产信创：麒麟系 (Debian/APT 底座) ──────────────────────
        # 银河麒麟 V10/V4、Ubuntu Kylin、中标麒麟
        ubuntukylin|neokylin)
            DISTRO_FAMILY="debian"
            PKG_MGR="apt"
            PKG_UPDATE="apt update"
            PKG_UPGRADE="apt upgrade -y"
            PKG_INSTALL="apt install -y"
            SVC_SSH="ssh"
            ;;
        # 银河麒麟 V10 Server RPM 版（龙芯/鲲鹏/飞腾/x86）
        kylin)
            if command -v apt &>/dev/null; then
                DISTRO_FAMILY="debian"
                PKG_MGR="apt"
                PKG_UPDATE="apt update"
                PKG_UPGRADE="apt upgrade -y"
                PKG_INSTALL="apt install -y"
                SVC_SSH="ssh"
            elif command -v dnf &>/dev/null; then
                DISTRO_FAMILY="redhat"
                PKG_MGR="dnf"
                PKG_UPDATE="dnf check-update"
                PKG_UPGRADE="dnf upgrade -y"
                PKG_INSTALL="dnf install -y"
                SVC_SSH="sshd"
            elif command -v yum &>/dev/null; then
                DISTRO_FAMILY="redhat"
                PKG_MGR="yum"
                PKG_UPDATE="yum check-update"
                PKG_UPGRADE="yum upgrade -y"
                PKG_INSTALL="yum install -y"
                SVC_SSH="sshd"
            fi
            ;;
        # ── 国产信创：统信 UOS / Deepin ──────────────────────────────
        # 统信 UOS 服务器版/桌面版、Deepin 均基于 Debian
        uos|uniontechos|deepin|deepin-v23)
            DISTRO_FAMILY="debian"
            PKG_MGR="apt"
            PKG_UPDATE="apt update"
            PKG_UPGRADE="apt upgrade -y"
            PKG_INSTALL="apt install -y"
            SVC_SSH="ssh"
            ;;
        # ── 国产信创：openEuler / EulerOS / 华为鸿蒙服务器版 ─────────
        openeuler|euler|euleros)
            DISTRO_FAMILY="redhat"
            if command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
                PKG_UPDATE="dnf check-update"
                PKG_UPGRADE="dnf upgrade -y"
                PKG_INSTALL="dnf install -y"
            else
                PKG_MGR="yum"
                PKG_UPDATE="yum check-update"
                PKG_UPGRADE="yum upgrade -y"
                PKG_INSTALL="yum install -y"
            fi
            SVC_SSH="sshd"
            ;;
        # ── 国产信创：龙蜥 Anolis OS / TencentOS / OpenCloudOS ───────
        anolis|tencentos|opencloudos)
            DISTRO_FAMILY="redhat"
            if command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
                PKG_UPDATE="dnf check-update"
                PKG_UPGRADE="dnf upgrade -y"
                PKG_INSTALL="dnf install -y"
            else
                PKG_MGR="yum"
                PKG_UPDATE="yum check-update"
                PKG_UPGRADE="yum upgrade -y"
                PKG_INSTALL="yum install -y"
            fi
            SVC_SSH="sshd"
            ;;
        # ── 国产信创：中科方德 / 普华 / 龙信 / 红旗 Linux ───────────
        # 这些系统通常基于 Debian 或 RHEL，优先按包管理器自动判断
        nfsdesktop|nfs-desktop|isoft|redflag|linx|startos|startos)
            if command -v apt &>/dev/null; then
                DISTRO_FAMILY="debian"
                PKG_MGR="apt"
                PKG_UPDATE="apt update"
                PKG_UPGRADE="apt upgrade -y"
                PKG_INSTALL="apt install -y"
                SVC_SSH="ssh"
            elif command -v dnf &>/dev/null; then
                DISTRO_FAMILY="redhat"
                PKG_MGR="dnf"
                PKG_UPDATE="dnf check-update"
                PKG_UPGRADE="dnf upgrade -y"
                PKG_INSTALL="dnf install -y"
                SVC_SSH="sshd"
            elif command -v yum &>/dev/null; then
                DISTRO_FAMILY="redhat"
                PKG_MGR="yum"
                PKG_UPDATE="yum check-update"
                PKG_UPGRADE="yum upgrade -y"
                PKG_INSTALL="yum install -y"
                SVC_SSH="sshd"
            fi
            ;;
        *)
            if command -v apt &>/dev/null;   then PKG_MGR="apt";   DISTRO_FAMILY="debian"; PKG_UPDATE="apt update"; PKG_UPGRADE="apt upgrade -y"; PKG_INSTALL="apt install -y"; SVC_SSH="ssh"; fi
            if command -v dnf &>/dev/null;   then PKG_MGR="dnf";   DISTRO_FAMILY="redhat"; PKG_UPDATE="dnf check-update"; PKG_UPGRADE="dnf upgrade -y"; PKG_INSTALL="dnf install -y"; SVC_SSH="sshd"; fi
            if command -v yum &>/dev/null;   then PKG_MGR="yum";   DISTRO_FAMILY="redhat"; PKG_UPDATE="yum check-update"; PKG_UPGRADE="yum upgrade -y"; PKG_INSTALL="yum install -y"; SVC_SSH="sshd"; fi
            if command -v apk &>/dev/null;   then PKG_MGR="apk";   DISTRO_FAMILY="alpine"; PKG_UPDATE="apk update"; PKG_UPGRADE="apk upgrade"; PKG_INSTALL="apk add"; SVC_SSH="sshd"; fi
            ;;
    esac

    # ----------------------------------------------------------------
    # 文件指纹兜底检测层：国产/嵌入式系统的深度兼容识别
    # 优先级低于 os-release，用于修正识别失败或 ID 非标的情况
    # ----------------------------------------------------------------

    # 银河麒麟 / 中标麒麟 (文件指纹)
    if [ -f /etc/kylin-release ] || grep -qi "kylin\|银河麒麟\|中标麒麟" /etc/os-release 2>/dev/null; then
        [ -z "$DISTRO_NAME" ] && DISTRO_NAME="银河麒麟/中标麒麟"
        if command -v dpkg &>/dev/null; then
            DISTRO_FAMILY="debian"
            [ "$PKG_MGR" = "unknown" ] && { PKG_MGR="apt"; PKG_UPDATE="apt update"; PKG_UPGRADE="apt upgrade -y"; PKG_INSTALL="apt install -y"; SVC_SSH="ssh"; }
        elif command -v rpm &>/dev/null; then
            DISTRO_FAMILY="redhat"
            if command -v dnf &>/dev/null; then
                [ "$PKG_MGR" = "unknown" ] && { PKG_MGR="dnf"; PKG_UPDATE="dnf check-update"; PKG_UPGRADE="dnf upgrade -y"; PKG_INSTALL="dnf install -y"; }
            else
                [ "$PKG_MGR" = "unknown" ] && { PKG_MGR="yum"; PKG_UPDATE="yum check-update"; PKG_UPGRADE="yum upgrade -y"; PKG_INSTALL="yum install -y"; }
            fi
            SVC_SSH="sshd"
        fi
    fi

    # 统信 UOS (文件指纹)
    if [ -f /etc/uos-release ] || grep -qi "uos\|uniontech\|统信" /etc/os-release 2>/dev/null; then
        [ -z "$DISTRO_NAME" ] && DISTRO_NAME="统信 UOS"
        DISTRO_FAMILY="debian"
        [ "$PKG_MGR" = "unknown" ] && { PKG_MGR="apt"; PKG_UPDATE="apt update"; PKG_UPGRADE="apt upgrade -y"; PKG_INSTALL="apt install -y"; SVC_SSH="ssh"; }
    fi

    # openEuler / EulerOS (文件指纹)
    if [ -f /etc/openEuler-release ] || [ -f /etc/EulerOS-release ] || \
       grep -qi "openeuler\|euleros\|openEuler" /etc/os-release 2>/dev/null; then
        [ -z "$DISTRO_NAME" ] && DISTRO_NAME="$(grep -m1 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'openEuler/EulerOS')"
        DISTRO_FAMILY="redhat"
        if command -v dnf &>/dev/null; then
            [ "$PKG_MGR" = "unknown" ] && { PKG_MGR="dnf"; PKG_UPDATE="dnf check-update"; PKG_UPGRADE="dnf upgrade -y"; PKG_INSTALL="dnf install -y"; }
        else
            [ "$PKG_MGR" = "unknown" ] && { PKG_MGR="yum"; PKG_UPDATE="yum check-update"; PKG_UPGRADE="yum upgrade -y"; PKG_INSTALL="yum install -y"; }
        fi
        SVC_SSH="sshd"
    fi

    # 龙蜥 Anolis OS (文件指纹)
    if [ -f /etc/anolis-release ] || grep -qi "anolis" /etc/os-release 2>/dev/null; then
        [ -z "$DISTRO_NAME" ] && DISTRO_NAME="Anolis OS"
        DISTRO_FAMILY="redhat"
        if command -v dnf &>/dev/null; then
            [ "$PKG_MGR" = "unknown" ] && { PKG_MGR="dnf"; PKG_UPDATE="dnf check-update"; PKG_UPGRADE="dnf upgrade -y"; PKG_INSTALL="dnf install -y"; }
        else
            [ "$PKG_MGR" = "unknown" ] && { PKG_MGR="yum"; PKG_UPDATE="yum check-update"; PKG_UPGRADE="yum upgrade -y"; PKG_INSTALL="yum install -y"; }
        fi
        SVC_SSH="sshd"
    fi

    # Armbian (文件指纹)
    if [ -f /etc/armbian-release ]; then
        DISTRO_FAMILY="debian"
        PKG_MGR="apt"
        DISTRO_NAME="Armbian ($(grep BOARD_NAME /etc/armbian-release 2>/dev/null | cut -d= -f2 || echo 'unknown board'))"
    fi

    # Raspberry Pi OS (文件指纹)
    if [ -f /etc/rpi-issue ] || grep -qi "raspberry" /proc/cpuinfo 2>/dev/null; then
        DISTRO_FAMILY="debian"
        PKG_MGR="apt"
    fi

    export DISTRO_ID DISTRO_NAME DISTRO_CODENAME DISTRO_VERSION_ID DISTRO_MAJOR_VER DISTRO_FAMILY
    export PKG_MGR PKG_UPDATE PKG_UPGRADE PKG_INSTALL SVC_SSH
}

# ----------------------------------------------------------------
# 服务网格控制降级层兼容
# ----------------------------------------------------------------
_svc_restart() {
    local svc=$1
    if command -v systemctl &>/dev/null; then
        systemctl restart "$svc" 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service "$svc" restart 2>/dev/null
    elif command -v service &>/dev/null; then
        service "$svc" restart 2>/dev/null
    fi
}

_svc_is_active() {
    local svc=$1
    if command -v systemctl &>/dev/null; then
        systemctl is-active --quiet "$svc" 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service "$svc" status 2>/dev/null | grep -q started
    fi
}

# ----------------------------------------------------------------
# 系统并发互斥锁引擎 (flock 防多终端/定时任务竞争)
# ----------------------------------------------------------------
OPSBOX_LOCK_DIR="/run/lock/opsbox"

_acquire_ops_lock() {
    local lock_name="${1:-ops_system}"
    local timeout="${2:-120}"
    mkdir -p "$OPSBOX_LOCK_DIR" 2>/dev/null
    local lock_file="$OPSBOX_LOCK_DIR/${lock_name}.lock"
    local lock_fd
    exec {lock_fd}>>"$lock_file" || return 1

    if ! flock -w "$timeout" "$lock_fd"; then
        _log_err "获取系统运维锁 [${lock_name}] 超时 (${timeout}秒)，其他操作正在执行中，请稍后重试。"
        exec {lock_fd}>&-
        return 1
    fi
    eval "OPSBOX_LOCK_FD_${lock_name}=$lock_fd"
    return 0
}

_release_ops_lock() {
    local lock_name="${1:-ops_system}"
    local var_name="OPSBOX_LOCK_FD_${lock_name}"
    local lock_fd="${!var_name}"
    if [ -n "$lock_fd" ]; then
        flock -u "$lock_fd" 2>/dev/null || true
        eval "exec ${lock_fd}>&-" 2>/dev/null || true
        unset "OPSBOX_LOCK_FD_${lock_name}"
    fi
}

# 包装器: 在排他锁保护下执行命令 (带防死锁超时)
_run_with_ops_lock() {
    local lock_name="$1"
    shift
    if ! command -v flock &>/dev/null; then
        "$@"
        return $?
    fi
    _acquire_ops_lock "$lock_name" 120 || return 1
    local ret=0
    "$@" || ret=$?
    _release_ops_lock "$lock_name"
    return $ret
}

# ----------------------------------------------------------------
# 全局统一软件包安装器 (支持跨多包管理器)
# ----------------------------------------------------------------
_pkg_install_universal() {
    [ $# -eq 0 ] && return 0
    local to_install=()
    for pkg in "$@"; do
        if ! command -v "$pkg" &>/dev/null; then
            to_install+=("$pkg")
        fi
    done
    [ ${#to_install[@]} -eq 0 ] && return 0

    _run_with_ops_lock "pkg_mgr" ${PKG_INSTALL:-apt install -y} "${to_install[@]}"
}

# ----------------------------------------------------------------
# 系统级磁盘空间预检机制 (防止软件安装写满分区)
# ----------------------------------------------------------------
_check_disk_space() {
    local required_mb="${1:-1024}"
    local target_path="${2:-/var}"
    [ ! -d "$target_path" ] && target_path="/"

    local avail_kb
    avail_kb=$(df -k "$target_path" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$avail_kb" ]; then
        local avail_mb=$((avail_kb / 1024))
        if [ "$avail_mb" -lt "$required_mb" ]; then
            echo -e "${RED}⚠️ 警告: 目标分区 (${target_path}) 剩余可用空间仅 ${avail_mb}MB，低于建议安全阈值 ${required_mb}MB！${NC}"
            echo -e "${YELLOW}若继续安装可能导致磁盘空间写满、包管理器锁定或服务异常。${NC}"
            read -p "是否仍然强制继续执行？[y/N]: " force_yn < /dev/tty
            if [[ ! "$force_yn" =~ ^[Yy]$ ]]; then
                echo -e "${BLUE}已取消安装操作。${NC}"
                return 1
            fi
        fi
    fi
    return 0
}

# ----------------------------------------------------------------
# 系统指令抽象层引擎 (System Commands Abstraction Layer)
# 功能: 根据检测到的系统版本与发行版特性，动态加载与适配对应的底层指令
# ----------------------------------------------------------------
_init_system_commands() {
    # 1. 探测底层 Init 服务管理系统 (systemd / openrc / sysvinit)
    export SYS_INIT_TYPE="sysvinit"
    if [ -d /run/systemd/system ] || [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] || command -v systemctl &>/dev/null; then
        SYS_INIT_TYPE="systemd"
    elif command -v rc-service &>/dev/null && [ -d /etc/init.d ]; then
        SYS_INIT_TYPE="openrc"
    elif command -v service &>/dev/null; then
        SYS_INIT_TYPE="sysvinit"
    fi

    # 2. 动态匹配防火墙管理指令体系
    export CMD_FW_TYPE="none"
    export CMD_FW_BIN=""
    if command -v ufw &>/dev/null; then
        CMD_FW_TYPE="ufw"
        CMD_FW_BIN="ufw"
    elif command -v firewall-cmd &>/dev/null; then
        CMD_FW_TYPE="firewalld"
        CMD_FW_BIN="firewall-cmd"
    elif command -v awall &>/dev/null; then
        CMD_FW_TYPE="awall"
        CMD_FW_BIN="awall"
    elif command -v nft &>/dev/null; then
        CMD_FW_TYPE="nftables"
        CMD_FW_BIN="nft"
    elif command -v iptables &>/dev/null; then
        CMD_FW_TYPE="iptables"
        CMD_FW_BIN="iptables"
    fi

    # 3. 动态匹配网络配置指令体系
    export CMD_NET_TYPE="unknown"
    if command -v netplan &>/dev/null; then
        CMD_NET_TYPE="netplan"
    elif command -v nmcli &>/dev/null; then
        CMD_NET_TYPE="nmcli"
    elif [ -d /etc/network/interfaces.d ] || [ -f /etc/network/interfaces ]; then
        CMD_NET_TYPE="ifupdown"
    elif [ -d /etc/sysconfig/network-scripts ]; then
        CMD_NET_TYPE="network-scripts"
    elif [ "$DISTRO_FAMILY" = "alpine" ]; then
        CMD_NET_TYPE="alpine-networking"
    fi

    # 4. 动态匹配时间同步服务指令
    export CMD_TIME_SVC="none"
    if command -v chronyc &>/dev/null || [ -f /etc/chrony.conf ] || [ -f /etc/chrony/chrony.conf ]; then
        CMD_TIME_SVC="chronyd"
    elif command -v timedatectl &>/dev/null && systemctl list-unit-files 2>/dev/null | grep -q "systemd-timesyncd"; then
        CMD_TIME_SVC="systemd-timesyncd"
    elif command -v ntpq &>/dev/null || [ -f /etc/ntp.conf ]; then
        CMD_TIME_SVC="ntp"
    fi

    # 5. 动态匹配系统清理与无用包移除指令
    export CMD_CLEAN_PKG=""
    case "$PKG_MGR" in
        apt)
            CMD_CLEAN_PKG="apt autoremove -y && apt clean"
            ;;
        dnf)
            CMD_CLEAN_PKG="dnf autoremove -y && dnf clean all"
            ;;
        yum)
            CMD_CLEAN_PKG="yum autoremove -y && yum clean all"
            ;;
        apk)
            CMD_CLEAN_PKG="apk cache clean"
            ;;
        pacman)
            CMD_CLEAN_PKG="pacman -Sc --noconfirm"
            ;;
        zypper)
            CMD_CLEAN_PKG="zypper clean -a"
            ;;
        *)
            CMD_CLEAN_PKG="true"
            ;;
    esac

    # 6. 安全加固体系检测 (SELinux / AppArmor)
    export CMD_SEC_MODULE="none"
    if command -v getenforce &>/dev/null; then
        CMD_SEC_MODULE="selinux"
    elif command -v aa-status &>/dev/null; then
        CMD_SEC_MODULE="apparmor"
    fi

    _log_info "系统指令集加载完成: [Init: ${SYS_INIT_TYPE}] [防火墙: ${CMD_FW_TYPE}] [网络栈: ${CMD_NET_TYPE}] [时间服务: ${CMD_TIME_SVC}] [安全组件: ${CMD_SEC_MODULE}]"
}

# ----------------------------------------------------------------
# 统一跨发行版服务操作适配器
# ----------------------------------------------------------------
_sys_service_ctl() {
    local action="$1"
    local svc_name="$2"
    case "$SYS_INIT_TYPE" in
        systemd)
            _log_exec "系统服务控制 [systemd: ${action} ${svc_name}]" systemctl "$action" "$svc_name"
            ;;
        openrc)
            local rc_action="$action"
            [ "$action" = "enable" ] && rc_action="add"
            [ "$action" = "disable" ] && rc_action="del"
            if [ "$rc_action" = "add" ] || [ "$rc_action" = "del" ]; then
                _log_exec "OpenRC服务自启 [${rc_action} ${svc_name}]" rc-update "$rc_action" "$svc_name" default
            else
                _log_exec "OpenRC服务控制 [${rc_action} ${svc_name}]" rc-service "$svc_name" "$rc_action"
            fi
            ;;
        sysvinit)
            case "$action" in
                enable)  _log_exec "SysVinit服务自启 [${svc_name}]" chkconfig "$svc_name" on 2>/dev/null || update-rc.d "$svc_name" defaults 2>/dev/null ;;
                disable) _log_exec "SysVinit服务禁用 [${svc_name}]" chkconfig "$svc_name" off 2>/dev/null || update-rc.d "$svc_name" disable 2>/dev/null ;;
                *)       _log_exec "SysVinit服务控制 [${action} ${svc_name}]" service "$svc_name" "$action" ;;
            esac
            ;;
        *)
            _log_warn "未识别的初始化管理体系，尝试通用 service 调用: ${svc_name} ${action}"
            service "$svc_name" "$action"
            ;;
    esac
}

# ----------------------------------------------------------------
# 系统硬件架构、时区与当前时间统一采集函数
# ----------------------------------------------------------------
_get_cpu_arch_info() {
    local raw_arch
    raw_arch=$(uname -m 2>/dev/null || echo "unknown")
    case "$raw_arch" in
        x86_64|amd64)   echo "x86_64 (Intel/AMD 64位)" ;;
        aarch64|arm64)  echo "aarch64 (ARM 64位)" ;;
        armv7l|armhf)   echo "armv7l (ARM 32位硬浮点)" ;;
        armv6l)         echo "armv6l (ARM 32位)" ;;
        loongarch64)    echo "loongarch64 (龙芯 64位)" ;;
        mips64el)       echo "mips64el (龙芯/MIPS 64位小端)" ;;
        riscv64)        echo "riscv64 (RISC-V 64位)" ;;
        i386|i686)      echo "x86 (Intel/AMD 32位)" ;;
        s390x)          echo "s390x (IBM Z 64位)" ;;
        ppc64le)        echo "ppc64le (POWER 64位)" ;;
        *)              echo "$raw_arch" ;;
    esac
}

_get_timezone_info() {
    local tz=""
    if command -v timedatectl &>/dev/null; then
        tz=$(timedatectl show --property=Timezone --value 2>/dev/null)
    fi
    if [ -z "$tz" ] || [ "$tz" = "未知" ]; then
        if [ -f /etc/timezone ]; then
            tz=$(cat /etc/timezone 2>/dev/null | tr -d '\r\n')
        elif [ -L /etc/localtime ]; then
            tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
        fi
    fi
    [ -z "$tz" ] && tz=$(date +%Z 2>/dev/null || echo "UTC")

    local offset
    offset=$(date +%:z 2>/dev/null || date +%z 2>/dev/null || echo "+00:00")
    local abbr
    abbr=$(date +%Z 2>/dev/null || echo "UTC")
    echo "${tz} (${abbr}, UTC${offset})"
}

_get_current_time() {
    date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "未知时间"
}

# --- Module Auto-Start Initialization ---
_init_distro
_init_system_commands

