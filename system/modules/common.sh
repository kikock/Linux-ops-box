#!/bin/bash

# =================================================================
# 模块名称: common.sh
# 描述: 核心底座与全局组件流转库 (日志追踪、架构自检、平滑服务跨域控制)
# 初始化时将被 main.sh 直接 source 汇入全局环境。
# =================================================================

# 控制台前端高亮配色规范
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export RED='\033[0;31m'
export YELLOW='\033[1;33m'
export CYAN='\033[0;36m'
export NC='\033[0m'

# -----------------------------------------------------------------
# 企业级审计日志引擎 (所做即所写)
# -----------------------------------------------------------------
LOG_FILE="/var/log/ck_system_init.log"
# 确保日志文件拥有初试操作权限
touch "$LOG_FILE" 2>/dev/null || true

_log_info() {
    local msg="$*"
    echo -e "${GREEN}[INFO]${NC} $msg"
    # 脱敏ANSI特殊字符后落盘
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $(echo "$msg" | sed -r 's/\x1B\[[0-9;]*[mK]//g')" >> "$LOG_FILE"
}

_log_warn() {
    local msg="$*"
    echo -e "${YELLOW}[WARN]${NC} $msg"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $(echo "$msg" | sed -r 's/\x1B\[[0-9;]*[mK]//g')" >> "$LOG_FILE"
}

_log_err() {
    local msg="$*"
    echo -e "${RED}[ERROR]${NC} $msg"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $(echo "$msg" | sed -r 's/\x1B\[[0-9;]*[mK]//g')" >> "$LOG_FILE"
}

# ----------------------------------------------------------------
# 跨平台自检引擎层
# ----------------------------------------------------------------
_init_distro() {
    export DISTRO_ID="unknown"
    export DISTRO_CODENAME=""
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
    fi

    case "$DISTRO_ID" in
        ubuntu|debian|raspbian|armbian|linuxmint|pop)
            DISTRO_FAMILY="debian"
            PKG_MGR="apt"
            PKG_UPDATE="apt update"
            PKG_UPGRADE="apt upgrade -y"
            PKG_INSTALL="apt install -y"
            SVC_SSH="ssh"
            ;;
        centos|rhel|rocky|almalinux|ol)
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
        alpine)
            DISTRO_FAMILY="alpine"
            PKG_MGR="apk"
            PKG_UPDATE="apk update"
            PKG_UPGRADE="apk upgrade"
            PKG_INSTALL="apk add"
            SVC_SSH="sshd"
            ;;
        *)
            if command -v apt &>/dev/null;   then PKG_MGR="apt";   DISTRO_FAMILY="debian"; fi
            if command -v dnf &>/dev/null;   then PKG_MGR="dnf";   DISTRO_FAMILY="redhat"; fi
            if command -v yum &>/dev/null;   then PKG_MGR="yum";   DISTRO_FAMILY="redhat"; fi
            if command -v apk &>/dev/null;   then PKG_MGR="apk";   DISTRO_FAMILY="alpine"; fi
            ;;
    esac

    # 复杂族系特判识别策略
    if [ -f /etc/armbian-release ]; then
        DISTRO_FAMILY="debian"
        PKG_MGR="apt"
        DISTRO_NAME="Armbian ($(grep BOARD_NAME /etc/armbian-release 2>/dev/null | cut -d= -f2 || echo 'unknown board'))"
    fi

    if [ -f /etc/rpi-issue ] || grep -qi "raspberry" /proc/cpuinfo 2>/dev/null; then
        DISTRO_FAMILY="debian"
        PKG_MGR="apt"
    fi

    export DISTRO_ID DISTRO_NAME DISTRO_CODENAME DISTRO_FAMILY
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

# --- Module Auto-Start Initialization ---
_init_distro
