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
            if [ -n "$VERSION_CODENAME" ]; then
                echo "${ID}:${VERSION_CODENAME}"
            else
                # 针对 CentOS 等无 codename 的系统，使用主版本号
                echo "${ID}:${VERSION_ID%%.*}"
            fi
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

        if [[ "$distro_id" == "ubuntu" || "$distro_id" == "debian" ]]; then
            # 备份原配置
            local bak="/etc/apt/sources.list.bak.$(date +%F_%H%M%S)"
            cp /etc/apt/sources.list "$bak" 2>/dev/null && echo -e "${BLUE}已备份原配置到: $bak${NC}"

            if [[ "$distro_id" == "ubuntu" ]]; then
                cat > /etc/apt/sources.list <<EOF
# Ubuntu $version_info - $mirror (自动生成 $(date +"%Y-%m-%d %H:%M:%S"))
deb $mirror $version_info main restricted universe multiverse
deb $mirror $version_info-updates main restricted universe multiverse
deb $mirror $version_info-security main restricted universe multiverse
EOF
            elif [[ "$distro_id" == "debian" ]]; then
                local mirror_base="${mirror%/debian}"
                local security_mirror="${mirror_base}/debian-security"
                [[ "$mirror" == *"deb.debian.org"* ]] && security_mirror="http://security.debian.org/debian-security"

                cat > /etc/apt/sources.list <<EOF
# Debian $version_info - $mirror (自动生成 $(date +"%Y-%m-%d %H:%M:%S"))
deb $mirror $version_info main contrib non-free
deb $mirror $version_info-updates main contrib non-free
deb $security_mirror $version_info-security main contrib non-free
EOF
            fi
        elif [[ "$distro_id" == "centos" ]]; then
            echo -e "${YELLOW}[INFO] 正在备份 YUM 配置目录 (/etc/yum.repos.d/)...${NC}"
            tar -czf "/etc/yum.repos.d.bak.$(date +%F).tar.gz" /etc/yum.repos.d/ &>/dev/null
            
            if [[ "$version_info" == "8" ]]; then
                echo -e "${YELLOW}[INFO] 正在为 CentOS 8 (EOL) 配置官方归档源 (Vault)...${NC}"
                sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-* 2>/dev/null
                sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-* 2>/dev/null
                # 如果用户选择了国内镜像地址
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
        else
            echo " 1-4. (抱歉，未能识别系统类型)"
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
        echo -e " 1. \u955c\u50cf\u6e90\u7ba1\u7406 (阿里云/清华/中科大/官方/还原)"
        echo -e " 2. 开启内核 BBR 网络加速"
        echo -e " 3. 配置 2GB zRAM 虚拟内存 (高压缩比)"
        echo -e " 4. 清除 zRAM/Swap 所有相关配置"
        echo -e " 5. 设置系统时区为上海 (Asia/Shanghai)"
        echo -e " 0. 返回主菜单"
        echo -e "${GREEN}==============================================${NC}"
        read -p "请选择操作 [0-5]: " opt_choice

        case $opt_choice in
            1)
                manage_mirror_sources
                ;;
            2)
                echo -e "${YELLOW}正在配置 BBR 加速...${NC}"
                if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
                    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
                    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
                    sysctl -p
                    echo -e "${GREEN}成功: BBR 已开启。${NC}"
                else
                    echo -e "${BLUE}提示: BBR 似乎已经开启，无需重复操作。${NC}"
                fi
                read -p "按回车键继续..."
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
                echo -e "${YELLOW}正在更新系统时区...${NC}"
                if command -v timedatectl &>/dev/null; then
                    timedatectl set-timezone Asia/Shanghai 2>/dev/null
                else
                    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
                    echo "Asia/Shanghai" > /etc/timezone 2>/dev/null
                fi
                echo -e "${GREEN}成功: 当前系统时间: $(date)${NC}"
                read -p "按回车键继续..."
                ;;
            0)
                echo -e "${BLUE}返回中...${NC}"
                break
                ;;
            *)
                echo -e "${RED}输入有误，请输入 0-5 之间的数字。${NC}"
                sleep 1
                ;;
        esac
    done
}

# ========== 网络 IP 配置模块 ==========

# 查看当前网络信息
install_common_tools() {
    echo -e "\n${BLUE}--- 开始安装常用基础系统组件 ---${NC}"
    echo -e "${YELLOW}由于最小化安装常缺少排查和诊断工具，脚本将为您安装基础包...${NC}"
    echo -e "${YELLOW}包管理器: ${PKG_MGR:-未知}${NC}"

    case "$PKG_MGR" in
        apt)
            PACKAGES="curl wget vim git htop net-tools unzip zip iputils-ping dnsutils tar sudo bash-completion"
            ;;
        dnf|yum)
            PACKAGES="curl wget vim git htop net-tools unzip zip bind-utils tar sudo bash-completion"
            ;;
        apk)
            PACKAGES="curl wget vim git htop net-tools unzip zip bind-tools tar sudo bash"
            ;;
        *)
            echo -e "${RED}错误: 未能识别当前包管理器，无法进行适配安装。${NC}"
            read -p "按回车键返回..."
            return
            ;;
    esac

    echo -e "即将安装的包清单: ${GREEN}${PACKAGES}${NC}\n"

    # 执行静默或快速安装
    if [ "$PKG_MGR" = "apt" ]; then
        apt update 2>/dev/null
    fi

    # 调用开头定义的安装指令变量进行安装
    $PKG_INSTALL $PACKAGES
    
    if [ $? -eq 0 ]; then
        echo -e "\n${GREEN}成功: 所有常用软件安装/检查完毕。${NC}"
    else
        echo -e "\n${RED}警告: 部分软件包安装过程报出错误，请检查日志。${NC}"
    fi
    read -p "按回车键返回主菜单..."
}
