#!/bin/bash 
export LANG=en_US.UTF-8
red='\033[0;31m'
bblue='\033[0;34m'
plain='\033[0m'
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" $2;}
[[ $EUID -ne 0 ]] && yellow "请以root模式运行脚本" && exit

if [[ -f /etc/redhat-release ]]; then
release="Centos"
elif cat /etc/issue | grep -q -E -i "alpine"; then
release="alpine"
elif cat /etc/issue | grep -q -E -i "debian"; then
release="Debian"
elif cat /etc/issue | grep -q -E -i "ubuntu"; then
release="Ubuntu"
elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
release="Centos"
elif cat /proc/version | grep -q -E -i "debian"; then
release="Debian"
elif cat /proc/version | grep -q -E -i "ubuntu"; then
release="Ubuntu"
elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
release="Centos"
else 
red "不支持当前的系统，请选择使用Ubuntu,Debian,Centos系统" && exit 
fi
vsid=$(grep -i version_id /etc/os-release 2>/dev/null | cut -d \" -f2 | cut -d . -f1)
op=$(cat /etc/redhat-release 2>/dev/null || cat /etc/os-release 2>/dev/null | grep -i pretty_name | cut -d \" -f2)
if [[ $(echo "$op" | grep -i -E "arch") ]]; then
red "脚本不支持当前的 $op 系统，请选择使用Ubuntu,Debian,Centos系统。" && exit
fi

v4v6(){
v4=$(curl -s4m5 icanhazip.com -k)
v6=$(curl -s6m5 icanhazip.com -k)
}

# ----------------------------------------------------------------
# 依赖工具智能检测与离线自适应
# ----------------------------------------------------------------
_check_acme_deps(){
    local missing_pkgs=()
    local packages=("curl" "openssl" "tar" "wget")

    for pkg in "${packages[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    # 检查 cron
    if ! command -v crontab &>/dev/null; then
        if [ "$release" = "Centos" ]; then
            missing_pkgs+=("cronie")
        else
            missing_pkgs+=("cron")
        fi
    fi

    # 检查 lsof
    if ! command -v lsof &>/dev/null && ! command -v ss &>/dev/null; then
        missing_pkgs+=("lsof")
    fi

    # 如果所有核心依赖均已就绪，直接返回
    if [ ${#missing_pkgs[@]} -eq 0 ]; then
        return 0
    fi

    # 1. 尝试从本地 packages/ 目录离线安装 deb/rpm
    local pkg_dir=""
    for d in "$BASE_DIR/packages" "/opt/ck_sysinit/packages" "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../packages"; do
        if [ -d "$d" ]; then
            pkg_dir="$d"
            break
        fi
    done

    if [ -n "$pkg_dir" ]; then
        if command -v dpkg &>/dev/null && ls "$pkg_dir"/*.deb &>/dev/null; then
            yellow "正在从本地 packages 目录离线安装 deb 依赖包..."
            dpkg -i "$pkg_dir"/*.deb 2>/dev/null || true
            return 0
        elif command -v rpm &>/dev/null && ls "$pkg_dir"/*.rpm &>/dev/null; then
            yellow "正在从本地 packages 目录离线安装 rpm 依赖包..."
            rpm -ivh --nodeps "$pkg_dir"/*.rpm 2>/dev/null || true
            return 0
        fi
    fi

    # 2. 联网状态下尝试包管理器安装
    yellow "检测到系统缺失部分工具: ${missing_pkgs[*]}，正在尝试自动安装..."
    if [ -x "$(command -v apt-get)" ]; then
        apt-get update -y 2>/dev/null || true
        apt-get install -y "${missing_pkgs[@]}" 2>/dev/null || true
    elif [ -x "$(command -v dnf)" ]; then
        dnf install -y epel-release 2>/dev/null || true
        dnf install -y "${missing_pkgs[@]}" 2>/dev/null || true
    elif [ -x "$(command -v yum)" ]; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y "${missing_pkgs[@]}" 2>/dev/null || true
    elif [ -x "$(command -v apk)" ]; then
        apk add "${missing_pkgs[@]}" 2>/dev/null || true
    fi
}

_check_acme_deps

if [[ -z $(curl -s4m2 icanhazip.com -k 2>/dev/null) ]]; then
    if [ -f /etc/resolv.conf ] && ! grep -q "2a00:1098" /etc/resolv.conf 2>/dev/null; then
        yellow "检测到VPS为纯IPV6或无法访问外网IPV4，配置dns64解析..."
        echo -e "nameserver 2a00:1098:2b::1\nnameserver 2a00:1098:2c::1\nnameserver 2a01:4f8:c2c:123f::1" >> /etc/resolv.conf 2>/dev/null || true
    fi
fi

acme2(){
local port_busy=false
if command -v lsof &>/dev/null; then
    if [[ -n $(lsof -i :80 2>/dev/null | grep -v "PID") ]]; then
        port_busy=true
    fi
elif command -v ss &>/dev/null; then
    if ss -tlpn 2>/dev/null | grep -q ":80 "; then
        port_busy=true
    fi
fi

if [ "$port_busy" = "true" ]; then
    yellow "检测到80端口被占用，现执行80端口全释放"
    sleep 1
    if command -v fuser &>/dev/null; then
        fuser -k 80/tcp >/dev/null 2>&1 || true
    elif command -v lsof &>/dev/null; then
        lsof -i :80 2>/dev/null | grep -v "PID" | awk '{print "kill -9",$2}' | sh >/dev/null 2>&1 || true
    else
        kill -9 $(ss -tlpn 2>/dev/null | grep ":80 " | grep -oE 'pid=[0-9]+' | cut -d= -f2) >/dev/null 2>&1 || true
    fi
    green "80端口全释放完毕！"
    sleep 1
fi
}

acme3(){
readp "请输入注册所需的邮箱（回车跳过则自动生成虚拟gmail邮箱）：" Aemail
if [ -z "$Aemail" ]; then
auto=$(date +%s%N 2>/dev/null | md5sum | cut -c 1-6)
[ -z "$auto" ] && auto="user$RANDOM"
Aemail="${auto}@gmail.com"
fi
yellow "当前注册的邮箱名称：$Aemail"

# 检查是否已安装 acme.sh
if [ -f "$HOME/.acme.sh/acme.sh" ] && [ -x "$HOME/.acme.sh/acme.sh" ]; then
    green "✓ 检测到 acme.sh 引擎已就绪，跳过重复安装。"
    return 0
fi

green "开始安装 acme.sh 证书申请引擎..."
bash "$HOME/.acme.sh/acme.sh" --uninstall >/dev/null 2>&1 || true
rm -rf "$HOME/.acme.sh" "$HOME/acme.sh" 2>/dev/null || true
uncronac

# 1. 优先寻找本地离线静态包
local LOCAL_TAR=""
for p in \
    "$BASE_DIR/static/acme.sh-master.tar.gz" \
    "/opt/ck_sysinit/static/acme.sh-master.tar.gz" \
    "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../static/acme.sh-master.tar.gz" \
    "$PWD/system/static/acme.sh-master.tar.gz"; do
    if [ -f "$p" ] && [ -s "$p" ]; then
        LOCAL_TAR="$p"
        break
    fi
done

local install_ok=false

if [ -n "$LOCAL_TAR" ]; then
    green "✓ 发现本地离线安装包: ${LOCAL_TAR}，正在执行离线安装..."
    local tmp_dir="/tmp/acme_install_$$"
    mkdir -p "$tmp_dir"
    tar -zxf "$LOCAL_TAR" -C "$tmp_dir" 2>/dev/null
    local src_dir
    src_dir=$(find "$tmp_dir" -maxdepth 2 -type d -name "*acme.sh*" | head -n 1)
    if [ -n "$src_dir" ] && [ -f "$src_dir/acme.sh" ]; then
        cd "$src_dir"
        ./acme.sh --install --email "$Aemail" >/dev/null 2>&1
        cd - >/dev/null 2>&1
        [ -f "$HOME/.acme.sh/acme.sh" ] && install_ok=true
    fi
    rm -rf "$tmp_dir"
fi

# 2. 本地包不存在或安装失败时，从云端拉取
if [ "$install_ok" = false ]; then
    yellow "正在从云端下载安装 acme.sh 引擎..."
    if command -v curl &>/dev/null; then
        curl -fsSL https://get.acme.sh | sh -s email="$Aemail" >/dev/null 2>&1 || true
    elif command -v wget &>/dev/null; then
        wget -qO- https://get.acme.sh | sh -s email="$Aemail" >/dev/null 2>&1 || true
    fi
    [ -f "$HOME/.acme.sh/acme.sh" ] && install_ok=true
fi

if [ -f "$HOME/.acme.sh/acme.sh" ]; then
    green "✓ 安装 acme.sh 证书申请程序成功！"
else
    red "❌ 安装 acme.sh 证书申请程序失败，请检查网络或离线包。" && exit 1
fi
}

checktls(){
if [[ -s /root/kikock/cert.crt && -s /root/kikock/private.key ]]; then
cronac
green "IP/域名证书申请成功或已存在！证书（cert.crt）和密钥（private.key）已保存到 /root/kikock 文件夹内" 
yellow "公钥文件crt路径如下，可直接复制"
green "/root/kikock/cert.crt"
yellow "密钥文件key路径如下，可直接复制"
green "/root/kikock/private.key"
ym=`bash ~/.acme.sh/acme.sh --list | awk 'NR>1{print $1}' | tail -1`
echo $ym > /root/kikock/ca.log
if [[ -f '/etc/hysteria/config.json' ]]; then
blue "检测到Hysteria-1代理协议，如果你安装了Hysteria脚本，请在Hysteria脚本执行申请/变更证书，此证书将自动应用"
fi
if [[ -f '/etc/caddy/Caddyfile' ]]; then
blue "检测到Naiveproxy代理协议，如果你安装了Naiveproxy脚本，请在Naiveproxy脚本执行申请/变更证书，此证书将自动应用"
fi
if [[ -f '/etc/tuic/tuic.json' ]]; then
blue "检测到Tuic代理协议，如果你安装了Tuic脚本，请在Tuic脚本执行申请/变更证书，此证书将自动应用"
fi
if [[ -f '/usr/bin/x-ui' ]]; then
blue "检测到x-ui（xray代理协议），如果你安装了x-ui脚本，开启tls选项，此证书将自动应用"
fi
if [[ -f '/etc/s-box/sb.json' ]]; then
blue "检测到Sing-box内核代理，如果你安装了Sing-box脚本，请在Sing-box脚本执行申请/变更证书，此证书将自动应用"
fi
if [[ -f "$HOME/agsbx/sb.json" ]]; then
blue "检测到sing-box内核代理，如果你安装了Argosbx小钢炮脚本，HY2/TUIC/AnyTLS/Naiveproxy四大协议将支持IP域名证书"
fi
else
bash ~/.acme.sh/acme.sh --uninstall >/dev/null 2>&1
rm -rf /root/kikock
rm -rf ~/.acme.sh acme.sh
uncronac
red "遗憾，IP域名证书申请失败，建议如下："
yellow "1、如果你是域名证书申请：如果解析到的IP是104.2开头的或者172开头的IP，请确保CF中的CDN黄云已关闭，解析的IP必须是VPS的本地IP"
echo
yellow "2、如果你是域名证书申请：更换下二级域名自定义名称再尝试执行重装脚本（重要）"
green "例：原二级域名 x.example.com ，在cloudflare中重命名其中的x名称"
echo
yellow "3、如果你是IP证书或者域名证书申请：因为同个本地IP连续多次申请证书有时间限制，等一段时间再重装脚本" && exit
fi
}

installCA(){
mkdir -p /root/kikock
bash ~/.acme.sh/acme.sh --install-cert -d ${ym} --key-file /root/kikock/private.key --fullchain-file /root/kikock/cert.crt --ecc
}

checkip(){
v4v6
if [[ -z $v4 ]]; then
vpsip=$v6
elif [[ -n $v4 && -n $v6 ]]; then
vpsip="$v6 或者 $v4"
else
vpsip=$v4
fi
domainIP=""
if command -v dig &>/dev/null; then
    domainIP=$(dig @8.8.8.8 +time=2 +short "$ym" 2>/dev/null | grep -m1 '^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+$')
    if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]]; then
        domainIP=$(dig @2001:4860:4860::8888 +time=2 aaaa +short "$ym" 2>/dev/null | grep -m1 ':')
    fi
fi

# 降级方案 1: 使用 getent hosts
if [ -z "$domainIP" ] && command -v getent &>/dev/null; then
    domainIP=$(getent hosts "$ym" 2>/dev/null | awk '{print $1}' | head -n 1)
fi

# 降级方案 2: 使用 ping
if [ -z "$domainIP" ] && command -v ping &>/dev/null; then
    domainIP=$(ping -c 1 -W 2 "$ym" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
fi

if echo "$domainIP" | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]] ; then
red "未解析出IP，请检查域名是否输入有误" 
yellow "是否尝试手动输入强行匹配？"
yellow "1：是！输入域名解析的IP"
yellow "2：否！退出脚本"
readp "请选择：" menu
if [ "$menu" = "1" ] ; then
green "VPS本地的IP：$vpsip"
readp "请输入域名解析的IP，与VPS本地IP($vpsip)保持一致：" domainIP
else
exit
fi
elif [[ -n $(echo $domainIP | grep ":") ]]; then
green "当前域名解析到的IPV6地址：$domainIP"
else
green "当前域名解析到的IPV4地址：$domainIP"
fi
if [[ ! $domainIP =~ $v4 ]] && [[ ! $domainIP =~ $v6 ]]; then
yellow "当前VPS本地的IP：$vpsip"
red "当前域名解析的IP与当前VPS本地的IP不匹配！！！"
green "建议如下："
if [[ "$v6" == "2a09"* || "$v4" == "104.28"* ]]; then
yellow "WARP未能自动关闭，请手动关闭！"
else
yellow "1、请确保CDN小黄云关闭状态(仅限DNS)，其他域名解析网站设置同理"
yellow "2、请检查域名解析网站设置的IP是否正确"
fi
exit 
else
green "IP匹配正确，申请证书开始…………"
fi
}

checkacmeca(){
if [[ "${ym}" == *ip6.arpa* ]]; then
red "目前不支持ip6.arpa域名申请证书" && exit
fi
nowca=`bash ~/.acme.sh/acme.sh --list | awk 'NR>1{print $1}' | tail -1`
if [[ $nowca == $ym ]]; then
red "经检测，输入的域名已有证书申请记录，不用重复申请"
red "证书申请记录如下："
bash ~/.acme.sh/acme.sh --list
yellow "如果一定要重新申请，请先执行删除证书选项" && exit
fi
}

ACMEstandaloneIP(){
v4v6
if [[ -z $v4 ]]; then
vpsip=$v6
elif [[ -n $v4 && -n $v6 ]]; then
vpsip="$v4 或者 $v6"
else
vpsip=$v4
fi
green "VPS本地的IP：$vpsip"
if [[ "$v6" == "2a09"* || "$v4" == "104.28"* ]]; then
red "经检测，你申请了WARP的IP。请关闭WARP后再申请IP证书" && exit
fi
readp "请输入申请IP证书的IP【格式：IPV4或者IPV6或者IPV4 IPV6，回车跳过使用${vpsip%% *}】:" ym
if [[ -z $ym ]]; then
ym=${vpsip%% *}
fi
checkacmeca
ip1=$(echo $ym | awk '{print $1}')
if [[ "$ym" == *" "* && "$ym" == *":"* ]]; then
ip2=$(echo $ym | awk '{print $2}')
bash ~/.acme.sh/acme.sh --issue -d "$ip1" -d "$ip2" --standalone -k ec-256 --server letsencrypt --cert-profile shortlived --days 3 --insecure
else
bash ~/.acme.sh/acme.sh --issue -d "$ym" --standalone -k ec-256 --server letsencrypt --cert-profile shortlived --days 3 --insecure
fi
mkdir -p /root/kikock
bash ~/.acme.sh/acme.sh --install-cert -d "$ip1" --key-file /root/kikock/private.key --fullchain-file /root/kikock/cert.crt --ecc
checktls
}

ACMEstandaloneDNS(){
v4v6
readp "请输入解析完成的域名:" ym
green "已输入的域名:$ym" && sleep 1
checkacmeca
checkip
if [[ $domainIP = $v4 ]]; then
bash ~/.acme.sh/acme.sh --issue -d ${ym} --standalone -k ec-256 --server letsencrypt --insecure
fi
if [[ $domainIP = $v6 ]]; then
bash ~/.acme.sh/acme.sh --issue -d ${ym} --standalone -k ec-256 --server letsencrypt --listen-v6 --insecure
fi
installCA
checktls
}

ACMEDNS(){
readp "请输入解析完成的域名:" ym
green "已输入的域名:$ym" && sleep 1
checkacmeca
if [[ -n $(echo $ym | grep \*) ]]; then
green "经检测，当前为泛域名证书申请，" && sleep 2
else
green "经检测，当前为单域名证书申请，" && sleep 2
fi
checkacmeca
checkip
echo
ab="请选择托管域名解析服务商：\n1.Cloudflare\n2.腾讯云DNSPod\n3.阿里云Aliyun\n 请选择："
readp "$ab" cd
case "$cd" in 
1 )
yellow "请选择 Cloudflare DNS API 验证方式："
yellow "1. API Token (推荐)"
yellow "2. Global API Key"
readp "请选择【1-2】：" cf_choice
if [ "$cf_choice" = "1" ]; then
    readp "请输入 Cloudflare Account ID (账户ID)：" CFAccountID
    export CF_Account_ID="$CFAccountID"
    readp "请输入 Cloudflare DNS API Token (API令牌)：" CFToken
    export CF_Token="$CFToken"
else
    readp "请输入登录Cloudflare的注册邮箱地址：" CFemail
    export CF_Email="$CFemail"
    readp "请复制Cloudflare的Global API Key：" GAK
    export CF_Key="$GAK"
fi
if [[ $domainIP = $v4 ]]; then
bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${ym} -k ec-256 --server letsencrypt --insecure
fi
if [[ $domainIP = $v6 ]]; then
bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${ym} -k ec-256 --server letsencrypt --listen-v6 --insecure
fi
;;
2 )
readp "请复制腾讯云DNSPod的DP_Id：" DPID
export DP_Id="$DPID"
readp "请复制腾讯云DNSPod的DP_Key：" DPKEY
export DP_Key="$DPKEY"
if [[ $domainIP = $v4 ]]; then
bash ~/.acme.sh/acme.sh --issue --dns dns_dp -d ${ym} -k ec-256 --server letsencrypt --insecure
fi
if [[ $domainIP = $v6 ]]; then
bash ~/.acme.sh/acme.sh --issue --dns dns_dp -d ${ym} -k ec-256 --server letsencrypt --listen-v6 --insecure
fi
;;
3 )
readp "请复制阿里云Aliyun的Ali_Key：" ALKEY
export Ali_Key="$ALKEY"
readp "请复制阿里云Aliyun的Ali_Secret：" ALSER
export Ali_Secret="$ALSER"
if [[ $domainIP = $v4 ]]; then
bash ~/.acme.sh/acme.sh --issue --dns dns_ali -d ${ym} -k ec-256 --server letsencrypt --insecure
fi
if [[ $domainIP = $v6 ]]; then
bash ~/.acme.sh/acme.sh --issue --dns dns_ali -d ${ym} -k ec-256 --server letsencrypt --listen-v6 --insecure
fi
;;
esac
installCA
checktls
}

ACMEDNScheck(){
wgcfv6=$(curl -s6m6 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep warp | cut -d= -f2)
wgcfv4=$(curl -s4m6 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep warp | cut -d= -f2)
if [[ ! $wgcfv4 =~ on|plus && ! $wgcfv6 =~ on|plus ]]; then
ACMEDNS
else
systemctl stop wg-quick@wgcf >/dev/null 2>&1
kill -15 $(pgrep warp-go) >/dev/null 2>&1 && sleep 2
ACMEDNS
systemctl start wg-quick@wgcf >/dev/null 2>&1
systemctl restart warp-go >/dev/null 2>&1
systemctl enable warp-go >/dev/null 2>&1
systemctl start warp-go >/dev/null 2>&1
fi
}

ACMEstandaloneDNScheck(){
wgcfv6=$(curl -s6m6 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep warp | cut -d= -f2)
wgcfv4=$(curl -s4m6 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep warp | cut -d= -f2)
if [[ ! $wgcfv4 =~ on|plus && ! $wgcfv6 =~ on|plus ]]; then
ACMEstandaloneDNS
else
systemctl stop wg-quick@wgcf >/dev/null 2>&1
kill -15 $(pgrep warp-go) >/dev/null 2>&1 && sleep 2
ACMEstandaloneDNS
systemctl start wg-quick@wgcf >/dev/null 2>&1
systemctl restart warp-go >/dev/null 2>&1
systemctl enable warp-go >/dev/null 2>&1
systemctl start warp-go >/dev/null 2>&1
fi
}

ACMEstandaloneIPcheck(){
wgcfv6=$(curl -s6m6 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep warp | cut -d= -f2)
wgcfv4=$(curl -s4m6 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep warp | cut -d= -f2)
if [[ ! $wgcfv4 =~ on|plus && ! $wgcfv6 =~ on|plus ]]; then
ACMEstandaloneIP
else
systemctl stop wg-quick@wgcf >/dev/null 2>&1
kill -15 $(pgrep warp-go) >/dev/null 2>&1 && sleep 2
ACMEstandaloneIP
systemctl start wg-quick@wgcf >/dev/null 2>&1
systemctl restart warp-go >/dev/null 2>&1
systemctl enable warp-go >/dev/null 2>&1
systemctl start warp-go >/dev/null 2>&1
fi
}

acme(){
mkdir -p /root/kikock
ab="1.选择独立80端口模式申请IP证书（无需域名，推荐）\n2.选择独立80端口模式申请域名证书（需域名）\n3.选择DNS API模式申请证书（需域名、ID、Key），自动识别单域名与泛域名\n 请选择："
readp "$ab" cd
case "$cd" in 
1 ) acme2 && acme3 && ACMEstandaloneIPcheck;;
2 ) acme2 && acme3 && ACMEstandaloneDNScheck;;
3 ) acme3 && ACMEDNScheck;;
esac
}

Certificate(){
[[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安装acme.sh证书申请，无法执行" && return
green "Main_Domain 下显示的域名就是已申请成功的域名证书，Renew 下显示对应域名证书的自动续期时间点"
bash ~/.acme.sh/acme.sh --list
readp "按回车键继续..." tmp_enter
}

acmeshow(){
if [[ -n $(~/.acme.sh/acme.sh -v 2>/dev/null) ]]; then
caacme1=`bash ~/.acme.sh/acme.sh --list | awk 'NR>1{print $1}' | tail -1`
if [[ -n $caacme1 && ! $caacme1 == "Main_Domain" ]] && [[ -f /root/kikock/cert.crt && -f /root/kikock/private.key && -s /root/kikock/cert.crt && -s /root/kikock/private.key ]]; then
caacme=$caacme1
else
caacme='无证书申请记录'
fi
else
caacme='未安装acme'
fi
}

cronac(){
uncronac
crontab -l > /tmp/crontab.tmp 2>/dev/null || true
echo "0 0 * * * bash ~/.acme.sh/acme.sh --cron >/dev/null 2>&1" >> /tmp/crontab.tmp
crontab /tmp/crontab.tmp
rm -f /tmp/crontab.tmp
}

uncronac(){
crontab -l > /tmp/crontab.tmp 2>/dev/null || true
sed -i '/--cron/d' /tmp/crontab.tmp
crontab /tmp/crontab.tmp 2>/dev/null || true
rm -f /tmp/crontab.tmp
}

acmerenew(){
[[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安装acme.sh证书申请，无法执行" && return
green "以下显示的域名就是已申请成功的主证书:"
bash ~/.acme.sh/acme.sh --list | awk 'NR>1{print $1}' | tail -1
echo
green "开始续期证书…………" && sleep 2
bash ~/.acme.sh/acme.sh --cron -f
checktls
readp "按回车键继续..." tmp_enter
}

uninstall(){
[[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安装acme.sh证书申请，无法执行" && return
curl https://get.acme.sh | sh -s -- --uninstall 2>/dev/null || bash ~/.acme.sh/acme.sh --uninstall 2>/dev/null || true
rm -rf /root/kikock
rm -rf ~/.acme.sh acme.sh
sed -i '/acme.sh.env/d' ~/.bashrc 2>/dev/null || true
uncronac
[[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && green "acme.sh 及证书已卸载清理完毕" || red "acme.sh 卸载失败"
readp "按回车键继续..." tmp_enter
}

# ----------------------------------------------------------------
# ACME 菜单入口
# ----------------------------------------------------------------
acme_menu(){
while true; do
clear
green "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"           
echo -e "${bblue} ░██   ░██  ░██  ░██   ░██   ░██████   ░██████   ░██   ░██${plain}"
echo -e "${bblue} ░██  ░██   ░██  ░██  ░██   ░██    ░██░██    ░██ ░██  ░██ ${plain}"
echo -e "${bblue} ░█████     ░██  ░█████     ░██    ░██░██        ░█████   ${plain}"
echo -e "${bblue} ░██  ░██   ░██  ░██  ░██   ░██    ░██░██    ░██ ░██  ░██ ${plain}"
echo -e "${bblue} ░██   ░██  ░██  ░██   ░██   ░██████   ░██████   ░██   ░██${plain}"
green "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
white "作者 / 项目维护 ：kikock (Linux-ops-box)"
yellow "特别鸣谢与致敬 ：甬哥Github项目 (github.com/yonggekkk)"
white "甬哥blogger博客 ：ygkkk.blogspot.com"
white "甬哥YouTube频道 ：www.youtube.com/@ygkkk"
yellow "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
green "ACME 证书自动化管理中心 (支持 Let's Encrypt / ZeroSSL)"
yellow "提示："
yellow "1、SSH登录的IP与VPS本地IP必须一致"
yellow "2、80端口模式仅支持单域名证书申请，在80端口不被占用的情况下支持自动续期"
yellow "3、DNS API模式支持单域名与泛域名证书申请，无条件自动续期"
yellow "4、泛域名申请前须在服务商解析处设置一个名称为 * 字符的解析记录 (*.domain.com)"
green "公钥文件crt保存路径：/root/kikock/cert.crt"
green "密钥文件key保存路径：/root/kikock/private.key"
echo
red "========================================================================="
acmeshow
blue "当前已申请成功的证书（域名形式）："
yellow "$caacme"
echo
red "========================================================================="
green " 1. acme.sh申请letsencrypt ECC证书 (支持IP模式、单域名模式、DNS API泛域名模式)"
green " 2. 查询已申请成功的域名及自动续期时间点"
green " 3. 手动一键证书续期"
green " 4. 删除证书并卸载 acme.sh"
green " 0. 返回上一级菜单"
echo
readp "请输入数字 [0-4]: " NumberInput
case "$NumberInput" in     
1 ) acme;;
2 ) Certificate;;
3 ) acmerenew;;
4 ) uninstall;;
0 ) break;;
* ) yellow "输入无效，请重新选择"; sleep 1;;
esac
done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    acme_menu
fi
