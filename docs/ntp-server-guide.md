# NTP 时间同步使用指南

> **适用场景：** A 主机作为 NTP 服务器（Docker 容器），B 主机/内网其他设备向 A 主机同步时间。  
> **模块位置：** 工具箱主菜单 → `14. 系统时间管理中心`

---

## 整体架构

```
┌─────────────────────────────────────────────────────────────────┐
│  互联网 NTP                                                      │
│  ntp.aliyun.com / ntp.tencent.com                               │
└────────────────────────────┬────────────────────────────────────┘
                             │ 上游同步（可选，联网环境）
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  A 主机（NTP 服务器）                                            │
│  ┌──────────────────────────────────────┐                       │
│  │  Docker 容器: ntp-server             │                       │
│  │  镜像: cturra/ntp                    │                       │
│  │  监听: UDP 0.0.0.0:123              │                       │
│  └──────────────────────────────────────┘                       │
│  IP: 192.168.1.100（示例，替换为实际 IP）                        │
└────────────────────────────┬────────────────────────────────────┘
                             │ UDP 123 内网广播
          ┌──────────────────┼──────────────────┐
          ▼                  ▼                  ▼
   B 主机           C 主机           D 主机/设备
 (ntpdate/chrony)  (timedatectl)    (任意支持NTP的设备)
```

---

## 第一步：A 主机 — 部署 Docker NTP 服务器

### 前提条件

- Docker 已安装并运行（工具箱菜单 `9. Docker 管理中心`）
- 防火墙已放通 **UDP 123** 端口

### 方法一：通过工具箱菜单（推荐）

```bash
# 运行工具箱
ck_sysinit

# 选择: 14 → 系统时间管理中心
# 选择: 2  → 部署 Docker NTP 服务器
# 选择时间源模式:
#   1 = 联网模式（从阿里云/腾讯云 NTP 同步后对外提供）
#   2 = 内网/离线模式（以本机硬件时钟 RTC 为时间源）
```

### 方法二：手动命令部署

**联网模式**（A 主机能访问互联网）：

```bash
docker run -d \
  --name ntp-server \
  --restart=always \
  --cap-add SYS_TIME \
  -p 123:123/udp \
  -e NTP_SERVERS="ntp.aliyun.com,ntp.tencent.com,cn.ntp.org.cn" \
  cturra/ntp:latest
```

**离线/内网模式**（A 主机无网，以硬件时钟为源）：

```bash
# 1. 创建自定义 ntpd 配置
mkdir -p /etc/ntp-docker
cat > /etc/ntp-docker/ntpd.conf << 'EOF'
# 使用本机硬件时钟（LOCAL clock driver）
server 127.127.1.0
fudge  127.127.1.0 stratum 10

# 允许局域网段查询（按实际网段修改）
restrict default kod nomodify notrap nopeer
restrict 127.0.0.1
restrict 192.168.0.0 mask 255.255.0.0 nomodify notrap
restrict 10.0.0.0    mask 255.0.0.0   nomodify notrap

driftfile /var/lib/ntp/ntp.drift
EOF

# 2. 启动容器并挂载配置
docker run -d \
  --name ntp-server \
  --restart=always \
  --cap-add SYS_TIME \
  -p 123:123/udp \
  -v /etc/ntp-docker/ntpd.conf:/etc/ntpd.conf:ro \
  cturra/ntp:latest
```

### 验证 A 主机 NTP 服务是否正常

```bash
# 查看容器状态
docker ps | grep ntp-server

# 查看容器日志（正常应看到 ntpd 同步日志）
docker logs --tail 20 ntp-server

# 检测本机 UDP 123 端口是否监听
ss -ulnp | grep 123

# 本机自测（需要安装 ntpdate）
ntpdate -q 127.0.0.1
```

---

## 第二步：A 主机 — 防火墙放通 UDP 123

工具箱菜单 `5. 防火墙安全管理中心` → 添加端口规则，或手动执行：

```bash
# UFW（Ubuntu/Debian）
ufw allow 123/udp
ufw reload

# FirewallD（CentOS/RHEL/麒麟 RPM）
firewall-cmd --permanent --add-port=123/udp
firewall-cmd --reload

# iptables（通用）
iptables -A INPUT -p udp --dport 123 -j ACCEPT
iptables-save > /etc/iptables/rules.v4
```

---

## 第三步：B 主机 — 同步到 A 主机的 NTP 服务

假设 A 主机 IP 为 `192.168.1.100`，请替换为实际地址。

### 方案一：ntpdate 单次立即同步（最简单）

```bash
# 安装 ntpdate（如未安装）
# Debian/Ubuntu/麒麟 APT
apt install -y ntpdate

# CentOS/RHEL/麒麟 RPM
yum install -y ntpdate   # 或 dnf install -y ntpdate

# 执行同步（-u 参数绕过防火墙限制）
ntpdate -u 192.168.1.100

# 同步后将系统时间写入硬件时钟
hwclock --systohc
```

### 方案二：通过工具箱一键同步（推荐）

