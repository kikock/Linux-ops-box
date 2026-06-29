#!/bin/bash

# ==========================================
# 颜色与样式常量定义 (ANSI Colors)
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m' # 无颜色恢复
BOLD='\033[1m'
UNDERLINE='\033[4m'

# ==========================================
# 全局常量配置
# ==========================================
PROXY_ADDR="http://192.168.40.240:10810"
NO_PROXY_LIST="localhost,127.0.0.1,192.168.0.0/16"
REG_DOMAIN="repo.yousen.plus"
REG_IP="117.173.15.227"
PROXY_FILE="/etc/profile.d/proxy.sh"
DOCKER_PROXY_DIR="/etc/systemd/system/docker.service.d"
DOCKER_PROXY_CONF="${DOCKER_PROXY_DIR}/http-proxy.conf"
DOCKER_DAEMON="/etc/docker/daemon.json"
DNS_LIST="223.5.5.5 119.29.29.29 8.8.8.8"

# ==========================================
# Root 权限安全校验
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}${BOLD}❌ 错误：此脚本涉及修改系统 Hosts、系统全局环境变量及服务重启，必须使用 root 权限运行！${NC}"
    echo -e "${YELLOW}👉 请使用 sudo 重新运行：sudo bash $0${NC}"
    exit 1
fi

# ==========================================
# 配置状态检测逻辑
# ==========================================
check_statuses() {
    # 1. 域名解析状态检测
    if grep -q "${REG_DOMAIN}" /etc/hosts 2>/dev/null; then
        HOSTS_OK="true"
    else
        HOSTS_OK="false"
    fi

    # 检测当前终端是否有残留代理环境变量
    local env_has_proxy="false"
    if [ -n "${http_proxy}" ] || [ -n "${https_proxy}" ] || [ -n "${no_proxy}" ] || \
       [ -n "${HTTP_PROXY}" ] || [ -n "${HTTPS_PROXY}" ] || [ -n "${NO_PROXY}" ]; then
        env_has_proxy="true"
    fi

    # 2. 系统全局代理文件检测
    if [ -f "${PROXY_FILE}" ]; then
        SYS_PROXY_OK="true"
    else
        if [ "${env_has_proxy}" = "true" ]; then
            SYS_PROXY_OK="cached" # 终端缓存残留
        else
            SYS_PROXY_OK="false"
        fi
    fi

    # 3 & 4. Docker 状态检测 (未安装防护)
    if ! command -v docker >/dev/null 2>&1; then
        DOCKER_PROXY_OK="not_installed"
        DOCKER_REG_OK="not_installed"
    else
        if [ -f "${DOCKER_PROXY_CONF}" ]; then
            DOCKER_PROXY_OK="true"
        else
            DOCKER_PROXY_OK="false"
        fi

        if [ -f "${DOCKER_DAEMON}" ] && grep -q "${REG_DOMAIN}" "${DOCKER_DAEMON}" 2>/dev/null; then
            DOCKER_REG_OK="true"
        else
            DOCKER_REG_OK="false"
        fi
    fi

    # 5. 公共 DNS 配置检测
    local dns_missing="false"
    for dns in ${DNS_LIST}; do
        if ! grep -q "^nameserver[[:space:]]\+${dns}" /etc/resolv.conf 2>/dev/null; then
            dns_missing="true"
        fi
    done
    if [ "${dns_missing}" = "false" ]; then
        DNS_OK="true"
    else
        DNS_OK="false"
    fi
}

get_status_label() {
    if [ "$1" = "true" ]; then
        echo -e "${GREEN}● 已生效${NC}"
    elif [ "$1" = "cached" ]; then
        echo -e "${YELLOW}● 终端缓存残留 (请重新打开终端或执行 unset)${NC}"
    elif [ "$1" = "not_installed" ]; then
        echo -e "${RED}○ 未安装 (已跳过)${NC}"
    else
        echo -e "${GRAY}○ 未开启${NC}"
    fi
}

