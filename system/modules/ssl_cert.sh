#!/bin/bash

# =================================================================
# 模块名称: ssl_cert.sh
# 描述: SSL/TLS 自签证书交互式管理中心
#       - 极速一键生成自签 SSL 证书 (包含现代浏览器强制要求的 SAN 扩展)
#       - 专家级自定义 SAN 证书 (支持 RSA/ECC、多域名、多 IP、有效期)
#       - 通配符 / 泛域名自签证书 (*.domain.com)
#       - 自建私有根 CA (Certificate Authority) 与证书签发体系
#       - 一键导入私有 CA 到操作系统受信任根证书库 (Debian/RHEL/Alpine)
#       - 证书格式转换 (PEM <-> PFX/PKCS#12 <-> DER)
#       - 证书深度巡检、到期倒计时与 CRT/KEY 密钥对匹配性校验
# 适配: Ubuntu / Debian / CentOS / RHEL / Fedora / Alpine Linux
# 制作人: kikock
# =================================================================

# 证书默认存储根目录
CERT_BASE_DIR="/etc/ssl/ops_certs"
ACME_CERT_DIR="/root/kikock"

# 引入 ACME 模块
_SSL_MODULE_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
if [ -f "$_SSL_MODULE_DIR/acme.sh" ]; then
    source "$_SSL_MODULE_DIR/acme.sh"
fi

# ----------------------------------------------------------------
# 内部辅助: 确保 OpenSSL 工具可用
# ----------------------------------------------------------------
_check_openssl() {
    if ! command -v openssl &>/dev/null; then
        echo -e "${YELLOW}检测到系统未安装 OpenSSL 工具包，正在尝试自动安装...${NC}"
        if [ -n "$PKG_INSTALL" ]; then
            $PKG_INSTALL openssl
        else
            if command -v apt &>/dev/null; then
                apt update -y && apt install -y openssl
            elif command -v yum &>/dev/null; then
                yum install -y openssl
            elif command -v dnf &>/dev/null; then
                dnf install -y openssl
            elif command -v apk &>/dev/null; then
                apk add openssl
            fi
        fi

        if ! command -v openssl &>/dev/null; then
            echo -e "${RED}错误: OpenSSL 安装失败，请手动安装后重试！${NC}"
            read -p "按回车键返回..." < /dev/tty
            return 1
        fi
        echo -e "${GREEN}OpenSSL 安装成功！${NC}"
    fi
    return 0
}

# ----------------------------------------------------------------
# 内部辅助: 确保证书存储目录存在并设置安全权限
# ----------------------------------------------------------------
_ensure_cert_dir() {
    local target_dir="${1:-$CERT_BASE_DIR}"
    if [ ! -d "$target_dir" ]; then
        mkdir -p "$target_dir"
        chmod 750 "$target_dir"
    fi
}

