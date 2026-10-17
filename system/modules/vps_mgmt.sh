#!/usr/bin/env bash
# ==============================================================================
# Linux-ops-box VPS 节点与代理服务管理中心 (vps_mgmt.sh)
# 职责: 聚合主流出海代理、VPN 隧道与 Sing-box-yg 全协议管理生态
# 支持: 独立单兵运行与微内核按需懒加载
# ==============================================================================

# 自动探测并加载通用底座函数 (双模兼容)
_CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_CURRENT_DIR/common.sh" ]; then
    source "$_CURRENT_DIR/common.sh"
fi

GREEN="${GREEN:-\033[0;32m}"
BLUE="${BLUE:-\033[0;34m}"
RED="${RED:-\033[0;31m}"
YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"
NC="${NC:-\033[0m}"

# 寻找宿主根目录下的脚本
_find_root_script() {
    local script_name="$1"
    local candidates=(
        "$_CURRENT_DIR/../../$script_name"
        "$_CURRENT_DIR/../$script_name"
        "/opt/ck_sysinit/$script_name"
        "/root/Linux-ops-box/$script_name"
        "$(pwd)/$script_name"
    )
    for p in "${candidates[@]}"; do
        if [ -f "$p" ]; then
            readlink -f "$p"
            return 0
        fi
    done
    return 1
}

# 1. 启动 VPS-VPN 专家管理工具
_launch_vpn_manager() {
    local vpn_sh
    vpn_sh=$(_find_root_script "install_vpn.sh")
    if [ -n "$vpn_sh" ] && [ -f "$vpn_sh" ]; then
        bash "$vpn_sh"
    else
        echo -e "${YELLOW}未在本地找到 install_vpn.sh，正在从官方加速源拉取执行...${NC}"
        bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/install_vpn.sh)
    fi
}

# 2. 启动 NaiveProxy 自动化安装与管理
_launch_naive_proxy() {
    local naive_sh
    naive_sh=$(_find_root_script "naive_install.sh")
    if [ -n "$naive_sh" ] && [ -f "$naive_sh" ]; then
        bash "$naive_sh"
    else
        echo -e "${YELLOW}未在本地找到 naive_install.sh，正在从官方加速源拉取执行...${NC}"
        bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/kikock/Linux-ops-box/main/naive_install.sh)
    fi
}