# ==========================================
# 主菜单界面 (优化版：采用抗拉伸开放式排版)
# ==========================================
menu() {
    check_statuses
    clear
    echo -e "${CYAN}================================================================${NC}"
    echo -e "         ${BOLD}${WHITE}🚀  代理与私有镜像仓库综合管理工具 (v3.0)${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo -e "  ${BOLD}${YELLOW}[ 当前环境配置状态 ]${NC}"
    echo -e "    1. 域名解析 (/etc/hosts)       -->  [ $(get_status_label $HOSTS_OK) ]"
    echo -e "    2. 系统全局代理 (profile.d)    -->  [ $(get_status_label $SYS_PROXY_OK) ]"
    echo -e "    3. Docker 运行服务代理          -->  [ $(get_status_label $DOCKER_PROXY_OK) ]"
    echo -e "    4. Docker 镜像仓库信任          -->  [ $(get_status_label $DOCKER_REG_OK) ]"
    echo -e "    5. 公共 DNS 配置 (resolv.conf) -->  [ $(get_status_label $DNS_OK) ]"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    echo -e "  ${BOLD}${YELLOW}[ 可选操作菜单 ]${NC}"
    echo -e "    ${BOLD}${GREEN}1)${NC} 一键应用配置 ${GRAY}(添加域名解析 + 开启代理 + 信任仓库)${NC}"
    echo -e "    ${BOLD}${RED}2)${NC} 一键还原配置 ${GRAY}(删除所有修改并恢复系统初始状态)${NC}"
    echo -e "    ${BOLD}${BLUE}3)${NC} 查看详细配置 ${GRAY}(诊断并输出当前系统全部实际配置)${NC}"
    echo -e "    ${BOLD}${WHITE}0)${NC} 安全退出脚本"
    echo -e "${CYAN}================================================================${NC}"
    echo -ne "👉 请输入选项编号 [${BOLD}${GREEN}0-3${NC}]: "
    read opt
}