# ----------------------------------------------------------------
# 内部辅助: 构造 OpenSSL SAN 临时配置文件
# ----------------------------------------------------------------
_build_san_config() {
    local tmp_conf="$1"
    local common_name="$2"
    local dns_list="$3"   # 逗号或空格分隔
    local ip_list="$4"    # 逗号或空格分隔
    local org="${5:-Linux-Ops-Box}"
    local country="${6:-CN}"
    local state="${7:-Beijing}"
    local city="${8:-Beijing}"
    local ou="${9:-DevOps}"

    cat > "$tmp_conf" <<EOF
[req]
default_bits        = 2048
distinguished_name  = req_distinguished_name
req_extensions      = v3_req
x509_extensions     = v3_req
prompt              = no

[req_distinguished_name]
C  = ${country}
ST = ${state}
L  = ${city}
O  = ${org}
OU = ${ou}
CN = ${common_name}

[v3_req]
basicConstraints     = CA:FALSE
keyUsage             = nonRepudiation, digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage     = serverAuth, clientAuth
subjectAltName       = @alt_names

[alt_names]
EOF

    local dns_idx=1
    local ip_idx=1

    # 解析 DNS 列表
    for item in $(echo "$dns_list" | tr ',' ' '); do
        item=$(echo "$item" | xargs)
        if [ -n "$item" ]; then
            echo "DNS.${dns_idx} = ${item}" >> "$tmp_conf"
            dns_idx=$((dns_idx + 1))
        fi
    done

    # 解析 IP 列表
    for item in $(echo "$ip_list" | tr ',' ' '); do
        item=$(echo "$item" | xargs)
        if [ -n "$item" ]; then
            echo "IP.${ip_idx} = ${item}" >> "$tmp_conf"
            ip_idx=$((ip_idx + 1))
        fi
    done

    # 如果两者均为空，至少将 common_name 赋予对应的 DNS 或 IP
    if [ "$dns_idx" -eq 1 ] && [ "$ip_idx" -eq 1 ]; then
        if [[ "$common_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "IP.1 = ${common_name}" >> "$tmp_conf"
        else
            echo "DNS.1 = ${common_name}" >> "$tmp_conf"
        fi
    fi
}

# ----------------------------------------------------------------
# 内部辅助: 打印证书生成结果与应用配置指引
# ----------------------------------------------------------------
_display_cert_success() {
    local cert_dir="$1"
    local cert_file="$2"
    local key_file="$3"
    local bundle_file="$4"
    local cn_domain="$5"

    echo ""
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}          🎉 SSL/TLS 自签证书生成成功！               ${NC}"
    echo -e "${GREEN}======================================================${NC}"
    echo -e " 📁 存储目录:   ${CYAN}${cert_dir}${NC}"
    echo -e " 📜 证书文件:   ${GREEN}${cert_file}${NC}"
    echo -e " 🔑 私钥文件:   ${YELLOW}${key_file}${NC} (权限: 600)"
    if [ -n "$bundle_file" ] && [ -f "$bundle_file" ]; then
        echo -e " 🔗 完整证书链: ${GREEN}${bundle_file}${NC}"
    fi
    echo -e "${CYAN}------------------------------------------------------${NC}"
    echo -e "${YELLOW}▌ 证书关键信息校验:${NC}"
    openssl x509 -in "$cert_file" -noout -subject -dates -issuer 2>/dev/null | sed 's/^/   /'
    echo -n "   SAN 扩展: "
    openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null | grep -v "X509v3" | xargs || echo "无"
    echo -e "${CYAN}------------------------------------------------------${NC}"
    echo -e "${BLUE}▌ Nginx 配置参考样例:${NC}"
    echo -e "   server {"
    echo -e "       listen 443 ssl http2;"
    echo -e "       server_name ${cn_domain};"
    echo -e "       ssl_certificate     ${cert_file};"
    echo -e "       ssl_certificate_key ${key_file};"
    echo -e "       ssl_protocols TLSv1.2 TLSv1.3;"
    echo -e "       ssl_ciphers HIGH:!aNULL:!MD5;"
    echo -e "   }"
    echo -e "${BLUE}▌ Caddyfile 配置参考样例:${NC}"
    echo -e "   ${cn_domain}:443 {"
    echo -e "       tls ${cert_file} ${key_file}"
    echo -e "       respond \"Hello Secure World!\""
    echo -e "   }"
    echo -e "${CYAN}------------------------------------------------------${NC}"
    echo -e "${YELLOW}▌ cURL 测试命令 (跳过自签证书告警):${NC}"
    echo -e "   curl -k -v https://${cn_domain}/"
    echo -e "${GREEN}======================================================${NC}"
}

# ================================================================
# 功能 1: 极速一键自签证书 (Quick SAN Certificate)
# ================================================================
_cert_quick_gen() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}       ⚡ 极速一键生成自签 SSL 证书 (带 SAN)         ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    _check_openssl || return

    local default_ip="${IP_ADDR:-127.0.0.1}"
    echo -e "当前探测到本机 IP: ${GREEN}${default_ip}${NC}"
    echo ""
    echo -e "${YELLOW}请输入证书主域名或 IP (例如 192.168.1.100 或 dev.local，直接回车使用当前 IP):${NC}"
    read -p "> " input_domain < /dev/tty
    input_domain=${input_domain:-$default_ip}

    # 标识名称，用于目录与文件名
    local safe_name
    safe_name=$(echo "$input_domain" | sed 's/[^a-zA-Z0-9._-]/_/g')
    local target_dir="${CERT_BASE_DIR}/${safe_name}"
    _ensure_cert_dir "$target_dir"

    local key_file="${target_dir}/${safe_name}.key"
    local crt_file="${target_dir}/${safe_name}.crt"
    local pem_file="${target_dir}/${safe_name}.pem"

    if [ -f "$crt_file" ]; then
        echo -e "${YELLOW}警告: 证书 ${crt_file} 已存在！${NC}"
        read -p "是否覆盖重新生成? [y/N]: " ow_choice < /dev/tty
        if [[ ! "$ow_choice" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}已取消生成。${NC}"
            read -p "按回车键继续..." < /dev/tty
            return
        fi
    fi

    # 智能构建 DNS 和 IP 列表 (默认将输入项与 127.0.0.1 / localhost 合并)
    local dns_list="localhost"
    local ip_list="127.0.0.1"

    if [[ "$input_domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip_list="${ip_list}, ${input_domain}"
    else
        dns_list="${dns_list}, ${input_domain}"
        [ "$default_ip" != "127.0.0.1" ] && ip_list="${ip_list}, ${default_ip}"
    fi

    local tmp_cnf="/tmp/openssl_quick_$$.cnf"
    _build_san_config "$tmp_cnf" "$input_domain" "$dns_list" "$ip_list" "Linux-Ops-Quick"

    echo -e "\n⏳ 正在生成 RSA 2048 位密钥与自签证书 (有效期 10 年 / 3650 天)..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$key_file" \
        -out "$crt_file" \
        -config "$tmp_cnf" 2>/dev/null

    local gen_status=$?
    rm -f "$tmp_cnf"

    if [ $gen_status -eq 0 ] && [ -f "$crt_file" ] && [ -f "$key_file" ]; then
        chmod 600 "$key_file"
        chmod 644 "$crt_file"
        # 整合为 PEM 格式 (适用于 HAProxy 等反代服务)
        cat "$crt_file" "$key_file" > "$pem_file"
        chmod 600 "$pem_file"

        _display_cert_success "$target_dir" "$crt_file" "$key_file" "$pem_file" "$input_domain"
    else
        echo -e "${RED}❌ 证书生成失败，请检查 OpenSSL 参数或磁盘权限。${NC}"
    fi

    read -p "按回车键返回..." < /dev/tty
}

# ================================================================
# 功能 2: 专家级自定义 SAN 证书 (Advanced SAN Certificate)
# ================================================================
_cert_custom_san_gen() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}       🛠  专家级自定义 SAN SSL 证书生成器           ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    _check_openssl || return

    # 1. 证书通用名称 (CN)
    echo -e "${YELLOW}[1/7] 请输入证书通用名称 Common Name (CN):${NC}"
    echo -e "  (如: test.example.com 或 10.0.0.8)"
    read -p "> " cn_input < /dev/tty
    if [ -z "$cn_input" ]; then
        echo -e "${RED}错误: Common Name 不能为空！${NC}"
        read -p "按回车键重试..." < /dev/tty
        return
    fi

    # 2. 附加 SAN 域名列表
    echo -e "\n${YELLOW}[2/7] 请输入附加 DNS 域名 (多个用逗号或空格隔开，回车跳过):${NC}"
    echo -e "  (如: dev.local, *.dev.local, api.internal)"
    read -p "> " dns_input < /dev/tty

    # 3. 附加 SAN IP 列表
    echo -e "\n${YELLOW}[3/7] 请输入附加 IP 地址 (多个用逗号或空格隔开，回车跳过):${NC}"
    echo -e "  (如: 192.168.1.50, 10.10.1.1, 127.0.0.1)"
    read -p "> " ip_input < /dev/tty

    # 4. 加密算法与密钥强度
    echo -e "\n${YELLOW}[4/7] 请选择公私钥算法与强度:${NC}"
    echo "  1. RSA 2048 位 (标准推荐，通用兼容)"
    echo "  2. RSA 4096 位 (超高安全性)"
    echo "  3. ECC prime256v1 (ECDSA P-256，性能高/体积小/现代首选)"
    echo "  4. ECC secp384r1 (ECDSA P-384)"
    read -p "请选择 [1-4，默认 1]: " algo_choice < /dev/tty
    algo_choice=${algo_choice:-1}

    # 5. 有效期限 (天)
    echo -e "\n${YELLOW}[5/7] 请输入证书有效天数 (默认 3650 天 / 10 年):${NC}"
    read -p "> " days_input < /dev/tty
    days_input=${days_input:-3650}

    # 6. 证书 Subject 信息 (可选扩展)
    echo -e "\n${YELLOW}[6/7] 是否自定义证书签发组织信息 (O/OU/C/ST/L)? [y/N]:${NC}"
    read -p "> " subj_custom < /dev/tty
    local org="Linux-Ops-Box"
    local ou="DevOps-Team"
    local country="CN"
    local state="Beijing"
    local city="Beijing"

    if [[ "$subj_custom" =~ ^[Yy]$ ]]; then
        read -p "国家代码 C (默认 CN): " input_c < /dev/tty
        country=${input_c:-$country}
        read -p "省份/州 ST (默认 Beijing): " input_st < /dev/tty
        state=${input_st:-$state}
        read -p "城市/地区 L (默认 Beijing): " input_l < /dev/tty
        city=${input_l:-$city}
        read -p "组织/公司名称 O (默认 Linux-Ops-Box): " input_o < /dev/tty
        org=${input_o:-$org}
        read -p "部门/单位 OU (默认 DevOps-Team): " input_ou < /dev/tty
        ou=${input_ou:-$ou}
    fi

    # 7. 存储路径
    local safe_name
    safe_name=$(echo "$cn_input" | sed 's/[^a-zA-Z0-9._-]/_/g')
    local target_dir="${CERT_BASE_DIR}/${safe_name}"
    echo -e "\n${YELLOW}[7/7] 证书保存目录 (默认: ${target_dir}):${NC}"
    read -p "> " custom_dir < /dev/tty
    [ -n "$custom_dir" ] && target_dir="$custom_dir"

    _ensure_cert_dir "$target_dir"
    local key_file="${target_dir}/${safe_name}.key"
    local crt_file="${target_dir}/${safe_name}.crt"
    local pem_file="${target_dir}/${safe_name}.pem"

    local tmp_cnf="/tmp/openssl_adv_$$.cnf"
    _build_san_config "$tmp_cnf" "$cn_input" "$dns_input" "$ip_input" "$org" "$country" "$state" "$city" "$ou"

    echo -e "\n⏳ 正在生成密钥与证书..."

    case $algo_choice in
        1)
            openssl req -x509 -nodes -days "$days_input" -newkey rsa:2048 \
                -keyout "$key_file" -out "$crt_file" -config "$tmp_cnf" 2>/dev/null
            ;;
        2)
            openssl req -x509 -nodes -days "$days_input" -newkey rsa:4096 \
                -keyout "$key_file" -out "$crt_file" -config "$tmp_cnf" 2>/dev/null
            ;;
        3)
            openssl req -x509 -nodes -days "$days_input" -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
                -keyout "$key_file" -out "$crt_file" -config "$tmp_cnf" 2>/dev/null
            ;;
        4)
            openssl req -x509 -nodes -days "$days_input" -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 \
                -keyout "$key_file" -out "$crt_file" -config "$tmp_cnf" 2>/dev/null
            ;;
        *)
            openssl req -x509 -nodes -days "$days_input" -newkey rsa:2048 \
                -keyout "$key_file" -out "$crt_file" -config "$tmp_cnf" 2>/dev/null
            ;;
    esac

    local gen_status=$?
    rm -f "$tmp_cnf"

    if [ $gen_status -eq 0 ] && [ -f "$crt_file" ] && [ -f "$key_file" ]; then
        chmod 600 "$key_file"
        chmod 644 "$crt_file"
        cat "$crt_file" "$key_file" > "$pem_file"
        chmod 600 "$pem_file"

        _display_cert_success "$target_dir" "$crt_file" "$key_file" "$pem_file" "$cn_input"
    else
        echo -e "${RED}❌ 证书生成失败！请检查输入参数是否合法。${NC}"
    fi

    read -p "按回车键返回..." < /dev/tty
}