# 3. 安装 / 覆盖更新 Sing-box-yg 精装桶 (yonggekkk)
_install_singbox_yg() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${CYAN}   📦 Sing-box-yg 精装桶小白专享一键五协议共存脚本 (by yonggekkk)      ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo -e " 官方项目: https://github.com/yonggekkk/sing-box-yg"
    echo -e " 特别支持: Vless-Reality / Vless-ws / VMess-ws / Hysteria2 / Tuic 多协议共存"
    echo -e "${CYAN}------------------------------------------------------------------------${NC}"
    echo ""
    echo -e "${YELLOW}即将启动官方安装引导流程...${NC}"
    read -rp "是否立即开始安装/更新 Sing-box-yg？[Y/n]: " do_inst < /dev/tty
    if [[ "$do_inst" =~ ^[Nn]$ ]]; then
        echo -e "${BLUE}已取消安装。${NC}"
        sleep 1
        return 0
    fi

    # 1. 确保基础下载工具 curl 或 wget 可用 (防止最小化系统空跑)
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        echo -e "${YELLOW}>> 未检测到 curl 或 wget，正在自动安装基础依赖...${NC}"
        if declare -f _pkg_install_universal &>/dev/null; then
            _pkg_install_universal curl wget
        elif command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y curl wget
        elif command -v yum &>/dev/null; then
            yum install -y curl wget
        elif command -v dnf &>/dev/null; then
            dnf install -y curl wget
        elif command -v apk &>/dev/null; then
            apk add --no-cache curl wget
        fi
    fi

    # 2. 定义候选下载源 (官方源 + 国内加速镜像备用源)
    local candidate_urls=(
        "https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh"
        "https://ghfast.top/https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh"
        "https://ghp.ci/https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh"
        "https://mirror.ghproxy.com/https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh"
    )

    local tmp_script="/tmp/sb_installer_$$.sh"
    rm -f "$tmp_script"

    echo ""
    echo -e "${CYAN}>> 正在连接并拉取 Sing-box-yg 核心安装脚本...${NC}"
    local dl_ok=false

    for url in "${candidate_urls[@]}"; do
        echo -n "   ➜ 尝试源 [${url:0:45}...] ... "
        if command -v curl &>/dev/null; then
            if curl -fsSL --connect-timeout 6 --max-time 30 -o "$tmp_script" "$url" 2>/dev/null; then
                if [ -s "$tmp_script" ] && grep -qE "(sing-box|yonggekkk|bash)" "$tmp_script"; then
                    echo -e "${GREEN}下载成功${NC}"
                    dl_ok=true
                    break
                fi
            fi
        elif command -v wget &>/dev/null; then
            if wget -q --timeout=6 --tries=2 -O "$tmp_script" "$url" 2>/dev/null; then
                if [ -s "$tmp_script" ] && grep -qE "(sing-box|yonggekkk|bash)" "$tmp_script"; then
                    echo -e "${GREEN}下载成功${NC}"
                    dl_ok=true
                    break
                fi
            fi
        fi
        echo -e "${RED}连接超时或失败${NC}"
        rm -f "$tmp_script"
    done

    if [ "$dl_ok" != "true" ] || [ ! -s "$tmp_script" ]; then
        echo ""
        echo -e "${RED}❌ 错误: 无法拉取 Sing-box-yg 安装脚本！${NC}"
        echo -e "${YELLOW}请检查当前 VPS 是否能够正常连接外网或 GitHub。${NC}"
        echo -e "您也可以尝试在终端中手动执行官方命令："
        echo -e "  ${CYAN}bash <(wget -qO- https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh)${NC}"
        echo -e "或"
        echo -e "  ${CYAN}bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh)${NC}"
        rm -f "$tmp_script"
        read -rp "按回车键返回菜单..." < /dev/tty
        return 1
    fi

    # 3. 赋予执行权限并以纯净终端环境启动执行 (解决管道进程替换劫持 stdin 问题)
    chmod +x "$tmp_script"
    echo ""
    echo -e "${GREEN}>> 脚本校验通过，正在启动 Sing-box-yg 安装向导...${NC}"
    echo -e "${CYAN}========================================================================${NC}"

    bash "$tmp_script"
    local run_code=$?
    rm -f "$tmp_script"

    echo ""
    echo -e "${CYAN}========================================================================${NC}"
    if [ $run_code -eq 0 ]; then
        echo -e "${GREEN}✅ Sing-box-yg 安装流程已结束！${NC}"
    else
        echo -e "${YELLOW}⚠️ Sing-box-yg 安装向导已退出 (退出码: $run_code)。${NC}"
    fi

    if command -v sb &>/dev/null || [ -x /usr/local/bin/sb ] || [ -f /root/sb.sh ]; then
        echo -e "${GREEN}✓ 系统全局快捷指令 [ sb ] 已注册，随时在终端输入 sb 即可唤出控制台！${NC}"
    fi
    echo ""
    read -rp "按回车键返回菜单..." < /dev/tty
}

