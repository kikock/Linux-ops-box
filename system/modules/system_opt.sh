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
        echo -e " 2. 开启内核 BBR 网络加速"
        echo -e " 3. 配置 2GB zRAM 虚拟内存 (高压缩比)"
        echo -e " 4. 清除 zRAM/Swap 所有相关配置"
        echo -e " 5. 设置系统时区为上海 (Asia/Shanghai)"
        echo -e " 6. 获取硬盘信息并交互式挂载"
        echo -e " 7. 配置终端网络代理 (临时/全局直连)"
        echo -e " 8. 修复中文乱码 (locale/字体/编码一键修复)"
        echo -e " 0. 返回主菜单"
        echo -e "${GREEN}==============================================${NC}"
        read -p "请选择操作 [0-8]: " opt_choice

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
            6)
                manage_disk_mount
                ;;
            7)
                manage_proxy_session
                ;;
            8)
                fix_chinese_locale
                ;;
            0)
                echo -e "${BLUE}返回中...${NC}"
                break
                ;;
            *)
                echo -e "${RED}输入有误，请输入 0-8 之间的数字。${NC}"
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