# ================================================================
# 功能 3: 泛域名 / 通配符证书生成 (*.domain.com)
# ================================================================
_cert_wildcard_gen() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}       🌐 泛域名 / 通配符 SSL 证书生成器              ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    _check_openssl || return

    echo -e "说明: 泛域名证书可同时保护主域名及所有二级子域名 (例如: *.internal.com + internal.com)"
    echo ""
    echo -e "${YELLOW}请输入主域名 (如: internal.com 或 dev.lan):${NC}"
    read -p "> " base_domain < /dev/tty

    if [ -z "$base_domain" ]; then
        echo -e "${RED}错误: 域名不能为空！${NC}"
        read -p "按回车键继续..." < /dev/tty
        return
    fi

    # 规范化：去除可能误输入的前缀 *.
    base_domain=$(echo "$base_domain" | sed 's/^\*\.//')
    local wildcard="*.${base_domain}"

    local safe_name="wildcard_${base_domain}"
    local target_dir="${CERT_BASE_DIR}/${safe_name}"
    _ensure_cert_dir "$target_dir"

    local key_file="${target_dir}/${safe_name}.key"
    local crt_file="${target_dir}/${safe_name}.crt"
    local pem_file="${target_dir}/${safe_name}.pem"

    local tmp_cnf="/tmp/openssl_wildcard_$$.cnf"
    _build_san_config "$tmp_cnf" "$wildcard" "${wildcard}, ${base_domain}, localhost" "127.0.0.1" "Linux-Ops-Wildcard"

    echo -e "\n⏳ 正在生成通配符证书 [${wildcard}] 与 [${base_domain}]..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$key_file" \
        -out "$crt_file" \
        -config "$tmp_cnf" 2>/dev/null

    local gen_status=$?
    rm -f "$tmp_cnf"

    if [ $gen_status -eq 0 ] && [ -f "$crt_file" ]; then
        chmod 600 "$key_file"
        chmod 644 "$crt_file"
        cat "$crt_file" "$key_file" > "$pem_file"
        chmod 600 "$pem_file"

        _display_cert_success "$target_dir" "$crt_file" "$key_file" "$pem_file" "$wildcard"
    else
        echo -e "${RED}❌ 通配符证书生成失败！${NC}"
    fi

    read -p "按回车键返回..." < /dev/tty
}

