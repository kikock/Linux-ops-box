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
        echo -e "${RED}    ✗ 配置文件不存在，请确认 SSH 服务是否已安装${NC}"
        read -p "按回车键返回..."; return
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
        SS_RESULT=$(ss -tlnp | grep sshd)
        if [ -z "$SS_RESULT" ]; then
            echo -e "    ${RED}✗ 未检测到 sshd 进程正在监听（服务可能未启动）${NC}"
        else
            echo "$SS_RESULT" | while read -r line; do
                echo -e "    ${GREEN}→ ${line}${NC}"
            done
        fi
    elif command -v netstat &>/dev/null; then
        NETSTAT_RESULT=$(netstat -tlnp 2>/dev/null | grep sshd)
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
    PASSWD_AUTH=$(grep -E "^PasswordAuthentication " "$SSHD_CONFIG" | awk '{print $2}')
    PERMIT_EMPTY=$(grep -E "^PermitEmptyPasswords " "$SSHD_CONFIG" | awk '{print $2}')
    PERMIT_ROOT=$(grep -E "^PermitRootLogin " "$SSHD_CONFIG" | awk '{print $2}')
    PUBKEY_AUTH=$(grep -E "^PubkeyAuthentication " "$SSHD_CONFIG" | awk '{print $2}')
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
                key_count=$(wc -l < "$auth_keys")
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

    # [7] SSH 服务状态 (彻底修复逻辑)
    echo -e "${YELLOW}[7] SSH 服务运行状态${NC}"
    if command -v systemctl &>/dev/null; then
        local ACTUAL_SVC=""
        if [ "$(systemctl is-active ssh 2>/dev/null)" = "active" ]; then
            ACTUAL_SVC="ssh"
        elif [ "$(systemctl is-active sshd 2>/dev/null)" = "active" ]; then
            ACTUAL_SVC="sshd"
        else
            ACTUAL_SVC="${SVC_SSH:-sshd}"
        fi

        ACTUAL_STATUS=$(systemctl is-active "$ACTUAL_SVC" 2>/dev/null)
        
        if [ "$ACTUAL_STATUS" = "active" ]; then
            echo -e "    状态: ${GREEN}✓ 运行中 (active)${NC}"
            echo -e "    服务: ${CYAN}${ACTUAL_SVC}${NC}"
            systemctl status "$ACTUAL_SVC" --no-pager -l 2>/dev/null | grep -E "Active:|Main PID:" | while read -r line; do
                echo -e "    ${line}"
            done
        else
            echo -e "    状态: ${RED}✗ 未运行 (${ACTUAL_STATUS:-unknown})${NC}"
            echo -e "    提示: 脚本尝试检查的是 [${YELLOW}${ACTUAL_SVC}${NC}]，请确认该服务名是否正确。"
        fi
    fi

    # [8] 本机 IP
    echo -e "${YELLOW}[8] 本机网络 IP 地址${NC}"
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
    read -p "按回车键返回..."
}

# 2.6 SSH 管理总入口 (二级菜单)
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
        echo " 0. 返回主菜单"
        echo -e "${GREEN}==============================================${NC}"
        read -p "请选择操作 [0-5]: " ssh_main_choice

        case $ssh_main_choice in
            1) change_user_password ;;
            2) enable_root_ssh ;;
            3) generate_ssh_keypair ;;
            4) manage_ssh_certs ;;
            5) check_ssh_config ;;
            0) break ;;
            *) echo -e "${RED}无效输入。${NC}"; sleep 1 ;;
        esac
    done
}

