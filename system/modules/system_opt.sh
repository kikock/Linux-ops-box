#!/usr/bin/env bash
# ==============================================================================
# Linux-ops-box 系统环境优化与软件包管理模块 (system_opt.sh)
# 支持独立单兵运行与主程序微内核懒加载
# ==============================================================================

# 底座依赖自探测
if ! declare -f _log_info &>/dev/null; then
    _COMMON_PATHS=(
        "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
        "/opt/ck_sysinit/system/modules/common.sh"
        "/opt/ck_sysinit/modules/common.sh"
    )
    for _c in "${_COMMON_PATHS[@]}"; do
        if [ -f "$_c" ]; then source "$_c"; break; fi
    done
fi

GREEN="${GREEN:-\033[0;32m}"
BLUE="${BLUE:-\033[0;34m}"
RED="${RED:-\033[0;31m}"
YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"
NC="${NC:-\033[0m}"

update_system_packages() {
    echo -e "\n${BLUE}--- 开始更新系统软件包 ---${NC}"
    echo -e "${YELLOW}当前包管理器: ${PKG_MGR:-未检测到}${NC}"

    case "$PKG_MGR" in
        apt)
            echo -e "${YELLOW}1. 正在更新软件源 (apt update)...${NC}"
            apt update 2>&1 | tee /tmp/apt_update_output.txt
            APT_EXIT=${PIPESTATUS[0]}
            if [ $APT_EXIT -ne 0 ]; then
                echo -e "\n${YELLOW}警告: apt update 存在错误 (详见上方输出)。${NC}"
                echo -e "${BLUE}建议: 前往 [系统环境优化 -> 镜像源管理] 修复源配置。${NC}"
                read -p "是否仍要继续升级? (y/n): " continue_upgrade
                [[ "$continue_upgrade" != "y" && "$continue_upgrade" != "Y" ]] && read -p "按回车键返回..." && return
            fi
            echo -e "${YELLOW}2. 正在升级软件包 (apt upgrade)...${NC}"
            apt upgrade -y
            ;;
        dnf)
            echo -e "${YELLOW}1. 正在检查可用更新 (dnf check-update)...${NC}"
            dnf check-update 2>&1; UPDATE_EXIT=$?
            # dnf check-update 返回 100 表示有可用更新（正常）
            if [ $UPDATE_EXIT -eq 0 ] || [ $UPDATE_EXIT -eq 100 ]; then
                echo -e "${YELLOW}2. 正在升级软件包 (dnf upgrade)...${NC}"
                dnf upgrade -y
            else
                echo -e "${RED}错误: dnf check-update 失败，请检查网络或 repo 配置。${NC}"
                read -p "按回车键返回..."; return
            fi
            ;;
        yum)
            echo -e "${YELLOW}1. 正在检查可用更新 (yum check-update)...${NC}"
            yum check-update 2>&1; UPDATE_EXIT=$?
            if [ $UPDATE_EXIT -eq 0 ] || [ $UPDATE_EXIT -eq 100 ]; then
                echo -e "${YELLOW}2. 正在升级软件包 (yum upgrade)...${NC}"
                yum upgrade -y
            else
                echo -e "${RED}错误: yum check-update 失败，请检查网络或 repo 配置。${NC}"
                read -p "按回车键返回..."; return
            fi
            ;;
        apk)
            echo -e "${YELLOW}1. 正在更新软件索引 (apk update)...${NC}"
            apk update
            echo -e "${YELLOW}2. 正在升级所有软件包 (apk upgrade)...${NC}"
            apk upgrade
            ;;
        *)
            echo -e "${RED}错误: 未检测到支持的包管理器 (apt/dnf/yum/apk)。${NC}"
            read -p "按回车键返回..."; return
            ;;
    esac

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}成功: 系统软件包已全部更新完毕。${NC}"
    else
        echo -e "${RED}错误: 软件包升级过程中出现问题，请检查上方错误信息。${NC}"
    fi
    echo ""
    read -p "按回车键返回主菜单..."
}

