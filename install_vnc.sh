#!/bin/bash
# =================================================================
# 脚本名称: install_vnc.sh
# 描述: 麒麟服务器 VNC 服务一键安装与开机自启配置程序
# 适配系统: 银河麒麟高级服务器操作系统 V10 (SP1/SP2/SP3) / 桌面版
#           同时兼容 openEuler、CentOS、Ubuntu/Debian 等主流发行版
# =================================================================

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 审计日志配置
LOG_FILE="/var/log/ck_vnc_install.log"
touch "$LOG_FILE" 2>/dev/null || true

_log_info() {
    local msg="$*"
    echo -e "${GREEN}[INFO]${NC} $msg"
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

# 1. 权限检测
if [[ $EUID -ne 0 ]]; then
   _log_err "该工具需要 root 权限，请使用 sudo 执行。"
   exit 1
fi

echo -e "${BLUE}======================================================${NC}"
echo -e "${GREEN}      Linux 服务器 VNC 服务一键安装与自启配置程序       ${NC}"
echo -e "${CYAN}   适用系统: 麒麟/openEuler/Rocky/CentOS/Ubuntu/Debian/Arch/Alpine  ${NC}"
echo -e "${BLUE}======================================================${NC}"

# 2. 系统发行版与包管理器自适应检测
_init_distro() {
    export DISTRO_FAMILY="unknown"
    export PKG_MGR="unknown"
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_NAME="${PRETTY_NAME:-$ID}"
    fi

    case "$DISTRO_ID" in
        kylin|neokylin|centos|rhel|rocky|almalinux|openEuler|euler)
            DISTRO_FAMILY="redhat"
            if command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi
            ;;
        ubuntu|debian|linx|deepin|uos|ubuntu-ky)
            DISTRO_FAMILY="debian"
            PKG_MGR="apt-get"
            ;;
        arch|manjaro)
            DISTRO_FAMILY="arch"
            PKG_MGR="pacman"
            ;;
        alpine)
            DISTRO_FAMILY="alpine"
            PKG_MGR="apk"
            ;;
        *)
            # 兜底检测
            if command -v apt-get &>/dev/null; then
                DISTRO_FAMILY="debian"
                PKG_MGR="apt-get"
            elif command -v dnf &>/dev/null; then
                DISTRO_FAMILY="redhat"
                PKG_MGR="dnf"
            elif command -v yum &>/dev/null; then
                DISTRO_FAMILY="redhat"
                PKG_MGR="yum"
            elif command -v pacman &>/dev/null; then
                DISTRO_FAMILY="arch"
                PKG_MGR="pacman"
            elif command -v apk &>/dev/null; then
                DISTRO_FAMILY="alpine"
                PKG_MGR="apk"
            fi
            ;;
    esac

    _log_info "检测到系统发行版: ${YELLOW}${DISTRO_NAME:-未知}${NC} (体系: ${CYAN}${DISTRO_FAMILY}${NC})"
}
_init_distro