# ================================================================
# 功能 4: 自建私有根 CA 体系与签发服务证书
# ================================================================
_cert_ca_create_root() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}           🏛  创建私有自签根证书授权中心 (CA)         ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    _check_openssl || return

    local ca_dir="${CERT_BASE_DIR}/my_root_ca"
    _ensure_cert_dir "$ca_dir"

    local ca_key="${ca_dir}/ca.key"
    local ca_crt="${ca_dir}/ca.crt"

    if [ -f "$ca_crt" ]; then
        echo -e "${YELLOW}提示: 已检测到现有私有根 CA: ${ca_crt}${NC}"
        openssl x509 -in "$ca_crt" -noout -subject -dates -issuer 2>/dev/null | sed 's/^/  /'
        echo ""
        read -p "是否覆盖并创建全新的根 CA? (覆盖后以往签发的证书将失效!) [y/N]: " ow_ca < /dev/tty
        if [[ ! "$ow_ca" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}已取消创建。${NC}"
            read -p "按回车键继续..." < /dev/tty
            return
        fi
    fi

    echo -e "\n${YELLOW}请输入根 CA 机构名称 Common Name (默认: OpsBox Root CA):${NC}"
    read -p "> " ca_cn < /dev/tty
    ca_cn=${ca_cn:-"OpsBox Root CA"}

    echo -e "${YELLOW}请输入根 CA 有效天数 (默认: 7300 天 / 20 年):${NC}"
    read -p "> " ca_days < /dev/tty
    ca_days=${ca_days:-7300}

    echo -e "\n⏳ 正在生成 4096 位高强度根 CA 密钥及自签根证书..."
    openssl req -x509 -new -nodes -sha256 -newkey rsa:4096 \
        -days "$ca_days" \
        -keyout "$ca_key" \
        -out "$ca_crt" \
        -subj "/C=CN/ST=Beijing/L=Beijing/O=OpsBox-Security/OU=Certificate-Authority/CN=${ca_cn}" 2>/dev/null

    if [ $? -eq 0 ] && [ -f "$ca_crt" ]; then
        chmod 600 "$ca_key"
        chmod 644 "$ca_crt"
        echo -e "\n${GREEN}🎉 私有根 CA 创建成功！${NC}"
        echo -e " 📜 根 CA 证书: ${GREEN}${ca_crt}${NC}"
        echo -e " 🔑 根 CA 私钥: ${YELLOW}${ca_key}${NC} (请妥善保管)"
        echo -e "\n${YELLOW}💡 提示: 将 ${ca_crt} 导入客户端/浏览器受信任根证书库后，所有由其签发的服务证书均可享受安全绿锁。${NC}"
    else
        echo -e "${RED}❌ 根 CA 创建失败！${NC}"
    fi

    read -p "按回车键继续..." < /dev/tty
}