# ==========================================
# 1. 一键应用配置
# ==========================================
apply_config() {
    echo -e "\n${BLUE}=================== [ 开始应用配置 ] ===================${NC}"

    echo -e "${YELLOW}👉 请确认并输入配置参数（直接按回车可保留默认值）：${NC}"
    
    # 交互式输入代理地址
    read -p "请输入代理地址 PROXY_ADDR [当前: $PROXY_ADDR]: " input_proxy
    if [ -n "$input_proxy" ]; then
        PROXY_ADDR="$input_proxy"
    fi

    # 交互式输入私有仓库域名
    read -p "请输入私有镜像仓库域名 REG_DOMAIN [当前: $REG_DOMAIN]: " input_domain
    if [ -n "$input_domain" ]; then
        REG_DOMAIN="$input_domain"
    fi

    # 交互式输入镜像仓库 IP
    read -p "请输入镜像仓库解析 IP 地址 REG_IP [当前: $REG_IP]: " input_ip
    if [ -n "$input_ip" ]; then
        REG_IP="$input_ip"
    fi

    echo -e "\n${BLUE}正在应用最新参数: PROXY_ADDR=$PROXY_ADDR, REG_DOMAIN=$REG_DOMAIN, REG_IP=$REG_IP${NC}\n"

    # 1. hosts 域名绑定 (如果存在则先清理，再写入，防止 IP 变化或重复绑定导致 hosts 记录冗余)
    if grep -q "${REG_DOMAIN}" /etc/hosts 2>/dev/null; then
        sed -i "/${REG_DOMAIN}/d" /etc/hosts
    fi
    echo "${REG_IP} ${REG_DOMAIN}" >> /etc/hosts
    echo -e " ${GREEN}✔${NC} 域名解析已添加至 /etc/hosts (${REG_IP} -> ${REG_DOMAIN})"

    # 2. 系统全局代理
    cat > "${PROXY_FILE}" <<EOF
export http_proxy=${PROXY_ADDR}
export https_proxy=${PROXY_ADDR}
export no_proxy=${NO_PROXY_LIST}
export HTTP_PROXY=${PROXY_ADDR}
export HTTPS_PROXY=${PROXY_ADDR}
export NO_PROXY=${NO_PROXY_LIST}
EOF
    chmod +x "${PROXY_FILE}"
    source "${PROXY_FILE}"
    echo -e " ${GREEN}✔${NC} 系统全局代理配置文件写入成功 (${PROXY_FILE})"

    # 3. Docker 相关配置 (如未安装则自动跳过)
    if ! command -v docker >/dev/null 2>&1; then
        echo -e " ${YELLOW}ℹ${NC} 系统未安装 Docker，已自动跳过 Docker 代理与信任仓库配置"
    else
        # 3. Docker systemd 代理配置
        mkdir -p "${DOCKER_PROXY_DIR}"
        cat > "${DOCKER_PROXY_CONF}" <<EOF
[Service]
Environment="HTTP_PROXY=${PROXY_ADDR}"
Environment="HTTPS_PROXY=${PROXY_ADDR}"
Environment="NO_PROXY=${NO_PROXY_LIST}"
EOF
        echo -e " ${GREEN}✔${NC} Docker Systemd 代理配置文件写入成功"

        # 4. Docker 信任私有仓库 (安全增量更新 JSON)
        mkdir -p /etc/docker
        if [ -f "${DOCKER_DAEMON}" ]; then
            # 备份原有文件
            if [ ! -f "${DOCKER_DAEMON}.bak" ]; then
                cp "${DOCKER_DAEMON}" "${DOCKER_DAEMON}.bak"
                echo -e " ${BLUE}ℹ${NC} 已将原 ${DOCKER_DAEMON} 备份为 daemon.json.bak"
            fi
            
            # 尝试使用 Python 安全合并 JSON
            if command -v python3 >/dev/null 2>&1; then
                python3 -c '
import sys, json
daemon_file = sys.argv[1]
reg_domain = sys.argv[2]
try:
    with open(daemon_file, "r") as f:
        d = json.load(f)
except Exception:
    d = {}
if "insecure-registries" not in d:
    d["insecure-registries"] = []
elif not isinstance(d["insecure-registries"], list):
    d["insecure-registries"] = [d["insecure-registries"]]
if reg_domain not in d["insecure-registries"]:
    d["insecure-registries"].append(reg_domain)
with open(daemon_file, "w") as f:
    json.dump(d, f, indent=2)
' "${DOCKER_DAEMON}" "${REG_DOMAIN}" && echo -e " ${GREEN}✔${NC} Docker 信任仓库配置合并成功 (保留了您原有的 daemon.json 配置)"
            elif command -v python >/dev/null 2>&1; then
                python -c '
import sys, json
daemon_file = sys.argv[1]
reg_domain = sys.argv[2]
try:
    with open(daemon_file, "r") as f:
        d = json.load(f)
except Exception:
    d = {}
if "insecure-registries" not in d:
    d["insecure-registries"] = []
elif not isinstance(d["insecure-registries"], list):
    d["insecure-registries"] = [d["insecure-registries"]]
if reg_domain not in d["insecure-registries"]:
    d["insecure-registries"].append(reg_domain)
with open(daemon_file, "w") as f:
    json.dump(d, f, indent=2)
' "${DOCKER_DAEMON}" "${REG_DOMAIN}" && echo -e " ${GREEN}✔${NC} Docker 信任仓库配置合并成功 (保留了您原有的 daemon.json 配置)"
            else
                # 无 Python，退化为直接覆盖但保留备份
                echo -e " ${YELLOW}⚠ 警告：未检测到 Python 环境，将直接覆盖 daemon.json 文件${NC}"
                cat > "${DOCKER_DAEMON}" <<EOF
{
  "insecure-registries": ["${REG_DOMAIN}"]
}
EOF
            fi
        else
            cat > "${DOCKER_DAEMON}" <<EOF
{
  "insecure-registries": ["${REG_DOMAIN}"]
}
EOF
            echo -e " ${GREEN}✔${NC} 新建 Docker 配置文件并成功添加信任仓库"
        fi

        # 5. 重载并重启 Docker
        echo -e " ${YELLOW}⏳ 正在重启 Docker 服务以应用配置...${NC}"
        systemctl daemon-reload
        if systemctl restart docker >/dev/null 2>&1; then
            echo -e " ${GREEN}✔${NC} Docker 服务重载并重启完成"
        else
            # 尝试非 systemd 环境容错（如 WSL 等环境）
            if service docker restart >/dev/null 2>&1; then
                echo -e " ${GREEN}✔${NC} Docker 服务重载并重启完成 (通过 SysV init)"
            else
                echo -e " ${RED}❌ Docker 服务重启失败，请手动重启以应用代理和信任仓库设置。${NC}"
            fi
        fi
    fi

    # 6. 配置公共 DNS (追加到 resolv.conf)
    echo -e "\n${BLUE}[ 配置公共 DNS ]${NC}"
    local dns_added="false"
    for dns in ${DNS_LIST}; do
        if ! grep -q "^nameserver[[:space:]]\+${dns}" /etc/resolv.conf 2>/dev/null; then
            echo "nameserver ${dns}" >> /etc/resolv.conf
            echo -e " ${GREEN}✔${NC} 已将 DNS ${dns} 追加至 /etc/resolv.conf"
            dns_added="true"
        fi
    done
    if [ "${dns_added}" = "false" ]; then
        echo -e " ${YELLOW}ℹ${NC} 公共 DNS 已存在于 /etc/resolv.conf，无需重复添加"
    fi

    echo -e "\n${GREEN}========================================================${NC}"
    echo -e " 🎉 ${BOLD}${GREEN}所有配置已成功生效！${NC}"
    echo -e " 👉 ${BOLD}${WHITE}重要提示：${NC}"
    echo -e "    1. 拉取私有镜像前，请先登录：${CYAN}docker login ${REG_DOMAIN}${NC}"
    echo -e "    2. 当前终端的代理变量已刷新。若其他已开启的终端需要立即生效，请执行："
    echo -e "       ${BOLD}${YELLOW}source ${PROXY_FILE}${NC}"
    echo -e "${GREEN}========================================================${NC}"
    read -p "按回车键返回主菜单..."
}

