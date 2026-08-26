#!/bin/bash

# =================================================================
# 模块名称: disk_mgmt.sh
# 描述: 硬盘检测与清理中心
#       - 硬盘整体使用情况 (多分区 / 使用率告警着色)
#       - 大文件扫描 (Top N / 指定路径)
#       - 大目录扫描 (du 排序分析)
#       - 按文件类型统计占用 (日志 / 压缩 / 视频 / 其他)
#       - inode 使用情况检测
#       - 一键清理辅助 (apt|yum 缓存 / 系统日志 / tmp / Docker)
# 适配: Ubuntu / Debian / CentOS / RHEL / Fedora / Alpine
# 制作人: kikock
# =================================================================

# ----------------------------------------------------------------
# 内部辅助: 格式化字节为人类可读
# ----------------------------------------------------------------
_disk_bytes_human() {
    local bytes="$1"
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ] 2>/dev/null; then
        echo "0B"
        return
    fi
    awk -v b="$bytes" 'BEGIN{
        if(b>=1073741824) printf "%.1fG\n", b/1073741824
        else if(b>=1048576) printf "%.1fM\n", b/1048576
        else if(b>=1024) printf "%.1fK\n", b/1024
        else printf "%dB\n", b
    }'
}

# ================================================================
# 功能 1: 磁盘整体使用情况
# ================================================================
_disk_show_overview() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}              💾  磁盘整体使用情况                    ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo ""

    # -- 1. 分区使用总览 --
    echo -e "${GREEN}▌ 分区挂载点使用情况 (df -hT)${NC}"
    printf "${BLUE}%-28s %-8s %-8s %-8s %-7s %-20s${NC}\n" \
        "文件系统" "类型" "总量" "已用" "使用率" "挂载点"
    printf "${BLUE}%-28s %-8s %-8s %-8s %-7s %-20s${NC}\n" \
        "----------------------------" "--------" "--------" "--------" "-------" "--------------------"

    df -hT 2>/dev/null | awk 'NR>1' | \
    grep -v 'tmpfs\|devtmpfs\|udev\|none\|squashfs\|overlay' | \
    while IFS= read -r line; do
        local fs type size used avail pct mount
        read -r fs type size used avail pct mount <<< "$line"
        local num color
        num=$(echo "$pct" | tr -d '%')
        color="${GREEN}"
        [ "${num:-0}" -ge 75 ] 2>/dev/null && color="${YELLOW}"
        [ "${num:-0}" -ge 90 ] 2>/dev/null && color="${RED}"
        printf "${color}%-28s %-8s %-8s %-8s %-7s %-20s${NC}\n" \
            "$fs" "$type" "$size" "$used" "$pct" "$mount"
    done

    echo ""
    echo -e "${GREEN}▌ 使用率图示 (仅实体分区)${NC}"
    df -h 2>/dev/null | awk 'NR>1' | \
    grep -v 'tmpfs\|devtmpfs\|udev\|none\|squashfs\|overlay' | \
    while IFS= read -r line; do
        local fs size used avail pct mount
        read -r fs size used avail pct mount <<< "$line"
        local num
        num=$(echo "$pct" | tr -d '%')
        [ -z "$num" ] && continue
        local bar_fill bar_empty bar color
        bar_fill=$(( num * 30 / 100 ))
        bar_empty=$(( 30 - bar_fill ))
        bar=""
        local i
        for ((i=0; i<bar_fill; i++)); do bar+="█"; done
        for ((i=0; i<bar_empty; i++)); do bar+="░"; done
        color="${GREEN}"
        [ "${num:-0}" -ge 75 ] 2>/dev/null && color="${YELLOW}"
        [ "${num:-0}" -ge 90 ] 2>/dev/null && color="${RED}"
        printf "  ${CYAN}%-20s${NC} [${color}%s${NC}] ${color}%s${NC} (%s / %s)\n" \
            "$mount" "$bar" "$pct" "$used" "$size"
    done

    echo ""
    # -- 2. 块设备信息 --
    if command -v lsblk &>/dev/null; then
        echo -e "${GREEN}▌ 块设备信息 (lsblk)${NC}"
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null | \
            grep -v 'loop\|sr0' | head -30
    fi

    echo ""
    # -- 3. 磁盘 IO 统计 (如有 iostat) --
    if command -v iostat &>/dev/null; then
        echo -e "${GREEN}▌ 磁盘 I/O 统计 (iostat -dx 1 1)${NC}"
        iostat -dx 1 1 2>/dev/null | grep -v 'loop\|^$' | head -20
    fi

    echo ""
    echo -e "${CYAN}======================================================${NC}"
    read -p "  按回车键返回磁盘管理菜单..." -r < /dev/tty
}