_cert_ca_sign_server() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}       ✍️  使用私有根 CA 签发服务器证书               ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    _check_openssl || return

    local ca_dir="${CERT_BASE_DIR}/my_root_ca"
    local ca_key="${ca_dir}/ca.key"
    local ca_crt="${ca_dir}/ca.crt"

    if [ ! -f "$ca_crt" ] || [ ! -f "$ca_key" ]; then
        echo -e "${RED}错误: 未检测到私有根 CA！请先执行 [1. 创建私有自签根 CA] 后再签发证书。${NC}"
        read -p "按回车键返回..." < /dev/tty
        return
    fi

    echo -e "当前使用的根 CA: ${GREEN}${ca_crt}${NC}"
    openssl x509 -in "$ca_crt" -noout -subject 2>/dev/null | sed 's/^/  /'
    echo ""

    echo -e "${YELLOW}请输入要签发的服务器域名或 IP (例如: api.corp.internal 或 192.168.1.200):${NC}"
    read -p "> " srv_domain < /dev/tty
    if [ -z "$srv_domain" ]; then
        echo -e "${RED}错误: 域名/IP 不能为空！${NC}"
        read -p "按回车键继续..." < /dev/tty
        return
    fi

    echo -e "${YELLOW}请输入附加 SAN DNS/IP (多个用逗号隔开，直接回车自动添加 localhost/127.0.0.1):${NC}"
    read -p "> " extra_san < /dev/tty

    local dns_list="localhost, ${srv_domain}"
    local ip_list="127.0.0.1"

    if [[ "$srv_domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip_list="${ip_list}, ${srv_domain}"
    fi

    for san_item in $(echo "$extra_san" | tr ',' ' '); do
        if [[ "$san_item" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ip_list="${ip_list}, ${san_item}"
        else
            dns_list="${dns_list}, ${san_item}"
        fi
    done

    local safe_name
    safe_name=$(echo "$srv_domain" | sed 's/[^a-zA-Z0-9._-]/_/g')
    local srv_dir="${CERT_BASE_DIR}/${safe_name}_ca_signed"
    _ensure_cert_dir "$srv_dir"

    local srv_key="${srv_dir}/${safe_name}.key"
    local srv_csr="${srv_dir}/${safe_name}.csr"
    local srv_crt="${srv_dir}/${safe_name}.crt"
    local srv_bundle="${srv_dir}/${safe_name}_bundle.crt"

    local tmp_cnf="/tmp/openssl_sign_$$.cnf"
    _build_san_config "$tmp_cnf" "$srv_domain" "$dns_list" "$ip_list" "OpsBox-Issued"

    echo -e "\n⏳ 1. 正在生成服务器 2048 位私钥与证书请求 (CSR)..."
    openssl req -new -nodes -newkey rsa:2048 \
        -keyout "$srv_key" \
        -out "$srv_csr" \
        -config "$tmp_cnf" 2>/dev/null

    echo -e "⏳ 2. 正在由私有根 CA 签名并注入 SAN 扩展 (有效期 3650 天)..."
    openssl x509 -req -days 3650 -sha256 \
        -in "$srv_csr" \
        -CA "$ca_crt" \
        -CAkey "$ca_key" \
        -CAcreateserial \
        -out "$srv_crt" \
        -extfile "$tmp_cnf" \
        -extensions v3_req 2>/dev/null

    local sign_status=$?
    rm -f "$tmp_cnf" "$srv_csr"

    if [ $sign_status -eq 0 ] && [ -f "$srv_crt" ]; then
        chmod 600 "$srv_key"
        chmod 644 "$srv_crt"
        # 拼接完整证书链 (服务证书 + 根CA证书)
        cat "$srv_crt" "$ca_crt" > "$srv_bundle"
        chmod 644 "$srv_bundle"

        _display_cert_success "$srv_dir" "$srv_crt" "$srv_key" "$srv_bundle" "$srv_domain"
    else
        echo -e "${RED}❌ 证书签发失败！${NC}"
    fi

    read -p "按回车键返回..." < /dev/tty
}

_cert_ca_trust_local() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}       🛡  一键导入私有根 CA 到本机操作系统信任库     ${NC}"
    echo -e "${CYAN}======================================================${NC}"

    local ca_crt="${CERT_BASE_DIR}/my_root_ca/ca.crt"
    if [ ! -f "$ca_crt" ]; then
        echo -e "${RED}错误: 未在 ${ca_crt} 找到根证书！请先创建根 CA。${NC}"
        read -p "按回车键返回..." < /dev/tty
        return
    fi

    echo -e "准备导入的根 CA 文件: ${GREEN}${ca_crt}${NC}"
    echo -e "当前系统发行版类别: ${CYAN}${DISTRO_FAMILY:-通用}${NC} (${DISTRO_ID:-未知})"
    echo ""

    if [ -d "/usr/local/share/ca-certificates" ] && command -v update-ca-certificates &>/dev/null; then
        # Debian / Ubuntu / Alpine
        cp -f "$ca_crt" "/usr/local/share/ca-certificates/opsbox_root_ca.crt"
        echo -e "⏳ 正在执行 update-ca-certificates 更新系统证书信任锚点..."
        update-ca-certificates
        echo -e "\n${GREEN}✅ 成功！已将根 CA 注入 Debian/Ubuntu 系统受信任证书库！${NC}"
    elif [ -d "/etc/pki/ca-trust/source/anchors" ] && command -v update-ca-trust &>/dev/null; then
        # RHEL / CentOS / AlmaLinux / Rocky / Fedora
        cp -f "$ca_crt" "/etc/pki/ca-trust/source/anchors/opsbox_root_ca.crt"
        echo -e "⏳ 正在执行 update-ca-trust extract 提取并更新信任链..."
        update-ca-trust extract
        echo -e "\n${GREEN}✅ 成功！已将根 CA 注入 RHEL/CentOS 信任链 (update-ca-trust)！${NC}"
    else
        echo -e "${YELLOW}未检测到标准 ca-certificates 信任工具，正在尝试通用方案...${NC}"
        if [ -f "/etc/ssl/certs/ca-certificates.crt" ]; then
            cat "$ca_crt" >> /etc/ssl/certs/ca-certificates.crt
            echo -e "${GREEN}✅ 已追加至 /etc/ssl/certs/ca-certificates.crt${NC}"
        else
            echo -e "${RED}无法自动适配当前系统的证书信任安装机制，请手动复制 ${ca_crt} 至系统证书目录。${NC}"
        fi
    fi

    echo -e "\n${YELLOW}测试效果验证: 本机执行 curl https://<已签发域名>/ 将不会再出现 self-signed certificate 告警！${NC}"
    read -p "按回车键继续..." < /dev/tty
}

_cert_ca_mgmt_menu() {
    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}          🏛  私有根 CA 与多级证书签发中心            ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        local ca_file="${CERT_BASE_DIR}/my_root_ca/ca.crt"
        if [ -f "$ca_file" ]; then
            local ca_subj ca_exp
            ca_subj=$(openssl x509 -in "$ca_file" -noout -subject 2>/dev/null | sed 's/subject=//')
            ca_exp=$(openssl x509 -in "$ca_file" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
            echo -e " ${GREEN}●${NC} 现有根 CA: ${GREEN}已就绪${NC}"
            echo -e "   Subject: ${CYAN}${ca_subj}${NC}"
            echo -e "   有效期至: ${YELLOW}${ca_exp}${NC}"
        else
            echo -e " ${YELLOW}●${NC} 现有根 CA: ${RED}未创建${NC}"
        fi
        echo -e "${CYAN}------------------------------------------------------${NC}"
        echo " 1. 🏗  创建全新的私有自签根 CA (Private Root CA)"
        echo " 2. ✍️  使用根 CA 签发服务器 SSL 证书 (带 SAN/生成完整链)"
        echo " 3. 🛡  一键将根 CA 导入本机操作系统信任库 (实现绿锁无告警)"
        echo " 4. 🔍  查看根 CA 证书详情"
        echo " 0. ↩  返回上一级菜单"
        echo -e "${CYAN}======================================================${NC}"
        read -p "请输入选项 [0-4]: " ca_choice < /dev/tty

        case $ca_choice in
            1) _cert_ca_create_root ;;
            2) _cert_ca_sign_server ;;
            3) _cert_ca_trust_local ;;
            4)
                if [ -f "$ca_file" ]; then
                    clear
                    echo -e "${CYAN}================ 根 CA 证书详情 ================${NC}"
                    openssl x509 -in "$ca_file" -text -noout
                    echo -e "${CYAN}================================================${NC}"
                    read -p "按回车键返回..." < /dev/tty
                else
                    echo -e "${RED}根 CA 证书不存在。${NC}"
                    sleep 1.5
                fi
                ;;
            0) return ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