# === 镜像源管理子菜单 ===
manage_mirror_sources() {
    # 自动识别系统发行版
    _detect_distro() {
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            local id_lower
            id_lower=$(echo "${ID:-unknown}" | tr '[:upper:]' '[:lower:]')
            local ver="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
            if [[ "$id_lower" == "ubuntu" ]] && [ -z "$ver" ] && command -v lsb_release &>/dev/null; then
                ver="$(lsb_release -cs 2>/dev/null)"
            fi
            # 无 codename 时取主版本号
            [ -z "$ver" ] && ver="${VERSION_ID%%.*}"

            # 国产系统 ID 归一化映射
            case "$id_lower" in
                ubuntukylin|neokylin)            id_lower="kylin-deb" ;;
                kylin)                           id_lower="kylin" ;;
                uos|uniontechos|deepin*)         id_lower="uos" ;;
                openeuler|euler|euleros)         id_lower="openeuler" ;;
                anolis|tencentos|opencloudos)    id_lower="anolis" ;;
            esac

            echo "${id_lower}:${ver}"
        else
            echo "unknown:"
        fi
    }

    # 写入镜像源，并禁用 backports
    _write_source() {
        local mirror=$1
        local distro_info
        distro_info=$(_detect_distro)
        local distro_id=${distro_info%%:*}
        local version_info=${distro_info##*:}

        echo -e "${YELLOW}检测到: $distro_id $version_info${NC}"

        # ── Debian/Ubuntu 族系 ──────────────────────────────────────────
        if [[ "$distro_id" == "ubuntu" ]]; then
            local bak="/etc/apt/sources.list.bak.$(date +%F_%H%M%S)"
            cp /etc/apt/sources.list "$bak" 2>/dev/null && echo -e "${BLUE}已备份原配置到: $bak${NC}"
            cat > /etc/apt/sources.list <<EOF
# Ubuntu $version_info - $mirror (自动生成 $(date +"%Y-%m-%d %H:%M:%S"))
deb $mirror $version_info main restricted universe multiverse
deb $mirror $version_info-updates main restricted universe multiverse
deb $mirror $version_info-security main restricted universe multiverse
EOF

        elif [[ "$distro_id" == "debian" ]]; then
            local bak="/etc/apt/sources.list.bak.$(date +%F_%H%M%S)"
            cp /etc/apt/sources.list "$bak" 2>/dev/null && echo -e "${BLUE}已备份原配置到: $bak${NC}"
            local mirror_base="${mirror%/debian}"
            local security_mirror="${mirror_base}/debian-security"
            [[ "$mirror" == *"deb.debian.org"* ]] && security_mirror="http://security.debian.org/debian-security"
            cat > /etc/apt/sources.list <<EOF
# Debian $version_info - $mirror (自动生成 $(date +"%Y-%m-%d %H:%M:%S"))
deb $mirror $version_info main contrib non-free
deb $mirror $version_info-updates main contrib non-free
deb $security_mirror $version_info-security main contrib non-free
EOF

        # ── 麒麟系 (APT) ────────────────────────────────────────────────
        elif [[ "$distro_id" == "kylin-deb" || "$distro_id" == "kylin" ]] && command -v apt &>/dev/null; then
            local bak="/etc/apt/sources.list.bak.$(date +%F_%H%M%S)"
            cp /etc/apt/sources.list "$bak" 2>/dev/null && echo -e "${BLUE}已备份原配置到: $bak${NC}"
            cat > /etc/apt/sources.list <<EOF
# Kylin $version_info - $mirror (自动生成 $(date +"%Y-%m-%d %H:%M:%S"))
deb $mirror $version_info main restricted universe multiverse
deb $mirror $version_info-updates main restricted universe multiverse
deb $mirror $version_info-security main restricted universe multiverse
EOF

        # ── 麒麟系 (RPM / DNF) ─────────────────────────────────────────
        elif [[ "$distro_id" == "kylin" ]] && command -v rpm &>/dev/null; then
            echo -e "${YELLOW}[INFO] 正在备份 YUM/DNF 配置目录 (/etc/yum.repos.d/)...${NC}"
            tar -czf "/etc/yum.repos.d.bak.$(date +%F).tar.gz" /etc/yum.repos.d/ &>/dev/null
            # 替换银河麒麟 V10 Server 官方 repo 中的 baseurl
            if ls /etc/yum.repos.d/kylin*.repo &>/dev/null; then
                sed -i "s|baseurl=.*|baseurl=$mirror|g" /etc/yum.repos.d/kylin*.repo
            else
                echo -e "${YELLOW}[提示] 未找到 kylin*.repo，请手动配置 /etc/yum.repos.d/ 下的 repo 文件。${NC}"
            fi

        # ── 统信 UOS / Deepin ──────────────────────────────────────────
        elif [[ "$distro_id" == "uos" ]]; then
            local bak="/etc/apt/sources.list.bak.$(date +%F_%H%M%S)"
            cp /etc/apt/sources.list "$bak" 2>/dev/null && echo -e "${BLUE}已备份原配置到: $bak${NC}"
            cat > /etc/apt/sources.list <<EOF
# UOS/Deepin $version_info - $mirror (自动生成 $(date +"%Y-%m-%d %H:%M:%S"))
deb $mirror $version_info main contrib non-free
deb $mirror $version_info-updates main contrib non-free
EOF

        # ── openEuler / EulerOS ─────────────────────────────────────────
        elif [[ "$distro_id" == "openeuler" ]]; then
            echo -e "${YELLOW}[INFO] 正在备份 openEuler repo 配置...${NC}"
            tar -czf "/etc/yum.repos.d.bak.$(date +%F).tar.gz" /etc/yum.repos.d/ &>/dev/null
            local repo_file="/etc/yum.repos.d/openEuler_mirror.repo"
            cat > "$repo_file" <<EOF
# openEuler $version_info - $mirror (自动生成 $(date +"%Y-%m-%d %H:%M:%S"))
[openEuler-OS]
name=openEuler-\$releasever - OS
baseurl=$mirror/\$releasever/OS/\$basearch/
enabled=1
gpgcheck=0

[openEuler-Everything]
name=openEuler-\$releasever - Everything
baseurl=$mirror/\$releasever/everything/\$basearch/
enabled=1
gpgcheck=0

[openEuler-Extras]
name=openEuler-\$releasever - Extras
baseurl=$mirror/\$releasever/extras/\$basearch/
enabled=1
gpgcheck=0
EOF
            echo -e "${GREEN}已生成 openEuler 镜像 repo: $repo_file${NC}"

        # ── Anolis OS / TencentOS ───────────────────────────────────────
        elif [[ "$distro_id" == "anolis" ]]; then
            echo -e "${YELLOW}[INFO] 正在备份 Anolis repo 配置...${NC}"
            tar -czf "/etc/yum.repos.d.bak.$(date +%F).tar.gz" /etc/yum.repos.d/ &>/dev/null
            local repo_file="/etc/yum.repos.d/anolis_mirror.repo"
            cat > "$repo_file" <<EOF
# Anolis OS $version_info - $mirror (自动生成 $(date +"%Y-%m-%d %H:%M:%S"))
[anolis-BaseOS]
name=Anolis OS \$releasever - BaseOS
baseurl=$mirror/\$releasever/BaseOS/\$basearch/os/
enabled=1
gpgcheck=0

[anolis-AppStream]
name=Anolis OS \$releasever - AppStream
baseurl=$mirror/\$releasever/AppStream/\$basearch/os/
enabled=1
gpgcheck=0

[anolis-Extras]
name=Anolis OS \$releasever - Extras
baseurl=$mirror/\$releasever/Extras/\$basearch/os/
enabled=1
gpgcheck=0
EOF
            echo -e "${GREEN}已生成 Anolis OS 镜像 repo: $repo_file${NC}"

        # ── CentOS ─────────────────────────────────────────────────────
        elif [[ "$distro_id" == "centos" ]]; then
            echo -e "${YELLOW}[INFO] 正在备份 YUM 配置目录 (/etc/yum.repos.d/)...${NC}"
            tar -czf "/etc/yum.repos.d.bak.$(date +%F).tar.gz" /etc/yum.repos.d/ &>/dev/null
            if [[ "$version_info" == "8" ]]; then
                echo -e "${YELLOW}[INFO] 正在为 CentOS 8 (EOL) 配置官方归档源 (Vault)...${NC}"
                sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-* 2>/dev/null
                sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-* 2>/dev/null
                if [[ "$mirror" != *"vault.centos.org"* ]]; then
                    sed -i "s|vault.centos.org|$mirror|g" /etc/yum.repos.d/CentOS-* 2>/dev/null
                fi
            else
                echo -e "${YELLOW}[INFO] 正在为 CentOS $version_info 处理 Repo 替换...${NC}"
                sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-Base.repo 2>/dev/null
                sed -i "s|http://mirror.centos.org/centos|$mirror|g" /etc/yum.repos.d/CentOS-Base.repo 2>/dev/null
            fi
        else
            echo -e "${RED}无法识别发行版: $distro_id，请手动配置。${NC}"
            return 1
        fi

        echo -e "${GREEN}镜像源配置处理完成。${NC}"
        echo -e "${YELLOW}正在更新软件索引...${NC}"
        if command -v apt &>/dev/null; then
            apt update 2>&1 | tail -5
        elif command -v dnf &>/dev/null; then
            dnf makecache
        elif command -v yum &>/dev/null; then
            yum makecache
        fi
        return $?
    }

    while true; do
        clear
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}          镜像源管理 (子菜单)              ${NC}"
        echo -e "${GREEN}==============================================${NC}"

        # 当前源预览
        distro_info=$(_detect_distro)
        distro_id=${distro_info%%:*}
        version_info=${distro_info##*:}
        echo -e "  当前系统: ${YELLOW}$distro_id $version_info${NC}"
        echo -e "  当前备份文件:"
        ls /etc/apt/sources.list.bak.* 2>/dev/null | tail -3 | while read -r f; do echo "    $f"; done || echo "    (无备份)"
        echo -e "${GREEN}==============================================${NC}"

        if [[ "$distro_id" == "ubuntu" ]]; then
            echo " 1. 阿里云 Ubuntu 镜像源 (mirrors.aliyun.com)"
            echo " 2. 清华大学 Ubuntu 镜像源 (mirrors.tuna.tsinghua.edu.cn)"
            echo " 3. 中科大 Ubuntu 镜像源 (mirrors.ustc.edu.cn)"
            echo " 4. Ubuntu 官方源 (archive.ubuntu.com)"
        elif [[ "$distro_id" == "debian" ]]; then
            echo " 1. 阿里云 Debian 镜像源 (mirrors.aliyun.com)"
            echo " 2. 清华大学 Debian 镜像源 (mirrors.tuna.tsinghua.edu.cn)"
            echo " 3. 中科大 Debian 镜像源 (mirrors.ustc.edu.cn)"
            echo " 4. Debian 官方源 (deb.debian.org)"
        elif [[ "$distro_id" == "centos" ]]; then
            if [[ "$version_info" == "8" ]]; then
                echo " 1. 阿里云 CentOS 8 Vault 归档源 (mirrors.aliyun.com)"
                echo " 2. 清华大学 CentOS 8 Vault 归档源 (mirrors.tuna.tsinghua.edu.cn)"
                echo " 3. 中科大 CentOS 8 Vault 归档源 (mirrors.ustc.edu.cn)"
                echo " 4. 官方 CentOS 8 Vault (vault.centos.org)"
            else
                echo " 1. 阿里云 CentOS $version_info 镜像源 (mirrors.aliyun.com)"
                echo " 2. 清华大学 CentOS $version_info 镜像源 (mirrors.tuna.tsinghua.edu.cn)"
                echo " 3. 中科大 CentOS $version_info 镜像源 (mirrors.ustc.edu.cn)"
                echo " 4. 官方 CentOS $version_info 镜像源 (mirror.centos.org)"
            fi
        elif [[ "$distro_id" == "kylin-deb" || "$distro_id" == "kylin" ]] && command -v apt &>/dev/null; then
            echo " 1. 麒麟官方镜像源 (archive.kylinos.cn)"
            echo " 2. 华为云 麒麟镜像源 (mirrors.huaweicloud.com/kylin)"
            echo " 3. 阿里云 Ubuntu 镜像源 (兼容 APT 底座)"
            echo " 4. 清华大学 Ubuntu 镜像源 (兼容 APT 底座)"
        elif [[ "$distro_id" == "kylin" ]] && command -v rpm &>/dev/null; then
            echo " 1. 麒麟官方 RPM 镜像源 (archive.kylinos.cn/kylin/KYLIN-ALL)"
            echo " 2. 华为云 麒麟 RPM 镜像源 (mirrors.huaweicloud.com/kylin)"
            echo " 3. 中科大 麒麟镜像源 (mirrors.ustc.edu.cn)"
            echo " 4. 清华大学 麒麟镜像源 (mirrors.tuna.tsinghua.edu.cn)"
        elif [[ "$distro_id" == "uos" ]]; then
            echo " 1. 统信 UOS 官方源 (pools.uniontech.com/ppa/dde-eagle)"
            echo " 2. 华为云 UOS/Deepin 镜像源 (mirrors.huaweicloud.com/deepin)"
            echo " 3. 阿里云 Deepin 镜像源 (mirrors.aliyun.com/deepin)"
            echo " 4. 清华大学 Deepin 镜像源 (mirrors.tuna.tsinghua.edu.cn/deepin)"
        elif [[ "$distro_id" == "openeuler" ]]; then
            echo " 1. 华为云 openEuler 镜像源 (mirrors.huaweicloud.com/openeuler)"
            echo " 2. 阿里云 openEuler 镜像源 (mirrors.aliyun.com/openeuler)"
            echo " 3. 清华大学 openEuler 镜像源 (mirrors.tuna.tsinghua.edu.cn/openeuler)"
            echo " 4. openEuler 官方源 (repo.openeuler.org)"
        elif [[ "$distro_id" == "anolis" ]]; then
            echo " 1. 阿里云 Anolis OS 镜像源 (mirrors.aliyun.com/anolis)"
            echo " 2. 清华大学 Anolis OS 镜像源 (mirrors.tuna.tsinghua.edu.cn/anolis)"
            echo " 3. 中科大 Anolis OS 镜像源 (mirrors.ustc.edu.cn/anolis)"
            echo " 4. Anolis 官方源 (mirrors.openanolis.cn/anolis)"
        else
            echo " 1-4. (抱歉，未能识别系统类型: $distro_id)"
        fi
        echo " 5. 查看当前 sources.list 内容/Repo 列表"
        echo " 6. 还原项目备份的镜像配置"
        echo " 7. [Debian/Ubuntu] 仅禁用/移除 backports 源"
        echo " 0. 返回上层菜单"
        echo -e "${GREEN}==============================================${NC}"
        read -p "请选择操作 [0-7]: " mirror_choice

        case $mirror_choice in
            1)
                if [[ "$distro_id" == "ubuntu" ]]; then _write_source "http://mirrors.aliyun.com/ubuntu"
                elif [[ "$distro_id" == "debian" ]]; then _write_source "http://mirrors.aliyun.com/debian"
                elif [[ "$distro_id" == "centos" ]]; then
                    if [[ "$version_info" == "8" ]]; then _write_source "http://mirrors.aliyun.com/centos-vault"
                    else _write_source "http://mirrors.aliyun.com/centos"
                    fi
                elif [[ "$distro_id" == "kylin-deb" || "$distro_id" == "kylin" ]] && command -v apt &>/dev/null; then
                    _write_source "http://archive.kylinos.cn/kylin/KYLIN-ALL"
                elif [[ "$distro_id" == "kylin" ]] && command -v rpm &>/dev/null; then
                    _write_source "http://archive.kylinos.cn/kylin/KYLIN-ALL"
                elif [[ "$distro_id" == "uos" ]]; then _write_source "http://pools.uniontech.com/ppa/dde-eagle"
                elif [[ "$distro_id" == "openeuler" ]]; then _write_source "https://mirrors.huaweicloud.com/openeuler"
                elif [[ "$distro_id" == "anolis" ]]; then _write_source "http://mirrors.aliyun.com/anolis"
                fi
                read -p "按回车键继续..."
                ;;
            2)
                if [[ "$distro_id" == "ubuntu" ]]; then _write_source "http://mirrors.tuna.tsinghua.edu.cn/ubuntu"
                elif [[ "$distro_id" == "debian" ]]; then _write_source "http://mirrors.tuna.tsinghua.edu.cn/debian"
                elif [[ "$distro_id" == "centos" ]]; then
                    if [[ "$version_info" == "8" ]]; then _write_source "http://mirrors.tuna.tsinghua.edu.cn/centos-vault"
                    else _write_source "http://mirrors.tuna.tsinghua.edu.cn/centos"
                    fi
                elif [[ "$distro_id" == "kylin-deb" || "$distro_id" == "kylin" ]] && command -v apt &>/dev/null; then
                    _write_source "http://mirrors.huaweicloud.com/kylin"
                elif [[ "$distro_id" == "kylin" ]] && command -v rpm &>/dev/null; then
                    _write_source "http://mirrors.huaweicloud.com/kylin"
                elif [[ "$distro_id" == "uos" ]]; then _write_source "http://mirrors.huaweicloud.com/deepin"
                elif [[ "$distro_id" == "openeuler" ]]; then _write_source "https://mirrors.aliyun.com/openeuler"
                elif [[ "$distro_id" == "anolis" ]]; then _write_source "http://mirrors.tuna.tsinghua.edu.cn/anolis"
                fi
                read -p "按回车键继续..."
                ;;
            3)
                if [[ "$distro_id" == "ubuntu" ]]; then _write_source "http://mirrors.ustc.edu.cn/ubuntu"
                elif [[ "$distro_id" == "debian" ]]; then _write_source "http://mirrors.ustc.edu.cn/debian"
                elif [[ "$distro_id" == "centos" ]]; then
                    if [[ "$version_info" == "8" ]]; then _write_source "http://mirrors.ustc.edu.cn/centos-vault"
                    else _write_source "http://mirrors.ustc.edu.cn/centos"
                    fi
                elif [[ "$distro_id" == "kylin-deb" || "$distro_id" == "kylin" ]] && command -v apt &>/dev/null; then
                    _write_source "http://mirrors.aliyun.com/ubuntu"
                elif [[ "$distro_id" == "kylin" ]] && command -v rpm &>/dev/null; then
                    _write_source "http://mirrors.ustc.edu.cn"
                elif [[ "$distro_id" == "uos" ]]; then _write_source "http://mirrors.aliyun.com/deepin"
                elif [[ "$distro_id" == "openeuler" ]]; then _write_source "https://mirrors.tuna.tsinghua.edu.cn/openeuler"
                elif [[ "$distro_id" == "anolis" ]]; then _write_source "http://mirrors.ustc.edu.cn/anolis"
                fi
                read -p "按回车键继续..."
                ;;
            4)
                if [[ "$distro_id" == "ubuntu" ]]; then _write_source "http://archive.ubuntu.com/ubuntu"
                elif [[ "$distro_id" == "debian" ]]; then _write_source "http://deb.debian.org/debian"
                elif [[ "$distro_id" == "centos" ]]; then
                    if [[ "$version_info" == "8" ]]; then _write_source "http://vault.centos.org"
                    else _write_source "http://mirror.centos.org/centos"
                    fi
                elif [[ "$distro_id" == "kylin-deb" || "$distro_id" == "kylin" ]] && command -v apt &>/dev/null; then
                    _write_source "http://mirrors.tuna.tsinghua.edu.cn/ubuntu"
                elif [[ "$distro_id" == "kylin" ]] && command -v rpm &>/dev/null; then
                    _write_source "http://mirrors.tuna.tsinghua.edu.cn"
                elif [[ "$distro_id" == "uos" ]]; then _write_source "http://mirrors.tuna.tsinghua.edu.cn/deepin"
                elif [[ "$distro_id" == "openeuler" ]]; then _write_source "https://repo.openeuler.org"
                elif [[ "$distro_id" == "anolis" ]]; then _write_source "http://mirrors.openanolis.cn/anolis"
                fi
                read -p "按回车键继续..."
                ;;
            5)
                echo -e "\n${BLUE}--- /etc/apt/sources.list 内容 ---${NC}"
                cat /etc/apt/sources.list
                read -p "按回车键继续..."
                ;;
            6)
                # 还原备份文件
                mapfile -t BAK_FILES < <(ls /etc/apt/sources.list.bak.* 2>/dev/null | sort -r)
                if [ ${#BAK_FILES[@]} -eq 0 ]; then
                    echo -e "${RED}错误: 没有找到任何备份文件。${NC}"
                    read -p "按回车键继续..."
                    continue
                fi
                echo -e "\n${YELLOW}可用的备份文件:${NC}"
                for i in "${!BAK_FILES[@]}"; do
                    echo "  [$((i+1))] ${BAK_FILES[$i]}"
                done
                echo "  [0] 取消"
                read -p "请输入要还原的备份序号: " bak_idx
                if [[ "$bak_idx" == "0" || -z "$bak_idx" ]]; then
                    continue
                fi
                if ! [[ "$bak_idx" =~ ^[0-9]+$ ]] || [ "$bak_idx" -lt 1 ] || [ "$bak_idx" -gt "${#BAK_FILES[@]}" ]; then
                    echo -e "${RED}无效选择。${NC}"; sleep 1; continue
                fi
                SELECTED_BAK="${BAK_FILES[$((bak_idx-1))]}"
                cp "$SELECTED_BAK" /etc/apt/sources.list
                echo -e "${GREEN}已还原: $SELECTED_BAK -> /etc/apt/sources.list${NC}"
                echo -e "${YELLOW}正在执行 apt update 验证...${NC}"
                apt update 2>&1 | tail -5
                read -p "按回车键继续..."
                ;;
            7)
                # 仅移除 backports 行，保留其他配置
                if grep -q "backports" /etc/apt/sources.list; then
                    cp /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%F_%H%M%S)"
                    sed -i '/backports/d' /etc/apt/sources.list
                    echo -e "${GREEN}已删除包含 backports 的所有行。${NC}"
                    apt update 2>&1 | tail -5
                else
                    echo -e "${BLUE}提示: 当前 sources.list 中未检测到 backports 相关配置。${NC}"
                fi
                read -p "按回车键继续..."
                ;;
            0) break ;;
            *) echo -e "${RED}无效输入。${NC}"; sleep 1 ;;
        esac
    done
}

