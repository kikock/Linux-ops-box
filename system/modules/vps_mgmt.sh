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
    echo -e "${YELLOW}即将执行官方安装引导：${NC}"
    echo -e "bash <(wget -qO- https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh)"
    echo ""
    read -rp "是否立即开始安装/更新 Sing-box-yg？[Y/n]: " do_inst < /dev/tty
    if [[ "$do_inst" =~ ^[Nn]$ ]]; then
        echo -e "${BLUE}已取消安装。${NC}"
        sleep 1
        return 0
    fi

    # 尝试直连拉取，若超时或受阻则通过加速镜像拉取
    echo -e "\n${YELLOW}正在连接并启动 Sing-box-yg 安装器...${NC}"
    if curl -Is -m 4 "https://raw.githubusercontent.com" &>/dev/null; then
        bash <(wget -qO- https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh)
    else
        echo -e "${YELLOW}检测到 GitHub 直连较慢，启用 GitHub 加速镜像拉取...${NC}"
        bash <(wget -qO- https://ghfast.top/https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh)
    fi

    echo ""
    echo -e "${GREEN}✅ Sing-box-yg 执行流程已结束。${NC}"
    if command -v sb &>/dev/null; then
        echo -e "${GREEN}✓ 系统全局快捷指令 [ sb ] 已注册就绪，在终端任意位置输入 sb 即可随时唤出管理！${NC}"
    fi
    read -rp "按回车键返回菜单..." < /dev/tty
}

# 4. 进入 Sing-box-yg 管理控制台
_enter_singbox_yg() {
    clear
    # 探测 sb 命令或常见落盘脚本路径
    if command -v sb &>/dev/null; then
        sb
    elif [ -f /usr/local/bin/sb ]; then
        bash /usr/local/bin/sb
    elif [ -f /root/sb.sh ]; then
        bash /root/sb.sh
    elif [ -f /etc/sing-box-yg/sb.sh ]; then
        bash /etc/sing-box-yg/sb.sh
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