```bash
# B 主机运行工具箱
ck_sysinit
# 选择: 14 → 系统时间管理中心
# 选择: 4  → 配置时间同步脚本（开机自启）
# 在 NTP 服务器列表中填入 A 主机 IP: 192.168.1.100
```

工具箱会自动生成同步脚本 `/usr/local/bin/ntp-sync.sh` 并注册 Systemd 开机服务。

### 方案三：chrony 持续守护同步（生产推荐）

```bash
# 安装 chrony（麒麟系统也适用）
apt install -y chrony       # Debian/Ubuntu/麒麟 APT
yum install -y chrony       # CentOS/RHEL/麒麟 RPM

# 编辑 chrony 配置
cat > /etc/chrony.conf << 'EOF'
# 优先同步 A 主机 NTP 服务器
server 192.168.1.100 iburst prefer

# 备用公网（可选，内网环境删除）
# server ntp.aliyun.com iburst

# 允许本机作为时间源
local stratum 10

# 记录时钟漂移
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF

# 重启并设置开机自启
systemctl restart chronyd    # RHEL/麒麟 RPM
# 或
systemctl restart chrony     # Debian/Ubuntu

systemctl enable chronyd

# 验证同步状态
chronyc tracking
chronyc sources -v
```

### 方案四：timedatectl 系统级 NTP 配置（Systemd 环境）

```bash
# 编辑 systemd-timesyncd 配置
cat > /etc/systemd/timesyncd.conf << 'EOF'
[Time]
NTP=192.168.1.100
FallbackNTP=ntp.aliyun.com
EOF

# 重启并验证
systemctl restart systemd-timesyncd
timedatectl set-ntp true
timedatectl status
```

---

## 第四步：B 主机 — 配置开机自动同步（ntp-sync 脚本方式）

如果使用工具箱生成的同步脚本：

```bash
# 查看生成的同步脚本
cat /usr/local/bin/ntp-sync.sh

# 手动测试执行
bash /usr/local/bin/ntp-sync.sh

# 查看同步日志
cat /var/log/ntp-sync.log

# 查看 Systemd 服务状态
systemctl status ntp-sync.service

# 验证开机自启
systemctl is-enabled ntp-sync.service
```

---

## 验证对时效果

### 在 B 主机执行

```bash
# 方法1: ntpdate 查询（不实际同步）
ntpdate -q 192.168.1.100
# 正常输出示例:
# server 192.168.1.100, stratum 11, offset +0.002345, delay 0.02678

# 方法2: chronyc 查看同步源
chronyc sources -v
# 正常输出示例:
# MS Name/IP address   Stratum  Poll  Reach  LastRx  Last sample
# ^* 192.168.1.100          11     6    377    52    +0.123ms  +-0.456ms

# 方法3: 查看当前系统时间与偏差
timedatectl status
date
```

### 在 A 主机执行（查看哪些客户端在同步）

```bash
# 查看 NTP 客户端连接
docker logs ntp-server 2>&1 | grep -i "client\|sync"

# 若安装了 ntpq
ntpq -p 127.0.0.1
```

---

## 常见问题排查

| 问题 | 原因 | 解决方案 |
|------|------|---------|
| `ntpdate: no server suitable for synchronization found` | A 主机防火墙未放通 UDP 123 | `ufw allow 123/udp` 或 `firewall-cmd --add-port=123/udp` |
| `Connection refused` | Docker 容器未运行 | `docker start ntp-server` |
| B 主机时间同步后又漂移 | 未写入硬件时钟 | 同步后执行 `hwclock --systohc` |
| `ntpdate` 命令不存在 | 未安装 | 工具箱 `14 → 7 → 安装 NTP 客户端工具` |
| 麒麟 RPM 系统安装 ntpdate 失败 | V10 Server 仓库无此包 | 改用 chrony（工具箱选项 1）|
| 时间偏差超过 1000 秒，ntpdate 拒绝同步 | 时间差太大 | 先手动设置大概时间: `date -s "2026-09-08 22:00:00"` 再同步 |

---

## 快速命令速查

```bash
# ===== A 主机（NTP 服务器）=====
docker ps | grep ntp                     # 查看容器状态
docker logs --tail 30 ntp-server         # 查看日志
docker restart ntp-server                # 重启服务
ss -ulnp | grep 123                      # 确认端口监听

# ===== B 主机（NTP 客户端）=====
ntpdate -u 192.168.1.100                 # 立即同步（替换 IP）
ntpdate -q 192.168.1.100                 # 查询不同步
chronyc tracking                         # chrony 同步状态
chronyc sources -v                       # chrony 源列表
timedatectl status                       # 系统时间状态
hwclock --show                           # 硬件时钟
hwclock --systohc                        # 系统时间→硬件时钟
cat /var/log/ntp-sync.log               # 工具箱同步日志
```

---

> 📌 **文档版本**: v1.0 · 2026-09-08  
> 📌 **工具箱版本**: Linux-ops-box v2.1+  
> 📌 **作者**: kikock  
> 📌 **适配系统**: Ubuntu / Debian / CentOS / RHEL / Rocky / 银河麒麟 / 统信UOS / openEuler / Anolis
