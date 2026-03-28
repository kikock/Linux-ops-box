# 3. 离线安装 Docker 逻辑 (已优化解压路径)
install_docker_offline() {
    echo -e "\n${BLUE}--- 开始离线安装 Docker ---${NC}"
    
    if command -v docker &> /dev/null; then
        echo -e "${YELLOW}检测到系统已安装 Docker，脚本将进行覆盖升级/重置操作。${NC}"
    fi

    read -p "请输入 Docker 离线包名称 (如 docker-26.1.3.tgz): " TAR_NAME
    TAR_FILE="$BASE_DIR/docker/$TAR_NAME"
    TEMP_DIR="$BASE_DIR/dockerApp"
    
    if [ ! -f "$TAR_FILE" ]; then
        echo -e "${RED}错误: 在 $BASE_DIR/docker/ 目录下找不到文件 $TAR_NAME${NC}"
        return
    fi

    # 环境准备
    echo -e "${YELLOW}正在处理 SELinux ...${NC}"
    if [ -f /etc/selinux/config ]; then
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
        setenforce 0 2>/dev/null
    fi

    # 创建隔离的解压目录
    [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"

    echo -e "${YELLOW}正在解压 $TAR_NAME 到 $TEMP_DIR ...${NC}"
    tar -xzvf "$TAR_FILE" -C "$TEMP_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 解压失败。${NC}"
        rm -rf "$TEMP_DIR"
        return
    fi

    # 配置目录与文件分发 (从临时目录拷贝)
    echo -e "${YELLOW}分发二进制文件与配置...${NC}"
    [ ! -d "/etc/docker" ] && mkdir -p "/etc/docker"
    
    # 拷贝解压后的 etc 目录内容
    if [ -d "$TEMP_DIR/etc" ]; then
        cp -r "$TEMP_DIR/etc/"* /etc/
    fi
    
    # 拷贝解压后的 docker 二进制文件
    if [ -d "$TEMP_DIR/docker" ]; then
        cp "$TEMP_DIR/docker/"* /usr/bin/
    fi

    # 核心组件来源: $BASE_DIR/docker/ (统一规范的内核引擎读取池)
    if [ -f "$BASE_DIR/docker/docker.service" ]; then
        cp "$BASE_DIR/docker/docker.service" /usr/lib/systemd/system/
        chmod +x /usr/lib/systemd/system/docker.service
    else
        echo -e "${RED}警告: 在 $BASE_DIR/docker/ 目录下未发现 docker.service 文件。${NC}"
    fi

    echo -e "${YELLOW}正在加载配置并启动/重启 Docker 服务...${NC}"
    systemctl daemon-reload
    # 使用 restart 确保如果是覆盖安装能立即生效
    systemctl restart docker
    systemctl enable docker.service

    # 安装 docker-compose (来源: $BASE_DIR/docker/)
    if [ -f "$BASE_DIR/docker/docker-compose" ]; then
        echo -e "${YELLOW}配置 docker-compose...${NC}"
        cp "$BASE_DIR/docker/docker-compose" /usr/local/bin/
        chmod +x /usr/local/bin/docker-compose
        ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    fi

    # 清理临时解压目录
    echo -e "${YELLOW}清理临时文件...${NC}"
    rm -rf "$TEMP_DIR"

    echo -e "${GREEN}Docker 离线安装/更新任务执行完毕。${NC}"
    docker -v
}

# 4. 卸载 Docker 逻辑
uninstall_docker() {
    echo -e "\n${RED}--- 开始卸载 Docker ---${NC}"
    read -p "确定要彻底卸载 Docker 及其组件吗? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    systemctl stop docker 2>/dev/null
    systemctl disable docker 2>/dev/null
    rm -f /usr/bin/docker* /usr/bin/containerd* /usr/bin/runc /usr/bin/ctr
    rm -f /usr/local/bin/docker-compose /usr/bin/docker-compose
    rm -f /usr/lib/systemd/system/docker.service
    rm -rf /etc/docker
    systemctl daemon-reload
    echo -e "${GREEN}Docker 卸载完成。${NC}"
}

# 5. 常用 Docker 命令说明
show_docker_commands() {
    clear
    echo -e "${BLUE}================ 常用 Docker 命令参考 ================${NC}"
    echo -e "${YELLOW}[ 容器管理 ]${NC}"
    echo "  docker ps          - 查看运行中的容器"
    echo "  docker ps -a       - 查看所有容器 (包括已停止)"
    echo "  docker start [ID]  - 启动容器"
    echo "  docker stop [ID]   - 停止容器"
    echo "  docker restart [ID]- 重启容器"
    echo "  docker logs -f [ID]- 查看容器实时日志"
    echo "  docker exec -it [ID] /bin/bash - 进入容器终端"
    echo ""
    echo -e "${YELLOW}[ 镜像管理 ]${NC}"
    echo "  docker images      - 列出本地所有镜像"
    echo "  docker rmi [ID]    - 删除本地镜像"
    echo "  docker pull [NAME] - 从仓库拉取镜像"
    echo ""
    echo -e "${YELLOW}[ Docker Compose ]${NC}"
    echo "  docker-compose up -d  - 后台启动所有服务"
    echo "  docker-compose down   - 停止并移除所有服务"
    echo "  docker-compose ps     - 查看服务状态"
    echo -e "${BLUE}======================================================${NC}"
    echo ""
    read -p "按回车键返回..."
}

# 6. 安装 Docker Web 管理功能 (docker-fast)
install_docker_fast_web() {
    echo -e "\n${BLUE}--- 开始安装 Docker Web 管理终端 ---${NC}"
    
    # 检查 Docker 是否安装
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker。${NC}"
        return
    fi
    
    # 检查 docker-fast.yml 是否存在
    YML_FILE="$BASE_DIR/docker/docker-fast.yml"
    if [ ! -f "$YML_FILE" ]; then
        echo -e "${RED}错误: 在 $BASE_DIR/docker/ 目录下找不到 docker-fast.yml 文件。${NC}"
        return
    fi
    
    # 检查是否已经运行
    if docker ps --format '{{.Names}}' | grep -q "docker-fast"; then
        echo -e "${YELLOW}检测到 Docker-Fast 已在运行，将进行配置检查并尝试更新。${NC}"
    fi

    echo -e "${YELLOW}正在使用 docker-compose 部署/更新 Web 管理端...${NC}"
    
    # 优先尝试 docker-compose 命令，其次尝试 docker compose
    if command -v docker-compose &> /dev/null; then
        docker-compose -f "$YML_FILE" up -d
    elif docker compose version &> /dev/null; then
        docker compose -f "$YML_FILE" up -d
    else
        echo -e "${RED}错误: 未检测到 docker-compose，请检查安装情况。${NC}"
        return
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}成功: Docker Web 管理端已启动/更新。${NC}"
        echo -e "${BLUE}提示: 请检查 $YML_FILE 中的端口映射，并使用浏览器访问服务器 IP。${NC}"
    else
        echo -e "${RED}错误: 部署失败。${NC}"
    fi
}

# 7. Docker 管理二级菜单
docker_menu() {
    while true; do
        clear
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}             Docker 管理 (二级菜单)           ${NC}"
        echo -e "${GREEN}==============================================${NC}"
        echo " 1. 离线安装 Docker"
        echo " 2. 彻底卸载 Docker"
        echo " 3. 常用 Docker 命令说明"
        echo " 4. 安装 Docker Web 管理终端 (docker-fast)"
        echo " 0. 返回主菜单"
        echo -e "${GREEN}==============================================${NC}"
        read -p "请选择操作 [0-4]: " sub_choice

        case $sub_choice in
            1) install_docker_offline; read -p "按回车键继续..." ;;
            2) uninstall_docker; read -p "按回车键继续..." ;;
            3) show_docker_commands ;;
            4) install_docker_fast_web; read -p "按回车键继续..." ;;
            0) break ;;
            *) echo -e "${RED}无效输入。${NC}"; sleep 1 ;;
        esac
    done
}