# ================================================================
# 功能 2: 大文件扫描
# ================================================================
_disk_find_large_files() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}              🔍  大文件扫描                          ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo ""
    echo -e " 请输入扫描路径 (直接回车默认: ${YELLOW}/${NC})"
    read -p " 扫描路径: " scan_path < /dev/tty
    [ -z "$scan_path" ] && scan_path="/"

    echo ""
    echo -e " 显示最大的多少个文件? (直接回车默认: ${YELLOW}20${NC})"
    read -p " 数量 [20]: " top_n < /dev/tty
    [ -z "$top_n" ] && top_n=20
    [[ ! "$top_n" =~ ^[0-9]+$ ]] && top_n=20

    echo ""
    echo -e " 最小文件大小过滤? (单位 MB, 直接回车默认: ${YELLOW}50${NC} MB)"
    read -p " 最小 MB [50]: " min_mb < /dev/tty
    [ -z "$min_mb" ] && min_mb=50
    [[ ! "$min_mb" =~ ^[0-9]+$ ]] && min_mb=50

    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}  🔍  大文件 Top ${top_n} — 扫描路径: ${YELLOW}${scan_path}${NC}${CYAN} (>= ${min_mb}MB)${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${YELLOW}  ⏳ 正在扫描中，大磁盘可能需要较长时间，请稍候...${NC}"
    echo ""

    printf "%-12s  %s\n" "大小" "文件路径"
    printf "%-12s  %s\n" "------------" "------------------------------------------------------------"

    find "$scan_path" -xdev -type f -size +"${min_mb}"M 2>/dev/null \
        -exec du -sh {} \; 2>/dev/null | \
        sort -rh | head -"$top_n" | \
        while read -r sz fpath; do
            printf "%-12s  %s\n" "$sz" "$fpath"
        done

    echo ""
    echo -e "${CYAN}======================================================${NC}"
    echo -e " ${YELLOW}提示: 使用 ${GREEN}rm -f <文件路径>${YELLOW} 删除不需要的大文件${NC}"
    echo -e " ${YELLOW}      使用 ${GREEN}gzip <文件>${YELLOW} 压缩日志节省空间${NC}"
    read -p "  按回车键返回磁盘管理菜单..." -r < /dev/tty
}

# ================================================================
# 功能 3: 大目录扫描
# ================================================================
_disk_find_large_dirs() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}              📁  大目录扫描分析                      ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo ""
    echo -e " 请输入扫描起始路径 (直接回车默认: ${YELLOW}/${NC})"
    read -p " 扫描路径: " scan_path < /dev/tty
    [ -z "$scan_path" ] && scan_path="/"

    echo ""
    echo -e " 显示最大的多少个目录? (直接回车默认: ${YELLOW}20${NC})"
    read -p " 数量 [20]: " top_n < /dev/tty
    [ -z "$top_n" ] && top_n=20
    [[ ! "$top_n" =~ ^[0-9]+$ ]] && top_n=20

    echo ""
    echo -e " 扫描深度? (1=仅一级子目录, 2=两层, 回车默认: ${YELLOW}2${NC})"
    read -p " 深度 [2]: " depth < /dev/tty
    [ -z "$depth" ] && depth=2
    [[ ! "$depth" =~ ^[0-9]+$ ]] && depth=2

    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}  📁  大目录 Top ${top_n} — 路径: ${YELLOW}${scan_path}${NC}${CYAN}  深度: ${depth}${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${YELLOW}  ⏳ 正在统计目录大小，请稍候...${NC}"
    echo ""

    printf "%-12s  %s\n" "占用大小" "目录路径"
    printf "%-12s  %s\n" "------------" "------------------------------------------------------------"

    du -hx --max-depth="$depth" "$scan_path" 2>/dev/null | \
        sort -rh | head -"$top_n" | \
        while read -r sz dpath; do
            printf "%-12s  %s\n" "$sz" "$dpath"
        done

    echo ""
    echo -e "${CYAN}======================================================${NC}"
    echo -e " ${YELLOW}提示: 可再次缩小扫描路径到大目录中进行二次定位分析${NC}"
    read -p "  按回车键返回磁盘管理菜单..." -r < /dev/tty
}

