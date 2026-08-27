# Nginx Proxy Manager 离线部署与自签 SSL 证书反代指南

本项目提供了在**纯内网 / 离线（无网络连接）服务器**上部署 **Nginx Proxy Manager (NPM)** 并结合**离线生成的自签 SSL 证书**，将公网/内网域名（如 `xxx.kikock.com`）通过 HTTPS 443 端口反向代理到本地 Docker 容器（8080 端口）的完整落地方案。

---

## 📂 目录结构说明

```text
npm_offline_deploy/
├── prepare_offline_image.sh   # [有网电脑] 负责下载并导出 NPM Docker 离线镜像包 (npm_image.tar)
├── deploy_npm.sh              # [无网服务器] 自动导入镜像并一键启动 NPM 容器
├── generate_cert.sh           # [无网服务器] 离线生成带 SAN 扩展的 10 年期自签 SSL 证书
├── docker-compose.yml         # NPM 容器编排定义文件 (支持 host.docker.internal 反代宿主机)
├── certs/                     # 生成的自签证书存放目录 (挂载进 NPM 容器)
├── data/                      # NPM 数据与数据库持久化目录
├── letsencrypt/               # 证书配置持久化目录
└── README.md                  # 本操作文档
```

## 📋 完整落地流程速查清单

| 步骤 | 操作要点 | 核心目的 / 检查项 |
|:---|:---|:---|
| **1. 调整原 Web 容器端口** | 确保原 Web 容器映射端口调整为 **`8080:8080`** (或 `8080:80`) | 💡 **重点**：把宿主机的 **`80`** 和 **`443`** 端口空出来，留给 NPM 网关统一接管。 |
| **2. 离线启动 NPM 容器** | 运行 `bash deploy_npm.sh`（占用宿主机 `80`、`443`、`81`） | NPM 容器启动后，即可作为全机统一的 HTTPS 流量调度网关。 |
| **3. 离线生成域名自签证书** | **推荐**：运行 `ck_sysinit`（或 `bash system/system_init.sh`），选择 **`12. SSL/TLS 证书管理中心`** -> **`5. 一键生成自签名 SSL 证书`**；<br>*（亦可直接运行 `bash generate_cert.sh`）* | 输入域名 `xxx.kikock.com`，全自动离线生成自带 SAN 扩展的 `.key` 私钥与 `.crt` 证书。 |
| **4. NPM UI 配置反代与证书** | 登录 `http://IP:81` 后操作：<br>① **SSL Certificates** -> **Add Custom Certificate** -> 粘贴生成的 `.key` 和 `.crt` 内容；<br>② **Proxy Hosts** -> 添加域名 `xxx.kikock.com` -> 转发到 `host.docker.internal:8080` -> 绑定证书并勾选 **Force SSL**。 | 图形化完成证书加载与 HTTPS 流量转发路由。 |
| **5. 验证与访问** | 浏览器访问：`https://xxx.kikock.com`<br>或终端测试：`curl -k -I https://xxx.kikock.com/` | 成功通过 HTTPS 加密隧道访问到映射在 8080 的 Web 业务页面。 |

```text
【用户浏览器】
      │  HTTPS (443) / HTTP (80)
      ▼
【Nginx Proxy Manager 网关】 (监听宿主机 80 / 443，负责 SSL 卸载)
      │  HTTP 转发至 host.docker.internal:8080
      ▼
【宿主机端口 8080】
      │  Docker 端口映射 (-p 8080:8080)
      ▼
【您的 Web 容器内部】 (监听 8080)
```

---

## 🚀 完整操作三部曲

### 第一阶段：在【有互联网连接的电脑】上准备

1. 进入 `npm_offline_deploy` 目录：
   ```bash
   cd npm_offline_deploy
   ```
2. 运行镜像导出脚本：
   ```bash
   bash prepare_offline_image.sh
   ```
   *脚本会自动拉取 `jc21/nginx-proxy-manager:latest` 镜像并打包为 `npm_image.tar`。*
3. 将整个 `Linux-ops-box` 文件夹（包含 `npm_offline_deploy` 及 `npm_image.tar`）拷贝至目标无网服务器。

---

### 第二阶段：在【无网目标服务器】上一键部署

1. 在无网服务器上进入 `npm_offline_deploy` 目录并启动 NPM：
   ```bash
   cd npm_offline_deploy
   chmod +x *.sh
   bash deploy_npm.sh
   ```
   *脚本会自动加载 `npm_image.tar` 并通过 Docker 启动 NPM 容器（监听 80、443、81 端口）。*