manage_disk_mount() {
    clear
    echo -e "${YELLOW}================ 硬盘信息与交互式挂载 ================${NC}"
    echo -e "${BLUE}当前存储设备列表 (排除 loop 设备):${NC}"
    lsblk -p -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -v 'loop'
    echo -e "--------------------------------------------------------"
    read -p "请输入要操作的磁盘名称 (如 /dev/sdb)，或输入 0 返回: " disk_name
    if [[ -z "$disk_name" || "$disk_name" == "0" ]]; then
        return
    fi

    if [ ! -b "$disk_name" ]; then
        echo -e "${RED}错误: 找不到指定的设备 $disk_name${NC}"
        sleep 2
        return
    fi
    
    # 检测是否已经挂载
    if lsblk -no MOUNTPOINT "$disk_name" | grep -q "/"; then
        echo -e "${RED}警告: 该设备或其分区已被挂载！请先卸载。${NC}"
        sleep 2
        return
    fi

    echo -e "\n${YELLOW}选项 1: 直接挂载已有文件系统的磁盘 (不格式化)${NC}"
    echo -e "${YELLOW}选项 2: 格式化为 ext4 并挂载 (将清空数据！)${NC}"
    read -p "请选择操作 [1/2, 输入其他返回]: " op_type
    
    if [[ "$op_type" == "2" ]]; then
        read -p "【危险】确定要格式化 $disk_name 为 ext4 吗？(格式化会清空数据) [y/N]: " confirm_format
        if [[ "$confirm_format" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}正在格式化 $disk_name 为 ext4...${NC}"
            mkfs.ext4 -F "$disk_name"
            if [ $? -ne 0 ]; then
                echo -e "${RED}错误: 格式化失败。${NC}"
                sleep 2
                return
            fi
            echo -e "${GREEN}格式化成功！${NC}"
        else
            echo -e "${BLUE}已取消格式化。${NC}"
            return
        fi
    elif [[ "$op_type" != "1" ]]; then
        return
    fi

    read -p "请输入挂载点目录 (例如 /data): " mount_point
    if [[ -z "$mount_point" ]]; then
        echo -e "${RED}挂载点不能为空。${NC}"; sleep 2; return
    fi
    
    if [ ! -d "$mount_point" ]; then
        mkdir -p "$mount_point"
        echo -e "${GREEN}已创建挂载点目录: $mount_point${NC}"
    fi

    # 获取 UUID
    UUID=$(blkid -s UUID -o value "$disk_name")
    if [[ -z "$UUID" ]]; then
        echo -e "${YELLOW}无法获取 UUID，将使用设备路径 $disk_name 挂载。${NC}"
        MOUNT_SRC="$disk_name"
    else
        MOUNT_SRC="UUID=$UUID"
    fi

    # 尝试挂载
    mount "$disk_name" "$mount_point"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}成功挂载 $disk_name 到 $mount_point${NC}"
        # 写入 fstab
        if ! grep -q "$mount_point" /etc/fstab; then
            echo "$MOUNT_SRC $mount_point ext4 defaults 0 0" >> /etc/fstab
            echo -e "${GREEN}已将挂载信息写入 /etc/fstab，实现开机自启。${NC}"
        else
            echo -e "${YELLOW}警告: /etc/fstab 中已存在关于 $mount_point 的配置，未重复写入。${NC}"
        fi
    else
        echo -e "${RED}挂载失败，请检查文件系统。${NC}"
    fi
    read -p "按回车键返回..."
}

manage_proxy_session() {
    while true; do
        clear
        echo -e "${YELLOW}================ 终端会话代理配置 ================${NC}"
        echo -e "${BLUE}>>> 当前脚本及终端会话代理状态 <<<${NC}"
        echo -e "HTTP_PROXY:  ${http_proxy:-未设置}"
        echo -e "HTTPS_PROXY: ${https_proxy:-未设置}"
        echo -e "ALL_PROXY:   ${all_proxy:-未设置}"
        echo -e "NO_PROXY:    ${no_proxy:-未设置}"
        echo -e "--------------------------------------------------------"
        echo -e "1. 增加/修改临时代理 (仅当前工具箱会话生效)"
        echo -e "2. 追加代理到 ~/.bashrc (对未来打开的终端生效)"
        echo -e "3. 清理当前及环境变量代理"
        echo -e "0. 返回"
        read -p "请选择操作 [0-3]: " proxy_choice

        case "$proxy_choice" in
            1|2)
                read -p "请输入代理地址 (如 http://192.168.1.100:7890): " proxy_addr
                if [[ -n "$proxy_addr" ]]; then
                    export http_proxy="$proxy_addr"
                    export https_proxy="$proxy_addr"
                    export all_proxy="$proxy_addr"
                    export no_proxy="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
                    echo -e "${GREEN}当前会话代理已更新为: $proxy_addr${NC}"
                    
                    if [[ "$proxy_choice" == "2" ]]; then
                        # 写入 .bashrc
                        sed -i '/# === Ops-Box Proxy ===/d' ~/.bashrc
                        sed -i '/export http_proxy=/d' ~/.bashrc
                        sed -i '/export https_proxy=/d' ~/.bashrc
                        sed -i '/export all_proxy=/d' ~/.bashrc
                        sed -i '/export no_proxy=/d' ~/.bashrc
                        echo "# === Ops-Box Proxy ===" >> ~/.bashrc
                        echo "export http_proxy=\"$proxy_addr\"" >> ~/.bashrc
                        echo "export https_proxy=\"$proxy_addr\"" >> ~/.bashrc
                        echo "export all_proxy=\"$proxy_addr\"" >> ~/.bashrc
                        echo "export no_proxy=\"localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16\"" >> ~/.bashrc
                        echo -e "${GREEN}已写入 ~/.bashrc，新终端登录将自动生效。${NC}"
                    fi
                else
                    echo -e "${RED}代理地址不能为空！${NC}"
                fi
                sleep 2
                ;;
            3)
                unset http_proxy https_proxy all_proxy no_proxy
                sed -i '/# === Ops-Box Proxy ===/d' ~/.bashrc
                sed -i '/export http_proxy=/d' ~/.bashrc
                sed -i '/export https_proxy=/d' ~/.bashrc
                sed -i '/export all_proxy=/d' ~/.bashrc
                sed -i '/export no_proxy=/d' ~/.bashrc
                echo -e "${GREEN}代理已彻底清除。${NC}"
                sleep 2
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}无效输入。${NC}"
                sleep 1
                ;;
        esac
    done
}


system_optimization_menu() {
    # 定义颜色常量 (如果外部未定义)
    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local RED='\033[0;31m'
    local BLUE='\033[0;34m'
    local NC='\033[0m'

    # Root 权限检查
    if [[ $EUID -ne 0 ]]; then
       echo -e "${RED}错误: 必须以 root 权限运行此脚本。${NC}"
       return 1
    fi

    while true; do
        clear
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}            系统环境优化 (二级菜单)            ${NC}"
        echo -e "${GREEN}==============================================${NC}"
        echo -e " 1. 镜像源管理 (阿里云/清华/中科大/官方/还原)"
        echo -e " 2. 🚀 Linux系统内核参数优化自动根据网络环境调优"
        echo -e " 3. 配置 2GB zRAM 虚拟内存 (高压缩比)"
        echo -e " 4. 清除 zRAM/Swap 所有相关配置"
        echo -e " 5. 获取硬盘信息并交互式挂载"
        echo -e " 6. 配置终端网络代理 (临时/全局直连)"
        echo -e " 7. 修复中文乱码 (locale/字体/编码一键修复)"
        echo -e " 0. 返回主菜单"
        echo -e "${GREEN}==============================================${NC}"
        read -p "请选择操作 [0-7]: " opt_choice

        case $opt_choice in
            1)
                manage_mirror_sources
                ;;
            2)
                local tune_script="${BASE_DIR:-/opt/ck_sysinit}/system/modules/network_tune.sh"
                if [ ! -f "$tune_script" ]; then
                    tune_script="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/network_tune.sh"
                fi
                if [ -f "$tune_script" ]; then
                    source "$tune_script"
                    network_tune_menu
                else
                    echo -e "${YELLOW}正在配置 BBR 加速...${NC}"
                    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
                        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
                        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
                        sysctl -p 2>/dev/null
                        echo -e "${GREEN}成功: BBR 已开启。${NC}"
                    else
                        echo -e "${BLUE}提示: BBR 似乎已经开启，无需重复操作。${NC}"
                    fi
                    read -p "按回车键继续..."
                fi
                ;;
            3)
                echo -e "${YELLOW}正在部署 zRAM 2GB 持久化方案...${NC}"
                if swapon --show | grep -q "/dev/zram0"; then
                    echo -e "${BLUE}提示: zRAM 已经在运行中。${NC}"
                else
                    # 创建初始化脚本
                    cat > /usr/local/bin/zram-init.sh <<EOF