# ================================================================
# 功能 4: 按文件类型统计磁盘占用
# ================================================================
_disk_analyze_by_type() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}              🗂  按文件类型分析磁盘占用               ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo ""
    echo -e " 请输入分析路径 (直接回车默认: ${YELLOW}/${NC})"
    read -p " 扫描路径: " scan_path < /dev/tty
    [ -z "$scan_path" ] && scan_path="/"

    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}  🗂  文件类型占用分析 — 路径: ${YELLOW}${scan_path}${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${YELLOW}  ⏳ 正在统计，请稍候...${NC}"
    echo ""

    local -a labels exts_list
    labels=(
        "📄 日志文件    (.log/.out)"
        "📦 压缩文件    (.gz/.zip/.tar/.bz2/.xz)"
        "🎬 视频文件    (.mp4/.mkv/.avi/.mov)"
        "🎵 音频文件    (.mp3/.wav/.flac)"
        "🖼  图片文件    (.jpg/.png/.gif)"
        "📂 备份文件    (.bak/.sql/.dump)"
        "💻 库/安装包   (.so/.deb/.rpm)"
        "📝 文档文件    (.pdf/.doc/.txt)"
    )
    exts_list=(
        "*.log *.out *.log.*"
        "*.gz *.zip *.tar *.bz2 *.xz *.7z *.rar *.tgz"
        "*.mp4 *.mkv *.avi *.mov *.flv *.wmv *.ts"
        "*.mp3 *.wav *.flac *.aac *.ogg *.m4a"
        "*.jpg *.jpeg *.png *.gif *.bmp *.svg *.webp"
        "*.bak *.bkp *.old *.sql *.dump *.backup"
        "*.so *.deb *.rpm *.exe *.bin"
        "*.pdf *.doc *.docx *.txt *.csv *.xls *.xlsx"
    )

    for idx in "${!labels[@]}"; do
        local label="${labels[$idx]}"
        local exts="${exts_list[$idx]}"
        local find_args=()
        local first=true
        # shellcheck disable=SC2086
        for ext in $exts; do
            if $first; then
                find_args+=(-name "$ext")
                first=false
            else
                find_args+=(-o -name "$ext")
            fi
        done

        local count_files total_bytes human
        count_files=$(find "$scan_path" -xdev -type f \( "${find_args[@]}" \) 2>/dev/null | wc -l)
        total_bytes=$(find "$scan_path" -xdev -type f \( "${find_args[@]}" \) \
            -exec du -b {} \; 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
        human=$(_disk_bytes_human "$total_bytes")
        printf "  ${CYAN}%-42s${NC}  数量: ${YELLOW}%-6s${NC}  占用: ${GREEN}%s${NC}\n" \
            "$label" "$count_files" "$human"
    done

    echo ""
    echo -e "${CYAN}======================================================${NC}"
    read -p "  按回车键返回磁盘管理菜单..." -r < /dev/tty
}

# ================================================================
# 功能 5: inode 使用情况检测
# ================================================================
_disk_check_inode() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}              🕵️  inode 使用情况检测                  ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo ""
    echo -e "${GREEN}▌ 各分区 inode 使用情况 (df -i)${NC}"
    printf "${BLUE}%-30s %-12s %-12s %-12s %-8s %-15s${NC}\n" \
        "文件系统" "inode总量" "inode已用" "inode剩余" "使用率" "挂载点"
    printf "${BLUE}%-30s %-12s %-12s %-12s %-8s %-15s${NC}\n" \
        "------------------------------" "------------" "------------" "------------" "--------" "---------------"

    df -i 2>/dev/null | awk 'NR>1' | \
    grep -v 'tmpfs\|devtmpfs\|udev\|none\|squashfs' | \
    while IFS= read -r line; do
        local fs itotal iused ifree pct mount color num
        read -r fs itotal iused ifree pct mount <<< "$line"
        num=$(echo "$pct" | tr -d '%')
        color="${GREEN}"
        [ "${num:-0}" -ge 75 ] 2>/dev/null && color="${YELLOW}"
        [ "${num:-0}" -ge 90 ] 2>/dev/null && color="${RED}"
        printf "${color}%-30s %-12s %-12s %-12s %-8s %-15s${NC}\n" \
            "$fs" "$itotal" "$iused" "$ifree" "$pct" "$mount"
    done

    echo ""
    echo -e "${GREEN}▌ inode 耗尽风险提示${NC}"
    local has_risk=false
    df -i 2>/dev/null | awk 'NR>1' | \
    grep -v 'tmpfs\|devtmpfs\|udev\|none\|squashfs' | \
    while IFS= read -r line; do
        local fs itotal iused ifree pct mount num
        read -r fs itotal iused ifree pct mount <<< "$line"
        num=$(echo "$pct" | tr -d '%')
        if [ "${num:-0}" -ge 90 ] 2>/dev/null; then
            has_risk=true
            echo -e "  ${RED}⚠  危险: 挂载点 ${mount} inode 使用率已达 ${pct}，接近耗尽！${NC}"
            echo -e "     建议: 排查 ${mount} 下大量小文件 (如 PHP session / 邮件队列):"
            echo -e "     ${CYAN}find ${mount} -xdev -type f | wc -l${NC}"
        elif [ "${num:-0}" -ge 75 ] 2>/dev/null; then
            echo -e "  ${YELLOW}⚡ 警告: 挂载点 ${mount} inode 使用率 ${pct}，请关注。${NC}"
        fi
    done
    echo -e "  ${GREEN}✓ inode 检测完成（无告警项表示 inode 使用正常）${NC}"

    echo ""
    echo -e "${GREEN}▌ 主要目录文件数量统计 (快速参考)${NC}"
    echo -e "${YELLOW}  ⏳ 正在统计...${NC}"
    for dir in / /var /tmp /home /usr /opt; do
        if [ -d "$dir" ]; then
            local cnt
            cnt=$(find "$dir" -maxdepth 2 -xdev -type f 2>/dev/null | wc -l)
            printf "  %-20s  文件数: ${YELLOW}%s${NC}\n" "$dir" "$cnt"
        fi
    done

    echo ""
    echo -e "${CYAN}======================================================${NC}"
    read -p "  按回车键返回磁盘管理菜单..." -r < /dev/tty
}