# 4. 进入 Sing-box-yg 管理控制台
_enter_singbox_yg() {
    clear
    local sb_bin=""
    if command -v sb &>/dev/null; then
        sb_bin="sb"
    elif [ -x /usr/local/bin/sb ]; then
        sb_bin="/usr/local/bin/sb"
    elif [ -x /usr/bin/sb ]; then
        sb_bin="/usr/bin/sb"
    elif [ -f /root/sb.sh ]; then
        sb_bin="bash /root/sb.sh"
    elif [ -f /etc/sing-box-yg/sb.sh ]; then
        sb_bin="bash /etc/sing-box-yg/sb.sh"
    fi

    if [ -n "$sb_bin" ]; then
        echo -e "${GREEN}>> 正在启动 Sing-box-yg 控制台 ($sb_bin)...${NC}"
        eval "$sb_bin"
    else
        echo -e "${RED}======================================================${NC}"
        echo -e "${RED} ⚠️ 未检测到已安装的 Sing-box-yg 控制台 (缺少 sb 命令) ${NC}"
        echo -e "${RED}======================================================${NC}"
        echo -e " 当前系统尚未安装 Sing-box-yg 精装桶，或安装未完整生成快捷方式。"
        echo ""
        read -rp " 是否现在立即执行一键安装？[Y/n]: " go_inst < /dev/tty
        if [[ ! "$go_inst" =~ ^[Nn]$ ]]; then
            _install_singbox_yg
        fi
    fi
}

# 5. 启动本地集成的 Sing-Box-Plus (备用模块)
_launch_singbox_plus() {
    local sbp_sh="$_CURRENT_DIR/sing-box-plus.sh"
    if [ -f "$sbp_sh" ]; then
        bash "$sbp_sh"
    else
        echo -e "${RED}错误: 未找到本地模块 $sbp_sh${NC}"
        read -rp "按回车键返回..." < /dev/tty
    fi
}

# ── VPS 与代理管理中心主菜单 ──────────────────────────────────────
vps_management_center() {
    while true; do
        clear
        echo -e "${CYAN}========================================================================${NC}"
        echo -e "${CYAN}           🌐 Linux-ops-box VPS 节点与代理管理中心                      ${NC}"
        echo -e "${CYAN}========================================================================${NC}"

        # 实时探测状态
        local sb_status="${RED}○ 未安装${NC}"
        if command -v sb &>/dev/null || [ -f /usr/local/bin/sb ] || [ -f /root/sb.sh ]; then
            sb_status="${GREEN}● 已就绪 (输入 sb 即可调用)${NC}"
        fi

        local vpn_status="${YELLOW}○ 离线/就绪${NC}"
        if systemctl is-active wg-quick@wg0 &>/dev/null || systemctl is-active xray &>/dev/null; then
            vpn_status="${GREEN}● 运行中 (WireGuard/Xray)${NC}"
        fi

        echo -e " Sing-box-yg 状态: $sb_status | VPN 隧道状态: $vpn_status"
        echo -e "${CYAN}------------------------------------------------------------------------${NC}"
        echo -e " 1. 🛡️  VPS-VPN 专家管理工具      (WireGuard隧道 / Xray-Reality隐蔽代理 / 链路诊断)"
        echo -e " 2. 🛸 NaiveProxy 自动化安装与管理 (基于 Caddy 补丁版的 HTTP/3 隐身代理)"
        echo -e " ------------------------------------------------------------------------"
        echo -e " 3. 📦 安装 / 更新 Sing-box-yg     (甬哥五协议共存精装桶一键安装脚本)"
        echo -e " 4. 🚀 进入 Sing-box-yg 管理控制台 (快速唤出 sb 控制台面板)"
        echo -e " ------------------------------------------------------------------------"
        echo -e " 5. 🌐 Sing-Box-Plus 多节点管理    (18节点直连+WARP综合管理脚本)"
        echo -e " 0. ↩  返回主菜单"
        echo -e "${CYAN}========================================================================${NC}"
        read -rp "请输入操作选项 [0-5]: " vps_choice < /dev/tty

        case "$vps_choice" in
            1) _launch_vpn_manager ;;
            2) _launch_naive_proxy ;;
            3) _install_singbox_yg ;;
            4) _enter_singbox_yg ;;
            5) _launch_singbox_plus ;;
            0) break ;;
            *) echo -e "${RED}输入无效，请重新选择。${NC}"; sleep 1 ;;
        esac
    done
}

# 双模运行守卫: 支持被主程序微内核懒加载 source 或独立单兵执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    vps_management_center
fi