# ==========================================
# 2. 一键还原配置
# ==========================================
restore_config() {
    echo -e "\n${RED}=================== [ 开始还原清空配置 ] ===================${NC}"

    # 1. 清理 hosts
    if grep -q "${REG_DOMAIN}" /etc/hosts 2>/dev/null; then
        sed -i "/${REG_DOMAIN}/d" /etc/hosts
        echo -e " ${GREEN}✔${NC} 已从 /etc/hosts 中清理域名解析"
    else
        echo -e " ${GRAY}○ /etc/hosts 中无相关域名解析，无需清理${NC}"
    fi

    # 2. 清理系统代理
    if [ -f "${PROXY_FILE}" ]; then
        rm -f "${PROXY_FILE}"
        unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
        echo -e " ${GREEN}✔${NC} 已删除系统全局代理配置文件 (${PROXY_FILE})"
    else
        echo -e " ${GRAY}○ 系统全局代理配置文件不存在，无需清理${NC}"
    fi

    # 3. 清理 Docker 代理
    if [ -d "${DOCKER_PROXY_DIR}" ]; then
        rm -rf "${DOCKER_PROXY_DIR}"
        echo -e " ${GREEN}✔${NC} 已删除 Docker 服务代理配置目录"
    else
        echo -e " ${GRAY}○ Docker 服务代理配置不存在，无需清理${NC}"
    fi

    # 4. 清理仓库信任 (安全恢复/剔除)
    if [ -f "${DOCKER_DAEMON}.bak" ]; then
        # 优先从备份恢复
        mv "${DOCKER_DAEMON}.bak" "${DOCKER_DAEMON}"
        echo -e " ${GREEN}✔${NC} 已从备份 daemon.json.bak 还原 Docker 配置"
    elif [ -f "${DOCKER_DAEMON}" ]; then
        # 若没有备份但有文件，利用 Python 安全剔除
        if command -v python3 >/dev/null 2>&1; then
            python3 -c '
import sys, json
daemon_file = sys.argv[1]
reg_domain = sys.argv[2]
try:
    with open(daemon_file, "r") as f:
        d = json.load(f)
except Exception:
    d = {}
if "insecure-registries" in d and isinstance(d["insecure-registries"], list):
    if reg_domain in d["insecure-registries"]:
        d["insecure-registries"].remove(reg_domain)
    if not d["insecure-registries"]:
        del d["insecure-registries"]
with open(daemon_file, "w") as f:
    json.dump(d, f, indent=2)
' "${DOCKER_DAEMON}" "${REG_DOMAIN}" && echo -e " ${GREEN}✔${NC} 已安全从 Docker daemon.json 中移除私有仓库信任 (保留了其他配置)"
        elif command -v python >/dev/null 2>&1; then
            python -c '
import sys, json
daemon_file = sys.argv[1]
reg_domain = sys.argv[2]
try:
    with open(daemon_file, "r") as f:
        d = json.load(f)
except Exception:
    d = {}
if "insecure-registries" in d and isinstance(d["insecure-registries"], list):
    if reg_domain in d["insecure-registries"]:
        d["insecure-registries"].remove(reg_domain)
    if not d["insecure-registries"]:
        del d["insecure-registries"]
with open(daemon_file, "w") as f:
    json.dump(d, f, indent=2)
' "${DOCKER_DAEMON}" "${REG_DOMAIN}" && echo -e " ${GREEN}✔${NC} 已安全从 Docker daemon.json 中移除私有仓库信任 (保留了其他配置)"
        else
            rm -f "${DOCKER_DAEMON}"
            echo -e " ${YELLOW}⚠ 未检测到 Python 环境，直接删除了整个 Docker daemon.json 配置${NC}"
        fi
    else
        echo -e " ${GRAY}○ Docker 仓库配置不存在，无需清理${NC}"
    fi

    # 5. 清理 DNS 配置
    local dns_removed="false"
    for dns in ${DNS_LIST}; do
        if grep -q "^nameserver[[:space:]]\+${dns}" /etc/resolv.conf 2>/dev/null; then
            sed -i "/^nameserver[[:space:]]\+${dns}/d" /etc/resolv.conf
            echo -e " ${GREEN}✔${NC} 已从 /etc/resolv.conf 中清理 DNS ${dns}"
            dns_removed="true"
        fi
    done
    if [ "${dns_removed}" = "false" ]; then
        echo -e " ${GRAY}○ /etc/resolv.conf 中无相关 DNS，无需清理${NC}"
    fi

    # 6. 重载并重启 Docker (仅在已安装 Docker 时)
    if command -v docker >/dev/null 2>&1; then
        echo -e " ${YELLOW}⏳ 正在重启 Docker 服务以应用配置...${NC}"
        systemctl daemon-reload
        if systemctl restart docker >/dev/null 2>&1; then
            echo -e " ${GREEN}✔${NC} Docker 服务重载并重启完成"
        else
            # WSL 等环境适配
            if service docker restart >/dev/null 2>&1; then
                echo -e " ${GREEN}✔${NC} Docker 服务重载并重启完成 (通过 SysV init)"
            else
                echo -e " ${RED}❌ Docker 服务重启失败，请确认服务状态。${NC}"
            fi
        fi
    else
        echo -e " ${GRAY}○ 系统未安装 Docker，无需重启服务${NC}"
    fi

    echo -e "\n${GREEN}========================================================${NC}"
    echo -e " ♻️  ${BOLD}${GREEN}系统级配置已完全恢复至初始状态！${NC}"
    echo -e " ${YELLOW}⚠  提示：由于 Linux 进程隔离限制，脚本无法直接清除当前正在操作的终端环境变量。${NC}"
    echo -e " 👉 ${BOLD}${WHITE}请手动执行以下操作以清除当前终端的代理缓存：${NC}"
    echo -e "    ${BOLD}${YELLOW}unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY${NC}"
    echo -e "    ${GRAY}(或者直接关闭当前终端，重新打开一个新的终端窗口即可)${NC}"
    echo -e "${GREEN}========================================================${NC}"
    read -p "按回车键返回主菜单..."
}

