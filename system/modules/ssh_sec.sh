# 2.1 修改账号密码 (支持指定任意账号)
change_user_password() {
    echo -e "\n${BLUE}--- 修改账号密码 ---${NC}"
    echo -e "${YELLOW}请输入要修改密码的用户名 (直接回车默认修改 root):${NC}"
    read -p "> " TARGET_USER
    TARGET_USER=${TARGET_USER:-root}

    # 验证用户是否存在
    if ! id "$TARGET_USER" &>/dev/null; then
        echo -e "${RED}错误: 用户 '$TARGET_USER' 不存在。${NC}"
        read -p "按回车键继续..."
        return
    fi

    echo -e "${YELLOW}正在为用户 ${GREEN}$TARGET_USER${YELLOW} 设置新密码:${NC}"
    passwd "$TARGET_USER"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}成功: 用户 '$TARGET_USER' 的密码已修改。${NC}"
    else
        echo -e "${RED}取消: 密码修改失败或用户取消操作。${NC}"
    fi
    read -p "按回车键继续..."
}

# 2.2 开启 Root SSH 登录
enable_root_ssh() {
    echo -e "\n${BLUE}--- 开启 Root SSH 远程登录 ---${NC}"
    echo -e "${YELLOW}正在修改 SSH 配置文件...${NC}"
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%F_%T)
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

    # 统一使用封装的跨平台重启函数
    _svc_restart "$SVC_SSH"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}成功: 已允许 Root 账号通过密码进行 SSH 远程登录。${NC}"
    else
        echo -e "${RED}错误: SSH 服务重启失败，请手动检查。${NC}"
    fi
    read -p "按回车键继续..."
}

# 2.3 生成 SSH 公私钥对
generate_ssh_keypair() {
    echo -e "\n${BLUE}--- 生成 SSH 公私钥对 ---${NC}"
    SSH_KEY_DIR="/data/ssh_key"

    # 确保目录存在
    if [ ! -d "$SSH_KEY_DIR" ]; then
        mkdir -p "$SSH_KEY_DIR"
        chmod 700 "$SSH_KEY_DIR"
        echo -e "${YELLOW}已创建目录: $SSH_KEY_DIR${NC}"
    fi

    # 询问密钥类型
    echo -e "${YELLOW}请选择密钥类型:${NC}"
    echo " 1. RSA 4096位  (兼容性最佳，推荐)"
    echo " 2. ED25519     (更短、更安全，现代系统推荐)"
    echo " 3. ECDSA 521位 (椭圆曲线)"
    read -p "请选择 [1-3，默认 1]: " key_type_choice
    key_type_choice=${key_type_choice:-1}

    case $key_type_choice in
        1) KEY_TYPE="rsa"; KEY_BITS="-b 4096" ;;
        2) KEY_TYPE="ed25519"; KEY_BITS="" ;;
        3) KEY_TYPE="ecdsa"; KEY_BITS="-b 521" ;;
        *) echo -e "${RED}无效选择，使用默认 RSA 4096。${NC}"; KEY_TYPE="rsa"; KEY_BITS="-b 4096" ;;
    esac

    # 询问密钥注释/名称
    echo -e "${YELLOW}请输入密钥注释/标识 (如: server-name 或邮箱, 直接回车跳过):${NC}"
    read -p "> " KEY_COMMENT
    KEY_COMMENT=${KEY_COMMENT:-"generated-by-system_init-$(date +%Y%m%d%H%M%S)"}

    # 生成文件名 (基于注释，避免特殊字符)
    KEY_FILENAME=$(echo "$KEY_COMMENT" | sed 's/[^a-zA-Z0-9._-]/_/g')
    KEY_PATH="$SSH_KEY_DIR/${KEY_TYPE}_${KEY_FILENAME}"

    # 如果文件已存在，询问是否覆盖
    if [ -f "${KEY_PATH}" ]; then
        echo -e "${YELLOW}警告: 密钥文件 ${KEY_PATH} 已存在。${NC}"
        read -p "是否覆盖? (y/n): " ow_confirm
        if [[ "$ow_confirm" != "y" && "$ow_confirm" != "Y" ]]; then
            echo -e "${YELLOW}已取消。${NC}"
            read -p "按回车键继续..."
            return
        fi
    fi

    echo -e "${YELLOW}正在生成 $KEY_TYPE 密钥对，请稍候...${NC}"
    # -N "" 表示不设置密语 (passphrase)
    ssh-keygen -t "$KEY_TYPE" $KEY_BITS -C "$KEY_COMMENT" -f "${KEY_PATH}" -N ""

    if [ $? -eq 0 ]; then
        chmod 600 "${KEY_PATH}"
        chmod 644 "${KEY_PATH}.pub"
        echo -e "${GREEN}======== 密钥生成成功 ========${NC}"
        echo -e "${YELLOW}私钥路径:${NC} ${KEY_PATH}"
        echo -e "${YELLOW}公钥路径:${NC} ${KEY_PATH}.pub"
        echo -e "${YELLOW}公钥内容 (可添加到服务器 authorized_keys):${NC}"
        echo -e "${BLUE}-----------------------------------${NC}"
        cat "${KEY_PATH}.pub"
        echo -e "${BLUE}-----------------------------------${NC}"
        echo -e "${GREEN}密钥文件已保存至: $SSH_KEY_DIR${NC}"
        ls -lh "$SSH_KEY_DIR/"
    else
        echo -e "${RED}错误: 密钥生成失败，请检查环境。${NC}"
    fi
    read -p "按回车键继续..."
}