# ================================================================
# 功能 6: 一键清理辅助
# ================================================================
_disk_cleanup_assistant() {
    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}              🧹  一键清理辅助中心                    ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo ""
        echo -e " ${YELLOW}⚠  所有清理操作均需二次确认，不会自动删除！${NC}"
        echo ""
        echo " 1. 🗑  清理包管理器缓存   (apt/yum/dnf/apk cache)"
        echo " 2. 📋  清理系统日志文件   (journald / /var/log/*.gz)"
        echo " 3. 🗂  清理 /tmp 临时目录  (> 7 天的文件)"
        echo " 4. 🐳  清理 Docker 悬空资源 (镜像/容器/卷)"
        echo " 5. 🖥  清理旧内核文件      (仅 Debian/Ubuntu)"
        echo " 6. 📤  清理用户缓存文件   (~/.cache 30天未访问)"
        echo " 7. 📊  全部执行 (批量安全清理)"
        echo " 0. ↩  返回磁盘管理菜单"
        echo ""
        echo -e "${CYAN}======================================================${NC}"
        read -p " 请输入选项 [0-7]: " opt < /dev/tty

        case $opt in
            1)
                echo ""
                echo -e "${YELLOW}➜ 将清理包管理器缓存，是否继续? [y/N]: ${NC}"
                read -p "" confirm < /dev/tty
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    if command -v apt &>/dev/null; then
                        echo -e "${CYAN}▶ apt autoremove -y && apt clean && apt autoclean -y${NC}"
                        apt autoremove -y && apt clean && apt autoclean -y 2>/dev/null
                    elif command -v dnf &>/dev/null; then
                        echo -e "${CYAN}▶ dnf autoremove -y && dnf clean all${NC}"
                        dnf autoremove -y && dnf clean all
                    elif command -v yum &>/dev/null; then
                        echo -e "${CYAN}▶ yum autoremove -y && yum clean all${NC}"
                        yum autoremove -y && yum clean all
                    elif command -v apk &>/dev/null; then
                        echo -e "${CYAN}▶ apk cache clean${NC}"
                        apk cache clean
                    else
                        echo -e "${RED}未检测到支持的包管理器${NC}"
                    fi
                    echo -e "${GREEN}✓ 包缓存清理完成${NC}"
                else
                    echo -e "${YELLOW}已取消${NC}"
                fi
                sleep 1
                ;;
            2)
                echo ""
                echo -e "${YELLOW}➜ 将清理 journald 日志 (保留最近 7 天) + /var/log 旧压缩包，是否继续? [y/N]: ${NC}"
                read -p "" confirm < /dev/tty
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    if command -v journalctl &>/dev/null; then
                        echo -e "${CYAN}▶ journalctl --vacuum-time=7d${NC}"
                        journalctl --vacuum-time=7d
                    fi
                    echo -e "${CYAN}▶ 清理 /var/log 下压缩旧日志 (*.gz, *.1~*.3 超过7天)${NC}"
                    find /var/log -type f \( -name "*.gz" -o -name "*.1" -o -name "*.2" -o -name "*.3" \) \
                        -mtime +7 -exec rm -fv {} \; 2>/dev/null
                    echo -e "${GREEN}✓ 日志清理完成${NC}"
                else
                    echo -e "${YELLOW}已取消${NC}"
                fi
                sleep 1
                ;;
            3)
                echo ""
                echo -e "${YELLOW}➜ 将删除 /tmp 中超过 7 天未访问的文件，是否继续? [y/N]: ${NC}"
                read -p "" confirm < /dev/tty
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    echo -e "${CYAN}▶ find /tmp -type f -mtime +7 -delete${NC}"
                    find /tmp -type f -mtime +7 -delete 2>/dev/null
                    find /tmp -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null
                    echo -e "${GREEN}✓ /tmp 清理完成${NC}"
                else
                    echo -e "${YELLOW}已取消${NC}"
                fi
                sleep 1
                ;;
            4)
                if ! command -v docker &>/dev/null; then
                    echo -e "${RED}  系统未安装 Docker，跳过此项${NC}"
                    sleep 1; continue
                fi
                echo ""
                echo -e "${YELLOW}➜ 将清理 Docker 悬空镜像/停止容器/未使用卷，是否继续? [y/N]: ${NC}"
                read -p "" confirm < /dev/tty
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    echo -e "${CYAN}▶ docker system prune -f${NC}"
                    docker system prune -f
                    echo -e "${CYAN}▶ docker volume prune -f${NC}"
                    docker volume prune -f
                    echo -e "${GREEN}✓ Docker 资源清理完成${NC}"
                else
                    echo -e "${YELLOW}已取消${NC}"
                fi
                sleep 1
                ;;
            5)
                if ! command -v apt &>/dev/null; then
                    echo -e "${RED}  仅支持 Debian/Ubuntu 系统的旧内核清理${NC}"
                    sleep 1; continue
                fi
                echo ""
                echo -e "${YELLOW}➜ 将自动移除非当前使用的旧内核，是否继续? [y/N]: ${NC}"
                read -p "" confirm < /dev/tty
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    echo -e "${CYAN}▶ apt autoremove --purge -y${NC}"
                    apt autoremove --purge -y
                    echo -e "${GREEN}✓ 旧内核清理完成${NC}"
                else
                    echo -e "${YELLOW}已取消${NC}"
                fi
                sleep 1
                ;;
            6)
                echo ""
                echo -e "${YELLOW}➜ 将清理 ~/.cache 中 30 天未访问的文件，是否继续? [y/N]: ${NC}"
                read -p "" confirm < /dev/tty
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    local home_dir="${HOME:-/root}"
                    if [ -d "${home_dir}/.cache" ]; then
                        echo -e "${CYAN}▶ 清理 ${home_dir}/.cache 中 30 天未访问的文件...${NC}"
                        find "${home_dir}/.cache" -type f -atime +30 -delete 2>/dev/null
                        find "${home_dir}/.cache" -mindepth 1 -type d -empty -delete 2>/dev/null
                        echo -e "${GREEN}✓ 用户缓存清理完成${NC}"
                    else
                        echo -e "${YELLOW}目录 ${home_dir}/.cache 不存在，跳过${NC}"
                    fi
                else
                    echo -e "${YELLOW}已取消${NC}"
                fi
                sleep 1
                ;;
            7)
                echo ""
                echo -e "${RED}⚠  将依次执行全部安全清理项目，是否继续? [y/N]: ${NC}"
                read -p "" confirm < /dev/tty
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    echo -e "${CYAN}── 步骤 1/5: 清理包管理器缓存 ──${NC}"
                    if command -v apt &>/dev/null; then
                        apt autoremove -y && apt clean && apt autoclean -y 2>/dev/null
                    elif command -v dnf &>/dev/null; then
                        dnf autoremove -y && dnf clean all
                    elif command -v yum &>/dev/null; then
                        yum autoremove -y && yum clean all
                    elif command -v apk &>/dev/null; then
                        apk cache clean
                    fi
                    echo -e "${GREEN}✓ 包缓存清理完成${NC}"

                    echo -e "${CYAN}── 步骤 2/5: 清理系统日志 ──${NC}"
                    command -v journalctl &>/dev/null && journalctl --vacuum-time=7d
                    find /var/log -type f \( -name "*.gz" -o -name "*.1" -o -name "*.2" -o -name "*.3" \) \
                        -mtime +7 -exec rm -f {} \; 2>/dev/null
                    echo -e "${GREEN}✓ 系统日志清理完成${NC}"

                    echo -e "${CYAN}── 步骤 3/5: 清理 /tmp ──${NC}"
                    find /tmp -type f -mtime +7 -delete 2>/dev/null
                    find /tmp -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null
                    echo -e "${GREEN}✓ /tmp 清理完成${NC}"

                    echo -e "${CYAN}── 步骤 4/5: 清理 Docker ──${NC}"
                    if command -v docker &>/dev/null; then
                        docker system prune -f 2>/dev/null
                        docker volume prune -f 2>/dev/null
                        echo -e "${GREEN}✓ Docker 清理完成${NC}"
                    else
                        echo -e "${YELLOW}  未安装 Docker，跳过${NC}"
                    fi

                    echo -e "${CYAN}── 步骤 5/5: 清理旧内核 (Debian/Ubuntu) ──${NC}"
                    if command -v apt &>/dev/null; then
                        apt autoremove --purge -y 2>/dev/null
                        echo -e "${GREEN}✓ 旧内核清理完成${NC}"
                    else
                        echo -e "${YELLOW}  非 Debian/Ubuntu，跳过${NC}"
                    fi

                    echo ""
                    echo -e "${CYAN}======================================================${NC}"
                    echo -e "${GREEN}  ✅ 全部清理项目执行完毕！当前磁盘使用情况:${NC}"
                    df -h 2>/dev/null | grep -v 'tmpfs\|devtmpfs\|udev\|none\|squashfs\|overlay'
                else
                    echo -e "${YELLOW}已取消${NC}"
                fi
                sleep 2
                ;;
            0) return ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