#!/bin/bash
/sbin/modprobe zram num_devices=1
echo lzo > /sys/block/zram0/comp_algorithm
echo 2147483648 > /sys/block/zram0/disksize
/sbin/mkswap /dev/zram0
/sbin/swapon /dev/zram0 -p 10
EOF
                    chmod +x /usr/local/bin/zram-init.sh

                    # 创建 Systemd 服务
                    cat > /etc/systemd/system/zram-setup.service <<EOF
[Unit]
Description=Setup zRAM Swap
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/zram-init.sh

[Install]
WantedBy=multi-user.target
EOF
                    systemctl daemon-reload
                    systemctl enable --now zram-setup.service
                    echo -e "${GREEN}成功: 2GB zRAM 已开启并设置为开机自启。${NC}"
                fi
                sleep 2
                ;;
            4)
                echo -e "${YELLOW}正在彻底移除虚拟内存配置...${NC}"
                systemctl stop zram-setup.service 2>/dev/null
                systemctl disable zram-setup.service 2>/dev/null
                rm -f /etc/systemd/system/zram-setup.service
                rm -f /usr/local/bin/zram-init.sh
                swapoff /dev/zram0 2>/dev/null
                modprobe -r zram 2>/dev/null
                systemctl daemon-reload
                echo -e "${GREEN}成功: 配置已清除。${NC}"
                sleep 2
                ;;
            5)
                manage_disk_mount
                ;;
            6)
                manage_proxy_session
                ;;
            7)
                fix_chinese_locale
                ;;
            0)
                echo -e "${BLUE}返回中...${NC}"
                break
                ;;
            *)
                echo -e "${RED}输入有误，请输入 0-7 之间的数字。${NC}"
                sleep 1
                ;;
        esac
    done
}

# ========== 中文乱码修复模块 ==========
fix_chinese_locale() {
    clear
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}      中文乱码一键修复 (Locale / 字体 / 编码)         ${NC}"
    echo -e "${GREEN}======================================================${NC}"

    # ---- 1. 检测当前 locale 状态 ----
    echo -e "\n${BLUE}[1/5] 正在检测当前 locale 配置...${NC}"
    CURRENT_LANG=$(locale 2>/dev/null | grep 'LANG=' | cut -d= -f2 | tr -d '"')
    echo -e "  当前 LANG 值: ${YELLOW}${CURRENT_LANG:-未设置}${NC}"

    if [[ "$CURRENT_LANG" == "zh_CN.UTF-8" ]]; then
        echo -e "  ${GREEN}✓ LANG 已正确设置为 zh_CN.UTF-8${NC}"
    else
        echo -e "  ${YELLOW}⚠ LANG 未正确设置，将进行修复...${NC}"
    fi

    # ---- 2. 按包管理器分发处理 ----
    echo -e "\n${BLUE}[2/5] 正在检测系统发行版与包管理器...${NC}"
    case "$PKG_MGR" in
        apt)
            echo -e "  检测到 Debian/Ubuntu 系列，使用 apt 处理...${NC}"

            echo -e "\n${BLUE}[3/5] 正在更新软件索引...${NC}"
            apt update -qq 2>&1 | tail -3

            echo -e "\n${BLUE}[4/5] 正在安装中文 locale 支持包与字体...${NC}"
            # 安装 locales 基础库
            if ! dpkg -l locales &>/dev/null; then
                apt install -y locales
            fi

            # Ubuntu 系列额外安装语言包
            if grep -qi ubuntu /etc/os-release 2>/dev/null; then
                apt install -y language-pack-zh-hans 2>/dev/null || true
            fi

            # 安装中文字体 (Noto CJK)
            echo -e "  ⏳ 正在安装 Noto CJK 中文字体包...${NC}"
            apt install -y fonts-noto-cjk 2>/dev/null || \
                apt install -y fonts-wqy-zenhei fonts-wqy-microhei 2>/dev/null || \
                echo -e "  ${YELLOW}⚠ 字体包安装失败，跳过（不影响终端 locale 修复）${NC}"

            # 生成 zh_CN.UTF-8 locale
            echo -e "\n  ⏳ 正在生成 zh_CN.UTF-8 locale...${NC}"
            if ! locale -a 2>/dev/null | grep -qi 'zh_CN.utf8'; then
                # 确保 locale.gen 中取消注释
                if [ -f /etc/locale.gen ]; then
                    sed -i 's/^# *zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen
                    # 若不存在则追加
                    grep -q 'zh_CN.UTF-8' /etc/locale.gen || echo 'zh_CN.UTF-8 UTF-8' >> /etc/locale.gen
                fi
                locale-gen zh_CN.UTF-8 2>&1
                update-locale LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 2>/dev/null
            else
                echo -e "  ${GREEN}✓ zh_CN.UTF-8 locale 已存在，跳过生成。${NC}"
            fi
            ;;

        dnf|yum)
            echo -e "  检测到 RHEL/CentOS/Fedora 系列...${NC}"

            echo -e "\n${BLUE}[3/5] 安装中文 locale 与字体支持...${NC}"
            # 安装 glibc-langpack-zh 提供 zh_CN.UTF-8
            $PKG_INSTALL glibc-langpack-zh 2>&1
            # 安装开源中文字体
            $PKG_INSTALL google-noto-cjk-fonts 2>/dev/null || \
                $PKG_INSTALL wqy-zenhei-fonts 2>/dev/null || true
            echo -e "  locale 安装完毕。"
            ;;

        apk)
            echo -e "  检测到 Alpine Linux...${NC}"
            echo -e "\n${BLUE}[3/5] 正在安装 musl-locales 与字体...${NC}"
            apk add --no-cache musl-locales musl-locales-lang font-noto-cjk 2>/dev/null || \
                apk add --no-cache font-noto 2>/dev/null || true
            ;;

        *)
            echo -e "${RED}[!] 未能识别当前包管理器，仅执行 locale 环境变量写入。${NC}"
            ;;
    esac

    # ---- 5. 全局写入 locale 环境变量 (所有发行版通用) ----
    echo -e "\n${BLUE}[5/5] 正在将 zh_CN.UTF-8 写入全局环境配置...${NC}"

    # /etc/default/locale (Debian/Ubuntu 标准路径)
    if [ -d /etc/default ]; then
        cat > /etc/default/locale <<EOF
LANG=zh_CN.UTF-8
LANGUAGE=zh_CN:zh
LC_ALL=zh_CN.UTF-8
EOF
        echo -e "  ${GREEN}✓ 已写入 /etc/default/locale${NC}"
    fi

    # /etc/environment (跨发行版兼容)
    if [ -f /etc/environment ]; then
        sed -i '/^LANG=/d; /^LANGUAGE=/d; /^LC_ALL=/d' /etc/environment
    fi
    cat >> /etc/environment <<EOF
LANG=zh_CN.UTF-8
LANGUAGE=zh_CN:zh
LC_ALL=zh_CN.UTF-8
EOF
    echo -e "  ${GREEN}✓ 已写入 /etc/environment${NC}"

    # /etc/profile.d/ 方式 (CentOS/Fedora/Alpine 兜底)
    cat > /etc/profile.d/locale-zh.sh <<EOF
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8
export LESSCHARSET=utf-8
EOF
    chmod +x /etc/profile.d/locale-zh.sh
    echo -e "  ${GREEN}✓ 已写入 /etc/profile.d/locale-zh.sh${NC}"

    # 刷新字体缓存 (如果 fc-cache 存在)
    if command -v fc-cache &>/dev/null; then
        echo -e "  ⏳ 正在刷新字体缓存...${NC}"
        fc-cache -fv &>/dev/null
        echo -e "  ${GREEN}✓ 字体缓存已刷新${NC}"
    fi

    echo -e "\n${GREEN}=======================================================${NC}"
    echo -e "${GREEN}✅ 中文字体与 locale 配置修复完成！${NC}"
    echo -e "${YELLOW}  > 当前会话重载: source /etc/profile.d/locale-zh.sh${NC}"
    echo -e "${YELLOW}  > 重新 SSH 登录或重启服务器后全面生效。${NC}"
    echo -e "${GREEN}=======================================================${NC}"
    read -p "按回车键返回..."
}

# ========== 网络 IP 配置模块 ==========

# ================================================================
# 辅助: 定位 download_offline_packages.sh
# 覆盖所有已知部署路径，返回首个找到的完整路径
# ================================================================
_find_dl_script() {
    local _script_name="download_offline_packages.sh"
    # 候选路径列表 (按优先级排序)
    local _candidates=(
        # 1. BASE_DIR 指向 system_init.sh 所在目录（最常见）
        "${BASE_DIR:-}"
        # 2. 标准安装路径 /opt/ck_sysinit
        "/opt/ck_sysinit"
        # 3. system_opt.sh 的父目录（system/modules/ -> system/）
        "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.."
        # 4. system_opt.sh 的同级目录（振错兼容）
        "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")"
        # 5. 当前工作目录子目录（开发阶段直运行时）
        "$PWD/system"
        "$PWD"
    )
    for _c in "${_candidates[@]}"; do
        [ -z "$_c" ] && continue
        if [ -f "${_c}/${_script_name}" ]; then
            echo "${_c}/${_script_name}"
            return 0
        fi
    done
    return 1
}