# 2.4 SSH 证书 (公钥) 管理函数
manage_ssh_certs() {
    # ---- 先选择目标用户 ----
    clear
    echo -e "${BLUE}--- 请选择要管理公钥的目标用户 ---${NC}"

    # 枚举可登录用户（shell 不是 nologin/false）
    mapfile -t CERT_USERS < <(
        awk -F: '($7 !~ /nologin|false/ && $3 >= 0) {print $1}' /etc/passwd
    )

    if [ ${#CERT_USERS[@]} -eq 0 ]; then
        echo -e "${RED}错误: 未找到可用用户。${NC}"
        read -p "按回车键返回..."
        return
    fi

    for i in "${!CERT_USERS[@]}"; do
        U="${CERT_USERS[$i]}"
        U_HOME=$(getent passwd "$U" | cut -d: -f6)
        AUTH_CNT=0
        [ -f "$U_HOME/.ssh/authorized_keys" ] && AUTH_CNT=$(grep -c . "$U_HOME/.ssh/authorized_keys" 2>/dev/null || echo 0)
        echo "  [$((i+1))] $U  (家目录: $U_HOME  已授权公钥: ${AUTH_CNT} 条)"
    done
    echo "  [0] 取消返回"
    echo ""
    read -p "请选择目标用户序号 [0-${#CERT_USERS[@]}]: " u_idx

    if [[ "$u_idx" == "0" || -z "$u_idx" ]]; then
        return
    fi
    if ! [[ "$u_idx" =~ ^[0-9]+$ ]] || [ "$u_idx" -lt 1 ] || [ "$u_idx" -gt "${#CERT_USERS[@]}" ]; then
        echo -e "${RED}无效的选择。${NC}"; sleep 1; return
    fi

    CERT_TARGET_USER="${CERT_USERS[$((u_idx-1))]}"
    TARGET_HOME=$(getent passwd "$CERT_TARGET_USER" | cut -d: -f6)
    TARGET_AUTH_KEYS="$TARGET_HOME/.ssh/authorized_keys"

    # ---- 确保 .ssh 目录和文件存在 ----
    if [ ! -d "$TARGET_HOME/.ssh" ]; then
        mkdir -p "$TARGET_HOME/.ssh"
        chmod 700 "$TARGET_HOME/.ssh"
        chown "$CERT_TARGET_USER":"$CERT_TARGET_USER" "$TARGET_HOME/.ssh" 2>/dev/null
    fi
    touch "$TARGET_AUTH_KEYS"
    chmod 600 "$TARGET_AUTH_KEYS"
    chown "$CERT_TARGET_USER":"$CERT_TARGET_USER" "$TARGET_AUTH_KEYS" 2>/dev/null

    while true; do
        clear
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}   SSH 证书管理 - 用户: ${YELLOW}$CERT_TARGET_USER${GREEN}           ${NC}"
        echo -e "${GREEN}   authorized_keys: $TARGET_AUTH_KEYS    ${NC}"
        echo -e "${GREEN}==============================================${NC}"
        echo " 1. 添加 SSH 公钥 (追加到 authorized_keys)"
        echo " 2. 查看已授权的公钥列表"
        echo " 3. 清空所有已授权公钥"
        echo " 4. 禁用密码登录 (仅限证书/密钥登录, 增强安全)"
        echo " 5. 恢复密码登录 (允许账号密码访问)"
        echo " 0. 返回"
        echo -e "${GREEN}==============================================${NC}"
        read -p "请选择操作 [0-5]: " ssh_choice

        case $ssh_choice in
            1)
                while true; do
                    clear
                    echo -e "${GREEN}==============================================${NC}"
                    echo -e "${GREEN}  添加公钥 → 用户: ${YELLOW}$CERT_TARGET_USER${GREEN}            ${NC}"
                    echo -e "${GREEN}==============================================${NC}"
                    echo " 1. 从 /data/ssh_key 读取已生成的公钥"
                    echo " 2. 手动粘贴公钥字符串"
                    echo " 0. 返回上层菜单"
                    echo -e "${GREEN}==============================================${NC}"
                    read -p "请选择 [0-2]: " add_mode

                    case $add_mode in
                        1)
                            SSH_KEY_DIR="/data/ssh_key"
                            PUB_COUNT=$(ls "$SSH_KEY_DIR"/*.pub 2>/dev/null | wc -l)
                            if [ ! -d "$SSH_KEY_DIR" ] || [ "$PUB_COUNT" -eq 0 ]; then
                                echo -e "\n${RED}错误: $SSH_KEY_DIR 中未找到任何 .pub 文件。${NC}"
                                echo -e "${YELLOW}提示: 请先通过 [SSH 管理 -> 生成 SSH 公私钥对] 创建密钥。${NC}"
                                read -p "按回车键继续..."
                                continue
                            fi

                            echo -e "\n${YELLOW}检测到以下公钥文件:${NC}"
                            mapfile -t PUB_FILES < <(ls "$SSH_KEY_DIR"/*.pub 2>/dev/null)
                            for i in "${!PUB_FILES[@]}"; do
                                FNAME=$(basename "${PUB_FILES[$i]}")
                                FCOMMENT=$(awk '{print $3}' "${PUB_FILES[$i]}" 2>/dev/null)
                                ALREADY_TAG=""
                                grep -qsF "$(cat "${PUB_FILES[$i]}")" "$TARGET_AUTH_KEYS" && ALREADY_TAG=" ${GREEN}[已授权给 $CERT_TARGET_USER]${NC}"
                                echo -e "  [$((i+1))] $FNAME  ${FCOMMENT:+(注释: $FCOMMENT)}$ALREADY_TAG"
                            done
                            echo "  [0] 取消"
                            echo ""
                            read -p "请选择要导入的序号 [0-${#PUB_FILES[@]}]: " pub_idx

                            if [[ "$pub_idx" == "0" || -z "$pub_idx" ]]; then
                                echo -e "${YELLOW}已取消。${NC}"
                                read -p "按回车键继续..."
                                continue
                            fi
                            if ! [[ "$pub_idx" =~ ^[0-9]+$ ]] || [ "$pub_idx" -lt 1 ] || [ "$pub_idx" -gt "${#PUB_FILES[@]}" ]; then
                                echo -e "${RED}无效的选择。${NC}"
                                read -p "按回车键继续..."
                                continue
                            fi

                            SELECTED_PUB="${PUB_FILES[$((pub_idx-1))]}"
                            PUB_KEY_CONTENT=$(cat "$SELECTED_PUB")

                            echo -e "\n${BLUE}--- 即将导入以下公钥到用户 [$CERT_TARGET_USER] ---${NC}"
                            echo "$PUB_KEY_CONTENT"
                            echo -e "${BLUE}-----------------------------------------------------${NC}"
                            read -p "确认添加? (y/n): " add_confirm

                            if [[ "$add_confirm" == "y" || "$add_confirm" == "Y" ]]; then
                                if grep -qsF "$PUB_KEY_CONTENT" "$TARGET_AUTH_KEYS"; then
                                    echo -e "${YELLOW}提示: 该公钥已在 authorized_keys 中，无需重复添加。${NC}"
                                else
                                    echo "$PUB_KEY_CONTENT" >> "$TARGET_AUTH_KEYS"
                                    chown "$CERT_TARGET_USER":"$CERT_TARGET_USER" "$TARGET_AUTH_KEYS" 2>/dev/null
                                    echo -e "${GREEN}成功: $(basename "$SELECTED_PUB") 已导入用户 [$CERT_TARGET_USER] 的 authorized_keys。${NC}"
                                fi
                            else
                                echo -e "${YELLOW}已取消。${NC}"
                            fi
                            read -p "按回车键继续..."
                            ;;
                        2)
                            echo -e "\n${YELLOW}请粘贴完整的 SSH 公钥字符串:${NC}"
                            echo -e "${BLUE}(示例: ssh-ed25519 AAAA... / ssh-rsa AAAA...)${NC}"
                            read -p "> " PUB_KEY
                            if [[ -n "$PUB_KEY" ]]; then
                                if ! echo "$PUB_KEY" | grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh-ed25519) "; then
                                    echo -e "${RED}警告: 公钥格式疑似有误 (未以标准前缀开头)。${NC}"
                                    read -p "仍要继续添加? (y/n): " force_add
                                    if [[ "$force_add" != "y" && "$force_add" != "Y" ]]; then
                                        read -p "按回车键继续..."
                                        continue
                                    fi
                                fi
                                if grep -qsF "$PUB_KEY" "$TARGET_AUTH_KEYS"; then
                                    echo -e "${YELLOW}提示: 该公钥已存在，无需重复添加。${NC}"
                                else
                                    echo "$PUB_KEY" >> "$TARGET_AUTH_KEYS"
                                    chown "$CERT_TARGET_USER":"$CERT_TARGET_USER" "$TARGET_AUTH_KEYS" 2>/dev/null
                                    echo -e "${GREEN}成功: 公钥已追加到用户 [$CERT_TARGET_USER] 的 authorized_keys。${NC}"
                                fi
                            else
                                echo -e "${YELLOW}未输入内容，已取消。${NC}"
                            fi
                            read -p "按回车键继续..."
                            ;;
                        0) break ;;
                        *) echo -e "${RED}无效选择。${NC}"; sleep 1 ;;
                    esac
                done
                ;;
            2)
                echo -e "\n${BLUE}--- 用户 [$CERT_TARGET_USER] 的授权公钥列表 ---${NC}"
                echo -e "${BLUE}文件: $TARGET_AUTH_KEYS${NC}"
                if [ -s "$TARGET_AUTH_KEYS" ]; then
                    cat "$TARGET_AUTH_KEYS" | nl
                else
                    echo "  (空，无已授权公钥)"
                fi
                read -p "按回车键继续..."
                ;;
            3)
                echo -e "${RED}警告: 将清空用户 [$CERT_TARGET_USER] 的所有已授权公钥!${NC}"
                read -p "确定清空? (y/n): " c_conf
                if [ "$c_conf" == "y" ]; then
                    > "$TARGET_AUTH_KEYS"
                    echo -e "${GREEN}已清空用户 [$CERT_TARGET_USER] 的 authorized_keys。${NC}"
                fi
                read -p "按回车键继续..."
                ;;
            4)
                echo -e "${RED}警告: 操作前请确保公钥已正确配置，否则将无法登录!${NC}"
                read -p "确认禁用密码登录? (y/n): " d_conf
                if [ "$d_conf" == "y" ]; then
                    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
                    _svc_restart "$SVC_SSH"
                    echo -e "${GREEN}已切换为证书/密钥登录模式。${NC}"
                fi
                read -p "按回车键继续..."
                ;;
            5)
                sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
                _svc_restart "$SVC_SSH"
                echo -e "${GREEN}已恢复密码登录。${NC}"
                read -p "按回车键继续..."
                ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

# ================================================================
# 辅助函数: 无依赖网络连通性探测 (自包含)
# ================================================================
_check_net_available() {
    local timeout=3
    # 方法 1: Bash /dev/tcp 探测 1.1.1.1:80（Cloudflare，无需 DNS）
    if (exec 9<>/dev/tcp/1.1.1.1/80) 2>/dev/null; then
        exec 9>&- 2>/dev/null
        return 0
    fi
    # 方法 2: /dev/tcp 探测 8.8.8.8:53（Google DNS）
    if (exec 9<>/dev/tcp/8.8.8.8/53) 2>/dev/null; then
        exec 9>&- 2>/dev/null
        return 0
    fi
    # 方法 3: ping 降级兜底
    if ping -c1 -W${timeout} 1.1.1.1 &>/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# ================================================================
# 辅助函数: 准确探测 SSH 真实服务单元名称
# 涵盖 Debian/Ubuntu (ssh), RHEL/CentOS/Euler/Kylin (sshd)
# ================================================================
_detect_ssh_service_name() {
    if command -v systemctl &>/dev/null; then
        # 1. 运行中的优先判断
        if systemctl is-active --quiet ssh 2>/dev/null; then
            echo "ssh"
            return 0
        fi
        if systemctl is-active --quiet sshd 2>/dev/null; then
            echo "sshd"
            return 0
        fi
        # 2. 检查 unit 文件是否存在
        if systemctl cat ssh.service &>/dev/null; then
            echo "ssh"
            return 0
        fi
        if systemctl cat sshd.service &>/dev/null; then
            echo "sshd"
            return 0
        fi
        if [ -n "${SVC_SSH:-}" ] && systemctl cat "${SVC_SSH}.service" &>/dev/null; then
            echo "$SVC_SSH"
            return 0
        fi
    fi

    # SysVinit / OpenRC 探测
    if [ -f /etc/init.d/ssh ]; then echo "ssh"; return 0; fi
    if [ -f /etc/init.d/sshd ]; then echo "sshd"; return 0; fi

    # 包管理器推断默认名称
    if command -v apt &>/dev/null; then
        echo "ssh"
    else
        echo "sshd"
    fi
    return 0
}

# 2.5 SSH 配置巡检
check_ssh_config() {
    # 强制确保变量已初始化
    [ -z "$SVC_SSH" ] && _init_distro
    
    local CYAN='\033[0;36m'
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    clear
    echo -e "${BLUE}======================================================${NC}"
    echo -e "${CYAN}          SSH 配置信息检查报告 (修正版)               ${NC}"
    echo -e "${BLUE}======================================================${NC}"
    echo -e "检查时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "主机名称: $(hostname)"
    echo ""

    # [1] 配置文件
    echo -e "${YELLOW}[1] SSH 配置文件路径: ${SSHD_CONFIG}${NC}"
    if [ ! -f "$SSHD_CONFIG" ]; then
        echo -e "${RED}    ✗ 配置文件不存在${NC}"
        echo ""
        echo -e "${YELLOW}  【诊断说明】${NC}"
        echo -e "  sshd_config 由 openssh-server 安装时创建，与服务是否启动无关。"
        echo -e "  文件不存在 = ${RED}openssh-server 软件包尚未安装${NC}（而非服务未启动）。"
        echo ""
        echo -e "${CYAN}  【修复方法】根据您的系统执行以下命令安装:${NC}"
        if command -v apt &>/dev/null; then
            echo -e "    ${GREEN}apt update && apt install -y openssh-server${NC}"
        elif command -v dnf &>/dev/null; then
            echo -e "    ${GREEN}dnf install -y openssh-server${NC}"
        elif command -v yum &>/dev/null; then
            echo -e "    ${GREEN}yum install -y openssh-server${NC}"
        elif command -v apk &>/dev/null; then
            echo -e "    ${GREEN}apk add openssh${NC}"
        else
            echo -e "    ${GREEN}apt install -y openssh-server${NC}  # Debian/Ubuntu"
            echo -e "    ${GREEN}yum install -y openssh-server${NC}  # CentOS/RHEL"
        fi
        echo ""
        echo -e "  安装完成后，执行: ${CYAN}systemctl enable --now ssh${NC} (或 sshd)"
        echo ""
        read -p "  是否立即进入「SSH 服务管理中心」进行安装？[Y/n]: " _goto_svc -r < /dev/tty
        if [[ -z "$_goto_svc" || "$_goto_svc" =~ ^[Yy]$ ]]; then
            manage_ssh_service
        fi
        return
    else
        echo -e "${GREEN}    ✓ 配置文件存在${NC}"
    fi
    echo ""

    # [2] 监听端口
    echo -e "${YELLOW}[2] SSH 监听端口配置${NC}"
    PORT_CFG=$(grep -E "^Port " "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}')
    [ -z "$PORT_CFG" ] && PORT_CFG="22 (默认值，配置文件中未显式指定)"
    echo -e "    配置文件中的端口: ${GREEN}${PORT_CFG}${NC}"
    echo ""

    # [3] 监听地址
    echo -e "${YELLOW}[3] SSH 监听地址配置${NC}"
    LISTEN_ADDR=$(grep -E "^ListenAddress " "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}')
    [ -z "$LISTEN_ADDR" ] && LISTEN_ADDR="0.0.0.0 (默认监听所有地址，配置文件中未显式指定)"
    echo -e "    配置文件中的监听地址: ${GREEN}${LISTEN_ADDR}${NC}"
    echo ""

    # [4] 实际运行时监听状态
    echo -e "${YELLOW}[4] 实际运行时 SSH 监听状态${NC}"
    if command -v ss &>/dev/null; then
        echo -e "    使用 ss 命令检测:"
        SS_RESULT=$(ss -tlnp 2>/dev/null | grep -E 'sshd|ssh')
        if [ -z "$SS_RESULT" ]; then
            echo -e "    ${RED}✗ 未检测到 sshd 进程正在监听（服务可能未启动）${NC}"
        else
            echo "$SS_RESULT" | while read -r line; do
                echo -e "    ${GREEN}→ ${line}${NC}"
            done
        fi
    elif command -v netstat &>/dev/null; then
        NETSTAT_RESULT=$(netstat -tlnp 2>/dev/null | grep -E 'sshd|ssh')
        if [ -z "$NETSTAT_RESULT" ]; then
            echo -e "    ${RED}✗ 未检测到 sshd 监听${NC}"
        else
            echo "$NETSTAT_RESULT" | while read -r line; do
                echo -e "    ${GREEN}→ ${line}${NC}"
            done
        fi
    else
        echo -e "    ${RED}✗ 未找到 ss 或 netstat 命令${NC}"
    fi
    echo ""

    # [5] 认证配置
    echo -e "${YELLOW}[5] 认证配置${NC}"
    PASSWD_AUTH=$(grep -E "^PasswordAuthentication " "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}')
    PERMIT_EMPTY=$(grep -E "^PermitEmptyPasswords " "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}')
    PERMIT_ROOT=$(grep -E "^PermitRootLogin " "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}')
    PUBKEY_AUTH=$(grep -E "^PubkeyAuthentication " "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}')
    [ -z "$PASSWD_AUTH" ]  && PASSWD_AUTH="yes (默认值)"
    [ -z "$PERMIT_EMPTY" ] && PERMIT_EMPTY="no (默认值)"
    [ -z "$PERMIT_ROOT" ]  && PERMIT_ROOT="prohibit-password (默认值)"
    [ -z "$PUBKEY_AUTH" ]  && PUBKEY_AUTH="yes (默认值)"
    echo -e "    密码认证(PasswordAuthentication):  ${GREEN}${PASSWD_AUTH}${NC}"
    echo -e "    允许空密码(PermitEmptyPasswords):   ${GREEN}${PERMIT_EMPTY}${NC}"
    echo -e "    Root登录(PermitRootLogin):          ${GREEN}${PERMIT_ROOT}${NC}"
    echo -e "    公钥认证(PubkeyAuthentication):     ${GREEN}${PUBKEY_AUTH}${NC}"
    echo ""

    # [6] 各用户 authorized_keys 状态
    echo -e "${YELLOW}[6] 系统用户 SSH 授权公钥状态${NC}"
    while IFS=: read -r username _ uid _ _ homedir shell; do
        if [[ "$uid" -ge 0 ]] && [[ "$shell" != */nologin ]] && [[ "$shell" != */false ]]; then
            auth_keys="${homedir}/.ssh/authorized_keys"
            if [ -f "$auth_keys" ]; then
                key_count=$(grep -c . "$auth_keys" 2>/dev/null || echo 0)
                echo -e "    用户: ${GREEN}${username}${NC} (UID=${uid})  公钥数: ${key_count} 条"
                while IFS= read -r keyline; do
                    [[ "$keyline" =~ ^#.*$ || -z "$keyline" ]] && continue
                    key_comment=$(echo "$keyline" | awk '{print $NF}')
                    key_type=$(echo "$keyline" | awk '{print $1}')
                    echo -e "      → 类型: ${CYAN}${key_type}${NC}  备注: ${CYAN}${key_comment}${NC}"
                done < "$auth_keys"
            fi
        fi
    done < /etc/passwd
    echo ""

    # [7] SSH 服务状态 (精准探测)
    echo -e "${YELLOW}[7] SSH 服务运行状态${NC}"
    local ACTUAL_SVC
    ACTUAL_SVC=$(_detect_ssh_service_name)
    local ACTUAL_STATUS="inactive"

    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet "$ACTUAL_SVC" 2>/dev/null; then
            ACTUAL_STATUS="active"
            echo -e "    状态: ${GREEN}✓ 运行中 (active)${NC}"
            echo -e "    服务: ${CYAN}${ACTUAL_SVC}${NC}"
            systemctl status "$ACTUAL_SVC" --no-pager -l 2>/dev/null | grep -E "Active:|Main PID:" | while read -r line; do
                echo -e "    ${line}"
            done
        else
            ACTUAL_STATUS="$(systemctl is-active "$ACTUAL_SVC" 2>/dev/null || echo "inactive")"
            echo -e "    状态: ${RED}✗ 未运行 (${ACTUAL_STATUS})${NC}"
            echo -e "    服务名称: ${YELLOW}${ACTUAL_SVC}${NC}"
            echo -e "    提示: 可在 [6. SSH 服务管理中心] 启动或重启服务。"
        fi
    elif command -v rc-service &>/dev/null; then
        if rc-service "$ACTUAL_SVC" status &>/dev/null; then
            ACTUAL_STATUS="active"
            echo -e "    状态: ${GREEN}✓ 运行中${NC} (OpenRC)"
        else
            echo -e "    状态: ${RED}✗ 未运行${NC} (OpenRC)"
        fi
    elif command -v service &>/dev/null; then
        if service "$ACTUAL_SVC" status &>/dev/null; then
            ACTUAL_STATUS="active"
            echo -e "    状态: ${GREEN}✓ 运行中${NC} (SysVinit)"
        else
            echo -e "    状态: ${RED}✗ 未运行${NC} (SysVinit)"
        fi
    else
        echo -e "    ${YELLOW}无法确定服务状态管理器${NC}"
    fi

    # [8] 本机 IP
    echo -e "\n${YELLOW}[8] 本机网络 IP 地址${NC}"
    ip -4 addr show 2>/dev/null | grep -E "inet " | grep -v "127.0.0.1" | while read -r line; do
        iface=$(echo "$line" | awk '{print $NF}')
        addr=$(echo "$line" | awk '{print $2}')
        echo -e "    网卡: ${CYAN}${iface}${NC}  地址: ${GREEN}${addr}${NC}"
    done
    echo ""

    echo -e "${BLUE}======================================================${NC}"
    echo -e "${GREEN}    ⚠  SSH 不会明文存储用户密码                      ${NC}"
    echo -e "${BLUE}======================================================${NC}"

    # [附] /etc/shadow 密码状态 (仅 root)
    if [ "$EUID" -eq 0 ]; then
        echo -e "\n${YELLOW}[附] /etc/shadow 中设有密码的用户${NC}"
        while IFS=: read -r user hash _; do
            if [[ "$hash" != "!" && "$hash" != "*" && -n "$hash" ]]; then
                echo -e "    用户: ${GREEN}${user}${NC}  哈希(前20字符): ${CYAN}${hash:0:20}...${NC}"
            fi
        done < /etc/shadow
    fi
    echo ""
    echo -e "${GREEN}检查完毕！${NC}"
    echo ""

    # 若未处于运行状态，主动询问是否跳转到服务管理中心
    if [ "$ACTUAL_STATUS" != "active" ]; then
        echo -e "${YELLOW}💡 检测到 SSH 服务当前未运行，是否进入服务管理中心进行启动或排查？[Y/n]: ${NC}"
        read -p "  立即进入? [Y/n]: " _handle_svc -r < /dev/tty
        if [[ -z "$_handle_svc" || "$_handle_svc" =~ ^[Yy]$ ]]; then
            manage_ssh_service
            return
        fi
    else
        read -p "按回车键返回..." -r < /dev/tty
    fi
}

# ================================================================
# 2.6 SSH 服务管理中心
# 功能: 查看状态 / 启动 / 停止 / 重启 / 开机自启 / 安装 openssh-server
# ================================================================
manage_ssh_service() {
    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}          🔑 SSH 服务管理中心 (运行与安装)            ${NC}"
        echo -e "${CYAN}======================================================${NC}"

        # ── 实时状态展示 ──────────────────────────────────────────
        local _installed=false _running=false _enabled=false _svc_name=""

        # 检测安装状态 (sshd_config 存在或 sshd 命令存在)
        if [ -f /etc/ssh/sshd_config ] || command -v sshd &>/dev/null; then
            _installed=true
        fi

        # 获取当前系统推断的服务名称
        _svc_name="$(_detect_ssh_service_name)"

        # 检测服务状态
        if command -v systemctl &>/dev/null; then
            if systemctl is-active --quiet "$_svc_name" 2>/dev/null; then
                _running=true
            fi
            if systemctl is-enabled --quiet "$_svc_name" 2>/dev/null; then
                _enabled=true
            fi
        elif command -v rc-service &>/dev/null; then
            rc-service "$_svc_name" status &>/dev/null && _running=true
        elif command -v service &>/dev/null; then
            service "$_svc_name" status &>/dev/null && _running=true
        fi

        # 状态展示区
        echo -e "  安装状态 : $([ "$_installed" = true ] && echo -e "${GREEN}✓ 已安装 (openssh-server)${NC}" || echo -e "${RED}✗ 未安装${NC}")"
        echo -e "  服务名称 : ${CYAN}${_svc_name}${NC}"
        echo -e "  运行状态 : $([ "$_running" = true ] && echo -e "${GREEN}● 运行中 (active)${NC}" || echo -e "${RED}● 已停止 (inactive)${NC}")"
        if command -v systemctl &>/dev/null; then
            echo -e "  开机自启 : $([ "$_enabled" = true ] && echo -e "${GREEN}已开启 (enabled)${NC}" || echo -e "${YELLOW}未开启 (disabled)${NC}")"
        fi
        echo ""
        echo -e "${CYAN}======================================================${NC}"

        # ── 菜单选项 ───────────────────────────────────────────
        echo -e " 1. 查看服务详细状态 (systemctl status / 日志)"
        echo -e " 2. 启动 SSH 服务"
        echo -e " 3. 停止 SSH 服务 ${RED}[危险操作，可能导致断连]${NC}"
        echo -e " 4. 重启 SSH 服务 (使新配置立即生效)"
        echo -e " 5. 设为开机自启 (enable)"
        echo -e " 6. 取消开机自启 (disable)"
        if [ "$_installed" = false ]; then
            echo -e " ${GREEN}7. 安装 openssh-server (当前未安装，一键部署)${NC}"
        else
            echo -e " 7. 重新安装 / 修复 openssh-server"
        fi
        echo -e " 0. 返回上级菜单"
        echo -e "${CYAN}======================================================${NC}"
        read -p "请选择操作 [0-7]: " _svc_choice < /dev/tty
        echo ""

        # 需要安装了服务才能执行的操作预检查
        case "$_svc_choice" in
            2|3|4|5|6)
                if [ "$_installed" = false ]; then
                    echo -e "${RED}✗ 系统尚未安装 openssh-server，无法操作服务。${NC}"
                    echo -e "  ${YELLOW}请先选择选项 [7] 安装 openssh-server。${NC}"
                    read -p "  按回车键继续..." -r < /dev/tty
                    continue
                fi
            ;;
        esac

        case "$_svc_choice" in
            1)
                echo -e "${BLUE}🔍 SSH 服务详细状态:${NC}"
                echo ""
                if command -v systemctl &>/dev/null; then
                    systemctl status "$_svc_name" --no-pager -l 2>/dev/null || true
                elif command -v rc-service &>/dev/null; then
                    rc-service "$_svc_name" status
                elif command -v service &>/dev/null; then
                    service "$_svc_name" status
                fi
                echo ""
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            2)
                echo -e "${YELLOW}⏳ 正在启动 ${_svc_name} 服务...${NC}"
                if command -v systemctl &>/dev/null; then
                    if systemctl start "$_svc_name" 2>/dev/null; then
                        echo -e "${GREEN}✅ SSH 服务启动成功！${NC}"
                        systemctl status "$_svc_name" --no-pager -l 2>/dev/null | grep 'Active:' | \
                            xargs -I{} echo -e "  {}"
                    else
                        echo -e "${RED}✗ 启动失败，请检查日志: journalctl -xe --unit=${_svc_name}${NC}"
                    fi
                elif command -v rc-service &>/dev/null; then
                    rc-service "$_svc_name" start
                elif command -v service &>/dev/null; then
                    service "$_svc_name" start
                fi
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            3)
                echo -e "${RED}⚠️ 警告: 停止 SSH 服务可能中断当前远程终端连接！${NC}"
                read -p "  确认停止? [y/N]: " _confirm < /dev/tty
                if [[ "$_confirm" =~ ^[Yy]$ ]]; then
                    if command -v systemctl &>/dev/null; then
                        systemctl stop "$_svc_name" 2>/dev/null && \
                            echo -e "${GREEN}✅ SSH 服务已停止。${NC}" || \
                            echo -e "${RED}✗ 停止失败。${NC}"
                    elif command -v service &>/dev/null; then
                        service "$_svc_name" stop
                    fi
                else
                    echo -e "${BLUE}操作已取消。${NC}"
                fi
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            4)
                echo -e "${YELLOW}⏳ 正在检查配置并重启 ${_svc_name} 服务...${NC}"
                if command -v sshd &>/dev/null; then
                    if ! sshd -t 2>/dev/null; then
                        echo -e "${RED}⚠️ sshd 配置语法检查失败，强行重启可能导致无法连接！${NC}"
                        sshd -t 2>&1 | head -10 || true
                        echo ""
                        read -p "  仍然强制重启? [y/N]: " _force_rst < /dev/tty
                        if ! [[ "$_force_rst" =~ ^[Yy]$ ]]; then
                            echo -e "${BLUE}操作已取消。${NC}"
                            read -p "按回车键继续..." -r < /dev/tty
                            continue
                        fi
                    fi
                fi

                if command -v systemctl &>/dev/null; then
                    if systemctl restart "$_svc_name" 2>/dev/null; then
                        echo -e "${GREEN}✅ SSH 服务重启成功！配置已生效。${NC}"
                        systemctl status "$_svc_name" --no-pager -l 2>/dev/null | grep 'Active:' | \
                            xargs -I{} echo -e "  {}"
                    else
                        echo -e "${RED}✗ 重启失败，详细错误:${NC}"
                        journalctl -u "$_svc_name" -n 15 --no-pager 2>/dev/null || true
                    fi
                elif command -v service &>/dev/null; then
                    service "$_svc_name" restart
                fi
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            5)
                if command -v systemctl &>/dev/null; then
                    systemctl enable "$_svc_name" 2>/dev/null && \
                        echo -e "${GREEN}✅ SSH 服务已设为开机自启 (enabled)。${NC}" || \
                        echo -e "${RED}✗ 设置失败。${NC}"
                elif command -v rc-update &>/dev/null; then
                    rc-update add "$_svc_name" default
                fi
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            6)
                echo -e "${YELLOW}⚠️ 取消自启后，系统重启后 SSH 服务将不会自动拉起。${NC}"
                read -p "  确认取消自启? [y/N]: " _confirm < /dev/tty
                if [[ "$_confirm" =~ ^[Yy]$ ]]; then
                    if command -v systemctl &>/dev/null; then
                        systemctl disable "$_svc_name" 2>/dev/null && \
                            echo -e "${GREEN}✅ 开机自启已取消 (disabled)。${NC}" || \
                            echo -e "${RED}✗ 取消失败。${NC}"
                    elif command -v rc-update &>/dev/null; then
                        rc-update del "$_svc_name" default
                    fi
                else
                    echo -e "${BLUE}操作已取消。${NC}"
                fi
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            7)
                # ── 安装 / 重装 openssh-server ─────────────────────────
                echo -e "${CYAN}======================================================${NC}"
                echo -e "${CYAN}         安装 / 重装 openssh-server              ${NC}"
                echo -e "${CYAN}======================================================${NC}"

                # 先检测网络
                echo -ne "${BLUE}正在检测网络连通性...${NC} "
                if _check_net_available; then
                    echo -e "${GREEN}✓ 网络可达 (在线安装模式)${NC}"
                    echo ""
                    local _pkg_cmd=""
                    local _pkg_name="openssh-server"
                    if command -v apt &>/dev/null; then
                        _pkg_cmd="apt"
                        echo -e "${YELLOW}⏳ 执行: apt update && apt install -y openssh-server...${NC}"
                        apt update -y 2>/dev/null || true
                        apt install -y openssh-server
                    elif command -v dnf &>/dev/null; then
                        _pkg_cmd="dnf"
                        echo -e "${YELLOW}⏳ 执行: dnf install -y openssh-server openssh-clients...${NC}"
                        dnf install -y openssh-server openssh-clients
                    elif command -v yum &>/dev/null; then
                        _pkg_cmd="yum"
                        echo -e "${YELLOW}⏳ 执行: yum install -y openssh-server openssh-clients...${NC}"
                        yum install -y openssh-server openssh-clients
                    elif command -v apk &>/dev/null; then
                        _pkg_cmd="apk"
                        echo -e "${YELLOW}⏳ 执行: apk add openssh...${NC}"
                        apk add openssh
                    else
                        echo -e "${RED}✗ 未检测到受支持的包管理器。${NC}"
                        read -p "按回车键继续..." -r < /dev/tty
                        continue
                    fi

                    local _install_exit=$?
                    echo ""
                    local _detect_again
                    _detect_again="$(_detect_ssh_service_name)"
                    if [ $_install_exit -eq 0 ] && ([ -f /etc/ssh/sshd_config ] || command -v sshd &>/dev/null); then
                        echo -e "${GREEN}✅ openssh-server 安装成功！${NC}"
                        echo -e "${YELLOW}⏳ 正在启动并设置开机自启 (${_detect_again})...${NC}"
                        if command -v systemctl &>/dev/null; then
                            systemctl enable --now "$_detect_again" 2>/dev/null && \
                                echo -e "${GREEN}✅ SSH 服务已成功启动并设为开机自启。${NC}" || true
                        fi
                    else
                        echo -e "${YELLOW}⚠️ 在线安装可能未完全成功，请检查上方日志输出。${NC}"
                    fi
                else
                    echo -e "${RED}✗ 网络不可达（离线模式）${NC}"
                    echo ""
                    # 尝试自动查找本地离线包
                    local _local_pkg_dir=""
                    for d in "${BASE_DIR:-}/packages" "/opt/ck_sysinit/packages" \
                             "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../packages" \
                             "$PWD/system/packages" "$PWD/packages"; do
                        if [ -d "$d" ]; then
                            _local_pkg_dir="$d"
                            break
                        fi
                    done

                    local _offline_installed=false
                    if [ -n "$_local_pkg_dir" ]; then
                        if command -v dpkg &>/dev/null; then
                            local _deb_files
                            _deb_files=$(find "$_local_pkg_dir" -name "*openssh*server*.deb" 2>/dev/null || true)
                            if [ -n "$_deb_files" ]; then
                                echo -e "${GREEN}✓ 发现本地离线包:${NC}"
                                echo "$_deb_files" | sed 's/^/    /'
                                read -p "  是否立即执行离线安装? [Y/n]: " _do_deb < /dev/tty
                                if [[ -z "$_do_deb" || "$_do_deb" =~ ^[Yy]$ ]]; then
                                    echo -e "${YELLOW}⏳ 正在执行 dpkg -i 安装...${NC}"
                                    dpkg -i $_deb_files 2>/dev/null || apt-get install -f -y 2>/dev/null || true
                                    _offline_installed=true
                                fi
                            fi
                        elif command -v rpm &>/dev/null; then
                            local _rpm_files
                            _rpm_files=$(find "$_local_pkg_dir" -name "*openssh*server*.rpm" 2>/dev/null || true)
                            if [ -n "$_rpm_files" ]; then
                                echo -e "${GREEN}✓ 发现本地离线包:${NC}"
                                echo "$_rpm_files" | sed 's/^/    /'
                                read -p "  是否立即执行离线安装? [Y/n]: " _do_rpm < /dev/tty
                                if [[ -z "$_do_rpm" || "$_do_rpm" =~ ^[Yy]$ ]]; then
                                    echo -e "${YELLOW}⏳ 正在执行 rpm 安装...${NC}"
                                    rpm -Uvh --replacepkgs --nodeps $_rpm_files 2>/dev/null || true
                                    _offline_installed=true
                                fi
                            fi
                        fi
                    fi

                    if [ "$_offline_installed" = true ]; then
                        local _detect_again
                        _detect_again="$(_detect_ssh_service_name)"
                        echo -e "${GREEN}✅ 离线安装命令已执行！${NC}"
                        if command -v systemctl &>/dev/null; then
                            systemctl enable --now "$_detect_again" 2>/dev/null || true
                        fi
                    else
                        echo -e "${YELLOW}📋 离线环境手动部署指南:${NC}"
                        echo -e "  1. 在【有互联网连接】的同系统机器上执行工具箱："
                        echo -e "     进入 [系统环境优化 → 9. 采集离线安装包]"
                        echo -e "  2. 采集完成后，将 ${CYAN}packages/${NC} 目录拷贝到无网机器"
                        echo -e "  3. 再次进入本菜单选项 7 即可一键自动离线部署，或手动执行:"
                        echo -e "     ${CYAN}dpkg -i packages/deb/openssh-server*.deb${NC} (Debian/Ubuntu)"
                        echo -e "     ${CYAN}rpm -Uvh packages/rpm/openssh-server*.rpm${NC} (CentOS/RHEL)"
                    fi
                fi
                echo ""
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            0) break ;;
            *)
                echo -e "${RED}无效输入。${NC}"
                sleep 1
                ;;
        esac
    done
}

# 2.7 SSH 管理总入口 (二级菜单)
ssh_menu() {
    while true; do
        clear
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}       SSH 远程连接管理 (二级菜单)            ${NC}"
        echo -e "${GREEN}==============================================${NC}"
        echo " 1. 修改用户密码 (可指定任意账号)"
        echo " 2. 开启 Root SSH 远程登录"
        echo " 3. 生成 SSH 公私钥对 (保存至 /data/ssh_key)"
        echo " 4. SSH 证书管理 (authorized_keys)"
        echo " 5. SSH 配置巡检 (端口/认证/公钥/服务状态)"
        echo " 6. SSH 服务管理中心 (状态/启动/重启/自启/安装)"
        echo " 0. 返回主菜单"
        echo -e "${GREEN}==============================================${NC}"
        read -p "请选择操作 [0-6]: " ssh_main_choice

        case $ssh_main_choice in
            1) change_user_password ;;
            2) enable_root_ssh ;;
            3) generate_ssh_keypair ;;
            4) manage_ssh_certs ;;
            5) check_ssh_config ;;
            6) manage_ssh_service ;;
            0) break ;;
            *) echo -e "${RED}无效输入。${NC}"; sleep 1 ;;
        esac
    done
}