# 3. 图形界面检测与一键部署
check_and_install_gui() {
    local has_gui=false
    
    # 检测常见桌面环境的会话管理器或 xsession 目录
    if [ -d /usr/share/xsessions ] && [ "$(ls -A /usr/share/xsessions 2>/dev/null)" ]; then
        has_gui=true
    elif command -v ukui-session &>/dev/null || command -v mate-session &>/dev/null || command -v gnome-session &>/dev/null || command -v xfce4-session &>/dev/null; then
        has_gui=true
    fi

    if [ "$has_gui" = true ]; then
        _log_info "检测到系统已安装图形界面 (GUI)。"
        return 0
    fi

    _log_warn "未检测到系统已安装桌面环境（图形界面）。"
    echo -e "${YELLOW}======================================================${NC}"
    echo -e "⚠️  VNC 服务运行必须依赖桌面环境。若无图形界面，连接后将遭遇黑屏。"
    echo -e "${YELLOW}======================================================${NC}"
    echo "请选择桌面环境安装策略:"
    echo -e "  1. 安装 ${GREEN}UKUI 桌面环境${NC} (麒麟默认桌面，推荐)"
    echo -e "  2. 安装 ${GREEN}MATE 桌面环境${NC} (轻量、稳定、兼容性好)"
    echo -e "  3. 安装 ${GREEN}XFCE 桌面环境${NC} (极度轻量，资源占用低)"
    echo -e "  4. 忽略警告，继续安装 VNC (我已自行安装或稍后手动配置)"
    echo -e "  0. 退出安装"
    echo -e "${YELLOW}------------------------------------------------------${NC}"
    
    read -p "请输入选项 [0-4]: " gui_choice < /dev/tty
    
    if [ "$gui_choice" = "1" ]; then
        _log_info "正在为您安装 UKUI 桌面环境，此过程可能需要几分钟，请耐心等待..."
        if [ "$DISTRO_FAMILY" = "redhat" ]; then
            $PKG_MGR groupinstall -y "UKUI Desktop" || $PKG_MGR install -y ukui
        elif [ "$DISTRO_FAMILY" = "debian" ]; then
            apt-get update && apt-get install -y ukui-desktop-environment
        else
            _log_warn "该系统体系暂未支持自动部署 UKUI，自动切换为安装 XFCE..."
            gui_choice="3"
        fi
    fi

    if [ "$gui_choice" = "2" ]; then
        _log_info "正在为您安装 MATE 桌面环境，此过程可能需要几分钟..."
        if [ "$DISTRO_FAMILY" = "redhat" ]; then
            if [[ "$DISTRO_ID" =~ (centos|rhel|rocky|almalinux) ]]; then
                if ! rpm -q epel-release &>/dev/null; then
                    _log_warn "检测到系统未启用 EPEL 软件源，正在为您部署 EPEL 以便下载图形组件..."
                    $PKG_MGR install -y epel-release || true
                fi
            fi
            $PKG_MGR groupinstall -y "MATE Desktop" || $PKG_MGR install -y mate-desktop
        elif [ "$DISTRO_FAMILY" = "debian" ]; then
            apt-get update && apt-get install -y mate-desktop-environment
        elif [ "$DISTRO_FAMILY" = "arch" ]; then
            pacman -Sy --noconfirm mate mate-extra
        elif [ "$DISTRO_FAMILY" = "alpine" ]; then
            apk update && apk add mate-desktop mate-icon-theme dbus xf86-input-libinput
        fi
    elif [ "$gui_choice" = "3" ]; then
        _log_info "正在为您安装 XFCE 桌面环境，此过程可能需要几分钟..."
        if [ "$DISTRO_FAMILY" = "redhat" ]; then
            if [[ "$DISTRO_ID" =~ (centos|rhel|rocky|almalinux) ]]; then
                if ! rpm -q epel-release &>/dev/null; then
                    _log_warn "检测到系统未启用 EPEL 软件源，正在为您部署 EPEL 以便下载图形组件..."
                    $PKG_MGR install -y epel-release || true
                fi
            fi
            $PKG_MGR groupinstall -y "Xfce" || $PKG_MGR install -y xfce-desktop-environment
        elif [ "$DISTRO_FAMILY" = "debian" ]; then
            apt-get update && apt-get install -y xfce4 xfce4-goodies
        elif [ "$DISTRO_FAMILY" = "arch" ]; then
            pacman -Sy --noconfirm xfce4 xfce4-goodies
        elif [ "$DISTRO_FAMILY" = "alpine" ]; then
            apk update && apk add xfce4 xfce4-screensaver dbus xf86-input-libinput
        fi
    elif [ "$gui_choice" = "4" ]; then
        _log_warn "跳过桌面环境安装，继续部署 VNC..."
        return 0
    elif [ "$gui_choice" = "0" ]; then
        _log_info "已取消安装。"
        exit 0
    else
        _log_err "输入无效，已取消桌面自动配置。"
    fi

    if [ $? -eq 0 ]; then
        _log_info "桌面环境部署成功！"
        # 设置系统默认启动到图形界面
        systemctl set-default graphical.target &>/dev/null || true
    else
        _log_err "桌面环境部署失败，请检查系统 YUM/APT/Pacman/APK 源配置。"
        read -p "是否强制继续配置 VNC 服务? (y/N): " force_cont < /dev/tty
        if [[ ! "$force_cont" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}
check_and_install_gui

# 4. 安装 VNC 服务端软件
install_vnc_packages() {
    _log_info "正在安装 VNC 服务端 (TigerVNC)..."
    if [ "$DISTRO_FAMILY" = "redhat" ]; then
        $PKG_MGR install -y tigervnc-server tigervnc-server-module
    elif [ "$DISTRO_FAMILY" = "debian" ]; then
        apt-get update
        apt-get install -y tigervnc-standalone-server tigervnc-common dbus-x11
    elif [ "$DISTRO_FAMILY" = "arch" ]; then
        pacman -Sy --noconfirm tigervnc xorg-server
    elif [ "$DISTRO_FAMILY" = "alpine" ]; then
        apk update
        apk add tigervnc dbus xvfb xorg-server
    else
        _log_err "该系统架构暂不支持自动下载 VNC 软件包，请先手动配置 vncserver 后再试。"
        exit 1
    fi

    if ! command -v vncserver &>/dev/null; then
        _log_err "VNC 服务端 (TigerVNC) 安装失败，请检查网络或软件源。"
        exit 1
    fi
    _log_info "TigerVNC 安装成功！"
}
install_vnc_packages

# 5. 配置用户、端口与密码
configure_vnc_user_details() {
    # 提取系统可登录的用户列表 (UID >= 1000 或 root)
    local_users=()
    while IFS=: read -r username _ uid _ _ home shell; do
        if [[ "$uid" -ge 1000 && "$uid" -lt 60000 ]] || [[ "$username" == "root" ]]; then
            if [[ -d "$home" ]]; then
                local_users+=("$username")
            fi
        fi
    done < /etc/passwd

    echo -e "\n${BLUE}================ 账户与访问端口配置 ================${NC}"
    echo "系统检测到以下可用账户:"
    for i in "${!local_users[@]}"; do
        echo -e "  [$((i+1))] ${GREEN}${local_users[$i]}${NC}"
    done
    echo -e "  [0] 手动输入其它用户名"
    echo -e "${BLUE}------------------------------------------------------${NC}"
    
    VNC_USER=""
    while [[ -z "$VNC_USER" ]]; do
        read -p "请选择要运行 VNC 的账户序号 [1-${#local_users[@]}，默认 1]: " user_idx < /dev/tty
        user_idx=${user_idx:-1}
        
        if [[ "$user_idx" -eq 0 ]]; then
            read -p "请输入自定义用户名: " custom_user < /dev/tty
            if id "$custom_user" &>/dev/null; then
                VNC_USER="$custom_user"
            else
                _log_err "用户 $custom_user 不存在，请重新选择！"
            fi
        elif [[ "$user_idx" -gt 0 && "$user_idx" -le "${#local_users[@]}" ]]; then
            VNC_USER="${local_users[$((user_idx-1))]}"
        else
            _log_err "输入序号无效，请重新输入。"
        fi
    done

    # 警告以 root 运行
    if [ "$VNC_USER" = "root" ]; then
        _log_warn "您选择了 root 账户。在生产环境中以 root 运行 VNC 存在较大安全风险！"
    fi

    # 获取用户 Home 目录
    USER_HOME=$(eval echo "~$VNC_USER")

    # 配置显示编号 (Display Number) 与端口
    echo -e "\n${BLUE}------------------------------------------------------${NC}"
    _log_info "配置 VNC 桌面号 (Display Number)"
    echo "默认桌面号 :1 对应端口 5901，:2 对应 5902，依此类推。"
    
    DISPLAY_NUM=""
    while [[ -z "$DISPLAY_NUM" ]]; do
        read -p "请输入桌面显示编号 [1-99，默认 1]: " disp_num < /dev/tty
        disp_num=${disp_num:-1}
        
        if [[ "$disp_num" =~ ^[0-9]+$ ]] && [[ "$disp_num" -ge 1 && "$disp_num" -le 99 ]]; then
            # 检测端口是否被占用
            local vnc_port=$((5900 + disp_num))
            if ss -tln | grep -q ":${vnc_port} "; then
                _log_warn "端口 ${vnc_port} 已被占用，请更换其它桌面编号！"
            else
                DISPLAY_NUM="$disp_num"
            fi
        else
            _log_err "输入无效，请输入 1 到 99 之间的数字。"
        fi
    done
    VNC_PORT=$((5900 + DISPLAY_NUM))

    # 配置 VNC 密码
    echo -e "\n${BLUE}------------------------------------------------------${NC}"
    _log_info "配置 VNC 访问密码"
    echo -e "${YELLOW}提示: VNC 密码长度必须在 6-8 位之间，多出部分会被自动截断。${NC}"
    
    VNC_PASSWD=""
    while [[ -z "$VNC_PASSWD" ]]; do
        read -s -p "请输入 VNC 远程连接密码: " passwd1 < /dev/tty
        echo ""
        read -s -p "请再次输入连接密码以确认: " passwd2 < /dev/tty
        echo ""
        
        if [ "$passwd1" != "$passwd2" ]; then
            _log_err "两次输入的密码不一致，请重新输入！"
        elif [[ ${#passwd1} -lt 6 ]]; then
            _log_err "密码太短，长度必须至少为 6 位！"
        else
            VNC_PASSWD="${passwd1:0:8}" # 自动截断到 8 位以符合 vnc 标准
            if [[ ${#passwd1} -gt 8 ]]; then
                _log_warn "密码长度超过 8 位，已自动截断为前 8 位: ${VNC_PASSWD}"
            fi
        fi
    done

    # 写入 VNC 密码文件
    _log_info "正在为用户 ${VNC_USER} 植入 VNC 访问授权..."
    mkdir -p "$USER_HOME/.vnc"
    echo "$VNC_PASSWD" | vncpasswd -f > "$USER_HOME/.vnc/passwd"
    chmod 600 "$USER_HOME/.vnc/passwd"
    chown -R "$VNC_USER:$VNC_USER" "$USER_HOME/.vnc"
}
configure_vnc_user_details

# 6. 配置桌面环境自启动脚本 (xstartup)
configure_xstartup_script() {
    _log_info "正在生成通用桌面映射引擎 (${USER_HOME}/.vnc/xstartup)..."
    
    cat > "$USER_HOME/.vnc/xstartup" << 'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# 环境初始化
[ -r $HOME/.Xresources ] && xrdb $HOME/.Xresources
vncconfig -iconic &

# 自动探测并拉起当前系统最佳的图形桌面
if [ -x /usr/bin/ukui-session ]; then
    # 银河麒麟默认 UKUI 桌面
    exec dbus-launch --exit-with-session /usr/bin/ukui-session
elif [ -x /usr/bin/mate-session ]; then
    # MATE 桌面
    exec dbus-launch --exit-with-session /usr/bin/mate-session
elif [ -x /usr/bin/gnome-session ]; then
    # GNOME 桌面
    export XDG_CURRENT_DESKTOP="GNOME"
    exec gnome-session
elif [ -x /usr/bin/xfce4-session ]; then
    # XFCE 桌面
    exec dbus-launch --exit-with-session /usr/bin/xfce4-session
elif [ -x /usr/bin/startxfce4 ]; then
    exec startxfce4
else
    # 极简窗口管理器兜底
    [ -x /etc/vnc/xstartup ] && exec /etc/vnc/xstartup
    exec x-window-manager
fi
EOF

    chmod +x "$USER_HOME/.vnc/xstartup"
    chown "$VNC_USER:$VNC_USER" "$USER_HOME/.vnc/xstartup"
    _log_info "xstartup 脚本配置完成并授权成功。"
}
configure_xstartup_script

# 7. 配置开机自启动与 Systemd 服务绑定
configure_systemd_and_autostart() {
    _log_info "正在配置 Systemd 服务守护以绑定用户与端口映射..."
    
    # 优先采用现代化 TigerVNC 服务配置模式 (Kylin V10 SP2/SP3, openEuler 22.03+, CentOS 8+)
    if [ -f "/etc/tigervnc/vncserver.users" ]; then
        _log_info "探测到现代化 VNC 架构配置模式，使用 vncserver.users 控制流..."
        
        # 1. 映射桌面号与用户
        # 清除可能冲突的同名桌面号映射
        sed -i "/^:${DISPLAY_NUM}=/d" /etc/tigervnc/vncserver.users
        echo ":${DISPLAY_NUM}=${VNC_USER}" >> /etc/tigervnc/vncserver.users
        
        # 2. 生成对应用户的专属配置文件
        # 自动检索系统已有的桌面会话名称
        local session_name="ukui"
        if [ -d /usr/share/xsessions ]; then
            local matched_session=$(ls /usr/share/xsessions/*.desktop 2>/dev/null | head -1 | xargs basename -s .desktop)
            if [ -n "$matched_session" ]; then
                session_name="$matched_session"
            fi
        fi
        
        _log_info "映射桌面会话 session 属性为: ${session_name}"
        
        cat > "$USER_HOME/.vnc/config" << EOF
session=${session_name}
geometry=1920x1080
alwaysshared
EOF
        chown "$VNC_USER:$VNC_USER" "$USER_HOME/.vnc/config"
        
        # 3. 启动并启用开机自启
        systemctl daemon-reload
        systemctl stop "vncserver@:${DISPLAY_NUM}.service" &>/dev/null || true
        systemctl enable --now "vncserver@:${DISPLAY_NUM}.service"
        
    else
        # 传统模式 (CentOS 7 等老版本体系)
        _log_info "采用传统 Systemd 服务模板复制与替换模式..."
        
        local template_path=""
        if [ -f "/lib/systemd/system/vncserver@.service" ]; then
            template_path="/lib/systemd/system/vncserver@.service"
        elif [ -f "/usr/lib/systemd/system/vncserver@.service" ]; then
            template_path="/usr/lib/systemd/system/vncserver@.service"
        fi
        
        local service_file="/etc/systemd/system/vncserver@:${DISPLAY_NUM}.service"
        
        if [ -n "$template_path" ]; then
            cp -f "$template_path" "$service_file"
            # 替换其中的 <USER> 占位符
            sed -i "s/<USER>/${VNC_USER}/g" "$service_file"
            # 兼容老版 Home 目录路径
            if [ "$VNC_USER" = "root" ]; then
                sed -i "s|/home/root|/root|g" "$service_file"
            fi
        else
            # 极低概率下模板被删除，自动动态构建兼容性 Systemd Unit 文件
            _log_warn "未在系统路径中找到 VNC 启动模板，为您自动跨平台编译构建专有 Unit..."
            
            local VNC_BIN=$(command -v vncserver)
            VNC_BIN=${VNC_BIN:-/usr/bin/vncserver}
            local user_group=$(id -gn "$VNC_USER")
            cat > "$service_file" << EOF
[Unit]
Description=Remote desktop service (VNC)
After=syslog.target network.target

[Service]
Type=forking
User=${VNC_USER}
Group=${user_group}
WorkingDirectory=${USER_HOME}

PIDFile=${USER_HOME}/.vnc/%H%i.pid

ExecStartPre=-${VNC_BIN} -kill %i > /dev/null 2>&1
ExecStart=${VNC_BIN} %i -geometry 1920x1080 -depth 24 -alwaysshared
ExecStop=${VNC_BIN} -kill %i

[Install]
WantedBy=multi-user.target
EOF
        fi
        
        # 启动并启用开机自启
        systemctl daemon-reload
        systemctl stop "vncserver@:${DISPLAY_NUM}.service" &>/dev/null || true
        systemctl enable --now "vncserver@:${DISPLAY_NUM}.service"
    fi

    # 验证服务是否成功运行
    sleep 2
    if systemctl is-active --quiet "vncserver@:${DISPLAY_NUM}.service"; then
        _log_info "${GREEN}VNC 服务已成功注册，自启守护挂载完毕，运行状态正常。${NC}"
    else
        _log_err "VNC 服务未能成功拉起，正在为您尝试手动修复冲突的锁文件并重启..."
        # 尝试清理可能存在的锁和 PID
        rm -f /tmp/.X${DISPLAY_NUM}-lock 2>/dev/null
        rm -f /tmp/.X11-unix/X${DISPLAY_NUM} 2>/dev/null
        systemctl restart "vncserver@:${DISPLAY_NUM}.service"
        
        if systemctl is-active --quiet "vncserver@:${DISPLAY_NUM}.service"; then
            _log_info "${GREEN}服务已通过深度链条重置成功拉起！${NC}"
        else
            _log_err "服务启动依然受阻，请手动检查运行日志: journalctl -xeu vncserver@:${DISPLAY_NUM}.service"
        fi
    fi
}
configure_systemd_and_autostart

# 8. 自动探测并放行防火墙端口
configure_firewall() {
    _log_info "正在检测网络防火墙状态并配置放行策略..."
    
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        _log_info "检测到 active 状态的 FirewallD 防火墙，正在自动放行 TCP 端口 ${VNC_PORT}..."
        firewall-cmd --permanent --add-port=${VNC_PORT}/tcp &>/dev/null
        firewall-cmd --reload &>/dev/null
        _log_info "FirewallD 端口放行成功！"
    elif command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        _log_info "检测到 active 状态的 UFW 防火墙，正在自动放行 TCP 端口 ${VNC_PORT}..."
        ufw allow ${VNC_PORT}/tcp &>/dev/null
        _log_info "UFW 端口放行成功！"
    else
        _log_info "未检测到运行中的系统防火墙，跳过端口开通操作。"
    fi
}
configure_firewall

# 获取服务器内网 IP 地址
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$SERVER_IP" ] && SERVER_IP="您的服务器IP"

echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN}🎉 恭喜！麒麟服务器 VNC 服务一键安装与开机自启部署成功！${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e " 👤 运行账户: ${CYAN}${VNC_USER}${NC}"
echo -e " 🔌 监听端口: ${CYAN}${VNC_PORT}${NC} (对应桌面号 :${DISPLAY_NUM})"
echo -e " 🚀 开机自启: ${GREEN}已启用 (Enabled)${NC}"
echo -e " 🖥️ 连接地址: ${YELLOW}${SERVER_IP}:${DISPLAY_NUM}${NC}  或  ${YELLOW}${SERVER_IP}:${VNC_PORT}${NC}"
echo -e " 🛠️ 启动服务: ${CYAN}systemctl start vncserver@:${DISPLAY_NUM}.service${NC}"
echo -e " 🛑 停止服务: ${CYAN}systemctl stop vncserver@:${DISPLAY_NUM}.service${NC}"
echo -e " 📝 审计日志: ${BLUE}${LOG_FILE}${NC}"
echo -e "${GREEN}======================================================${NC}"
exit 0
