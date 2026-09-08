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