# ================================================================
# 磁盘管理中心主菜单 (外部调用入口)
# ================================================================
disk_management_center() {
    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}           💾  硬盘检测与清理中心  v1.0              ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo ""

        # 实时磁盘简报
        local disk_root disk_pct num_pct disk_color
        disk_root=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')
        disk_pct=$(df / 2>/dev/null | awk 'NR==2{print $5}')
        num_pct=$(echo "$disk_pct" | tr -d '%')
        disk_color="${GREEN}"
        [ "${num_pct:-0}" -ge 75 ] 2>/dev/null && disk_color="${YELLOW}"
        [ "${num_pct:-0}" -ge 90 ] 2>/dev/null && disk_color="${RED}"

        echo -e " ${CYAN}●${NC} 根分区实时状态: ${disk_color}${disk_root}${NC}"
        echo ""
        echo " 1. 📊  硬盘使用总览     (分区 / 挂载点 / 使用率图示)"
        echo " 2. 🔍  大文件扫描       (查找占用最多空间的文件)"
        echo " 3. 📁  大目录扫描       (按目录统计占用排名)"
        echo " 4. 🗂  文件类型分析     (日志/压缩/视频/备份等分类)"
        echo " 5. 🕵️  inode 使用检测   (排查 inode 耗尽风险)"
        echo " 6. 🧹  一键清理辅助     (缓存/日志/tmp/Docker)"
        echo " 0. ↩  返回主菜单"
        echo ""
        echo -e "${CYAN}======================================================${NC}"
        read -p " 请输入选项 [0-6]: " sub_choice < /dev/tty

        case $sub_choice in
            1) _disk_show_overview     ;;
            2) _disk_find_large_files  ;;
            3) _disk_find_large_dirs   ;;
            4) _disk_analyze_by_type   ;;
            5) _disk_check_inode       ;;
            6) _disk_cleanup_assistant ;;
            0) return                  ;;
            *) echo -e "${RED}输入无效，请重新选择。${NC}"; sleep 1 ;;
        esac
    done
}
