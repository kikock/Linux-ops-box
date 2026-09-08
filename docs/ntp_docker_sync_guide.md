# Linux 环境 NTP 服务 Docker 部署与客户端同步实践指南

本文档提供从零搭建 **A主机（Docker NTP 时间服务器）** 与 **B主机（NTP 客户端同步）** 的完整工程化操作指南，涵盖**联网同步**与**纯内网/离线孤岛**两种典型场景。

---

## 目录
- [1. 方案架构与环境准备](#1-方案架构与环境准备)
- [2. A主机：部署 NTP Docker 服务端](#2-a主机部署-ntp-docker-服务端)
  - [2.1 宿主机环境前置准备](#21-宿主机环境前置准备)
  - [2.2 场景一：联网模式部署（公网上游授时）](#22-场景一联网模式部署公网上游授时)
  - [2.3 场景二：纯内网/离线孤岛部署（本机硬件时钟授时）](#23-场景二纯内网离线孤岛部署本机硬件时钟授时)
  - [2.4 防火墙与网络安全策略放行](#24-防火墙与网络安全策略放行)
  - [2.5 服务端健康状态检验](#25-服务端健康状态检验)
- [3. B主机：配置 NTP 客户端同步](#3-b主机配置-ntp-客户端同步)
  - [3.1 方案一：Chrony 客户端（生产环境强烈推荐）](#31-方案一chrony-客户端生产环境强烈推荐)
  - [3.2 方案二：systemd-timesyncd 轻量客户端（现代 Linux 默认）](#32-方案二systemd-timesyncd-轻量客户端现代-linux-默认)
  - [3.3 方案三：ntpdate 单次同步 + Crontab 定时（传统应急方案）](#33-方案三ntpdate-单次同步--crontab-定时传统应急方案)
  - [3.4 方案四：使用运维工具一键健康检测（支持任意 IP+端口）](#34-方案四使用运维工具一键健康检测支持任意-ip端口)
- [4. 双机联调验证](#4-双机联调验证)
- [5. 核心避坑与故障排查速查表 (FAQ)](#5-核心避坑与故障排查速查表-faq)

---

## 1. 方案架构与环境准备

### 1.1 节点规划示例

| 主机角色 | 示例 IP | 部署组件 | 功能描述 |
| :--- | :--- | :--- | :--- |
| **A 主机** (Server) | `192.168.1.100` | Docker (`cturra/ntp`) | NTP 服务端，对外提供 UDP 123 端口时间校准 |
| **B 主机** (Client) | `192.168.1.101` | Chrony / systemd-timesyncd / ntpdate | NTP 客户端，定期向 A 主机同步时间 |

### 1.2 网络与协议要求
- **协议与端口**：`UDP 123`（NTP 协议默认通信端口）。
- **连通性**：B 主机必须能在网络层访问 A 主机的 `UDP 123` 端口。

---

## 2. A主机：部署 NTP Docker 服务端

### 2.1 宿主机环境前置准备

#### ① 统一系统时区为东八区（Asia/Shanghai）
```bash
sudo timedatectl set-timezone Asia/Shanghai
date
```

#### ② 检查并释放宿主机 123 端口
由于 NTP 使用 `UDP 123` 端口，如果宿主机本身运行了 `chronyd`、`ntpd` 或其他 NTP 服务，会导致 Docker 端口映射冲突（报错 `bind: address already in use`）：
```bash
# 检查 123 端口占用
sudo ss -ulpn | grep :123

# 若被 chronyd 占用，停止并禁用宿主机 chronyd
sudo systemctl stop chronyd && sudo systemctl disable chronyd

# 若被 ntpd 占用，停止并禁用宿主机 ntpd
sudo systemctl stop ntp && sudo systemctl disable ntp

# 若被 systemd-timesyncd 占用（通常只作客户端，不监听 123，若有则停用）
sudo systemctl stop systemd-timesyncd && sudo systemctl disable systemd-timesyncd
```

---

### 2.2 场景一：联网模式部署（公网上游授时）
> **适用场景**：A 主机能够访问公网，从外部优质 NTP 源（阿里云、腾讯云、国家授时中心）同步高精度时间，并作为内网中继节点为 B 主机授时。

推荐使用官方成熟轻量级镜像 `cturra/ntp`（基于 Alpine Linux + ntpd）：

#### 方式 A：Docker CLI 单行启动
```bash
docker run -d \
  --name ntp-server \
  --restart=always \
  --cap-add SYS_TIME \
  -p 123:123/udp \
  -e NTP_SERVERS="ntp.aliyun.com,ntp.tencent.com,cn.ntp.org.cn" \
  cturra/ntp:latest
```

#### 方式 B：Docker Compose 编排启动
创建文件 `/data/ntp/docker-compose.yml`：
```yaml
version: '3.8'

services:
  ntp-server:
    image: cturra/ntp:latest
    container_name: ntp-server
    restart: always
    cap_add:
      - SYS_TIME
    ports:
      - "123:123/udp"
    environment:
      - NTP_SERVERS=ntp.aliyun.com,ntp.tencent.com,cn.ntp.org.cn,pool.ntp.org
```
启动容器：
```bash
cd /data/ntp && docker compose up -d
```

> **参数说明**：
> - `--cap-add SYS_TIME`：必须赋予容器调整内核时间的 Linux Capability，否则 ntpd 无法校准时钟。
> - `-p 123:123/udp`：将容器的 NTP 端口以 UDP 协议映射至宿主机。

---

### 2.3 场景二：纯内网/离线孤岛部署（本机硬件时钟授时）
> **适用场景**：A 主机处于完全隔离的涉密内网或无外网环境。A 主机以**自身硬件时钟（RTC/Local Clock）**作为基准源（Stratum 10），为局域网内的 B 主机等所有设备提供时间统一基准。

#### 步骤 1：先校准 A 主机的硬件时钟
在部署前，务必先手动校准好 A 主机的当前系统时间，并写入主板硬件时钟：
```bash
# 格式：YYYY-MM-DD hh:mm:ss
sudo date -s "2026-09-08 23:00:00"

# 将系统时间写入硬件时钟 (RTC)
sudo hwclock --systohc

# 查看硬件时钟确认
sudo hwclock --show
```

#### 步骤 2：生成自定义 ntpd.conf 配置文件
```bash
sudo mkdir -p /etc/ntp-docker

sudo cat > /etc/ntp-docker/ntpd.conf << 'EOF'
# ntpd.conf - 纯内网/离线模式配置文件
# 使用本地时钟驱动 (LOCAL Clock 127.127.1.0)
server 127.127.1.0
fudge  127.127.1.0 stratum 10

# 访问控制权限
restrict default kod nomodify notrap nopeer
restrict 127.0.0.1
restrict -6 ::1

# 允许私有局域网网段设备进行时间查询
restrict 10.0.0.0    mask 255.0.0.0 nomodify notrap
restrict 172.16.0.0  mask 255.240.0.0 nomodify notrap
restrict 192.168.0.0 mask 255.255.0.0 nomodify notrap

driftfile /var/lib/ntp/ntp.drift
EOF
```

#### 步骤 3：启动离线模式容器
```bash
docker run -d \
  --name ntp-server \
  --restart=always \
  --cap-add SYS_TIME \
  -p 123:123/udp \
  -v /etc/ntp-docker/ntpd.conf:/etc/ntpd.conf:ro \
  cturra/ntp:latest
```

---

### 2.4 防火墙与网络安全策略放行

根据 A 主机操作系统的防火墙类型，放行 UDP 123 端口：

#### 若使用 Firewalld (CentOS / RHEL / Rocky / openEuler / 统信UOS)
```bash
sudo firewall-cmd --add-port=123/udp --permanent
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports | grep 123
```

#### 若使用 UFW (Ubuntu / Debian)
```bash
sudo ufw allow 123/udp
sudo ufw status | grep 123
```

#### 若使用 Iptables
```bash
sudo iptables -A INPUT -p udp --dport 123 -j ACCEPT
```

---

### 2.5 服务端健康状态检验

#### ① 检查容器运行状态与日志
```bash
docker ps -f name=ntp-server
docker logs -f ntp-server
```
*正常日志输出应显示 ntpd 启动成功并正在监听端口。*

#### ② 在 A 主机本地执行 UDP 端口自检
```bash
# 查看宿主机是否在监听 UDP 123
sudo ss -ulpn | grep :123
```

#### ③ 使用 Bash 原生 UDP 套接字探测（无需额外工具）
```bash
timeout 3 bash -c 'exec 9<>/dev/udp/127.0.0.1/123 && printf "\x1b\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" >&9 && read -r -t 2 -n 1 <&9' && echo "✓ NTP UDP 123 端口响应正常" || echo "✗ NTP 无响应"
```

---

## 3. B主机：配置 NTP 客户端同步

在 B 主机（`192.168.1.101`）上同步 A 主机（`192.168.1.100`）的时间。根据生产需求选择以下三种方案之一：

### 3.1 方案一：Chrony 客户端（生产环境强烈推荐）
> **推荐理由**：Chrony 相比传统 ntpdate 的核心优势在于**平滑同步（Slew）**机制。若时间相差较小，Chrony 会通过微调时钟频率让时间逐步逼近，**绝不发生时间后退**，保障 MySQL、Kafka、Redis、ES 等分布式系统不会因时间骤变产生数据死锁或租约超时。

#### 步骤 1：安装 Chrony
- **Ubuntu / Debian**:
  ```bash
  sudo apt update && sudo apt install -y chrony
  ```
- **CentOS / RHEL / Rocky / openEuler / 麒麟 / 统信**:
  ```bash
  sudo dnf install -y chrony || sudo yum install -y chrony
  ```

#### 步骤 2：修改配置文件
备份原配置并编辑配置文件（Ubuntu 位于 `/etc/chrony/chrony.conf`，CentOS 位于 `/etc/chrony.conf`）：
```bash
# 自动定位配置文件路径
CONF_FILE="/etc/chrony.conf"
[ ! -f "$CONF_FILE" ] && CONF_FILE="/etc/chrony/chrony.conf"

sudo cp "$CONF_FILE" "${CONF_FILE}.bak"

# 覆盖配置，指向 A 主机
sudo tee "$CONF_FILE" > /dev/null << 'EOF'
# 指向 A 主机 NTP 服务器，iburst 选项允许在刚启动时快速突发同步
server 192.168.1.100 iburst minpoll 4 maxpoll 6

# 前 3 次更新中，若时钟偏差大于 1.0 秒允许步进跳变(Step)，之后进入严格平滑微调(Slew)
makestep 1.0 3

# 记录时钟漂移率
driftfile /var/lib/chrony/drift

# 允许根据系统时钟更新硬件时钟 (RTC)
rtcsync

# 禁用本机对外充当 NTP 服务器（作为纯客户端）
port 0

logdir /var/log/chrony
EOF
```

#### 步骤 3：重启并启用 Chrony 服务
- **Debian / Ubuntu**:
  ```bash
  sudo systemctl restart chrony
  sudo systemctl enable chrony
  ```
- **RHEL / CentOS / 麒麟**:
  ```bash
  sudo systemctl restart chronyd
  sudo systemctl enable chronyd
  ```

#### 步骤 4：查看同步状态与生效检验
```bash
# 查看 NTP 源服务器状态
chronyc sources -v
```
**输出判定**：
- 若 A 主机地址前带有 `^*` 符号（例如 `^* 192.168.1.100`），表示**已成功锁定并作为当前首选同步源**！
- 若带 `^?` 符号，表示仍在尝试握手或网络未联通，请等待 15~30 秒再次执行。

```bash
# 查看详细跟踪与偏差指标
chronyc tracking
```
重点关注：
- `Reference ID`：应显示 A 主机 IP 或其标识。
- `Stratum`：层级（若 A 是联网模式通常为 2~3，离线模式为 11）。
- `System time`：系统时间偏差量（通常在微秒或毫秒级别）。

---

### 3.2 方案二：systemd-timesyncd 轻量客户端（现代 Linux 默认）
> **适用场景**：轻量级容器宿主机、Ubuntu 默认系统，不想额外安装 Chrony 时使用。

#### 步骤 1：配置 timesyncd
编辑 `/etc/systemd/timesyncd.conf`：
```ini
[Time]
NTP=192.168.1.100
FallbackNTP=ntp.aliyun.com
RootDistanceMaxSec=5
PollIntervalMinSec=32
PollIntervalMaxSec=2048
```

#### 步骤 2：启动并检查
```bash
# 重启并启用服务
sudo systemctl restart systemd-timesyncd
sudo systemctl enable systemd-timesyncd

# 查看同步状态
timedatectl timesync-status
```
输出中若 `Server: 192.168.1.100` 且 `Offset` 显示正常数值，即表示同步成功。

---

### 3.3 方案三：ntpdate 单次同步 + Crontab 定时（传统应急方案）
> **适用场景**：存量老旧系统（CentOS 6/7 等），或仅需手动执行单次快速对齐。
> ⚠️ **注意**：`ntpdate` 是直接步进跳变修改时间，不建议在高并发数据库节点直接通过 crontab 频繁运行。

#### 步骤 1：安装 ntpdate
```bash
# Ubuntu / Debian
sudo apt install -y ntpdate

# CentOS / RHEL
sudo yum install -y ntpdate
```

#### 步骤 2：手动单次执行对齐
```bash
# 关键参数 -u：使用非特权端口发送 NTP 查询，防止被防火墙拦截或与本地端口冲突
sudo ntpdate -u 192.168.1.100

# 同步成功后，将系统时间写入主板 RTC
sudo hwclock --systohc
```

#### 步骤 3：配置 Crontab 周期性同步
```bash
# 编写定时任务（例如每小时的第 10 分钟同步一次）
(crontab -l 2>/dev/null; echo "10 * * * * /usr/sbin/ntpdate -u 192.168.1.100 && /sbin/hwclock --systohc >/dev/null 2>&1") | crontab -
```

---

### 3.4 方案四：使用运维工具一键健康检测（支持任意 IP+端口）
> 本项目 `system/modules/time_mgmt.sh` 提供了交互式 NTP 健康检测功能，支持检测**本机**或**远端任意 NTP 服务器及自定义端口**。

#### 操作步骤：
1. 运行时间管理菜单：
   ```bash
   bash system/system_init.sh
   # 选择时间管理模块，或直接调用：
   bash -c 'source system/modules/time_mgmt.sh && _check_ntp_health'
   ```
2. 选择检测模式：
   - **选项 1**：检测本机 NTP 服务（默认 `127.0.0.1:123`，包含 Docker 容器状态、本机端口监听、NTP 协议及系统时间）。
   - **选项 2**：检测远程其他服务器（支持输入 `IP` 或 `IP:端口`，例如 `192.168.1.100`、`192.168.1.100:123` 或自定义端口 `192.168.1.100:1123`）。
3. 工具自动化执行四阶段诊断：
   - `[1/4]` **ICMP Ping 连通性**：判断网络路由是否可达。
   - `[2/4]` **UDP 端口通信探测**：建立 UDP 通信信道。
   - `[3/4]` **NTP 协议层握手与质量探测**：若有 `ntpdate`/`ntpq` 工具则输出 Stratum、Offset、Delay 参数；若无客户端工具或为非标准端口，自动使用原生 48 字节 NTP v3 协议包进行精准底层探测。
   - `[4/4]` **诊断汇总与配置建议**：给出健康评级、客户端单次同步命令及 Chrony 配置片段建议。

---

## 4. 双机联调验证

完成上述配置后，按以下测试用例验证整套时间同步链路：

### 阶段一：网络层联通性检验（B主机 -> A主机）
在 B 主机测试能否触达 A 主机 UDP 123 端口：
```bash
# 使用 nc (netcat) 测试 UDP 连通性
nc -z -v -u 192.168.1.100 123
```
*提示 `Connection to 192.168.1.100 123 port [udp/ntp] succeeded!` 说明链路正常。*

### 阶段二：手动单次验证抓取（B主机）
在 B 主机临时运行探测（不会修改本地时间，仅查询）：
```bash
# 使用 ntpdate -q (query only) 模拟查询
ntpdate -q 192.168.1.100
```
成功响应示例：
```text
server 192.168.1.100, stratum 2, offset 0.001245, delay 0.02612
8 Sep 23:15:00 ntpdate[18942]: adjust time server 192.168.1.100 offset 0.001245 sec
```

### 阶段三：模拟时间漂移校准测试
1. 在 B 主机故意将时间拨慢 5 分钟：
   ```bash
   sudo date -s "-5 minutes"
   date
   ```
2. 触发同步（以 Chrony 为例）：
   ```bash
   sudo chronyc makestep
   date
   ```
3. 检查 B 主机时间是否瞬间与 A 主机完全一致。

---

## 5. 核心避坑与故障排查速查表 (FAQ)

### Q1: B主机提示 `no server suitable for synchronization found`
| 可能原因 | 排查与解决方案 |
| :--- | :--- |
| **原因 1：A主机容器刚启动，尚未就绪** | NTP 服务启动后，需要至少 **15 ~ 60 秒**与上游完成时钟滤波和收敛。在收敛完成前，容器对外宣告自身的 Stratum 为 16（代表时钟不可信），客户端会自动忽略。**请等待 1 分钟后重试**。 |
| **原因 2：A主机防火墙未放行 UDP 123** | 在 A 主机执行 `sudo firewall-cmd --add-port=123/udp --permanent && sudo firewall-cmd --reload` 或 `sudo ufw allow 123/udp`。 |
| **原因 3：内网离线模式未配置 fudge stratum** | 在内网离线模式下，若 `ntpd.conf` 未配置 `fudge 127.127.1.0 stratum 10`，ntpd 也会判定本地源无效（Stratum 16）。严格按照 2.3 节挂载配置。 |

---

### Q2: A主机启动 Docker 报错 `bind: address already in use`
- **根因**：A 宿主机自带的 `chronyd` 或 `ntpd` 服务占用了 `0.0.0.0:123` UDP 端口。
- **解决**：
  ```bash
  sudo systemctl stop chronyd ntpd
  sudo systemctl disable chronyd ntpd
  # 重新运行 docker run
  ```

---

### Q3: 为什么必须给容器加 `--cap-add SYS_TIME`？
- **根因**：Docker 容器默认处于未提权状态，无权调用宿主机的底层内核时间系统调用 `adjtimex`。
- **解决**：启动参数必须显式声明 `--cap-add SYS_TIME`，赋予容器调整内核时钟的能力。

---

### Q4: 客户端报 `the NTP socket is in use, exiting`
- **根因**：B 主机正在运行 `chronyd` 或后台 `ntpd` 服务，独占了本地 123 端口，此时直接执行 `ntpdate 192.168.1.100` 会冲突。
- **解决**：加上 `-u` 参数使用高位非特权端口查询：
  ```bash
  ntpdate -u 192.168.1.100
  ```
  或者使用客户端自身管理命令：`chronyc makestep`。

---

### Q5: 为什么生产环境不要用 `ntpdate` 频繁定时强刷时间？
- `ntpdate` 采用**阶跃修改（Step）**，如果前一次时间慢了 2 秒，它会瞬间把时钟往回拨 2 秒。
- **危害**：
  - 数据库事务出现“过去的时间戳”，导致主从同步延迟报警或死锁。
  - 日志记录顺序错乱。
  - 监控系统触发异常告警。
- **正解**：生产环境必须采用 **Chrony**，让时钟通过走快或走慢（Slew）平滑对齐。