# ================================================================
# 辅助: 无依赖网络连通性探测
# 优先用 Bash 内置 /dev/tcp (零依赖)，兼顾国内与国际网络节点
# 返回 0=有网  1=无网
# ================================================================
_check_net_available() {
    local timeout=2
    # 优先测试国内高可用 DNS 节点（阿里 DNS 223.5.5.5 / 腾讯 DNS 119.29.29.29）
    if (exec 9<>/dev/tcp/223.5.5.5/53) 2>/dev/null; then
        exec 9>&- 2>/dev/null
        return 0
    fi
    if (exec 9<>/dev/tcp/119.29.29.29/53) 2>/dev/null; then
        exec 9>&- 2>/dev/null
        return 0
    fi
    # 备选测试国际公共节点（Cloudflare / Google）
    if (exec 9<>/dev/tcp/1.1.1.1/80) 2>/dev/null; then
        exec 9>&- 2>/dev/null
        return 0
    fi
    if (exec 9<>/dev/tcp/8.8.8.8/53) 2>/dev/null; then
        exec 9>&- 2>/dev/null
        return 0
    fi
    # ping 降级兜底测试
    if ping -c1 -W${timeout} 223.5.5.5 &>/dev/null 2>&1 || \
       ping -c1 -W${timeout} 119.29.29.29 &>/dev/null 2>&1 || \
       ping -c1 -W${timeout} 1.1.1.1 &>/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# ================================================================
# 子功能 1: 采集离线安装包 (需联网, 供无网服务器使用)
# ================================================================
_collect_offline_packages() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}      📦 采集离线安装包到本地 (system/packages)       ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${BLUE}说明: 本操作需要在【有网络】的机器上执行，"
    echo -e "  下载的离线包可随工具箱一起拷贝至无网服务器使用。${NC}"
    echo ""
    # 网络检测
    if _check_net_available; then
        echo -e "${GREEN}✓ 网络连通，开始采集离线包...${NC}"
        echo ""
        local _dl_script
        _dl_script=$(_find_dl_script)
        if [ -n "$_dl_script" ]; then
            bash "$_dl_script"
        else
            echo -e "${RED}✗ 未找到 download_offline_packages.sh${NC}"
            echo -e "  搜索过: ${BASE_DIR:-未知} / /opt/ck_sysinit / 当前目录"
            echo -e "  ${YELLOW}[解决] 请重新安装工具箱完整同步最新版本。${NC}"
        fi
    else
        echo -e "${RED}✗ 当前网络不可达，无法采集离线包！${NC}"
        echo -e "  ${YELLOW}请在有网络的同型号/同架构机器上执行此操作。${NC}"
    fi
    echo ""
    read -p "按回车键继续..." -r < /dev/tty
}

# ================================================================
# 子功能 2: 常用基础软件管理看板 (Kejilion 风格: 状态矩阵/单独/批量/一键安装/卸载)
# ================================================================
_direct_install_online_tools() {
    # 常用基础软件元数据定义 (编号|名称|检测命令|apt包名|yum/dnf包名|apk包名|说明)
    local TOOLS_DEF=(
        "1|curl|curl|curl|curl|curl|网络请求传输"
        "2|wget|wget|wget|wget|wget|文件下载工具"
        "3|openssh-server|sshd|openssh-server|openssh-server openssh-clients|openssh|SSH远程服务"
        "4|vim|vim|vim|vim-enhanced|vim|全功能编辑器"
        "5|nano|nano|nano|nano|nano|轻量文本编辑"
        "6|git|git|git|git|git|版本控制工具"
        "7|htop|htop|htop|htop|htop|交互进程监控"
        "8|net-tools|netstat|net-tools|net-tools|net-tools|网络诊断netstat"
        "9|lsof|lsof|lsof|lsof|lsof|端口文件查看"
        "10|socat|socat|socat|socat|socat|端口管道转发"
        "11|tar|tar|tar|tar|tar|标准归档解包"
        "12|unzip/zip|unzip|unzip zip|unzip zip|unzip zip|ZIP解压压缩"
        "13|cron|crontab|cron|cronie|cronie|定时任务调度"
        "14|dnsutils|dig|dnsutils|bind-utils|bind-tools|DNS诊断dig"
        "15|iputils-ping|ping|iputils-ping|iputils|iputils|网络Ping探测"
        "16|sudo|sudo|sudo|sudo|sudo|管理员提权"
        "17|bash-completion|bash-comp|bash-completion|bash-completion|bash-completion|命令自动补全"
        "18|openssl|openssl|openssl|openssl|openssl|SSL证书工具"
        "19|tmux|tmux|tmux|tmux|tmux|终端会话复用"
        "20|rsync|rsync|rsync|rsync|rsync|增量文件同步"
        "21|tree|tree|tree|tree|tree|目录树形展示"
        "22|jq|jq|jq|jq|jq|命令行JSON处理"
    )

    # 检查命令是否存在函数
    _is_tool_installed() {
        local check_cmd="$1"
        case "$check_cmd" in
            sshd)
                command -v sshd &>/dev/null || command -v ssh &>/dev/null
                ;;
            bash-comp)
                [ -f /usr/share/bash-completion/bash_completion ] || [ -f /etc/bash_completion ] || command -v bash &>/dev/null
                ;;
            *)
                command -v "$check_cmd" &>/dev/null
                ;;
        esac
    }

    # 获取当前包管理器对应的安装包名称
    _get_pkg_names() {
        local apt_pkg="$1"
        local yum_pkg="$2"
        local apk_pkg="$3"
        case "$PKG_MGR" in
            apt)     echo "$apt_pkg" ;;
            dnf|yum) echo "$yum_pkg" ;;
            apk)     echo "$apk_pkg" ;;
            *)       echo "$apt_pkg" ;;
        esac
    }

    # 获取当前系统的包管理安装/卸载命令
    local install_cmd="${PKG_INSTALL:-}"
    if [ -z "$install_cmd" ]; then
        case "$PKG_MGR" in
            apt)     install_cmd="apt install -y" ;;
            dnf)     install_cmd="dnf install -y" ;;
            yum)     install_cmd="yum install -y" ;;
            apk)     install_cmd="apk add" ;;
            *)       install_cmd="apt install -y" ;;
        esac
    fi

    local remove_cmd=""
    case "$PKG_MGR" in
        apt)     remove_cmd="apt purge -y" ;;
        dnf)     remove_cmd="dnf remove -y" ;;
        yum)     remove_cmd="yum remove -y" ;;
        apk)     remove_cmd="apk del" ;;
        *)       remove_cmd="" ;;
    esac

    # 主循环看板
    while true; do
        clear
        echo -e "${CYAN}========================================================================${NC}"
        echo -e "${CYAN}             🚀 常用基础运维软件管理看板 (Kejilion 矩阵风格)          ${NC}"
        echo -e "${CYAN}========================================================================${NC}"
        echo -e " 系统发行版: ${GREEN}${DISTRO_NAME:-未知}${NC}  |  包管理器: ${CYAN}${PKG_MGR:-未知}${NC}  |  网络探测: $(_check_net_available && echo -e "${GREEN}正常联网${NC}" || echo -e "${RED}网络受限${NC}")"
        echo -e "${CYAN}------------------------------------------------------------------------${NC}"

        # 预先检测各工具状态
        local total_tools=${#TOOLS_DEF[@]}
        local installed_flags=()
        local installed_count=0

        for ((i=0; i<total_tools; i++)); do
            IFS='|' read -r id name check_cmd apt_p yum_p apk_p desc <<< "${TOOLS_DEF[$i]}"
            if _is_tool_installed "$check_cmd"; then
                installed_flags[$i]=1
                ((installed_count++))
            else
                installed_flags[$i]=0
            fi
        done

        # 双列输出矩阵 (左侧 1..11, 右侧 12..22)
        local half=$(( (total_tools + 1) / 2 ))
        for ((i=0; i<half; i++)); do
            # 左列项
            IFS='|' read -r l_id l_name l_check l_apt l_yum l_apk l_desc <<< "${TOOLS_DEF[$i]}"
            local l_status_text=""
            if [ "${installed_flags[$i]}" -eq 1 ]; then
                l_status_text="${GREEN}[✔已装]${NC}"
            else
                l_status_text="${RED}[✗未装]${NC}"
            fi
            local left_col
            printf -v left_col " %2d. %-14s %b  %-12s" "$l_id" "$l_name" "$l_status_text" "$l_desc"

            # 右列项
            local right_idx=$((i + half))
            local right_col=""
            if [ $right_idx -lt $total_tools ]; then
                IFS='|' read -r r_id r_name r_check r_apt r_yum r_apk r_desc <<< "${TOOLS_DEF[$right_idx]}"
                local r_status_text=""
                if [ "${installed_flags[$right_idx]}" -eq 1 ]; then
                    r_status_text="${GREEN}[✔已装]${NC}"
                else
                    r_status_text="${RED}[✗未装]${NC}"
                fi
                printf -v right_col " %2d. %-14s %b  %-12s" "$r_id" "$r_name" "$r_status_text" "$r_desc"
            fi

            echo -e "${left_col}  │  ${right_col}"
        done

        echo -e "${CYAN}------------------------------------------------------------------------${NC}"
        echo -e " 软件总计: ${total_tools} 个  |  已就绪: ${GREEN}${installed_count}${NC} 个  |  待安装: ${YELLOW}$((total_tools - installed_count))${NC} 个"
        echo -e "${CYAN}========================================================================${NC}"
        echo -e " ${GREEN}[操作指令]${NC}"
        echo -e "  • ${CYAN}[编号]${NC}      单选或多选安装 (例: ${YELLOW}3${NC} 或 ${YELLOW}1 3 7 19 22${NC})"
        echo -e "  • ${CYAN}a${NC} / ${CYAN}all${NC}   一键安装/补齐全量 22 项常用组件"
        echo -e "  • ${CYAN}u <编号>${NC}  卸载指定软件 (例: ${YELLOW}u 7${NC} 卸载 htop)"
        echo -e "  • ${CYAN}r${NC}          重新检测并刷新当前看板状态"
        echo -e "  • ${CYAN}0${NC}          返回上级菜单"
        echo -e "${CYAN}========================================================================${NC}"
        read -p "请输入指令: " action_input < /dev/tty

        case "$action_input" in
            0)
                break
                ;;
            r|R|"")
                continue
                ;;
            a|all|ALL)
                echo ""
                echo -e "${BLUE}=== 正在执行全量常用基础软件安装 ===${NC}"
                if ! _check_net_available; then
                    echo -e "${RED}✗ 网络检测未通过，请检查网络设置或使用本地离线包。${NC}"
                    read -p "按回车键继续..." -r < /dev/tty
                    continue
                fi
                if ! _check_disk_space 2048 /var; then
                    continue
                fi
                if [ "$PKG_MGR" = "apt" ]; then
                    echo -e "${YELLOW}⏳ 正在更新软件源索引...${NC}"
                    apt update -y 2>/dev/null || true
                fi
                # 拼接全量包名
                local all_pkgs=""
                for ((k=0; k<total_tools; k++)); do
                    IFS='|' read -r _id _name _chk _apt _yum _apk _desc <<< "${TOOLS_DEF[$k]}"
                    local pkg_for_sys
                    pkg_for_sys=$(_get_pkg_names "$_apt" "$_yum" "$_apk")
                    all_pkgs="$all_pkgs $pkg_for_sys"
                done
                echo -e "安装包列表: ${CYAN}${all_pkgs}${NC}"
                $install_cmd $all_pkgs
                echo -e "${GREEN}✅ 全量安装指令执行完毕。${NC}"
                read -p "按回车键刷新看板..." -r < /dev/tty
                ;;
            u\ *|U\ *)
                # 卸载逻辑
                local target_id="${action_input#* }"
                target_id=$(echo "$target_id" | xargs)
                if ! [[ "$target_id" =~ ^[0-9]+$ ]] || [ "$target_id" -lt 1 ] || [ "$target_id" -gt "$total_tools" ]; then
                    echo -e "${RED}错误: 无效的软件编号 '$target_id'${NC}"
                    sleep 1.5
                    continue
                fi
                local target_idx=$((target_id - 1))
                IFS='|' read -r u_id u_name u_chk u_apt u_yum u_apk u_desc <<< "${TOOLS_DEF[$target_idx]}"
                local u_pkgs
                u_pkgs=$(_get_pkg_names "$u_apt" "$u_yum" "$u_apk")

                # 高危防护判断 (ssh, sudo, bash)
                if [ "$u_name" = "sudo" ] || [ "$u_name" = "openssh-server" ] || [ "$u_name" = "tar" ]; then
                    echo -e "${RED}⚠️ 高危警告: 卸载 [${u_name}] 可能导致远程无法登录或关键权限丢失！${NC}"
                    read -p "确定仍要继续卸载吗？(输入 yes 确认): " confirm_u < /dev/tty
                    if [ "$confirm_u" != "yes" ]; then
                        echo -e "${YELLOW}已取消卸载。${NC}"
                        sleep 1.5
                        continue
                    fi
                else
                    read -p "确认卸载 [${u_name}] (${u_pkgs}) 吗？[y/N]: " confirm_u < /dev/tty
                    if [[ ! "$confirm_u" =~ ^[Yy]$ ]]; then
                        echo -e "${YELLOW}已取消卸载。${NC}"
                        sleep 1
                        continue
                    fi
                fi

                echo -e "${YELLOW}正在卸载 ${u_name} (${u_pkgs})...${NC}"
                if [ -n "$remove_cmd" ]; then
                    $remove_cmd $u_pkgs
                    echo -e "${GREEN}卸载操作执行完毕。${NC}"
                else
                    echo -e "${RED}错误: 当前包管理器不支持自动卸载。${NC}"
                fi
                read -p "按回车键刷新看板..." -r < /dev/tty
                ;;
            *)
                # 单选或多选安装 (解析输入的多个数字)
                local selected_ids=($action_input)
                local valid_install_pkgs=""
                local valid_count=0

                for sid in "${selected_ids[@]}"; do
                    if [[ "$sid" =~ ^[0-9]+$ ]] && [ "$sid" -ge 1 ] && [ "$sid" -le "$total_tools" ]; then
                        local s_idx=$((sid - 1))
                        IFS='|' read -r s_id s_name s_chk s_apt s_yum s_apk s_desc <<< "${TOOLS_DEF[$s_idx]}"
                        local s_pkg
                        s_pkg=$(_get_pkg_names "$s_apt" "$s_yum" "$s_apk")
                        valid_install_pkgs="$valid_install_pkgs $s_pkg"
                        ((valid_count++))
                    fi
                done

                if [ "$valid_count" -eq 0 ]; then
                    echo -e "${RED}输入无法识别，请输入正确的软件编号或命令（输入 0 返回）。${NC}"
                    sleep 1.5
                    continue
                fi

                echo ""
                echo -e "${BLUE}=== 正在安装选中的软件组件 (${valid_count}项) ===${NC}"
                if ! _check_net_available; then
                    echo -e "${RED}✗ 网络检测未通过，无法进行在线安装！${NC}"
                    read -p "按回车键继续..." -r < /dev/tty
                    continue
                fi
                if ! _check_disk_space 512 /var; then
                    continue
                fi

                if [ "$PKG_MGR" = "apt" ]; then
                    echo -e "${YELLOW}⏳ 正在更新软件源索引...${NC}"
                    apt update -y 2>/dev/null || true
                fi

                echo -e "正在执行安装: ${CYAN}${valid_install_pkgs}${NC}"
                $install_cmd $valid_install_pkgs
                local ins_code=$?
                echo ""
                if [ $ins_code -eq 0 ]; then
                    echo -e "${GREEN}✅ 软件安装成功！${NC}"
                else
                    echo -e "${YELLOW}⚠️ 安装退出代码为 ${ins_code}，请检查包管理器输出或源配置。${NC}"
                fi
                read -p "按回车键刷新看板..." -r < /dev/tty
                ;;
        esac
    done
}

