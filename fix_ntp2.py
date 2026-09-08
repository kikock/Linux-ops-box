#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
修复1: _bash_ntp_probe null byte 警告
修复2: _setup_ntp_docker 增加离线/内网模式（硬件时钟作为NTP源）
"""

FILE = "system/modules/time_mgmt.sh"

with open(FILE, 'r', encoding='utf-8') as f:
    content = f.read()

# ============================================================
# 修复1: _bash_ntp_probe
# 去掉 ntp_pkt=$(printf ...) 命令替换，直接 printf >&9
# ============================================================
OLD_PROBE = r"""_bash_ntp_probe() {
    local host="${1:-127.0.0.1}"
    local timeout=3
    # 48 字节 NTP v3 客户端请求（LI=0, VN=3, Mode=3）
    local ntp_pkt
    ntp_pkt=$(printf '\x1b\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00')
    # 尝试打开 UDP 套接字（/dev/udp 是 Bash 内置虚拟文件）
    exec 9<>/dev/udp/${host}/123 2>/dev/null || return 1
    # 发送请求
    printf '%s' "$ntp_pkt" >&9 2>/dev/null || { exec 9>&-; return 1; }
    # 等待响应（read -t 超时读 1 字节）
    local resp
    IFS= read -r -t "$timeout" -d '' -n 1 resp <&9 2>/dev/null
    local rc=$?
    exec 9>&-
    # rc=0 或 read 因有数据而提前退出（rc=1 but resp非空）表示有响应
    if [ $rc -eq 0 ] || [ -n "$resp" ]; then
        return 0
    fi
    return 1
}"""

NEW_PROBE = r"""_bash_ntp_probe() {
    local host="${1:-127.0.0.1}"
    local timeout=3
    # 尝试打开 UDP 套接字（/dev/udp 是 Bash 内置虚拟文件）
    exec 9<>/dev/udp/${host}/123 2>/dev/null || return 1
    # 直接写入 48 字节 NTP v3 客户端请求（LI=0, VN=3, Mode=3）
    # 避免使用 $() 命令替换——Bash 会丢弃空字节并产生警告
    printf '\x1b\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' >&9 2>/dev/null \
        || { exec 9>&-; return 1; }
    # 等待响应（read -t 超时读 1 字节）
    local resp
    IFS= read -r -t "$timeout" -d '' -n 1 resp <&9 2>/dev/null
    local rc=$?
    exec 9>&-
    # rc=0 或 read 因有数据而提前退出（rc=1 but resp非空）均表示有响应
    if [ $rc -eq 0 ] || [ -n "$resp" ]; then
        return 0
    fi
    return 1
}"""

if OLD_PROBE in content:
    content = content.replace(OLD_PROBE, NEW_PROBE)
    print("✓ 修复1: _bash_ntp_probe null byte 已修复")
else:
    print("✗ 修复1: 未找到旧的 _bash_ntp_probe，检查内容...")
    idx = content.find("_bash_ntp_probe")
    print(f"  函数位置: {idx}")
    print(f"  附近内容: {repr(content[idx:idx+200])}")

# ============================================================
# 修复2: _setup_ntp_docker 增加离线/内网模式
# 在 [4/5] 配置 NTP 上游服务器 部分增加模式选择
# ============================================================
OLD_UPSTREAM = """    # --- 2.4 配置 NTP 上游服务器 ---
    echo -e "${BLUE}[4/5] 配置 NTP 上游服务器...${NC}"
    echo -e \"  默认上游: ${CYAN}${_NTP_UPSTREAM_DEFAULT}${NC}\"
    read -p \"  是否使用默认上游？直接回车=是，或输入自定义（逗号分隔）: \" custom_upstream < /dev/tty
    local ntp_upstream=\"${_NTP_UPSTREAM_DEFAULT}\"
    if [ -n \"$custom_upstream\" ]; then
        ntp_upstream=\"$custom_upstream\"
        echo -e \"  ${GREEN}✓ 使用自定义上游: ${ntp_upstream}${NC}\"
    else
        echo -e \"  ${GREEN}✓ 使用默认国内上游 NTP 源${NC}\"
    fi
    echo \"\""""

NEW_UPSTREAM = """    # --- 2.4 配置 NTP 上游服务器 ---
    echo -e "${BLUE}[4/5] 配置 NTP 上游服务器...${NC}"
    echo -e \"  ${YELLOW}请选择 NTP 时间源模式:${NC}\"
    echo -e \"  1. ${GREEN}联网模式${NC}（默认）— 从阿里云/腾讯云 NTP 同步（需要互联网）\"
    echo -e \"  2. ${CYAN}内网/离线模式${NC}   — 以本机硬件时钟(RTC)为时间源，供局域网设备同步\"
    echo -e \"  3. ${BLUE}自定义${NC}          — 手动输入 NTP 服务器地址\"
    read -p \"  请选择 [1-3，直接回车=1]: \" ntp_mode_choice < /dev/tty
    ntp_mode_choice=\"${ntp_mode_choice:-1}\"

    local ntp_upstream=\"\"
    local ntp_mode_label=\"\"
    local offline_mode=false

    case \"$ntp_mode_choice\" in
        2)
            # 离线/内网模式：使用 ntpd LOCAL 本地时钟驱动
            # 127.127.1.0 是 ntpd 的本地时钟 (LOCAL clock) 伪地址
            offline_mode=true
            ntp_mode_label=\"内网/离线模式（硬件时钟作为时间源）\"
            echo -e \"  ${CYAN}⏰ 检测本机硬件时钟状态...${NC}\"
            if hwclock --show &>/dev/null 2>&1; then
                local hw_now
                hw_now=\$(hwclock --show 2>/dev/null)
                echo -e \"  ${GREEN}✓ 硬件时钟(RTC)可用: ${hw_now}${NC}\"
            else
                echo -e \"  ${YELLOW}⚠ 无法读取硬件时钟（容器/虚拟机环境），将使用系统时钟代替${NC}\"
            fi
            echo -e \"  ${BLUE}ℹ 局域网模式: 本机将作为 NTP 服务器，内网设备指向本机 IP 同步时间${NC}\"
            echo -e \"  ${BLUE}  使用方法: 客户端执行 ntpdate -u <本机IP>${NC}\"
            ;;
        3)
            echo -e \"  ${BLUE}请输入自定义 NTP 服务器（逗号分隔，如: 192.168.1.1,ntp.aliyun.com）:${NC}\"
            read -p \"  NTP 服务器: \" custom_upstream < /dev/tty
            if [ -n \"$custom_upstream\" ]; then
                ntp_upstream=\"$custom_upstream\"
                ntp_mode_label=\"自定义上游: ${ntp_upstream}\"
            else
                ntp_upstream=\"${_NTP_UPSTREAM_DEFAULT}\"
                ntp_mode_label=\"默认国内上游（输入为空，已回退）\"
            fi
            ;;
        *)
            # 默认联网模式
            ntp_upstream=\"${_NTP_UPSTREAM_DEFAULT}\"
            ntp_mode_label=\"联网模式（阿里云/腾讯云 NTP）\"
            ;;
    esac

    echo -e \"  ${GREEN}✓ 时间源模式: ${ntp_mode_label}${NC}\"
    echo \"\""""

if OLD_UPSTREAM in content:
    content = content.replace(OLD_UPSTREAM, NEW_UPSTREAM)
    print("✓ 修复2: NTP 上游配置（离线模式）已更新")
else:
    print("✗ 修复2: 未找到旧的上游配置段，尝试关键词定位...")
    idx = content.find("是否使用默认上游")
    print(f"  关键词位置: {idx}")

# ============================================================
# 修复3: _setup_ntp_docker 容器启动时根据模式传入不同配置
# ============================================================
OLD_DOCKER_RUN = """    docker run -d \\
        --name \"$_NTP_CONTAINER_NAME\" \\
        --restart=always \\
        --cap-add SYS_TIME \\
        -p 123:123/udp \\
        -e NTP_SERVERS=\"${ntp_upstream}\" \\
        cturra/ntp:latest"""

NEW_DOCKER_RUN = """    if [ \"$offline_mode\" = true ]; then
        # ---- 内网/离线模式：挂载自定义 ntpd.conf，使用本机时钟驱动 ----
        local ntp_conf_dir=\"/etc/ntp-docker\"
        mkdir -p \"$ntp_conf_dir\"
        cat > \"${ntp_conf_dir}/ntpd.conf\" << 'NTP_CONF_EOF'
# ntpd.conf - 离线/内网模式（本机硬件时钟作为时间源）
# 由 Linux-ops-box 自动生成

# 本地时钟驱动 (LOCAL clock)，stratum 10 防止外部同步时优先级过高
server 127.127.1.0
fudge  127.127.1.0 stratum 10

# 允许局域网所有设备查询
restrict default kod nomodify notrap nopeer
restrict 127.0.0.1
restrict -6 ::1
restrict 10.0.0.0    mask 255.0.0.0 nomodify notrap
restrict 172.16.0.0  mask 255.240.0.0 nomodify notrap
restrict 192.168.0.0 mask 255.255.0.0 nomodify notrap

driftfile /var/lib/ntp/ntp.drift
NTP_CONF_EOF
        echo -e \"  ${CYAN}  已生成离线 ntpd 配置: ${ntp_conf_dir}/ntpd.conf${NC}\"

        docker run -d \\
            --name \"$_NTP_CONTAINER_NAME\" \\
            --restart=always \\
            --cap-add SYS_TIME \\
            -p 123:123/udp \\
            -v \"${ntp_conf_dir}/ntpd.conf:/etc/ntpd.conf:ro\" \\
            cturra/ntp:latest
    else
        # ---- 联网/自定义模式：通过 NTP_SERVERS 环境变量传入上游 ----
        docker run -d \\
            --name \"$_NTP_CONTAINER_NAME\" \\
            --restart=always \\
            --cap-add SYS_TIME \\
            -p 123:123/udp \\
            -e NTP_SERVERS=\"${ntp_upstream}\" \\
            cturra/ntp:latest
    fi"""

if OLD_DOCKER_RUN in content:
    content = content.replace(OLD_DOCKER_RUN, NEW_DOCKER_RUN)
    print("✓ 修复3: Docker run 命令（离线模式 ntpd.conf）已更新")
else:
    print("✗ 修复3: 未找到旧的 docker run 语句")

# ============================================================
# 写回文件
# ============================================================
with open(FILE, 'w', encoding='utf-8') as f:
    f.write(content)

print(f"\n文件已更新: {FILE}")