# ==========================================
# 3. 详细配置诊断查看
# ==========================================
show_config() {
    clear
    echo -e "${CYAN}=========================================================${NC}"
    echo -e "       ${BOLD}${WHITE}🔍 详细配置诊断状态输出${NC}"
    echo -e "${CYAN}=========================================================${NC}"

    # 1. hosts 域名解析记录
    echo -e "\n${BOLD}${BLUE}[ 1. 域名解析记录 (/etc/hosts) ]${NC}"
    if grep -q "${REG_DOMAIN}" /etc/hosts 2>/dev/null; then
        grep --color=always "${REG_DOMAIN}" /etc/hosts
    else
        echo -e "${GRAY}无相关域名解析记录${NC}"
    fi

    # 2. 系统全局代理文件内容
    echo -e "\n${BOLD}${BLUE}[ 2. 系统全局代理配置 (${PROXY_FILE}) ]${NC}"
    if [ -f "${PROXY_FILE}" ]; then
        cat "${PROXY_FILE}"
    else
        echo -e "${GRAY}文件不存在 (未配置系统代理)${NC}"
    fi

    # 3. 当前终端环境变量
    echo -e "\n${BOLD}${BLUE}[ 3. 当前终端代理环境变量 (env) ]${NC}"
    if env | grep -Ei "proxy|PROXY" >/dev/null 2>&1; then
        env | grep -Ei --color=always "proxy|PROXY"
        if [ ! -f "${PROXY_FILE}" ]; then
            echo -e "\n${YELLOW}⚠ 提示：系统级代理配置文件已清除，但当前终端环境变量仍有缓存残留！${NC}"
            echo -e "${YELLOW}👉 请手动执行命令清空终端缓存：unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY${NC}"
        fi
    else
        echo -e "${GRAY}当前运行终端内无代理环境变量${NC}"
    fi

    # 4. Docker systemd 代理配置文件
    echo -e "\n${BOLD}${BLUE}[ 4. Docker 服务代理配置 (${DOCKER_PROXY_CONF}) ]${NC}"
    if [ -f "${DOCKER_PROXY_CONF}" ]; then
        cat "${DOCKER_PROXY_CONF}"
    else
        echo -e "${GRAY}文件不存在 (未配置 Docker 服务代理)${NC}"
    fi

    # 5. Docker daemon 信任仓库 file
    echo -e "\n${BOLD}${BLUE}[ 5. Docker 私有仓库信任配置 (${DOCKER_DAEMON}) ]${NC}"
    if [ -f "${DOCKER_DAEMON}" ]; then
        cat "${DOCKER_DAEMON}"
    else
        echo -e "${GRAY}文件不存在 (未配置 Docker 私有仓库信任)${NC}"
    fi

    # 6. Docker 运行时代理 & 信任列表实际状态
    echo -e "\n${BOLD}${BLUE}[ 6. Docker 引擎运行时生效参数 (docker info) ]${NC}"
    if command -v docker >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then
            docker info 2>/dev/null | grep -Ei --color=always "Proxy|Insecure Registries" || echo -e "${GRAY}未检测到 Docker 内生效的代理与不安全仓库配置${NC}"
        else
            echo -e "${RED}❌ 无法与 Docker 守护进程通信，请检查 Docker 服务是否启动！${NC}"
        fi
    else
        echo -e "${GRAY}○ 系统未安装 docker，已自动跳过运行时诊断${NC}"
    fi

    # 7. DNS 实际配置
    echo -e "\n${BOLD}${BLUE}[ 7. 公共 DNS 配置 (/etc/resolv.conf) ]${NC}"
    if [ -f /etc/resolv.conf ]; then
        cat /etc/resolv.conf | grep -E "^nameserver" || echo -e "${GRAY}无 nameserver 配置${NC}"
    else
        echo -e "${GRAY}/etc/resolv.conf 文件不存在${NC}"
    fi

    echo -e "\n${CYAN}=========================================================${NC}"
    read -p "按回车键返回主菜单..."
}

# ==========================================
# 主业务循环
# ==========================================
while true; do
    menu
    case ${opt} in
        1)
            apply_config
            ;;
        2)
            restore_config
            ;;
        3)
            show_config
            ;;
        0)
            echo -e "\n${GREEN}✔ 感谢使用代理与仓库综合管理工具，脚本已安全退出！${NC}\n"
            exit 0
            ;;
        *)
            echo -e "\n${RED}❌ 输入错误，请输入 0、1、2 或 3 进行操作！${NC}"
            sleep 1.2
            ;;
    esac
done