# ================================================================
# 功能 5: 证书格式转换与打包 (PKCS#12 / PFX / DER)
# ================================================================
_cert_convert_menu() {
    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}          🔄  SSL 证书格式转换与打包中心              ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo " 1. 📦  PEM (.crt + .key) 导出为 PKCS#12 (.pfx / .p12) [Windows/Java/IIS]"
        echo " 2. 📤  PKCS#12 (.pfx / .p12) 提取为 PEM 证书与私钥"
        echo " 3. 🔄  PEM 格式与 DER 二进制格式互转"
        echo " 4. 🧩  合并 CRT 证书与 KEY 私钥为单一 PEM 整合文件 (HAProxy 专用)"
        echo " 0. ↩  返回上一级菜单"
        echo -e "${CYAN}======================================================${NC}"
        read -p "请输入选项 [0-4]: " conv_choice < /dev/tty

        case $conv_choice in
            1)
                clear
                echo -e "${CYAN}--- PEM 转 PKCS#12 (.pfx) ---${NC}"
                read -p "请输入 CRT 证书文件路径: " in_crt < /dev/tty
                read -p "请输入 KEY 私钥文件路径: " in_key < /dev/tty
                if [ ! -f "$in_crt" ] || [ ! -f "$in_key" ]; then
                    echo -e "${RED}错误: 指定的文件不存在！${NC}"
                    sleep 2; continue
                fi
                read -p "请输入输出的 PFX 文件路径 (如 /tmp/server.pfx): " out_pfx < /dev/tty
                [ -z "$out_pfx" ] && out_pfx="/tmp/server_exported.pfx"
                echo -e "${YELLOW}请设置 PFX 保护密码 (直接回车表示不设密码):${NC}"
                openssl pkcs12 -export -out "$out_pfx" -inkey "$in_key" -in "$in_crt"
                if [ $? -eq 0 ] && [ -f "$out_pfx" ]; then
                    echo -e "\n${GREEN}✅ 导出成功: ${out_pfx}${NC}"
                else
                    echo -e "\n${RED}❌ 导出失败！${NC}"
                fi
                read -p "按回车键继续..." < /dev/tty
                ;;
            2)
                clear
                echo -e "${CYAN}--- PKCS#12 (.pfx) 提取 PEM ---${NC}"
                read -p "请输入 PFX / P12 文件路径: " in_pfx < /dev/tty
                if [ ! -f "$in_pfx" ]; then
                    echo -e "${RED}错误: 文件不存在！${NC}"
                    sleep 2; continue
                fi
                read -p "输出目录 (默认 /tmp): " out_dir < /dev/tty
                out_dir=${out_dir:-/tmp}
                mkdir -p "$out_dir"
                echo -e "⏳ 正在提取证书..."
                openssl pkcs12 -in "$in_pfx" -clcerts -nokeys -out "${out_dir}/extracted_cert.crt"
                echo -e "⏳ 正在提取私钥 (无密码模式)..."
                openssl pkcs12 -in "$in_pfx" -nocerts -nodes -out "${out_dir}/extracted_key.key"
                echo -e "\n${GREEN}✅ 提取完成！输出文件:${NC}"
                echo -e " 证书: ${out_dir}/extracted_cert.crt"
                echo -e " 私钥: ${out_dir}/extracted_key.key"
                read -p "按回车键继续..." < /dev/tty
                ;;
            3)
                clear
                echo -e "${CYAN}--- PEM <-> DER 互转 ---${NC}"
                echo "1. PEM 转 DER (X509)"
                echo "2. DER 转 PEM (X509)"
                read -p "请选择 [1-2]: " der_opt < /dev/tty
                if [ "$der_opt" = "1" ]; then
                    read -p "输入 PEM 证书文件路径: " pem_in < /dev/tty
                    read -p "输出 DER 证书路径 (如 /tmp/cert.der): " der_out < /dev/tty
                    openssl x509 -in "$pem_in" -outform DER -out "$der_out" 2>/dev/null && \
                        echo -e "${GREEN}✅ 转换成功: ${der_out}${NC}" || echo -e "${RED}❌ 转换失败${NC}"
                elif [ "$der_opt" = "2" ]; then
                    read -p "输入 DER 证书文件路径: " der_in < /dev/tty
                    read -p "输出 PEM 证书路径 (如 /tmp/cert.crt): " pem_out < /dev/tty
                    openssl x509 -inform DER -in "$der_in" -outform PEM -out "$pem_out" 2>/dev/null && \
                        echo -e "${GREEN}✅ 转换成功: ${pem_out}${NC}" || echo -e "${RED}❌ 转换失败${NC}"
                fi
                read -p "按回车键继续..." < /dev/tty
                ;;
            4)
                clear
                echo -e "${CYAN}--- 合并为 HAProxy 单一 PEM ---${NC}"
                read -p "请输入 CRT 证书路径: " merge_crt < /dev/tty
                read -p "请输入 KEY 私钥路径: " merge_key < /dev/tty
                read -p "请输入输出 PEM 路径 (如 /etc/ssl/ops_certs/combined.pem): " merge_out < /dev/tty
                if [ -f "$merge_crt" ] && [ -f "$merge_key" ]; then
                    cat "$merge_crt" "$merge_key" > "$merge_out"
                    chmod 600 "$merge_out"
                    echo -e "${GREEN}✅ 合并完成: ${merge_out}${NC}"
                else
                    echo -e "${RED}错误: 输入文件不完整！${NC}"
                fi
                read -p "按回车键继续..." < /dev/tty
                ;;
            0) return ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

