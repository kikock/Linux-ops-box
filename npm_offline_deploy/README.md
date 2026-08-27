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
| **3. 离线生成域名自签证书** | 运行 `bash generate_cert.sh` 或使用 `ck_sysinit` 选 **15** | 输入 `xxx.kikock.com`，生成自带 SAN 扩展的 `.key` 和 `.crt` 文件。 |
| **4. NPM UI 配置反代与证书** | 登录 `http://IP:81` 后操作：<br>① **SSL 证书** -> **自定义证书** -> 粘贴 `.key` 和 `.crt` 内容；<br>② **代理服务 (Proxy Hosts)** -> 添加域名 `xxx.kikock.com` -> 转发到 `host.docker.internal:8080` -> 绑定证书并勾选 **Force SSL**。 | 图形化完成证书加载与 HTTPS 流量转发路由。 |
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
3. 将整个 `npm_offline_deploy` 文件夹（包含 `npm_image.tar`）拷贝至目标无网服务器。

---

### 第二阶段：在【无网目标服务器】上一键部署

1. 在无网服务器上进入该目录并赋予执行权限：
   ```bash
   cd npm_offline_deploy
   chmod +x *.sh
   ```

2. 运行一键部署脚本：
   ```bash
   bash deploy_npm.sh
   ```
   *脚本会自动加载 `npm_image.tar` 并通过 Docker 启动 NPM 容器（监听 80、443、81 端口）。*

3. 离线生成域名自签 SSL 证书：
   ```bash
   bash generate_cert.sh
   ```
   *根据提示输入您的域名（如 `xxx.kikock.com`），脚本将自动在 `certs/xxx_kikock_com/` 目录下生成带有 SAN 扩展的 `.crt` 证书与 `.key` 私钥。*

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
   - **Certificate Key**: 打开服务器上生成的 `certs/xxx_kikock_com/xxx_kikock_com.key`，复制全部文本内容粘贴进来；
   - **Certificate**: 打开服务器上生成的 `certs/xxx_kikock_com/xxx_kikock_com.crt`，复制全部文本内容粘贴进来；
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