# ================================================================
# 子功能 3: 本地离线安装常用专家工具集 (供无网服务器部署)
# ================================================================
_install_offline_packages_local() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}       💾 本地离线安装常用工具集 (离线环境专用)       ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "当前系统类型: ${GREEN}${DISTRO_NAME:-未知}${NC} (包管理器: ${CYAN}${PKG_MGR:-未知}${NC})"
    echo ""

    # 搜索本地 packages/ 目录
    echo -e "${BLUE}[1/2] 正在搜索本地 packages/ 目录...${NC}"
    local pkg_dir=""
    for d in "$BASE_DIR/packages" "/opt/ck_sysinit/packages" \
             "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../packages" \
             "$PWD/system/packages" "$PWD/packages"; do
        if [ -d "$d" ]; then
            pkg_dir="$d"
            break
        fi
    done

    local has_local_pkg=false
    if [ -n "$pkg_dir" ]; then
        if command -v dpkg &>/dev/null; then
            local deb_source=""
            if [ -d "$pkg_dir/deb" ] && ls "$pkg_dir/deb"/*.deb &>/dev/null 2>&1; then
                deb_source="$pkg_dir/deb"
            elif ls "$pkg_dir"/*.deb &>/dev/null 2>&1; then
                deb_source="$pkg_dir"
            fi
            if [ -n "$deb_source" ]; then
                has_local_pkg=true
                local deb_count
                deb_count=$(ls "$deb_source"/*.deb 2>/dev/null | wc -l)
                echo -e "${GREEN}✓ 发现本地 DEB 离线安装包: ${CYAN}${deb_source}${NC} (共 ${deb_count} 个)"
                echo -e "⏳ 正在执行 dpkg -i 离线批量安装..."
                dpkg -i "$deb_source"/*.deb 2>/dev/null || apt-get install -f -y 2>/dev/null || true
                echo -e "${GREEN}✅ 离线 DEB 组件安装/升级完成！${NC}"
            fi
        elif command -v rpm &>/dev/null; then
            local rpm_source=""
            if [ -d "$pkg_dir/rpm" ] && ls "$pkg_dir/rpm"/*.rpm &>/dev/null 2>&1; then
                rpm_source="$pkg_dir/rpm"
            elif ls "$pkg_dir"/*.rpm &>/dev/null 2>&1; then
                rpm_source="$pkg_dir"
            fi
            if [ -n "$rpm_source" ]; then
                has_local_pkg=true
                local rpm_count
                rpm_count=$(ls "$rpm_source"/*.rpm 2>/dev/null | wc -l)
                echo -e "${GREEN}✓ 发现本地 RPM 离线安装包: ${CYAN}${rpm_source}${NC} (共 ${rpm_count} 个)"
                echo -e "⏳ 正在执行 rpm 离线批量安装..."
                rpm -Uvh --replacepkgs --nodeps "$rpm_source"/*.rpm 2>/dev/null || true
                echo -e "${GREEN}✅ 离线 RPM 组件安装/升级完成！${NC}"
            fi
        fi
    fi

    if [ "$has_local_pkg" = false ]; then
        echo -e "${RED}✗ 未找到任何本地离线安装包！${NC}"
        echo ""
        echo -e "${YELLOW}📋 使用指引：${NC}"
        echo -e "  1. 请先在【有网络】的同架构机器上运行此工具箱；"
        echo -e "  2. 进入「3. 常用专家工具集安装」并选择「1. 采集离线安装包」；"
        echo -e "  3. 将采集生成的 packages/ 目录随工具箱一起拷贝回本机；"
        echo -e "  4. 再次执行此选项即可完成一键离线部署。"
    else
        # 状态自检
        echo ""
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${GREEN}[2/2] 常用命令状态自检:${NC}"
        for cmd in curl openssl lsof socat tar wget crontab dig nano vim git htop netstat unzip zip ssh; do
            if command -v "$cmd" &>/dev/null; then
                printf "  %-12s: ${GREEN}[已就绪]${NC}\n" "$cmd"
            else
                printf "  %-12s: ${RED}[未安装]${NC}\n" "$cmd"
            fi
        done
        echo -e "${CYAN}======================================================${NC}"
    fi
    echo ""
    read -p "按回车键继续..." -r < /dev/tty
}

# ================================================================
# 子功能 4: Mise 多运行时环境管理
# (Mise 安装/配置/版本查看/管理 Java, Node.js, Go, Python)
# ================================================================

# 确保 mise 命令在当前环境中可用
_ensure_mise_env() {
    if ! command -v mise &>/dev/null; then
        if [ -x "/usr/local/bin/mise" ]; then
            export PATH="/usr/local/bin:$PATH"
        elif [ -x "$HOME/.local/bin/mise" ]; then
            export PATH="$HOME/.local/bin:$PATH"
        fi
    fi
    if [ -d "$HOME/.local/share/mise/shims" ]; then
        case ":$PATH:" in
            *":$HOME/.local/share/mise/shims:"*) ;;
            *) export PATH="$HOME/.local/share/mise/shims:$PATH" ;;
        esac
    fi
    if command -v mise &>/dev/null; then
        eval "$(mise activate bash 2>/dev/null)" || true
    fi
}

# 1. 安装或更新 Mise
_mise_install_core() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}         🚀 安装 / 更新 Mise 多运行时管理器           ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    _ensure_mise_env

    if command -v mise &>/dev/null; then
        local cur_ver
        cur_ver=$(mise --version 2>/dev/null || echo "未知")
        echo -e "${GREEN}检测到 Mise 已安装: ${CYAN}${cur_ver}${NC}"
        echo ""
        read -p "是否尝试在线更新 Mise 至最新版? [y/N]: " update_choice < /dev/tty
        if [[ "$update_choice" =~ ^[Yy]$ ]]; then
            echo -e "⏳ 正在执行 mise self-update..."
            if mise self-update -y 2>/dev/null || mise self-update 2>/dev/null; then
                echo -e "${GREEN}✅ Mise 自更新成功！${NC}"
            else
                echo -e "${YELLOW}自更新返回异常，尝试使用官方安装脚本覆写更新...${NC}"
                curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh
            fi
        else
            echo -e "${BLUE}已取消更新。${NC}"
            read -p "按回车键继续..." -r < /dev/tty
            return 0
        fi
    else
        echo -e "${BLUE}[1/3] 正在检测网络与基础依赖...${NC}"
        if ! _check_net_available; then
            echo -e "${RED}✗ 网络不可达，Mise 需要网络连接下载二进制文件！${NC}"
            read -p "按回车键返回..." -r < /dev/tty
            return 1
        fi

        # 补齐必备基础依赖 curl / tar / git / sudo
        if ! command -v curl &>/dev/null || ! command -v tar &>/dev/null || ! command -v git &>/dev/null; then
            echo -e "${YELLOW}⏳ 正在安装必备依赖 (curl, tar, git)...${NC}"
            case "$PKG_MGR" in
                apt)     apt-get update -y 2>/dev/null; apt-get install -y curl tar git sudo ;;
                dnf|yum) $PKG_INSTALL curl tar git sudo ;;
                apk)     apk add curl tar git sudo ;;
            esac
        fi

        echo -e "${BLUE}[2/3] 正在下载并安装 Mise 核心程序到 /usr/local/bin/mise...${NC}"
        local install_success=false

        # 尝试标准官方渠道
        if curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh; then
            install_success=true
        else
            echo -e "${YELLOW}官方直接通道拉取失败，尝试使用 GitHub 加速镜像拉取...${NC}"
            if curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/jdx/mise/main/packaging/standalone/install.sh | MISE_INSTALL_PATH=/usr/local/bin/mise sh; then
                install_success=true
            fi
        fi

        if [ "$install_success" = false ] && [ ! -x "/usr/local/bin/mise" ] && [ ! -x "$HOME/.local/bin/mise" ]; then
            echo -e "${RED}❌ Mise 安装失败，请检查服务器对 GitHub / mise.jdx.dev 的网络连通性。${NC}"
            read -p "按回车键返回..." -r < /dev/tty
            return 1
        fi

        if [ -x "/usr/local/bin/mise" ]; then
            chmod +x /usr/local/bin/mise
        fi
        echo -e "${GREEN}✓ Mise 核心程序下载并部署成功！${NC}"
    fi

    # 自动配置全局 Profile 与 Shell 激活
    echo -e "${BLUE}[3/3] 正在配置系统级 Shell 激活与环境变量...${NC}"
    cat > /etc/profile.d/mise.sh << 'EOF'
# Mise Environment Loader
export PATH="/usr/local/bin:$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
if command -v mise &>/dev/null; then
    eval "$(mise activate bash 2>/dev/null)"
fi
EOF
    chmod 644 /etc/profile.d/mise.sh

    # 用户级 ~/.bashrc 兜底保证
    if ! grep -q "mise activate bash" "$HOME/.bashrc" 2>/dev/null; then
        echo -e '\n# Mise activation\nexport PATH="/usr/local/bin:$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"' >> "$HOME/.bashrc"
        echo 'if command -v mise &>/dev/null; then eval "$(mise activate bash 2>/dev/null)"; fi' >> "$HOME/.bashrc"
    fi

    _ensure_mise_env
    echo ""
    local final_ver
    final_ver=$(mise --version 2>/dev/null || echo "已就绪")
    echo -e "${GREEN}✅ Mise 安装与初始化完成！当前版本: ${CYAN}${final_ver}${NC}"
    echo -e "${YELLOW}提示: 环境变量已写入 /etc/profile.d/mise.sh 及 ~/.bashrc，全局会话自动激活。${NC}"
    echo ""
    read -p "按回车键继续..." -r < /dev/tty
}

# 2. 配置 Mise 与国内镜像加速
_mise_config_env() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}         ⚙️  配置 Mise 环境与语言镜像加速源           ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    _ensure_mise_env

    if ! command -v mise &>/dev/null; then
        echo -e "${RED}错误: 未检测到 Mise，请先执行选项 1 安装 Mise。${NC}"
        read -p "按回车键返回..." -r < /dev/tty
        return 1
    fi

    echo -e "请选择需要配置的加速与环境选项:"
    echo -e " 1. 🚀 配置国内常用开发镜像加速 (Go代理 + NPM镜像 + Python PyPI源)"
    echo -e " 2. 🔄 重建并刷新系统级 Shell 钩子 (/etc/profile.d/mise.sh 与 ~/.bashrc)"
    echo -e " 3. 🛠  开启 Mise Shims 模式并重新生成 shims (mise reshim)"
    echo -e " 0. 返回"
    echo -e "${CYAN}======================================================${NC}"
    read -p "请选择操作 [0-3]: " cfg_choice < /dev/tty

    case $cfg_choice in
        1)
            echo -e "${BLUE}正在写入开发语言国内加速源配置...${NC}"
            # 1. Go Proxy 加速
            if ! grep -q "GOPROXY=" /etc/profile.d/mise.sh 2>/dev/null; then
                echo 'export GOPROXY="https://goproxy.cn,direct"' >> /etc/profile.d/mise.sh
            fi
            export GOPROXY="https://goproxy.cn,direct"
            echo -e "  ✓ Go 代理已设置为: ${GREEN}https://goproxy.cn,direct${NC}"

            # 2. NPM 镜像加速
            if command -v npm &>/dev/null; then
                npm config set registry https://registry.npmmirror.com 2>/dev/null || true
                echo -e "  ✓ NPM 镜像已设置为: ${GREEN}https://registry.npmmirror.com${NC}"
            fi

            # 3. Pip 镜像加速
            mkdir -p "$HOME/.pip"
            cat > "$HOME/.pip/pip.conf" << 'EOF'
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
trusted-host = pypi.tuna.tsinghua.edu.cn
EOF
            echo -e "  ✓ Pip 镜像已设置为: ${GREEN}清华大学开源镜像源 (pypi.tuna.tsinghua.edu.cn)${NC}"
            echo -e "${GREEN}✅ 国内开发镜像加速源配置完成！${NC}"
            ;;
        2)
            echo -e "${BLUE}正在重建系统级环境变量与 Shell 钩子...${NC}"
            cat > /etc/profile.d/mise.sh << 'EOF'
# Mise Environment Loader
export PATH="/usr/local/bin:$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
if command -v mise &>/dev/null; then
    eval "$(mise activate bash 2>/dev/null)"
fi
EOF
            chmod 644 /etc/profile.d/mise.sh
            _ensure_mise_env
            echo -e "${GREEN}✅ Shell 激活与全局配置文件已刷新。${NC}"
            ;;
        3)
            echo -e "${BLUE}正在执行 mise reshim 刷新二进制软链接...${NC}"
            mise reshim 2>/dev/null || true
            echo -e "${GREEN}✅ Shims 已重新生成！${NC}"
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            ;;
    esac
    echo ""
    read -p "按回车键继续..." -r < /dev/tty
}

# 3. 查看 Mise 版本与多语言环境状态
_mise_view_status() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}         🔍 Mise 版本与多语言运行环境状态自检         ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    _ensure_mise_env

    if ! command -v mise &>/dev/null; then
        echo -e "${RED}状态: 未检测到 Mise 安装。${NC}"
        echo -e "${YELLOW}提示: 请在二级菜单选择「1. 安装 / 更新 Mise」进行一键安装。${NC}"
        echo ""
        read -p "按回车键继续..." -r < /dev/tty
        return 1
    fi

    echo -e "${GREEN}【Mise 核心信息】${NC}"
    echo -ne "  程序路径: "
    which mise 2>/dev/null || echo "/usr/local/bin/mise"
    echo -ne "  核心版本: ${CYAN}"
    mise --version 2>/dev/null || echo "未知"
    echo -e "${NC}"

    echo -e "${GREEN}【Mise 已安装运行时清单 (mise ls)】${NC}"
    local ls_output
    ls_output=$(mise ls 2>/dev/null || true)
    if [ -z "$ls_output" ]; then
        echo -e "  ${YELLOW}(暂无通过 Mise 安装的运行时组件)${NC}"
    else
        echo "$ls_output" | sed 's/^/  /'
    fi
    echo ""

    echo -e "${GREEN}【当前全局激活版本 (mise current)】${NC}"
    local cur_output
    cur_output=$(mise current 2>/dev/null || true)
    if [ -z "$cur_output" ]; then
        echo -e "  ${YELLOW}(暂未设置全局激活运行时)${NC}"
    else
        echo "$cur_output" | sed 's/^/  /'
    fi
    echo ""

    echo -e "${GREEN}【终端当前实际解析命令状态】${NC}"
    # Java
    if command -v java &>/dev/null; then
        local j_ver
        j_ver=$(java -version 2>&1 | head -n 1)
        printf "  %-10s: ${GREEN}[已就绪]${NC} %s\n" "Java" "$j_ver"
    else
        printf "  %-10s: ${RED}[未就绪]${NC}\n" "Java"
    fi

    # Node.js
    if command -v node &>/dev/null; then
        local n_ver
        n_ver=$(node -v 2>/dev/null)
        printf "  %-10s: ${GREEN}[已就绪]${NC} %s\n" "Node.js" "$n_ver"
    else
        printf "  %-10s: ${RED}[未就绪]${NC}\n" "Node.js"
    fi

    # Go
    if command -v go &>/dev/null; then
        local g_ver
        g_ver=$(go version 2>/dev/null)
        printf "  %-10s: ${GREEN}[已就绪]${NC} %s\n" "Go" "$g_ver"
    else
        printf "  %-10s: ${RED}[未就绪]${NC}\n" "Go"
    fi

    # Python
    if command -v python3 &>/dev/null; then
        local py_ver
        py_ver=$(python3 --version 2>/dev/null)
        printf "  %-10s: ${GREEN}[已就绪]${NC} %s\n" "Python3" "$py_ver"
    else
        printf "  %-10s: ${RED}[未就绪]${NC}\n" "Python3"
    fi

    echo -e "${CYAN}======================================================${NC}"
    read -p "按回车键继续..." -r < /dev/tty
}

# 辅助: 检查并安装编译依赖 (针对 Python 等可能需要编译或特定底层库的运行时)
_ensure_runtime_build_deps() {
    local tool="$1"
    if [ "$tool" = "python" ]; then
        echo -e "${YELLOW}⏳ 检测到正在安装 Python，正在补充必要底层系统库 (ssl/ffi/zlib)...${NC}"
        case "$PKG_MGR" in
            apt)
                apt-get update -y 2>/dev/null || true
                apt-get install -y build-essential libssl-dev zlib1g-dev libbz2-dev \
                    libreadline-dev libsqlite3-dev libffi-dev liblzma-dev 2>/dev/null || true
                ;;
            dnf|yum)
                $PKG_INSTALL gcc make openssl-devel zlib-devel bzip2-devel \
                    readline-devel sqlite-devel libffi-devel xz-devel 2>/dev/null || true
                ;;
            apk)
                apk add build-base openssl-dev zlib-dev bzip2-dev readline-dev sqlite-dev libffi-dev xz-dev 2>/dev/null || true
                ;;
        esac
    fi
}

# 4/5/6/7 通用语言运行时安装与管理
_manage_mise_tool() {
    local tool="$1"
    local tool_label="$2"
    local rec_versions="$3"

    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}      📦 Mise 运行时管理: ${tool_label} (${tool})      ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        _ensure_mise_env

        if ! command -v mise &>/dev/null; then
            echo -e "${RED}错误: 未检测到 Mise，请先在上一级菜单安装 Mise！${NC}"
            read -p "按回车键返回..." -r < /dev/tty
            return 1
        fi

        # 显示当前已安装版本
        echo -e "${GREEN}当前已安装的 ${tool_label} 版本:${NC}"
        local installed_list
        installed_list=$(mise ls "$tool" 2>/dev/null || true)
        if [ -z "$installed_list" ]; then
            echo -e "  ${YELLOW}(暂无已安装版本)${NC}"
        else
            echo "$installed_list" | sed 's/^/  /'
        fi
        echo ""

        echo -e "可选操作:"
        echo -e " 1. 🚀 安装推荐版本 (${rec_versions})"
        echo -e " 2. ✍️  手动指定版本号安装"
        echo -e " 3. 🌐 查询可用的远程版本清单 (最近25个)"
        echo -e " 4. 🔀 切换全局生效版本 (mise use -g ${tool}@<版本>)"
        echo -e " 5. 🗑  卸载指定版本 (mise uninstall ${tool}@<版本>)"
        echo -e " 0. 返回上一级菜单"
        echo -e "${CYAN}======================================================${NC}"
        read -p "请选择操作 [0-5]: " act_choice < /dev/tty

        case $act_choice in
            1)
                echo ""
                echo -e "${GREEN}推荐版本清单: ${CYAN}${rec_versions}${NC}"
                read -p "请输入要安装的推荐版本 (例如 ${rec_versions%%,*}): " ver_input < /dev/tty
                if [ -z "$ver_input" ]; then
                    echo -e "${YELLOW}已取消安装。${NC}"
                    sleep 1
                    continue
                fi
                _ensure_runtime_build_deps "$tool"
                echo -e "⏳ 正在通过 Mise 安装 ${tool}@${ver_input}，请稍候..."
                if mise install "${tool}@${ver_input}"; then
                    mise use -g "${tool}@${ver_input}"
                    mise reshim 2>/dev/null || true
                    _ensure_mise_env
                    echo -e "${GREEN}✅ ${tool_label} (${tool}@${ver_input}) 安装并设置为全局默认成功！${NC}"
                else
                    echo -e "${RED}❌ 安装失败，请检查网络或版本号输入是否正确。${NC}"
                fi
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            2)
                echo ""
                read -p "请输入欲安装的具体版本号 (例如 latest 或 具体数字): " custom_ver < /dev/tty
                if [ -z "$custom_ver" ]; then
                    echo -e "${YELLOW}输入为空，取消操作。${NC}"
                    sleep 1
                    continue
                fi
                _ensure_runtime_build_deps "$tool"
                echo -e "⏳ 正在安装 ${tool}@${custom_ver}..."
                if mise install "${tool}@${custom_ver}"; then
                    read -p "是否将其设为系统全局默认版本? [Y/n]: " set_global < /dev/tty
                    if [[ ! "$set_global" =~ ^[Nn]$ ]]; then
                        mise use -g "${tool}@${custom_ver}"
                    fi
                    mise reshim 2>/dev/null || true
                    _ensure_mise_env
                    echo -e "${GREEN}✅ ${tool}@${custom_ver} 处理完成！${NC}"
                else
                    echo -e "${RED}❌ 安装过程出现错误。${NC}"
                fi
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            3)
                echo ""
                echo -e "${BLUE}⏳ 正在查询 ${tool} 远程可用版本清单 (可能需要数秒)...${NC}"
                local remote_list
                remote_list=$(mise ls-remote "$tool" 2>/dev/null | tail -n 25 || true)
                if [ -n "$remote_list" ]; then
                    echo -e "${GREEN}远程可用版本 (最新25个):${NC}"
                    echo "$remote_list" | sed 's/^/  /'
                else
                    echo -e "${YELLOW}未能获取到远程版本，请检查网络连接。${NC}"
                fi
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            4)
                echo ""
                read -p "请输入要激活为全局默认的版本号: " switch_ver < /dev/tty
                if [ -n "$switch_ver" ]; then
                    if mise use -g "${tool}@${switch_ver}"; then
                        mise reshim 2>/dev/null || true
                        _ensure_mise_env
                        echo -e "${GREEN}✅ 全局默认版本已成功切换为: ${tool}@${switch_ver}${NC}"
                    else
                        echo -e "${RED}❌ 切换失败，请确认该版本是否已安装。${NC}"
                    fi
                fi
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            5)
                echo ""
                read -p "请输入要卸载的版本号: " uninst_ver < /dev/tty
                if [ -n "$uninst_ver" ]; then
                    echo -e "⏳ 正在卸载 ${tool}@${uninst_ver}..."
                    mise uninstall "${tool}@${uninst_ver}"
                    mise reshim 2>/dev/null || true
                    echo -e "${GREEN}✅ 卸载完成。${NC}"
                fi
                read -p "按回车键继续..." -r < /dev/tty
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}输入有误，请输入 0-5 之间的数字。${NC}"
                sleep 1
                ;;
        esac
    done
}

# 8. 一键快捷部署核心四大语言开发环境组合
_mise_install_all_recommended() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}   ⚡ 一键快捷部署推荐开发组合 (Java+Node+Go+Python)   ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    _ensure_mise_env

    if ! command -v mise &>/dev/null; then
        echo -e "${YELLOW}未检测到 Mise，正在自动执行一键安装...${NC}"
        _mise_install_core
        _ensure_mise_env
    fi

    echo -e "本次将自动下载并全局部署以下主流企业级稳定版本:"
    echo -e "  - ${CYAN}Java${NC}   : 21 (Temurin / Adoptium LTS)"
    echo -e "  - ${CYAN}Node.js${NC}: lts (稳定长期支持版)"
    echo -e "  - ${CYAN}Go${NC}     : latest (稳定最新版)"
    echo -e "  - ${CYAN}Python${NC} : 3.12 (现代化标准版本)"
    echo ""
    read -p "是否立即开始批量安装并设为全局默认? [y/N]: " confirm_all < /dev/tty
    if [[ ! "$confirm_all" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消一键安装。${NC}"
        read -p "按回车键返回..." -r < /dev/tty
        return 0
    fi

    # 1. 编译依赖安装
    _ensure_runtime_build_deps "python"

    # 2. 依次安装并全局生效
    echo -e "${BLUE}[1/4] 正在安装 Java 21 LTS...${NC}"
    mise use -g java@21 || echo -e "${YELLOW}Java 安装过程异常，继续后续流程...${NC}"

    echo -e "${BLUE}[2/4] 正在安装 Node.js LTS...${NC}"
    mise use -g node@lts || echo -e "${YELLOW}Node.js 安装过程异常，继续后续流程...${NC}"

    echo -e "${BLUE}[3/4] 正在安装 Go latest...${NC}"
    mise use -g go@latest || echo -e "${YELLOW}Go 安装过程异常，继续后续流程...${NC}"

    echo -e "${BLUE}[4/4] 正在安装 Python 3.12...${NC}"
    mise use -g python@3.12 || echo -e "${YELLOW}Python 安装过程异常，继续后续流程...${NC}"

    mise reshim 2>/dev/null || true
    _ensure_mise_env

    echo ""
    echo -e "${GREEN}✅ 一键装机流程执行完毕！状态概览:${NC}"
    _mise_view_status
}

# 9. 卸载 Mise
_mise_uninstall_core() {
    clear
    echo -e "${RED}======================================================${NC}"
    echo -e "${RED}             🗑  卸载与清理 Mise 环境                 ${NC}"
    echo -e "${RED}======================================================${NC}"
    echo -e "${YELLOW}警告: 此操作将移除 Mise 可执行文件并可选择清理所有已安装的运行时环境！${NC}"
    read -p "是否确认卸载 Mise? [y/N]: " un_confirm < /dev/tty
    if [[ "$un_confirm" =~ ^[Yy]$ ]]; then
        rm -f /usr/local/bin/mise "$HOME/.local/bin/mise" /etc/profile.d/mise.sh 2>/dev/null
        read -p "是否彻底删除 Mise 运行时数据与缓存 (~/.local/share/mise)? [y/N]: " rm_data < /dev/tty
        if [[ "$rm_data" =~ ^[Yy]$ ]]; then
            rm -rf "$HOME/.local/share/mise" "$HOME/.config/mise" 2>/dev/null
            echo -e "${GREEN}✓ Mise 数据与缓存已彻底清除。${NC}"
        fi
        echo -e "${GREEN}✅ Mise 已从系统中卸载。${NC}"
    else
        echo -e "${BLUE}已取消卸载。${NC}"
    fi
    read -p "按回车键继续..." -r < /dev/tty
}

# ================================================================
# Mise 多运行时环境管理 (专属二级子菜单)
# ================================================================
_mise_management_menu() {
    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}       🧰 Mise 多运行时环境管理 (Java/Node/Go/Py)      ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        _ensure_mise_env

        local mise_ver="未安装"
        if command -v mise &>/dev/null; then
            mise_ver="$(mise --version 2>/dev/null || echo '已就绪')"
        fi
        echo -e "当前系统类型: ${GREEN}${DISTRO_NAME:-未知}${NC} | Mise 状态: ${CYAN}${mise_ver}${NC}"
        echo ""
        echo -e " 1. 🚀 安装 / 更新 Mise 核心程序  (官方脚本/多架构/自动激活)"
        echo -e " 2. ⚙️  配置 Mise 环境与国内镜像源 (Go/NPM/Pip加速/Shims配置)"
        echo -e " 3. 🔍 查看当前版本与运行状态     (mise ls / current / 环境变量)"
        echo -e " ----------------------------------------------------"
        echo -e " 4. ☕ 管理 Java 环境             (Java 8/11/17/21/自定义版本)"
        echo -e " 5. 🟢 管理 Node.js 环境          (Node 18/20/22/LTS/自定义版本)"
        echo -e " 6. 🔵 管理 Go 环境               (Go 1.21/1.22/1.23/自定义版本)"
        echo -e " 7. 🐍 管理 Python 环境           (Python 3.10/3.11/3.12/编译依赖)"
        echo -e " ----------------------------------------------------"
        echo -e " 8. ⚡ 一键装机推荐组合           (Java+Node+Go+Python 一键就绪)"
        echo -e " 9. 🗑  卸载与清理 Mise"
        echo -e " 0. 返回上一级菜单"
        echo -e "${CYAN}======================================================${NC}"
        read -p "请选择操作 [0-9]: " mise_choice < /dev/tty

        case $mise_choice in
            1)
                _mise_install_core
                ;;
            2)
                _mise_config_env
                ;;
            3)
                _mise_view_status
                ;;
            4)
                _manage_mise_tool "java" "Java (JDK)" "21,17,11,8"
                ;;
            5)
                _manage_mise_tool "node" "Node.js" "lts,22,20,18"
                ;;
            6)
                _manage_mise_tool "go" "Go (Golang)" "latest,1.23,1.22,1.21"
                ;;
            7)
                _manage_mise_tool "python" "Python" "3.12,3.11,3.10"
                ;;
            8)
                _mise_install_all_recommended
                ;;
            9)
                _mise_uninstall_core
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}输入有误，请输入 0-9 之间的数字。${NC}"
                sleep 1
                ;;
        esac
    done
}

# ================================================================
# 常用专家工具集安装 (二级菜单)
# 选项 1: 采集离线安装包 (需联网, 供无网服务器使用)
# 选项 2: 直接在线安装常用工具集 (联网在线安装, 不处理离线)
# 选项 3: 本地离线安装常用工具集 (无网服务器专用, 从本地部署)
# 选项 4: Mise 多运行时环境管理 (安装/配置/版本查看/管理 Java, Node, Go, Python)
# ================================================================
install_common_tools() {
    # Root 权限检查
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须以 root 权限运行此脚本。${NC}"
        read -p "按回车键返回..." -r < /dev/tty
        return 1
    fi

    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}       🛠  常用专家工具集安装 (最小化系统必备)        ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo -e "当前系统类型: ${GREEN}${DISTRO_NAME:-未知}${NC} (包管理器: ${CYAN}${PKG_MGR:-未知}${NC})"
        echo ""
        echo -e " 1. 📦 采集离线安装包到本地 (需联网, 供无网服务器使用)"
        echo -e " 2. 🚀 常用基础软件管理看板 (Kejilion风格: 矩阵看板/单选多选/一键全量/卸载)"
        echo -e " 3. 💾 本地离线安装工具集   (无网服务器使用本地离线包部署)"
        echo -e " 4. 🧰 Mise 多运行时环境管理 (安装/配置/版本查看/管理 Java Node Go Python)"
        echo -e " 0. 返回主菜单"
        echo -e "${CYAN}======================================================${NC}"
        read -p "请选择操作 [0-4]: " tool_choice < /dev/tty

        case $tool_choice in
            1)
                _collect_offline_packages
                ;;
            2)
                _direct_install_online_tools
                ;;
            3)
                _install_offline_packages_local
                ;;
            4)
                _mise_management_menu
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}输入有误，请输入 0-4 之间的数字。${NC}"
                sleep 1
                ;;
        esac
    done
}

# 双模运行守卫: 支持被主程序 source 引用或独立单兵执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    system_optimization_menu
fi