# ================================================================
# 功能 6: 本地证书深度巡检与诊断 (Inspect & Validate)
# ================================================================
_cert_inspect_details() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}           🔍  SSL 证书内容深度巡检与解析             ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    _check_openssl || return

    echo -e "${YELLOW}请输入要查看的证书文件路径 (.crt / .pem / .cer):${NC}"
    read -p "> " inspect_crt < /dev/tty

    if [ ! -f "$inspect_crt" ]; then
        echo -e "${RED}错误: 文件 [${inspect_crt}] 不存在！${NC}"
        read -p "按回车键返回..." < /dev/tty
        return
    fi

    echo ""
    echo -e "${GREEN}================ 证书解析报表 ================${NC}"
    local subj issuer start_date end_date san sha256_fp algo

    subj=$(openssl x509 -in "$inspect_crt" -noout -subject 2>/dev/null | sed 's/subject=//')
    issuer=$(openssl x509 -in "$inspect_crt" -noout -issuer 2>/dev/null | sed 's/issuer=//')
    start_date=$(openssl x509 -in "$inspect_crt" -noout -startdate 2>/dev/null | sed 's/notBefore=//')
    end_date=$(openssl x509 -in "$inspect_crt" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    sha256_fp=$(openssl x509 -in "$inspect_crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/SHA256 Fingerprint=//')
    san=$(openssl x509 -in "$inspect_crt" -noout -ext subjectAltName 2>/dev/null | grep -v "X509v3" | xargs)

    echo -e " 📄 文件路径:     ${CYAN}${inspect_crt}${NC}"
    echo -e " 🏷  通用主体 (CN): ${GREEN}${subj}${NC}"
    echo -e " 🏛  颁发机构:     ${YELLOW}${issuer}${NC}"
    echo -e " 🌐 SAN 备用名称:  ${CYAN}${san:-无 SAN 扩展}${NC}"
    echo -e " 📅 生效时间:     ${start_date}"
    echo -e " ⏳ 到期时间:     ${YELLOW}${end_date}${NC}"
    echo -e " 🔐 SHA256 指纹:  ${BLUE}${sha256_fp}${NC}"

    # 检查是否过期
    if openssl x509 -checkend 0 -noout -in "$inspect_crt" &>/dev/null; then
        echo -e " ⚡ 证书健康状态: ${GREEN}✓ 证书在有效期内${NC}"
    else
        echo -e " ⚡ 证书健康状态: ${RED}✗ 证书已过期！${NC}"
    fi

    echo -e "${GREEN}==============================================${NC}"
    read -p "按回车键返回..." < /dev/tty
}

_cert_verify_pair() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}        🔑 证书 (CRT) 与私钥 (KEY) 配对校验          ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    _check_openssl || return

    echo -e "说明: 本功能通过计算证书公钥与私钥的 Hash 模数，100% 确定两者是否为同源密钥对。"
    echo ""
    read -p "请输入 CRT 证书路径: " test_crt < /dev/tty
    read -p "请输入 KEY 私钥路径: " test_key < /dev/tty

    if [ ! -f "$test_crt" ] || [ ! -f "$test_key" ]; then
        echo -e "${RED}错误: 输入的文件不存在！${NC}"
        read -p "按回车键继续..." < /dev/tty
        return
    fi

    local crt_md5 key_md5
    crt_md5=$(openssl x509 -noout -modulus -in "$test_crt" 2>/dev/null | openssl md5 | awk '{print $NF}')
    key_md5=$(openssl rsa -noout -modulus -in "$test_key" 2>/dev/null | openssl md5 | awk '{print $NF}')

    # 若为 ECC 证书
    if [ -z "$crt_md5" ]; then
        crt_md5=$(openssl x509 -noout -pubkey -in "$test_crt" 2>/dev/null | openssl md5 | awk '{print $NF}')
        key_md5=$(openssl pkey -pubout -in "$test_key" 2>/dev/null | openssl md5 | awk '{print $NF}')
    fi

    echo ""
    echo -e " 📜 证书 Hash: ${CYAN}${crt_md5:-无法提取}${NC}"
    echo -e " 🔑 私钥 Hash: ${CYAN}${key_md5:-无法提取}${NC}"
    echo ""

    if [ -n "$crt_md5" ] && [ "$crt_md5" = "$key_md5" ]; then
        echo -e "${GREEN}🎉 校验通过！该证书与私钥完全匹配，可以安全部署在 Nginx / Caddy 等服务中！${NC}"
    else
        echo -e "${RED}❌ 校验失败！证书与私钥不匹配，部署后服务将启动失败或报 SSL 错误！${NC}"
    fi

    read -p "按回车键返回..." < /dev/tty
}