2. **使用工具箱生成域名自签 SSL 证书（推荐方式）**：
   ```bash
   ck_sysinit
   # 或进入 system 目录运行: bash system/system_init.sh
   ```
   * **操作步骤**：
     1. 主菜单选择 **`12. SSL/TLS 证书管理中心`**；
     2. 子菜单选择 **`5. 一键生成自签名 SSL 证书 (RSA 2048 + 10年)`**；
     3. 输入您的域名：`xxx.kikock.com`；
     4. 脚本将全自动生成私钥与证书，默认保存在 `/root/kikock_ssl/xxx.kikock.com/`：
        - 私钥文件：`/root/kikock_ssl/xxx.kikock.com/server.key`
        - 证书文件：`/root/kikock_ssl/xxx.kikock.com/server.crt`
   
   *(备用方式：亦可在 `npm_offline_deploy` 目录下直接执行 `bash generate_cert.sh`)*

---

### 第三阶段：NPM Web 界面配置（3 分钟完成）

1. **登录 NPM 管理后台**：
   - 浏览器打开：`http://<服务器IP>:81`
   - 默认账号：`admin@example.com`
   - 默认密码：`changeme`
   - *(首次登录请按提示修改邮箱和初始密码)*

2. **录入离线 SSL 证书**：
   - 点击顶部导航栏 **`SSL Certificates`**；
   - 点击右上角 **`Add SSL Certificate`** -> 选择 **`Custom`**；
   - **Name**: 填写 `xxx.kikock.com`；
   - **Certificate Key**: 打开服务器上生成的 `server.key`（或 `xxx_kikock_com.key`），复制全部文本内容粘贴进来；
   - **Certificate**: 打开服务器上生成的 `server.crt`（或 `xxx_kikock_com.crt`），复制全部文本内容粘贴进来；
   - 点击 **Save** 保存。

3. **配置反向代理规则 (Proxy Host)**：
   - 点击顶部导航栏 **`Hosts`** -> **`Proxy Hosts`** -> 点击 **`Add Proxy Host`**；
   - 在 **`Details`** 选项卡填写：
     - **Domain Names**: `xxx.kikock.com`
     - **Scheme**: `http`
     - **Forward Hostname / IP**: `host.docker.internal` *(NPM 已内置此映射)*
     - **Forward Port**: `8080` *(您的 Docker Web 容器端口)*
     - 勾选：
       -  **Block Common Exploits**
       -  **Websockets Support**
   - 切换到 **`SSL`** 选项卡：
     - **SSL Certificate**: 下拉选择刚添加的 `xxx.kikock.com` 证书；
     - 勾选：
       -  **Force SSL** *(自动将 HTTP 重定向至 HTTPS)*
       -  **HTTP/2 Support** *(开启性能加速)*
       -  **HSTS Enabled**
   - 点击 **Save** 保存。

---

## 🎯 验证与测试

在内网客户端电脑中，确保 Hosts 或内网 DNS 已将 `xxx.kikock.com` 指向服务器 IP：

```bash
# 测试 HTTPS 请求
curl -k -I https://xxx.kikock.com/
```

现在直接在浏览器访问：
```text
https://xxx.kikock.com
```
即可安全、无阻碍地通过 HTTPS 访问到映射在 `8080` 端口的 Docker Web 服务！

---

## 🔒 解决浏览器提示“不安全” / 导入受信任根证书指南

> 💡 **原理说明**：自签名证书是本地私有离线生成的，虽然通信数据链路已 **100% 经过 AES-256 高强度 SSL/TLS 加密**，但由于浏览器内置列表仅信任商业公共根 CA（如 DigiCert），初次访问会提示“不安全/证书不受信任”。只要在访问客户端导入一次证书，即可永久消除警告并显示**安全小绿锁 🔒**！

### 💻 Windows 客户端导入步骤（30秒完成）：
1. 在本地电脑找到生成的证书文件（如 `kikock.cn.crt`），**双击打开**；
2. 在证书属性弹窗中，点击底部的 **【安装证书...】**；
3. **存储位置**：选择 **【当前用户】**（或“本地计算机”），点击 **下一步**；
4. **证书存储**：勾选 **【将所有的证书都放入下列存储】** -> 点击 **【浏览...】**；
5. 在弹出的存储列表中，选中 **【受信任的根证书颁发机构】 (Trusted Root Certification Authorities)**，点击 **确定**；
6. 点击 **下一步** -> **完成**；
7. 弹出系统安全警告提示时，点击 **【是 (Yes)】** 确认导入；
8. **彻底关闭当前浏览器并重新打开**，再次访问 `https://xxx.kikock.com`，地址栏将立即显示安全小锁头 🔒！

---

### 🍏 macOS / iOS 客户端导入步骤：
1. 双击证书文件导入到 **【钥匙串访问 (Keychain Access)】** 中的“系统”或“登录”；
2. 双击该证书 -> 展开 **【信任 (Trust)】** 选项 -> 将“使用此证书时”修改为 **【始终信任 (Always Trust)】** 并保存。

---

### 🌐 公网环境免导入方案：
如果后续服务器接入了互联网，可直接使用工具箱的 **`ck_sysinit` -> `12. SSL/TLS 证书管理中心` -> `ACME 商业证书申请`**（基于 Let's Encrypt / ZeroSSL），任何公网客户端访问均无需手动导入，天然自带绿锁！