_cert_list_installed() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}         📂  本机系统证书资产总览                     ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e " 自签证书目录: ${CYAN}${CERT_BASE_DIR}${NC}"
    echo -e " ACME 证书目录: ${CYAN}${ACME_CERT_DIR}${NC}\n"

    printf "${BLUE}%-30s | %-15s | %-20s | %-10s${NC}\n" "证书目录/路径" "类型" "到期日期" "状态"
    printf "${BLUE}%-30s | %-15s | %-20s | %-10s${NC}\n" "------------------------------" "---------------" "--------------------" "----------"

    # 1. 检查 /root/kikock/ ACME 商业证书
    if [ -d "$ACME_CERT_DIR" ] && [ -f "$ACME_CERT_DIR/cert.crt" ]; then
        local acme_file="$ACME_CERT_DIR/cert.crt"
        local exp_date status_str
        exp_date=$(openssl x509 -in "$acme_file" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        if openssl x509 -checkend 0 -noout -in "$acme_file" &>/dev/null; then
            status_str="${GREEN}有效${NC}"
        else
            status_str="${RED}已过期${NC}"
        fi
        printf "%-30s | %-15s | %-20s | %-10s\n" "$ACME_CERT_DIR" "ACME 商业证书" "${exp_date:0:20}" "$status_str"
    fi

    # 2. 检查自签证书库
    if [ -d "$CERT_BASE_DIR" ] && [ -n "$(ls -A "$CERT_BASE_DIR" 2>/dev/null)" ]; then
        find "$CERT_BASE_DIR" -type f \( -name "*.crt" -o -name "*.pem" \) | while read -r cfile; do
            [[ "$cfile" =~ bundle ]] && continue
            local cdir_name ctype exp_date is_valid status_str

            cdir_name=$(basename "$(dirname "$cfile")")
            ctype="自签服务证书"
            [[ "$cfile" =~ /my_root_ca/ ]] && ctype="私有根 CA"
            [[ "$cfile" =~ wildcard ]] && ctype="泛域名证书"
            [[ "$cfile" =~ _ca_signed ]] && ctype="CA 签发证书"

            exp_date=$(openssl x509 -in "$cfile" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
            if openssl x509 -checkend 0 -noout -in "$cfile" &>/dev/null; then
                status_str="${GREEN}有效${NC}"
            else
                status_str="${RED}已过期${NC}"
            fi

            printf "%-30s | %-15s | %-20s | %-10s\n" "${cdir_name:0:28}" "$ctype" "${exp_date:0:20}" "$status_str"
        done
    fi

    echo -e "\n${CYAN}======================================================${NC}"
    read -p "按回车键返回..." < /dev/tty
}

# ================================================================
# SSL/TLS 证书管理总入口 (二级菜单)
# ================================================================
ssl_cert_menu() {
    while true; do
        clear
        echo -e "${CYAN}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
        echo -e "${BLUE} ░██   ░██  ░██  ░██   ░██   ░██████   ░██████   ░██   ░██${NC}"
        echo -e "${BLUE} ░██  ░██   ░██  ░██  ░██   ░██    ░██░██    ░██ ░██  ░██ ${NC}"
        echo -e "${BLUE} ░█████     ░██  ░█████     ░██    ░██░██        ░█████   ${NC}"
        echo -e "${BLUE} ░██  ░██   ░██  ░██  ░██   ░██    ░██░██    ░██ ░██  ░██ ${NC}"
        echo -e "${BLUE} ░██   ░██  ░██  ░██   ░██   ░██████   ░██████   ░██   ░██${NC}"
        echo -e "${CYAN}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
        echo -e " ${GREEN}●${NC} 项目维护: ${GREEN}kikock (Linux-ops-box)${NC}"
        echo -e " ${YELLOW}● 特别鸣谢与致敬: 甬哥Github项目 (github.com/yonggekkk)${NC}"
        echo -e "   甬哥博客: ygkkk.blogspot.com | YouTube: www.youtube.com/@ygkkk"
        echo -e "${CYAN}=======================================================================${NC}"
        echo -e "${GREEN}【🌐  ACME 联网商业证书申请】${NC}"
        echo " 1. 🚀  acme.sh 申请证书 (IP模式 / 80端口单域名 / DNS API 泛域名)"
        echo " 2. 📋  查询已申请域名及自动续期时间点"
        echo " 3. 🔄  手动一键证书续期"
        echo " 4. 🗑   删除证书并卸载 acme.sh"
        echo -e "${GREEN}【🔒  本地离线自签证书体系】${NC}"
        echo " 5. ⚡  极速一键自签证书   (自动检测IP/绑定localhost/10年期)"
        echo " 6. 🛠   专家级自定义 SAN   (算法选择/多域名/多IP/自设有效期)"
        echo " 7. 🌐  通配符/泛域名证书  (*.domain.com + domain.com)"
        echo " 8. 🏛   私有根 CA 体系管理 (自建根CA/签发服务证书/一键信任)"
        echo -e "${GREEN}【🛠   证书格式转换与诊断工具】${NC}"
        echo " 9. 🔄  证书格式转换中心   (PEM <-> PFX/PKCS#12 <-> DER/合并)"
        echo " 10. 🔍 证书深度巡检与诊断 (查看域名SAN/到期时间/SHA256指纹)"
        echo " 11. 🔑 CRT 证书与 KEY 校验 (公钥/私钥 Hash 匹配性验证)"
        echo " 12. 📂 查看已生成证书资产 (/root/kikock 与 /etc/ssl/ops_certs)"
        echo " 0. ↩  返回主菜单"
        echo -e "${CYAN}=======================================================================${NC}"
        read -p "请输入操作选项 [0-12]: " cert_main_choice < /dev/tty

        case $cert_main_choice in
            1)
                if command -v acme &>/dev/null; then
                    acme
                elif [ -f "$_SSL_MODULE_DIR/acme.sh" ]; then
                    source "$_SSL_MODULE_DIR/acme.sh"
                    acme
                else
                    echo -e "${RED}错误: 找不到 acme.sh 模块${NC}"
                    sleep 1.5
                fi
                ;;
            2)
                if command -v Certificate &>/dev/null; then
                    Certificate
                elif [ -f "$_SSL_MODULE_DIR/acme.sh" ]; then
                    source "$_SSL_MODULE_DIR/acme.sh"
                    Certificate
                else
                    echo -e "${RED}错误: 找不到 acme.sh 模块${NC}"
                    sleep 1.5
                fi
                ;;
            3)
                if command -v acmerenew &>/dev/null; then
                    acmerenew
                elif [ -f "$_SSL_MODULE_DIR/acme.sh" ]; then
                    source "$_SSL_MODULE_DIR/acme.sh"
                    acmerenew
                else
                    echo -e "${RED}错误: 找不到 acme.sh 模块${NC}"
                    sleep 1.5
                fi
                ;;
            4)
                if command -v uninstall &>/dev/null; then
                    uninstall
                elif [ -f "$_SSL_MODULE_DIR/acme.sh" ]; then
                    source "$_SSL_MODULE_DIR/acme.sh"
                    uninstall
                else
                    echo -e "${RED}错误: 找不到 acme.sh 模块${NC}"
                    sleep 1.5
                fi
                ;;
            5) _cert_quick_gen ;;
            6) _cert_custom_san_gen ;;
            7) _cert_wildcard_gen ;;
            8) _cert_ca_mgmt_menu ;;
            9) _cert_convert_menu ;;
            10) _cert_inspect_details ;;
            11) _cert_verify_pair ;;
            12) _cert_list_installed ;;
            0) return ;;
            *) echo -e "${RED}输入无效，请重新选择。${NC}"; sleep 1 ;;
        esac
    done
}
