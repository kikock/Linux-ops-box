#!/bin/bash
# =================================================================
# 脚本名称: db_manager.sh
# 描述: 数据库备份/恢复/配置/定时任务管理工具
# 支持: MySQL / PostgreSQL（含 Docker 容器模式）
# 作者: kikock
# 版本: v2.0 - 新增 Docker 容器连接模式
# =================================================================

# ── 颜色 ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── 脚本目录 & 配置文件路径 ────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.db"
CONFIG_FILE="$SCRIPT_DIR/db_connections.json"

# ── 加载 .env.db ──────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/backups}"
MAX_BACKUPS="${MAX_BACKUPS:-10}"
BACKUP_COMPRESS="${BACKUP_COMPRESS:-gzip}"
BACKUP_PREFIX="${BACKUP_PREFIX:-db_backup}"
DB_CONFIG_FILE="${DB_CONFIG_FILE:-$CONFIG_FILE}"
ARCHIVE_CONFIG="${ARCHIVE_CONFIG:-$SCRIPT_DIR/archive_rules.json}"

# ── Docker 模式辅助函数 ───────────────────────────────────────────
# 连接信息全局变量（由 select_connection 填充）
# SELECTED_MODE: host | docker
# SELECTED_CONTAINER: Docker 容器名或ID（docker 模式下有效）

# 检查 docker 是否可用
check_docker() {
    if ! command -v docker &>/dev/null; then
        log_error "未找到 docker 命令，请先安装 Docker"; return 1
    fi
    return 0
}

# 检查指定容器是否运行中
check_container_running() {
    local cname="$1"
    if ! docker inspect --format='{{.State.Running}}' "$cname" 2>/dev/null | grep -q 'true'; then
        log_error "容器 '$cname' 未运行或不存在"; return 1
    fi
    return 0
}

# 构建 mysql 执行命令前缀（返回字符串供 eval 使用）
# 用法: run_mysql_cmd HOST PORT USER PASS [mode] [container] -- <mysql_args>
build_mysql_args() {
    local host="$1" port="$2" user="$3" pass="$4"
    local mode="${5:-host}" container="${6:-}"
    if [ "$mode" = "docker" ] && [ -n "$container" ]; then
        # docker 模式：不需要 -h/-P，容器内部连本地 socket
        echo "docker exec -i $container mysql -u${user} -p${pass}"
    else
        echo "MYSQL_PWD=${pass} mysql -h${host} -P${port} -u${user}"
    fi
}

# 构建 psql 执行命令前缀
build_psql_args() {
    local host="$1" port="$2" user="$3" pass="$4"
    local mode="${5:-host}" container="${6:-}"
    if [ "$mode" = "docker" ] && [ -n "$container" ]; then
        echo "docker exec -i $container psql -U ${user}"
    else
        echo "PGPASSWORD=${pass} psql -h ${host} -p ${port} -U ${user}"
    fi
}

# ── 工具函数 ──────────────────────────────────────────────────────
# 所有日志输出到 stderr，避免被 $() 子shell捕获污染数据
log_info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_title() { echo -e "\n${BOLD}${CYAN}$*${NC}" >&2; echo -e "${CYAN}$(printf '─%.0s' {1..50})${NC}" >&2; }
press_enter() { echo -e "\n${YELLOW}按 Enter 返回主菜单...${NC}" >&2; read -r; }

# ── jq 检测 ───────────────────────────────────────────────────────
check_jq() {
    if ! command -v jq &>/dev/null; then
        log_warn "未检测到 jq，尝试自动安装..."
        if command -v apt-get &>/dev/null; then apt-get install -y jq &>/dev/null
        elif command -v yum &>/dev/null; then yum install -y jq &>/dev/null
        elif command -v dnf &>/dev/null; then dnf install -y jq &>/dev/null; fi
        if ! command -v jq &>/dev/null; then
            log_error "jq 安装失败，请手动安装: apt install jq / yum install jq"; exit 1
        fi
        log_info "jq 安装成功"
    fi
}

# ── 初始化配置文件 ────────────────────────────────────────────────
init_config() {
    if [ ! -f "$DB_CONFIG_FILE" ]; then
        echo "[]" > "$DB_CONFIG_FILE"
        log_info "已创建空配置文件: $DB_CONFIG_FILE"
    fi
    mkdir -p "$BACKUP_DIR"
}

# ── 读取连接数列表 ────────────────────────────────────────────────
list_connections() {
    jq -r 'to_entries[] | "\(.key) \(.value.alias) [\(.value.type)] \(.value.host):\(.value.port)"' "$DB_CONFIG_FILE" 2>/dev/null
}

get_connection_count() {
    jq 'length' "$DB_CONFIG_FILE" 2>/dev/null || echo 0
}

# ── 选择数据库连接（交互） ────────────────────────────────────────
select_connection() {
    local count; count=$(get_connection_count)
    if [ "$count" -eq 0 ]; then
        log_warn "暂无已配置的数据库连接"
        echo ""
        read -rp "是否现在添加一个新连接? [y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] && { add_connection; select_connection; } || return 1
    fi
    log_title "请选择数据库连接"
    while IFS=" " read -r idx alias type hostport; do
        # 读取连接模式标识
        local _mode; _mode=$(jq -r ".[$idx].mode // \"host\"" "$DB_CONFIG_FILE")
        local _tag="[HOST]"; [ "$_mode" = "docker" ] && _tag="[DOCKER]"
        echo -e "  ${GREEN}[$idx]${NC} ${BOLD}$alias${NC} $type $hostport ${CYAN}$_tag${NC}"
    done < <(list_connections)
    echo ""
    read -rp "请输入序号: " sel
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -ge "$count" ]; then
        log_error "无效的序号"; return 1
    fi
    SELECTED_IDX="$sel"
    SELECTED_ALIAS=$(jq -r ".[$sel].alias" "$DB_CONFIG_FILE")
    SELECTED_TYPE=$(jq  -r ".[$sel].type"  "$DB_CONFIG_FILE")
    SELECTED_HOST=$(jq  -r ".[$sel].host"  "$DB_CONFIG_FILE")
    SELECTED_PORT=$(jq  -r ".[$sel].port"  "$DB_CONFIG_FILE")
    SELECTED_USER=$(jq  -r ".[$sel].user"  "$DB_CONFIG_FILE")
    SELECTED_PASS=$(jq  -r ".[$sel].password" "$DB_CONFIG_FILE")
    SELECTED_MODE=$(jq  -r ".[$sel].mode // \"host\"" "$DB_CONFIG_FILE")
    SELECTED_CONTAINER=$(jq -r ".[$sel].container // \"\"" "$DB_CONFIG_FILE")
    return 0
}

# ── 检查客户端工具 ───────────────────────────────────────────────
check_db_client() {
    local type="$1" mode="${2:-host}" container="${3:-}"
    # docker 模式：只需检查 docker 命令和容器
    if [ "$mode" = "docker" ] && [ -n "$container" ]; then
        check_docker || return 1
        check_container_running "$container" || return 1
        return 0
    fi
    # host 模式：检查本地客户端
    if [ "$type" = "mysql" ]; then
        if ! command -v mysql &>/dev/null; then
            log_error "未找到 mysql 客户端，请安装: apt install mysql-client"; return 1
        fi
        if ! command -v mysqldump &>/dev/null; then
            log_error "未找到 mysqldump，请安装: apt install mysql-client"; return 1
        fi
    else
        if ! command -v psql &>/dev/null; then
            log_error "未找到 psql，请安装: apt install postgresql-client"; return 1
        fi
        if ! command -v pg_dump &>/dev/null; then
            log_error "未找到 pg_dump，请安装: apt install postgresql-client"; return 1
        fi
    fi
    return 0
}

# ── 测试连接（显示真实错误） ──────────────────────────────────────
test_connection() {
    local type="$1" host="$2" port="$3" user="$4" pass="$5"
    local mode="${6:-host}" container="${7:-}"
    local err_out ret
    if [ "$mode" = "docker" ] && [ -n "$container" ]; then
        if [ "$type" = "mysql" ]; then
            err_out=$(docker exec -i "$container" mysql -u"$user" -p"$pass" \
                --connect-timeout=5 -e "SELECT 1;" 2>&1 >/dev/null); ret=$?
        else
            err_out=$(docker exec -i "$container" psql -U "$user" \
                -c "SELECT 1;" 2>&1 >/dev/null); ret=$?
        fi
    else
        if [ "$type" = "mysql" ]; then
            err_out=$(MYSQL_PWD="$pass" mysql -h"$host" -P"$port" -u"$user" \
                --connect-timeout=5 -e "SELECT 1;" 2>&1 >/dev/null); ret=$?
        else
            err_out=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" \
                --connect-timeout=5 -c "SELECT 1;" 2>&1 >/dev/null); ret=$?
        fi
    fi
    if [ "$ret" -ne 0 ]; then
        log_error "连接失败: $err_out"; return 1
    fi
    return 0
}

# ── 获取数据库列表（公共函数，显示错误） ─────────────────────────
fetch_db_list() {
    local type="$1" host="$2" port="$3" user="$4" pass="$5"
    local mode="${6:-host}" container="${7:-}"
    local result err_out

    check_db_client "$type" "$mode" "$container" || return 1

    log_info "正在测试数据库连接..."
    if ! test_connection "$type" "$host" "$port" "$user" "$pass" "$mode" "$container"; then
        return 1
    fi
    log_info "连接成功，正在获取数据库列表..."

    if [ "$type" = "mysql" ]; then
        if [ "$mode" = "docker" ] && [ -n "$container" ]; then
            err_out=$(docker exec -i "$container" mysql -u"$user" -p"$pass" \
                -e "SHOW DATABASES;" 2>&1)
        else
            err_out=$(MYSQL_PWD="$pass" mysql -h"$host" -P"$port" -u"$user" \
                --connect-timeout=5 -e "SHOW DATABASES;" 2>&1)
        fi
        if [ $? -ne 0 ]; then log_error "获取列表失败: $err_out"; return 1; fi
        result=$(echo "$err_out" | grep -Ev "^(Database|information_schema|performance_schema|mysql|sys|Warning)")
    else
        local sql="SELECT datname FROM pg_database WHERE datistemplate=false;"
        if [ "$mode" = "docker" ] && [ -n "$container" ]; then
            err_out=$(docker exec -i "$container" psql -U "$user" -t -c "$sql" 2>&1)
        else
            err_out=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" \
                --connect-timeout=5 -t -c "$sql" 2>&1)
        fi
        if [ $? -ne 0 ]; then log_error "获取列表失败: $err_out"; return 1; fi
        result=$(echo "$err_out" | tr -d ' ' | grep -v '^$')
    fi

    if [ -z "$result" ]; then
        log_warn "未找到任何用户数据库（系统库已过滤）"; return 1
    fi
    echo "$result"
    return 0
}

# ── 添加数据库连接 ────────────────────────────────────────────────
add_connection() {
    log_title "添加数据库连接"
    read -rp "别名 (如: 生产MySQL): " alias
    echo -e "数据库类型: ${GREEN}1)${NC} MySQL  ${GREEN}2)${NC} PostgreSQL"
    read -rp "选择 [1/2]: " tsel
    local type="mysql"; [ "$tsel" = "2" ] && type="postgresql"

    # 连接模式选择
    echo -e "\n连接模式:"
    echo -e "  ${GREEN}1)${NC} 直连模式 (Host/IP + 端口)"
    echo -e "  ${GREEN}2)${NC} Docker 容器模式 (通过 docker exec 连接容器内部 DB)"
    read -rp "选择 [1/2, 默认1]: " msel
    local mode="host"; [ "$msel" = "2" ] && mode="docker"

    local host port user pass container=""
    if [ "$mode" = "docker" ]; then
        read -rp "Docker 容器名或 ID: " container
        [ -z "$container" ] && { log_error "容器名不能为空"; return 1; }
        # docker 模式下 host/port 仅作备注，不参与实际连接
        host="127.0.0.1"
        local def_port=3306; [ "$type" = "postgresql" ] && def_port=5432
        port="$def_port"
    else
        read -rp "主机地址 [127.0.0.1]: " host; host="${host:-127.0.0.1}"
        local def_port=3306; [ "$type" = "postgresql" ] && def_port=5432
        read -rp "端口 [$def_port]: " port; port="${port:-$def_port}"
    fi
    read -rp "用户名 [root]: " user; user="${user:-root}"
    read -rsp "密码: " pass; echo ""

    log_info "正在测试连接..."
    if test_connection "$type" "$host" "$port" "$user" "$pass" "$mode" "$container"; then
        log_info "连接测试成功！"
    else
        log_warn "连接测试失败，仍要保存? [y/N]: "
        read -rp "" yn
        [[ ! "$yn" =~ ^[Yy]$ ]] && return 1
    fi

    local new_entry
    new_entry=$(jq -n \
        --arg alias "$alias"     --arg type "$type" \
        --arg host "$host"       --argjson port "$port" \
        --arg user "$user"       --arg pass "$pass" \
        --arg mode "$mode"       --arg container "$container" \
        '{alias:$alias,type:$type,host:$host,port:$port,user:$user,password:$pass,mode:$mode,container:$container}')

    local tmp; tmp=$(mktemp)
    jq --argjson e "$new_entry" '. += [$e]' "$DB_CONFIG_FILE" > "$tmp" && mv "$tmp" "$DB_CONFIG_FILE"
    log_info "连接 \"$alias\" 已保存 [模式: $mode${container:+ / 容器: $container}]"
}

# ── 删除数据库连接 ────────────────────────────────────────────────
delete_connection() {
    log_title "删除数据库连接"
    select_connection || return
    read -rp "确认删除 \"$SELECTED_ALIAS\"? [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && return
    local tmp; tmp=$(mktemp)
    jq "del(.[$SELECTED_IDX])" "$DB_CONFIG_FILE" > "$tmp" && mv "$tmp" "$DB_CONFIG_FILE"
    log_info "已删除连接: $SELECTED_ALIAS"
}

# ── 列出所有连接 ──────────────────────────────────────────────────
show_connections() {
    log_title "已配置的数据库连接"
    local count; count=$(get_connection_count)
    if [ "$count" -eq 0 ]; then log_warn "暂无配置"; return; fi
    jq -r '.[] | "\(.alias)  \(.type)  \(.host):\(.port)  用户:\(.user)  模式:\(.mode // "host")\(if .container != null and .container != "" then "  容器:\(.container)" else "" end)"' "$DB_CONFIG_FILE"
}

# ── 备份单库 ──────────────────────────────────────────────────────
do_backup_db() {
    local type="$1" host="$2" port="$3" user="$4" pass="$5" dbname="$6" alias="$7"
    local mode="${8:-host}" container="${9:-}"
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local year; year=$(date +%Y)
    local safe_alias; safe_alias=$(echo "$alias" | tr ' ' '_')
    local outdir="$BACKUP_DIR/$safe_alias/$year"
    mkdir -p "$outdir"
    local filename="${BACKUP_PREFIX}_${dbname}_${ts}.sql"
    local filepath="$outdir/$filename"

    local mode_tag=""; [ "$mode" = "docker" ] && mode_tag=" [docker:$container]"
    log_info "正在备份 [$alias]$mode_tag 数据库: $dbname ..."

    # 记录开始时间
    local t_start; t_start=$(date +%s)

    if [ "$BACKUP_COMPRESS" = "gzip" ]; then
        # 管道直接写入压缩文件，无中间文件
        local gz_filepath="${filepath}.gz"
        if [ "$type" = "mysql" ]; then
            if [ "$mode" = "docker" ] && [ -n "$container" ]; then
                docker exec "$container" mysqldump -u"$user" -p"$pass" \
                    --single-transaction --routines --triggers "$dbname" 2>/dev/null | gzip > "$gz_filepath"
            else
                MYSQL_PWD="$pass" mysqldump -h"$host" -P"$port" -u"$user" \
                    --single-transaction --routines --triggers "$dbname" 2>/dev/null | gzip > "$gz_filepath"
            fi
        else
            if [ "$mode" = "docker" ] && [ -n "$container" ]; then
                docker exec "$container" pg_dump -U "$user" "$dbname" 2>/dev/null | gzip > "$gz_filepath"
            else
                PGPASSWORD="$pass" pg_dump -h "$host" -p "$port" -U "$user" "$dbname" 2>/dev/null | gzip > "$gz_filepath"
            fi
        fi
        if [ ${PIPESTATUS[0]} -ne 0 ] || [ ! -s "$gz_filepath" ]; then
            log_error "备份失败: $dbname"; rm -f "$gz_filepath"; return 1
        fi
        filepath="$gz_filepath"
    else
        # 未压缩模式
        if [ "$type" = "mysql" ]; then
            if [ "$mode" = "docker" ] && [ -n "$container" ]; then
                docker exec "$container" mysqldump -u"$user" -p"$pass" \
                    --single-transaction --routines --triggers "$dbname" > "$filepath" 2>/dev/null
            else
                MYSQL_PWD="$pass" mysqldump -h"$host" -P"$port" -u"$user" \
                    --single-transaction --routines --triggers "$dbname" > "$filepath"
            fi
        else
            if [ "$mode" = "docker" ] && [ -n "$container" ]; then
                docker exec "$container" pg_dump -U "$user" "$dbname" > "$filepath" 2>/dev/null
            else
                PGPASSWORD="$pass" pg_dump -h "$host" -p "$port" -U "$user" "$dbname" > "$filepath"
            fi
        fi
        if [ $? -ne 0 ]; then log_error "备份失败: $dbname"; rm -f "$filepath"; return 1; fi
    fi

    # 计算耗时和文件大小
    local t_end; t_end=$(date +%s)
    local elapsed=$(( t_end - t_start ))
    local fsize; fsize=$(du -sh "$filepath" 2>/dev/null | cut -f1)

    log_info "备份成功: $filepath  大小: ${fsize}  耗时: ${elapsed}s"

    # 写入备份日志
    local log_file="${BACKUP_DIR}/backup.log"
    mkdir -p "$BACKUP_DIR"
    printf "[%s] 操作=BACKUP  连接=%-20s 库=%-30s 文件=%s  大小=%-8s 耗时=%ds\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$alias" "$dbname" "$(basename "$filepath")" "${fsize:-?}" "$elapsed" \
        >> "$log_file"

    # 清理旧备份
    local files; files=$(ls -t "$outdir"/${BACKUP_PREFIX}_${dbname}_* 2>/dev/null)
    local bcount; bcount=$(echo "$files" | grep -c .)
    if [ "$bcount" -gt "$MAX_BACKUPS" ]; then
        echo "$files" | tail -n "+$((MAX_BACKUPS+1))" | xargs rm -f
        log_warn "已清理旧备份，当前保留最新 $MAX_BACKUPS 份"
    fi
}

# ── 通配符/序号解析，输出匹配的数据库名列表 ──────────────────────
# 用法: resolve_db_selection "$sel" db_map_ref $total
# 将匹配到的库名逐行输出到 stdout
resolve_db_selection() {
    local sel="$1" total="$3"
    local -n _rmap="$2"
    local matched=()
    for token in $sel; do
        if [[ "$token" == *"*"* || "$token" == *"?"* ]]; then
            # 通配符模式匹配
            local found=0
            for ((j=0; j<total; j++)); do
                local db="${_rmap[$j]:-}"
                [[ -z "$db" ]] && continue
                # bash 原生 glob 匹配（不展开文件系统）
                if [[ "$db" == $token ]]; then
                    matched+=("$db"); ((found++))
                fi
            done
            [ "$found" -eq 0 ] && log_warn "通配符 '$token' 无匹配数据库"
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            local db="${_rmap[$token]:-}"
            [ -n "$db" ] && matched+=("$db") || log_warn "跳过无效序号: $token"
        else
            log_warn "忽略无法识别的输入: $token"
        fi
    done
    # 去重输出
    printf '%s\n' "${matched[@]}" | sort -u
}

# ── 备份功能主流程 ────────────────────────────────────────────────
backup_menu() {
    log_title "备份数据库"
    select_connection || { press_enter; return; }
    log_info "已选择: $SELECTED_ALIAS ($SELECTED_TYPE @ $SELECTED_HOST:$SELECTED_PORT)${SELECTED_MODE:+ [模式:$SELECTED_MODE]}${SELECTED_CONTAINER:+ 容器:$SELECTED_CONTAINER}"

    # 获取数据库列表（含连接诊断）
    local db_list
    db_list=$(fetch_db_list "$SELECTED_TYPE" "$SELECTED_HOST" "$SELECTED_PORT" "$SELECTED_USER" "$SELECTED_PASS" "$SELECTED_MODE" "$SELECTED_CONTAINER")
    if [ $? -ne 0 ]; then press_enter; return; fi

    echo -e "\n可用数据库:"
    local i=0
    declare -A db_map
    while IFS= read -r db; do
        [ -z "$db" ] && continue
        echo -e "  ${GREEN}[$i]${NC} $db"
        db_map[$i]="$db"; ((i++))
    done <<< "$db_list"
    local total=$i
    echo -e "  ${GREEN}[a]${NC} 备份全部"
    echo -e "\n  ${CYAN}[使用说明]${NC}"
    echo -e "  · 序号选择 : ${YELLOW}0 3 5${NC}          → 备份第0、3、5个库"
    echo -e "  · 通配符   : ${YELLOW}ys-*${NC}           → 备份所有 ys- 开头的库"
    echo -e "  · 混合使用 : ${YELLOW}0 ys-* *service*${NC} → 混合选择"
    echo -e "  · 全部备份 : ${YELLOW}a${NC}"

    read -rp $'\n请输入选择: ' sel

    local backup_targets=()
    if [ "$sel" = "a" ]; then
        for ((j=0; j<total; j++)); do
            [ -n "${db_map[$j]:-}" ] && backup_targets+=("${db_map[$j]}")
        done
    else
        while IFS= read -r db; do
            [ -n "$db" ] && backup_targets+=("$db")
        done < <(resolve_db_selection "$sel" db_map "$total")
    fi

    if [ ${#backup_targets[@]} -eq 0 ]; then
        log_warn "未选中任何数据库，取消备份"; press_enter; return
    fi

    echo -e "\n${BOLD}即将备份以下 ${#backup_targets[@]} 个数据库:${NC}"
    printf '  · %s\n' "${backup_targets[@]}"
    read -rp "确认开始备份? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { log_warn "已取消"; press_enter; return; }

    for db in "${backup_targets[@]}"; do
        do_backup_db "$SELECTED_TYPE" "$SELECTED_HOST" "$SELECTED_PORT" "$SELECTED_USER" "$SELECTED_PASS" "$db" "$SELECTED_ALIAS" "$SELECTED_MODE" "$SELECTED_CONTAINER"
    done
    press_enter
}

# ── 恢复功能主流程 ────────────────────────────────────────────────
restore_menu() {
    log_title "恢复数据库"

    # ── Step 1: 选择目标数据库连接（恢复到哪里）────────────────────
    echo -e "${BOLD}第一步：选择目标数据库连接（数据将恢复到此连接）${NC}" >&2
    select_connection || { press_enter; return; }
    local dst_alias="$SELECTED_ALIAS"
    local dst_type="$SELECTED_TYPE"
    local dst_host="$SELECTED_HOST"
    local dst_port="$SELECTED_PORT"
    local dst_user="$SELECTED_USER"
    local dst_pass="$SELECTED_PASS"
    local dst_mode="$SELECTED_MODE"
    local dst_container="$SELECTED_CONTAINER"
    log_info "目标连接: $dst_alias ($dst_type @ $dst_host:$dst_port)"

    # ── Step 2: 选择备份来源文件夹（可跨连接）─────────────────────
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        log_error "备份目录为空或不存在: $BACKUP_DIR"; press_enter; return
    fi

    echo -e "\n${BOLD}第二步：选择备份来源（连接别名目录）${NC}" >&2
    echo -e "备份目录: ${CYAN}$BACKUP_DIR${NC}" >&2
    echo "" >&2
    local j=0
    declare -A src_dir_map
    while IFS= read -r d; do
        local dname; dname=$(basename "$d")
        # 统计该目录下备份文件总数
        local fcount; fcount=$(find "$d" -type f -name "${BACKUP_PREFIX}_*" 2>/dev/null | wc -l)
        echo -e "  ${GREEN}[$j]${NC} ${BOLD}$dname${NC}  ${CYAN}($fcount 个备份文件)${NC}"
        src_dir_map[$j]="$d"; ((j++))
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

    if [ "$j" -eq 0 ]; then
        log_error "备份目录下无任何连接备份文件夹"; press_enter; return
    fi

    read -rp "请选择备份来源序号: " dsel
    local src_dir="${src_dir_map[$dsel]:-}"
    [ -z "$src_dir" ] && { log_error "无效序号"; press_enter; return; }
    log_info "已选择来源目录: $(basename "$src_dir")"

    # ── Step 3: 在来源目录中选择备份文件──────────────────────────
    local file_list
    file_list=$(find "$src_dir" -type f -name "${BACKUP_PREFIX}_*" | sort -r)
    if [ -z "$file_list" ]; then
        log_error "该目录下无备份文件"; press_enter; return
    fi

    echo -e "\n${BOLD}第三步：选择要恢复的备份文件${NC}" >&2
    local i=0
    declare -A file_map
    while IFS= read -r f; do
        local rel; rel="${f#$BACKUP_DIR/}"
        echo -e "  ${GREEN}[$i]${NC} $rel  ${CYAN}($(du -sh "$f" | cut -f1))${NC}"
        file_map[$i]="$f"; ((i++))
    done <<< "$file_list"

    read -rp "请选择文件序号: " fsel
    local bak_file="${file_map[$fsel]:-}"
    [ -z "$bak_file" ] && { log_error "无效序号"; press_enter; return; }

    # ── Step 4: 确认目标库名（自动从文件名提取）────────────────────
    local fname; fname=$(basename "$bak_file" .gz); fname="${fname%.sql}"
    local default_db; default_db=$(echo "$fname" | sed "s/^${BACKUP_PREFIX}_//;s/_[0-9]\{8\}_[0-9]\{6\}$//")
    echo "" >&2
    read -rp "目标数据库名称 [默认: $default_db]: " target_db
    target_db="${target_db:-$default_db}"
    [ -z "$target_db" ] && { log_error "数据库名不能为空"; press_enter; return; }

    # ── Step 5: 检查目标库是否存在──────────────────────────────────
    local db_exists=0
    if [ "$dst_type" = "mysql" ]; then
        local chk
        if [ "$dst_mode" = "docker" ] && [ -n "$dst_container" ]; then
            chk=$(docker exec -i "$dst_container" mysql -u"$dst_user" -p"$dst_pass" \
                -se "SHOW DATABASES LIKE '$target_db';" 2>/dev/null)
        else
            chk=$(MYSQL_PWD="$dst_pass" mysql -h"$dst_host" -P"$dst_port" \
                -u"$dst_user" -se "SHOW DATABASES LIKE '$target_db';" 2>/dev/null)
        fi
        [ -n "$chk" ] && db_exists=1
    else
        local chk
        if [ "$dst_mode" = "docker" ] && [ -n "$dst_container" ]; then
            chk=$(docker exec -i "$dst_container" psql -U "$dst_user" \
                -tAc "SELECT 1 FROM pg_database WHERE datname='$target_db';" 2>/dev/null)
        else
            chk=$(PGPASSWORD="$dst_pass" psql -h "$dst_host" -p "$dst_port" \
                -U "$dst_user" -tAc "SELECT 1 FROM pg_database WHERE datname='$target_db';" 2>/dev/null)
        fi
        [ "$chk" = "1" ] && db_exists=1
    fi

    echo "" >&2
    if [ "$db_exists" -eq 0 ]; then
        echo -e "${YELLOW}[提示]${NC} 目标连接 '$dst_alias' 中数据库 '${BOLD}$target_db${NC}' 不存在" >&2
        read -rp "是否自动创建该数据库? [Y/n]: " create_yn
        if [[ "$create_yn" =~ ^[Nn]$ ]]; then
            log_warn "已取消恢复"; press_enter; return
        fi
        local create_ok=0
        if [ "$dst_type" = "mysql" ]; then
            if [ "$dst_mode" = "docker" ] && [ -n "$dst_container" ]; then
                docker exec -i "$dst_container" mysql -u"$dst_user" -p"$dst_pass" \
                    -e "CREATE DATABASE \`$target_db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null && create_ok=1
            else
                MYSQL_PWD="$dst_pass" mysql -h"$dst_host" -P"$dst_port" \
                    -u"$dst_user" -e "CREATE DATABASE \`$target_db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null && create_ok=1
            fi
        else
            if [ "$dst_mode" = "docker" ] && [ -n "$dst_container" ]; then
                docker exec -i "$dst_container" psql -U "$dst_user" \
                    -c "CREATE DATABASE \"$target_db\";" 2>/dev/null && create_ok=1
            else
                PGPASSWORD="$dst_pass" psql -h "$dst_host" -p "$dst_port" \
                    -U "$dst_user" -c "CREATE DATABASE \"$target_db\";" 2>/dev/null && create_ok=1
            fi
        fi
        if [ "$create_ok" -eq 1 ]; then
            log_info "数据库 '$target_db' 创建成功"
        else
            log_error "数据库创建失败，请检查权限"; press_enter; return
        fi
    else
        echo -e "${RED}[警告] '$dst_alias' 中数据库 '$target_db' 已存在，恢复将覆盖现有数据！${NC}" >&2
    fi

    # ── Step 6: 最终确认 & 执行──────────────────────────────────────
    echo "" >&2
    echo -e "${BOLD}恢复摘要:${NC}" >&2
    echo -e "  来源文件: ${CYAN}${bak_file#$BACKUP_DIR/}${NC}" >&2
    echo -e "  目标连接: ${GREEN}$dst_alias${NC} ($dst_host:$dst_port)" >&2
    echo -e "  目标库名: ${GREEN}$target_db${NC}" >&2
    echo "" >&2
    read -rp "确认开始恢复? [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && { log_warn "已取消"; press_enter; return; }

    # 记录恢复开始时间
    local r_start; r_start=$(date +%s)
    log_info "开始执行恢复..."
    local restore_rc=0

    # 执行恢复（docker 模式用管道输入，无需临时文件）
    if [ "$dst_mode" = "docker" ] && [ -n "$dst_container" ]; then
        if [ "$dst_type" = "mysql" ]; then
            gunzip -c "$bak_file" 2>/dev/null | docker exec -i "$dst_container" mysql -u"$dst_user" -p"$dst_pass" "$target_db"
        else
            gunzip -c "$bak_file" 2>/dev/null | docker exec -i "$dst_container" psql -U "$dst_user" -d "$target_db"
        fi
        restore_rc=${PIPESTATUS[1]}
    else
        # host 模式：解压到临时文件再导入
        local sql_file="$bak_file"
        if [[ "$bak_file" == *.gz ]]; then
            sql_file="/tmp/_db_restore_$$.sql"
            gunzip -c "$bak_file" > "$sql_file"
        fi
        if [ "$dst_type" = "mysql" ]; then
            MYSQL_PWD="$dst_pass" mysql -h"$dst_host" -P"$dst_port" -u"$dst_user" "$target_db" < "$sql_file"
        else
            PGPASSWORD="$dst_pass" psql -h "$dst_host" -p "$dst_port" -U "$dst_user" -d "$target_db" -f "$sql_file"
        fi
        restore_rc=$?
        [[ "$bak_file" == *.gz ]] && rm -f "$sql_file"
    fi

    # 统计并记录耗时
    local r_end; r_end=$(date +%s)
    local r_elapsed=$(( r_end - r_start ))
    local bak_size; bak_size=$(du -sh "$bak_file" 2>/dev/null | cut -f1)
    local log_file="${BACKUP_DIR}/backup.log"
    mkdir -p "$BACKUP_DIR"

    if [ "$restore_rc" -eq 0 ]; then
        log_info "✓ 恢复成功！数据库: $target_db  耗时: ${r_elapsed}s"
        printf "[%s] 操作=RESTORE 连接=%-20s 库=%-30s 文件=%s  大小=%-8s 耗时=%ds 状态=SUCCESS\n" \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$dst_alias" "$target_db" "$(basename "$bak_file")" "${bak_size:-?}" "$r_elapsed" \
            >> "$log_file"
    else
        log_error "✗ 恢复失败！数据库: $target_db  耗时: ${r_elapsed}s"
        printf "[%s] 操作=RESTORE 连接=%-20s 库=%-30s 文件=%s  大小=%-8s 耗时=%ds 状态=FAILED\n" \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$dst_alias" "$target_db" "$(basename "$bak_file")" "${bak_size:-?}" "$r_elapsed" \
            >> "$log_file"
    fi
    press_enter
}



# ── 定时备份管理 ──────────────────────────────────────────────────
cron_menu() {
    while true; do
        log_title "定时备份管理"
        echo -e "  ${GREEN}[1]${NC} 添加定时备份任务"
        echo -e "  ${GREEN}[2]${NC} 查看定时备份任务"
        echo -e "  ${GREEN}[3]${NC} 删除定时备份任务"
        echo -e "  ${GREEN}[0]${NC} 返回主菜单"
        read -rp "请选择: " ch
        case "$ch" in
            1) cron_add ;;
            2) cron_list ;;
            3) cron_delete ;;
            0) break ;;
        esac
    done
}

cron_add() {
    log_title "添加定时备份任务"
    select_connection || return

    log_info "已选择连接: $SELECTED_ALIAS"
    # 选择数据库（含连接诊断）
    local db_list
    db_list=$(fetch_db_list "$SELECTED_TYPE" "$SELECTED_HOST" "$SELECTED_PORT" "$SELECTED_USER" "$SELECTED_PASS" "$SELECTED_MODE" "$SELECTED_CONTAINER")
    if [ $? -ne 0 ]; then press_enter; return; fi

    echo -e "\n可用数据库:"
    local i=0; declare -A db_map2
    while IFS= read -r db; do
        [ -z "$db" ] && continue
        echo -e "  ${GREEN}[$i]${NC} $db"; db_map2[$i]="$db"; ((i++))
    done <<< "$db_list"
    local total2=$i
    echo -e "  ${GREEN}[a]${NC} 全部数据库"
    echo -e "  ${CYAN}[提示]${NC} 支持通配符(如 ${YELLOW}ys-*${NC})、序号(如 ${YELLOW}0 3${NC})或混合使用"
    read -rp "请选择: " dbsel

    local target_db
    if [ "$dbsel" = "a" ]; then
        target_db="__ALL__"
    elif [[ "$dbsel" == *"*"* || "$dbsel" == *"?"* || "$dbsel" == *" "* ]]; then
        # 通配符或多选 → 存为 __PATTERN__:原始输入
        target_db="__PATTERN__:$dbsel"
    else
        target_db="${db_map2[$dbsel]:-}"
        [ -z "$target_db" ] && { log_error "无效选择"; return; }
    fi

    echo -e "\n备份频率:"
    echo -e "  ${GREEN}[1]${NC} 每天定时"
    echo -e "  ${GREEN}[2]${NC} 每周定时"
    echo -e "  ${GREEN}[3]${NC} 自定义 cron 表达式"
    read -rp "请选择: " freq

    local cron_expr
    case "$freq" in
        1)
            read -rp "每天几点备份 [0-23，默认2]: " hr; hr="${hr:-2}"
            cron_expr="0 $hr * * *"
            ;;
        2)
            echo -e "星期几备份: ${GREEN}0${NC}=周日 ${GREEN}1${NC}=周一 ... ${GREEN}6${NC}=周六"
            read -rp "选择 [默认0]: " wd; wd="${wd:-0}"
            read -rp "几点 [默认2]: " hr; hr="${hr:-2}"
            cron_expr="0 $hr * * $wd"
            ;;
        3)
            read -rp "请输入 cron 表达式 (分 时 日 月 周): " cron_expr
            ;;
        *) log_error "无效选择"; return ;;
    esac

    # 生成 cron 命令
    local script_path; script_path=$(realpath "$0")
    local db_arg="$target_db"
    local cron_cmd="$cron_expr bash $script_path --cron-backup $SELECTED_IDX \"$db_arg\" >> $BACKUP_DIR/cron.log 2>&1"

    # 写入 crontab
    (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab -
    log_info "定时任务已添加: $cron_expr"
    log_info "任务: [$SELECTED_ALIAS] 备份 $db_arg"
}

cron_list() {
    log_title "当前定时备份任务"
    local tasks; tasks=$(crontab -l 2>/dev/null | grep "db_manager.sh --cron-backup")
    if [ -z "$tasks" ]; then
        log_warn "暂无定时备份任务"
    else
        echo "$tasks"
    fi
    press_enter
}

cron_delete() {
    log_title "删除定时备份任务"
    local tasks; tasks=$(crontab -l 2>/dev/null | grep "db_manager.sh --cron-backup")
    if [ -z "$tasks" ]; then log_warn "暂无任务"; press_enter; return; fi

    local i=0; declare -A cron_map
    while IFS= read -r line; do
        echo -e "  ${GREEN}[$i]${NC} $line"; cron_map[$i]="$line"; ((i++))
    done <<< "$tasks"

    read -rp "请选择要删除的任务序号: " sel
    local target="${cron_map[$sel]}"
    [ -z "$target" ] && { log_error "无效序号"; return; }

    local escaped; escaped=$(printf '%s\n' "$target" | sed 's/[[\.*^$()+?{|]/\\&/g')
    crontab -l 2>/dev/null | grep -v "$escaped" | crontab -
    log_info "任务已删除"
    press_enter
}

# ── cron 静默备份入口 ─────────────────────────────────────────────
cron_backup_run() {
    local idx="$1" db_arg="$2"
    init_config
    local _alias _type _host _port _user _pass _mode _container
    _alias=$(jq -r ".[$idx].alias" "$DB_CONFIG_FILE")
    _type=$(jq  -r ".[$idx].type"  "$DB_CONFIG_FILE")
    _host=$(jq  -r ".[$idx].host"  "$DB_CONFIG_FILE")
    _port=$(jq  -r ".[$idx].port"  "$DB_CONFIG_FILE")
    _user=$(jq  -r ".[$idx].user"  "$DB_CONFIG_FILE")
    _pass=$(jq  -r ".[$idx].password" "$DB_CONFIG_FILE")
    _mode=$(jq  -r ".[$idx].mode // \"host\"" "$DB_CONFIG_FILE")
    _container=$(jq -r ".[$idx].container // \"\"" "$DB_CONFIG_FILE")

    local db_list
    db_list=$(fetch_db_list "$_type" "$_host" "$_port" "$_user" "$_pass" "$_mode" "$_container")
    if [ $? -ne 0 ]; then log_error "cron: 无法获取数据库列表"; exit 1; fi

    if [ "$db_arg" = "__ALL__" ]; then
        while IFS= read -r db; do
            [ -z "$db" ] && continue
            do_backup_db "$_type" "$_host" "$_port" "$_user" "$_pass" "$db" "$_alias" "$_mode" "$_container"
        done <<< "$db_list"
    elif [[ "$db_arg" == __PATTERN__:* ]]; then
        local pattern="${db_arg#__PATTERN__:}"
        local i=0; declare -A _cron_map
        while IFS= read -r db; do
            [ -z "$db" ] && continue
            _cron_map[$i]="$db"; ((i++))
        done <<< "$db_list"
        while IFS= read -r db; do
            [ -n "$db" ] && do_backup_db "$_type" "$_host" "$_port" "$_user" "$_pass" "$db" "$_alias" "$_mode" "$_container"
        done < <(resolve_db_selection "$pattern" _cron_map "$i")
    else
        do_backup_db "$_type" "$_host" "$_port" "$_user" "$_pass" "$db_arg" "$_alias" "$_mode" "$_container"
    fi
}

# ── 配置管理菜单 ──────────────────────────────────────────────────
config_menu() {
    while true; do
        log_title "数据库连接配置"
        echo -e "  ${GREEN}[1]${NC} 查看所有连接"
        echo -e "  ${GREEN}[2]${NC} 添加新连接"
        echo -e "  ${GREEN}[3]${NC} 删除连接"
        echo -e "  ${GREEN}[0]${NC} 返回主菜单"
        read -rp "请选择: " ch
        case "$ch" in
            1) show_connections; press_enter ;;
            2) add_connection; press_enter ;;
            3) delete_connection; press_enter ;;
            0) break ;;
        esac
    done
}

# ── 批量恢复 ─────────────────────────────────────────────────────
batch_restore_menu() {
    log_title "批量恢复数据库"

    # Step 1: 选择目标连接
    echo -e "${BOLD}第一步：选择目标数据库连接${NC}" >&2
    select_connection || { press_enter; return; }
    local dst_alias="$SELECTED_ALIAS" dst_type="$SELECTED_TYPE"
    local dst_host="$SELECTED_HOST"   dst_port="$SELECTED_PORT"
    local dst_user="$SELECTED_USER"   dst_pass="$SELECTED_PASS"
    local dst_mode="$SELECTED_MODE"   dst_container="$SELECTED_CONTAINER"
    log_info "目标连接: $dst_alias ($dst_type @ $dst_host:$dst_port)"

    # Step 2: 选择来源备份目录
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        log_error "备份目录为空或不存在: $BACKUP_DIR"; press_enter; return
    fi
    echo -e "\n${BOLD}第二步：选择备份来源目录${NC}" >&2
    echo -e "备份目录: ${CYAN}$BACKUP_DIR${NC}" >&2
    echo "" >&2
    local j=0; declare -A src_dir_map
    while IFS= read -r d; do
        local fcount; fcount=$(find "$d" -type f -name "${BACKUP_PREFIX}_*" 2>/dev/null | wc -l)
        echo -e "  ${GREEN}[$j]${NC} ${BOLD}$(basename "$d")${NC}  ${CYAN}($fcount 个备份文件)${NC}"
        src_dir_map[$j]="$d"; ((j++))
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
    [ "$j" -eq 0 ] && { log_error "无可用备份目录"; press_enter; return; }
    read -rp "请选择来源序号: " dsel
    local src_dir="${src_dir_map[$dsel]:-}"
    [ -z "$src_dir" ] && { log_error "无效序号"; press_enter; return; }
    log_info "来源目录: $(basename "$src_dir")"

    # Step 3: 按数据库名分组，每个DB只取最新一份备份
    echo -e "\n${BOLD}第三步：选择要批量恢复的数据库${NC}" >&2
    # 找出所有DB名（从文件名解析）
    declare -A latest_map   # db_name -> 最新备份文件路径
    while IFS= read -r f; do
        local bname; bname=$(basename "$f" .gz); bname="${bname%.sql}"
        local dbname; dbname=$(echo "$bname" | sed "s/^${BACKUP_PREFIX}_//;s/_[0-9]\{8\}_[0-9]\{6\}$//")
        # sort -r 已经保证第一个是最新，只记录第一次出现
        [ -z "${latest_map[$dbname]+x}" ] && latest_map[$dbname]="$f"
    done < <(find "$src_dir" -type f -name "${BACKUP_PREFIX}_*" | sort -r)

    if [ ${#latest_map[@]} -eq 0 ]; then
        log_error "未找到任何备份文件"; press_enter; return
    fi

    local k=0; declare -A db_idx_map
    # 排序输出
    while IFS= read -r dbname; do
        local f="${latest_map[$dbname]}"
        local rel; rel="${f#$src_dir/}"
        echo -e "  ${GREEN}[$k]${NC} ${BOLD}$dbname${NC}  ${CYAN}← $rel${NC}"
        db_idx_map[$k]="$dbname"; ((k++))
    done < <(printf '%s\n' "${!latest_map[@]}" | sort)
    local total_db=$k

    echo -e "  ${GREEN}[a]${NC} 恢复全部"
    echo -e "\n  ${CYAN}[说明]${NC} 支持序号(${YELLOW}0 2 5${NC})、通配符(${YELLOW}ys-*${NC})、混合(${YELLOW}0 ys-*${NC})或 ${YELLOW}a${NC} 全部"
    read -rp $'\n请输入选择: ' sel

    # 解析选择
    local restore_dbs=()
    if [ "$sel" = "a" ]; then
        for ((m=0; m<total_db; m++)); do
            [ -n "${db_idx_map[$m]:-}" ] && restore_dbs+=("${db_idx_map[$m]}")
        done
    else
        while IFS= read -r dbname; do
            [ -n "$dbname" ] && restore_dbs+=("$dbname")
        done < <(resolve_db_selection "$sel" db_idx_map "$total_db")
    fi

    if [ ${#restore_dbs[@]} -eq 0 ]; then
        log_warn "未选中任何数据库，取消操作"; press_enter; return
    fi

    # 确认摘要
    echo -e "\n${BOLD}批量恢复摘要:${NC}" >&2
    echo -e "  目标连接: ${GREEN}$dst_alias${NC} ($dst_host:$dst_port)" >&2
    echo -e "  来源目录: ${CYAN}$(basename "$src_dir")${NC}" >&2
    echo -e "  恢复数量: ${BOLD}${#restore_dbs[@]}${NC} 个数据库" >&2
    printf '  · %s\n' "${restore_dbs[@]}" >&2
    echo "" >&2
    read -rp "确认开始批量恢复? [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && { log_warn "已取消"; press_enter; return; }

    # 批量执行
    local ok=0 fail=0
    for dbname in "${restore_dbs[@]}"; do
        local bak_file="${latest_map[$dbname]}"
        log_info "━━ 正在恢复: $dbname ←── $(basename "$bak_file")"

        # 检查目标库是否存在
        local db_exists=0
        if [ "$dst_type" = "mysql" ]; then
            local chk
            if [ "$dst_mode" = "docker" ] && [ -n "$dst_container" ]; then
                chk=$(docker exec -i "$dst_container" mysql -u"$dst_user" -p"$dst_pass" \
                    -se "SHOW DATABASES LIKE '$dbname';" 2>/dev/null)
            else
                chk=$(MYSQL_PWD="$dst_pass" mysql -h"$dst_host" -P"$dst_port" \
                    -u"$dst_user" -se "SHOW DATABASES LIKE '$dbname';" 2>/dev/null)
            fi
            [ -n "$chk" ] && db_exists=1
        else
            local chk
            if [ "$dst_mode" = "docker" ] && [ -n "$dst_container" ]; then
                chk=$(docker exec -i "$dst_container" psql -U "$dst_user" \
                    -tAc "SELECT 1 FROM pg_database WHERE datname='$dbname';" 2>/dev/null)
            else
                chk=$(PGPASSWORD="$dst_pass" psql -h "$dst_host" -p "$dst_port" \
                    -U "$dst_user" -tAc "SELECT 1 FROM pg_database WHERE datname='$dbname';" 2>/dev/null)
            fi
            [ "$chk" = "1" ] && db_exists=1
        fi

        if [ "$db_exists" -eq 0 ]; then
            if [ "$dst_type" = "mysql" ]; then
                if [ "$dst_mode" = "docker" ] && [ -n "$dst_container" ]; then
                    docker exec -i "$dst_container" mysql -u"$dst_user" -p"$dst_pass" \
                        -e "CREATE DATABASE \`$dbname\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
                else
                    MYSQL_PWD="$dst_pass" mysql -h"$dst_host" -P"$dst_port" \
                        -u"$dst_user" -e "CREATE DATABASE \`$dbname\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
                fi
            else
                if [ "$dst_mode" = "docker" ] && [ -n "$dst_container" ]; then
                    docker exec -i "$dst_container" psql -U "$dst_user" \
                        -c "CREATE DATABASE \"$dbname\";" 2>/dev/null
                else
                    PGPASSWORD="$dst_pass" psql -h "$dst_host" -p "$dst_port" \
                        -U "$dst_user" -c "CREATE DATABASE \"$dbname\";" 2>/dev/null
                fi
            fi
            log_info "  已创建数据库: $dbname"
        fi

        # 导入（docker 模式用管道）
        if [ "$dst_mode" = "docker" ] && [ -n "$dst_container" ]; then
            if [ "$dst_type" = "mysql" ]; then
                gunzip -c "$bak_file" 2>/dev/null | docker exec -i "$dst_container" mysql -u"$dst_user" -p"$dst_pass" "$dbname"
            else
                gunzip -c "$bak_file" 2>/dev/null | docker exec -i "$dst_container" psql -U "$dst_user" -d "$dbname"
            fi
        else
            local sql_file="$bak_file"
            if [[ "$bak_file" == *.gz ]]; then
                sql_file="/tmp/_db_restore_$$.sql"
                gunzip -c "$bak_file" > "$sql_file"
            fi
            if [ "$dst_type" = "mysql" ]; then
                MYSQL_PWD="$dst_pass" mysql -h"$dst_host" -P"$dst_port" -u"$dst_user" "$dbname" < "$sql_file"
            else
                PGPASSWORD="$dst_pass" psql -h "$dst_host" -p "$dst_port" -U "$dst_user" -d "$dbname" -f "$sql_file" &>/dev/null
            fi
            [[ "$bak_file" == *.gz ]] && rm -f "$sql_file"
        fi

        if [ $? -eq 0 ]; then
            log_info "  ✓ $dbname 恢复成功"; ((ok++))
        else
            log_error "  ✗ $dbname 恢复失败"; ((fail++))
        fi
        [[ "$bak_file" == *.gz ]] && rm -f "$sql_file"
    done

    echo "" >&2
    echo -e "${BOLD}批量恢复完成: ${GREEN}成功 $ok${NC} / ${RED}失败 $fail${NC}${BOLD} / 共 ${#restore_dbs[@]} 个${NC}" >&2
    press_enter
}

# ── 恢复子菜单 ───────────────────────────────────────────────────
restore_submenu() {
    while true; do
        log_title "恢复数据库"
        echo -e "  ${GREEN}[1]${NC} 单库恢复（精选文件版本）"
        echo -e "  ${GREEN}[2]${NC} 批量恢复（自动用最新备份）"
        echo -e "  ${GREEN}[0]${NC} 返回主菜单"
        read -rp "请选择: " ch
        case "$ch" in
            1) restore_menu ;;
            2) batch_restore_menu ;;
            0) break ;;
        esac
    done
}

# =================================================================
# ── 数据表归档模块 ─────────────────────────────────────────────────
# =================================================================

# 初始化归档配置文件
init_archive_config() {
    if [ ! -f "$ARCHIVE_CONFIG" ]; then
        echo "[]" > "$ARCHIVE_CONFIG"
        log_info "已创建归档规则文件: $ARCHIVE_CONFIG"
    fi
}

# 执行 SQL（支持 host/docker 模式），输出到 stdout
_archive_exec_sql() {
    local type="$1" host="$2" port="$3" user="$4" pass="$5"
    local mode="$6" container="$7" db="$8"
    shift 8
    local sql="$*"
    if [ "$type" = "mysql" ]; then
        if [ "$mode" = "docker" ] && [ -n "$container" ]; then
            docker exec -i "$container" mysql -u"$user" -p"$pass" -D"$db" -se "$sql" 2>/dev/null
        else
            MYSQL_PWD="$pass" mysql -h"$host" -P"$port" -u"$user" -D"$db" -se "$sql" 2>/dev/null
        fi
    else
        if [ "$mode" = "docker" ] && [ -n "$container" ]; then
            docker exec -i "$container" psql -U "$user" -d "$db" -tAc "$sql" 2>/dev/null
        else
            PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db" -tAc "$sql" 2>/dev/null
        fi
    fi
}

# 执行 SQL 并获取返回码（不捕获输出）
_archive_exec_sql_rc() {
    local type="$1" host="$2" port="$3" user="$4" pass="$5"
    local mode="$6" container="$7" db="$8"
    shift 8
    local sql="$*"
    if [ "$type" = "mysql" ]; then
        if [ "$mode" = "docker" ] && [ -n "$container" ]; then
            docker exec -i "$container" mysql -u"$user" -p"$pass" -D"$db" -e "$sql" 2>/dev/null
        else
            MYSQL_PWD="$pass" mysql -h"$host" -P"$port" -u"$user" -D"$db" -e "$sql" 2>/dev/null
        fi
    else
        if [ "$mode" = "docker" ] && [ -n "$container" ]; then
            docker exec -i "$container" psql -U "$user" -d "$db" -c "$sql" 2>/dev/null
        else
            PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db" -c "$sql" 2>/dev/null
        fi
    fi
}

# ── 核心：执行单条归档规则 ────────────────────────────────────────
do_archive_rule() {
    local rule_idx="$1" interactive="${2:-0}"
    init_archive_config

    local rule_name conn_idx db_name tbl_name date_col retention mode
    local archive_db archive_tbl batch_size max_batches
    rule_name=$(jq -r   ".[$rule_idx].name"                        "$ARCHIVE_CONFIG")
    conn_idx=$(jq -r    ".[$rule_idx].conn_idx"                    "$ARCHIVE_CONFIG")
    db_name=$(jq -r     ".[$rule_idx].database"                    "$ARCHIVE_CONFIG")
    tbl_name=$(jq -r    ".[$rule_idx].table"                       "$ARCHIVE_CONFIG")
    date_col=$(jq -r    ".[$rule_idx].date_column"                 "$ARCHIVE_CONFIG")
    retention=$(jq -r   ".[$rule_idx].retention_days"              "$ARCHIVE_CONFIG")
    mode=$(jq -r        ".[$rule_idx].mode"                        "$ARCHIVE_CONFIG")
    archive_db=$(jq -r  ".[$rule_idx].archive_db  // \"\""         "$ARCHIVE_CONFIG")
    archive_tbl=$(jq -r ".[$rule_idx].archive_table // \"\""       "$ARCHIVE_CONFIG")
    batch_size=$(jq -r  ".[$rule_idx].batch_size  // 5000"         "$ARCHIVE_CONFIG")
    max_batches=$(jq -r ".[$rule_idx].max_batches // 0"            "$ARCHIVE_CONFIG")

    # 读取连接信息
    local _type _host _port _user _pass _cmode _container
    _type=$(jq -r      ".[$conn_idx].type"              "$DB_CONFIG_FILE")
    _host=$(jq -r      ".[$conn_idx].host"              "$DB_CONFIG_FILE")
    _port=$(jq -r      ".[$conn_idx].port"              "$DB_CONFIG_FILE")
    _user=$(jq -r      ".[$conn_idx].user"              "$DB_CONFIG_FILE")
    _pass=$(jq -r      ".[$conn_idx].password"          "$DB_CONFIG_FILE")
    _cmode=$(jq -r     ".[$conn_idx].mode // \"host\""  "$DB_CONFIG_FILE")
    _container=$(jq -r ".[$conn_idx].container // \"\""  "$DB_CONFIG_FILE")

    log_info "═══ 归档规则: $rule_name ═══"
    log_info "  表: $db_name.$tbl_name | 保留: ${retention}天 | 模式: $mode | 批次: ${batch_size}条"

    # 自动检查并为时间字段添加索引
    if [ "$_type" = "mysql" ]; then
        local has_index
        has_index=$(_archive_exec_sql "$_type" "$_host" "$_port" "$_user" "$_pass" "$_cmode" "$_container" "information_schema" \
            "SELECT COUNT(1) FROM STATISTICS WHERE TABLE_SCHEMA='$db_name' AND TABLE_NAME='$tbl_name' AND COLUMN_NAME='$date_col' AND SEQ_IN_INDEX=1;" 2>/dev/null)
        has_index=$(echo "$has_index" | grep -oE '^[0-9]+$' | tail -1)
        if [ "${has_index:-0}" -eq 0 ]; then
            log_warn "  未检测到时间字段 \`$date_col\` 的前缀索引，正在自动创建 (大表可能耗时较久，请耐心等待)..."
            _archive_exec_sql_rc "$_type" "$_host" "$_port" "$_user" "$_pass" "$_cmode" "$_container" "$db_name" \
                "ALTER TABLE \`$db_name\`.\`$tbl_name\` ADD INDEX \`idx_${date_col}_archive\` (\`$date_col\`);" 2>/dev/null
            if [ $? -eq 0 ]; then
                log_info "  ✓ 索引创建成功，查询性能已优化"
            else
                log_error "  ✗ 索引创建失败，归档操作可能会因全表扫描而极其缓慢"
            fi
        fi
    else
        # PostgreSQL 支持原生的 IF NOT EXISTS
        _archive_exec_sql_rc "$_type" "$_host" "$_port" "$_user" "$_pass" "$_cmode" "$_container" "$db_name" \
            "CREATE INDEX IF NOT EXISTS \"idx_${tbl_name}_${date_col}_archive\" ON \"$tbl_name\" (\"$date_col\");" 2>/dev/null
        [ $? -eq 0 ] || log_error "  ✗ PostgreSQL 索引创建/验证失败"
    fi

    # 统计待归档行数
    local count_sql total_rows
    if [ "$_type" = "mysql" ]; then
        count_sql="SELECT COUNT(*) FROM \`$db_name\`.\`$tbl_name\` WHERE \`$date_col\` < DATE_SUB(NOW(), INTERVAL $retention DAY);"
    else
        count_sql="SELECT COUNT(*) FROM \"$db_name\".\"$tbl_name\" WHERE \"$date_col\" < NOW() - INTERVAL '$retention days';"
    fi
    total_rows=$(_archive_exec_sql "$_type" "$_host" "$_port" "$_user" "$_pass" "$_cmode" "$_container" "$db_name" "$count_sql")
    total_rows=$(echo "$total_rows" | tr -d ' \n\r')
    log_info "  待处理行数: ${total_rows:-未知}"
    [ "${total_rows:-0}" = "0" ] && { log_info "  无需归档，跳过"; return 0; }

    # move 模式：确保归档表存在
    if [ "$mode" = "move" ]; then
        [ -z "$archive_db" ]  && archive_db="${db_name}_archive"
        [ -z "$archive_tbl" ] && archive_tbl="${tbl_name}_archive"
        log_info "  归档目标: $archive_db.$archive_tbl"

        local create_sql
        if [ "$_type" = "mysql" ]; then
            # 确保归档库存在
            _archive_exec_sql_rc "$_type" "$_host" "$_port" "$_user" "$_pass" "$_cmode" "$_container" \
                "information_schema" "CREATE DATABASE IF NOT EXISTS \`$archive_db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
            create_sql="CREATE TABLE IF NOT EXISTS \`$archive_db\`.\`$archive_tbl\` LIKE \`$db_name\`.\`$tbl_name\`;"
        else
            # PostgreSQL: 使用同一数据库内不同模式（schema）方式，或同一 DB
            create_sql="CREATE TABLE IF NOT EXISTS \"${archive_tbl}\" (LIKE \"${tbl_name}\" INCLUDING ALL);"
            db_name_for_archive="$db_name"
        fi
        _archive_exec_sql_rc "$_type" "$_host" "$_port" "$_user" "$_pass" "$_cmode" "$_container" \
            "${db_name_for_archive:-$db_name}" "$create_sql"
        [ $? -ne 0 ] && { log_error "  创建归档表失败"; return 1; }
    fi

    # ── 元数据预取（仅查一次，避免在每个批次内重复查询 information_schema）──
    local pk_col="" order_clause="" update_str="" where=""
    if [ "$_type" = "mysql" ]; then
        pk_col=$(_archive_exec_sql "$_type" "$_host" "$_port" "$_user" "$_pass" "$_cmode" "$_container" "information_schema" \
            "SELECT COLUMN_NAME FROM KEY_COLUMN_USAGE
             WHERE TABLE_SCHEMA='$db_name' AND TABLE_NAME='$tbl_name' AND CONSTRAINT_NAME='PRIMARY'
             ORDER BY ORDINAL_POSITION LIMIT 1;" 2>/dev/null)
        pk_col=$(echo "$pk_col" | grep -v "COLUMN_NAME" | tr -d ' \n\r')
        [ -n "$pk_col" ] && order_clause="ORDER BY \`$pk_col\` ASC"

        # 预取所有列，拼接 ON DUPLICATE KEY UPDATE 子句
        local cols_raw=""
        cols_raw=$(_archive_exec_sql "$_type" "$_host" "$_port" "$_user" "$_pass" "$_cmode" "$_container" "information_schema" \
            "SELECT COLUMN_NAME FROM COLUMNS
             WHERE TABLE_SCHEMA='$db_name' AND TABLE_NAME='$tbl_name'
             ORDER BY ORDINAL_POSITION;" 2>/dev/null)
        for col in $(echo "$cols_raw" | grep -v "COLUMN_NAME" | tr -d '\r'); do
            [ -n "$update_str" ] && update_str="$update_str, "
            update_str="$update_str\`$col\`=VALUES(\`$col\`)"
        done
        where="\`$date_col\` < DATE_SUB(NOW(), INTERVAL $retention DAY)"
    else
        where="\"$date_col\" < NOW() - INTERVAL '$retention days'"
    fi

    # 无主键时退回到普通 LIMIT（降级兼容）
    local has_pk=1
    [ -z "$pk_col" ] && has_pk=0

    # ── 批次循环处理（带时间统计）──────────────────────────────────────
    local moved=0 batch_no=0 affected
    local ts_total_start ts_total_end batch_start batch_end elapsed_batch speed
    ts_total_start=$(date +%s)

    while true; do
        ((batch_no++))
        [ "$max_batches" -gt 0 ] && [ "$batch_no" -gt "$max_batches" ] && {
            log_warn "  已达最大批次限制 ($max_batches)，本次停止"; break
        }

        batch_start=$(date +%s%3N)   # 毫秒级时间戳

        if [ "$_type" = "mysql" ]; then
            if [ "$has_pk" -eq 1 ]; then
                # ── 精准批次：用临时表锁定同一批主键，保证 INSERT 和 DELETE 操作完全相同的行 ──
                local tmp_table="_arch_tmp_$$"
                if [ "$mode" = "move" ]; then
                    affected=$(_archive_exec_sql "$_type" "$_host" "$_port" "$_user" "$_pass" "$_cmode" "$_container" "$db_name" \
                        "CREATE TEMPORARY TABLE IF NOT EXISTS \`$tmp_table\` AS
                           SELECT \`$pk_col\` FROM \`$db_name\`.\`$tbl_name\`
                           WHERE $where $order_clause LIMIT $batch_size;
                         INSERT INTO \`$archive_db\`.\`$archive_tbl\`
                           SELECT * FROM \`$db_name\`.\`$tbl_name\`
                           WHERE \`$pk_col\` IN (SELECT \`$pk_col\` FROM \`$tmp_table\`)
                         ON DUPLICATE KEY UPDATE $update_str;
                         DELETE FROM \`$db_name\`.\`$tbl_name\`
                           WHERE \`$pk_col\` IN (SELECT \`$pk_col\` FROM \`$tmp_table\`);
                         SELECT ROW_COUNT();
                         DROP TEMPORARY TABLE IF EXISTS \`$tmp_table\`;" 2>/dev/null)
                else
                    affected=$(_archive_exec_sql "$_type" "$_host" "$_port" "$_user" "$_pass" "$_cmode" "$_container" "$db_name" \
                        "CREATE TEMPORARY TABLE IF NOT EXISTS \`$tmp_table\` AS
                           SELECT \`$pk_col\` FROM \`$db_name\`.\`$tbl_name\`
                           WHERE $where $order_clause LIMIT $batch_size;
                         DELETE FROM \`$db_name\`.\`$tbl_name\`
                           WHERE \`$pk_col\` IN (SELECT \`$pk_col\` FROM \`$tmp_table\`);
                         SELECT ROW_COUNT();
                         DROP TEMPORARY TABLE IF EXISTS \`$tmp_table\`;" 2>/dev/null)
                fi
            else
                # ── 降级兼容：无主键时用 LIMIT（无法保证原子性，但可正常运行）──
                if [ "$mode" = "move" ]; then
                    affected=$(_archive_exec_sql "$_type" "$_host" "$_port" "$_user" "$_pass" "$_cmode" "$_container" "$db_name" \
                        "INSERT INTO \`$archive_db\`.\`$archive_tbl\`
                           SELECT * FROM \`$db_name\`.\`$tbl_name\` WHERE $where LIMIT $batch_size
                         ON DUPLICATE KEY UPDATE $update_str;
                         DELETE FROM \`$db_name\`.\`$tbl_name\` WHERE $where LIMIT $batch_size;
                         SELECT ROW_COUNT();" 2>/dev/null)
                else
                    affected=$(_archive_exec_sql "$_type" "$_host" "$_port" "$_user" "$_pass" "$_cmode" "$_container" "$db_name" \
                        "DELETE FROM \`$db_name\`.\`$tbl_name\` WHERE $where LIMIT $batch_size;
                         SELECT ROW_COUNT();" 2>/dev/null)
                fi
            fi
            affected=$(echo "$affected" | grep -oE '^-?[0-9]+$' | tail -1)
        else
            # PostgreSQL: CTE 原子移动
            if [ "$mode" = "move" ]; then
                affected=$(_archive_exec_sql "$_type" "$_host" "$_port" "$_user" "$_pass" "$_cmode" "$_container" "$db_name" \
                    "WITH moved AS (
                       DELETE FROM \"$tbl_name\"
                       WHERE ctid IN (
                         SELECT ctid FROM \"$tbl_name\" WHERE $where LIMIT $batch_size
                       ) RETURNING *
                     ), ins AS (
                       INSERT INTO \"$archive_tbl\" SELECT * FROM moved RETURNING 1
                     ) SELECT COUNT(*) FROM ins;" 2>/dev/null)
            else
                affected=$(_archive_exec_sql "$_type" "$_host" "$_port" "$_user" "$_pass" "$_cmode" "$_container" "$db_name" \
                    "WITH del AS (
                       DELETE FROM \"$tbl_name\"
                       WHERE ctid IN (
                         SELECT ctid FROM \"$tbl_name\" WHERE $where LIMIT $batch_size
                       ) RETURNING 1
                     ) SELECT COUNT(*) FROM del;" 2>/dev/null)
            fi
            affected=$(echo "$affected" | grep -oE '^-?[0-9]+$' | tail -1)
        fi

        affected="${affected:-0}"
        if [ "$affected" -le 0 ]; then
            [ "$affected" -lt 0 ] && log_error "  批次 $batch_no: SQL 执行失败，中止循环"
            break
        fi

        batch_end=$(date +%s%3N)
        elapsed_batch=$(( batch_end - batch_start ))
        # 计算本批速度 行/s，避免除零
        if [ "$elapsed_batch" -gt 0 ]; then
            speed=$(( affected * 1000 / elapsed_batch ))
        else
            speed=9999
        fi

        moved=$((moved + affected))
        log_info "  批次 $batch_no: ${affected} 行 | 耗时 ${elapsed_batch}ms | 速度 ${speed} 行/s | 累计 $moved 行"

        sleep 0.1
    done

    ts_total_end=$(date +%s)
    local elapsed_total=$(( ts_total_end - ts_total_start ))
    local avg_speed=0
    [ "$elapsed_total" -gt 0 ] && avg_speed=$(( moved / elapsed_total ))

    log_info "  ✓ 归档完成 | 总行数: $moved | 总耗时: ${elapsed_total}s | 平均速度: ${avg_speed} 行/s"

    # 写入归档日志统计记录
    local log_file="${BACKUP_DIR}/archive.log"
    local ts_str
    ts_str=$(date "+%Y-%m-%d %H:%M:%S")
    mkdir -p "$BACKUP_DIR"
    printf "[%s] 规则=%-20s 库表=%-40s 模式=%-6s 处理行=%d 耗时=%ds 速度=%d行/s\n" \
        "$ts_str" "$rule_name" "${db_name}.${tbl_name}" "$mode" "$moved" "$elapsed_total" "$avg_speed" \
        >> "$log_file"

    return 0
}


# ── 添加归档规则 ──────────────────────────────────────────────────
archive_add_rule() {
    log_title "添加归档规则"
    init_archive_config

    read -rp "规则名称 (如: 日志归档): " rule_name
    [ -z "$rule_name" ] && { log_error "名称不能为空"; return 1; }

    # 选择数据库连接
    echo -e "${BOLD}选择数据库连接:${NC}" >&2
    select_connection || return 1
    local conn_idx="$SELECTED_IDX"
    log_info "连接: $SELECTED_ALIAS ($SELECTED_TYPE)"

    # 输入库名
    read -rp "数据库名: " db_name
    [ -z "$db_name" ] && { log_error "库名不能为空"; return 1; }

    # 列出该库的表
    local tbl_sql
    if [ "$SELECTED_TYPE" = "mysql" ]; then
        tbl_sql="SHOW TABLES FROM \`$db_name\`;"
    else
        tbl_sql="SELECT tablename FROM pg_tables WHERE schemaname='public';"
    fi
    local tbl_list
    tbl_list=$(_archive_exec_sql "$SELECTED_TYPE" "$SELECTED_HOST" "$SELECTED_PORT" \
        "$SELECTED_USER" "$SELECTED_PASS" "$SELECTED_MODE" "$SELECTED_CONTAINER" "$db_name" "$tbl_sql")
    if [ -n "$tbl_list" ]; then
        echo -e "\n${CYAN}可用数据表:${NC}"
        local ti=0; declare -A tbl_map
        while IFS= read -r t; do
            [ -z "$t" ] && continue
            echo -e "  ${GREEN}[$ti]${NC} $t"
            tbl_map[$ti]="$t"; ((ti++))
        done <<< "$tbl_list"
        read -rp "选择序号或直接输入表名: " tsel
        if [[ "$tsel" =~ ^[0-9]+$ ]] && [ -n "${tbl_map[$tsel]:-}" ]; then
            tbl_name="${tbl_map[$tsel]}"
        else
            tbl_name="$tsel"
        fi
    else
        read -rp "数据表名: " tbl_name
    fi
    [ -z "$tbl_name" ] && { log_error "表名不能为空"; return 1; }

    read -rp "时间字段名 (如: created_at): " date_col
    [ -z "$date_col" ] && { log_error "时间字段不能为空"; return 1; }
    read -rp "数据保留天数 [默认90]: " retention; retention="${retention:-90}"
    echo -e "\n归档模式:\n  ${GREEN}1)${NC} move — 移至归档表（保留数据，可查询）\n  ${GREEN}2)${NC} delete — 直接删除（彻底清理）"
    read -rp "选择 [1/2, 默认1]: " msel
    local amode="move"; [ "$msel" = "2" ] && amode="delete"
    local archive_db="" archive_tbl=""
    if [ "$amode" = "move" ]; then
        read -rp "归档库名 [默认: ${db_name}_archive]: " archive_db; archive_db="${archive_db:-${db_name}_archive}"
        read -rp "归档表名 [默认: ${tbl_name}_archive]: " archive_tbl; archive_tbl="${archive_tbl:-${tbl_name}_archive}"
    fi
    read -rp "每批处理行数 [默认5000]: " batch_size; batch_size="${batch_size:-5000}"
    read -rp "每次最大批数 (0=不限) [默认0]: " max_batches; max_batches="${max_batches:-0}"

    local new_rule
    new_rule=$(jq -n \
        --arg  name         "$rule_name" \
        --argjson conn_idx  "$conn_idx" \
        --arg  database     "$db_name" \
        --arg  table        "$tbl_name" \
        --arg  date_column  "$date_col" \
        --argjson retention_days "$retention" \
        --arg  mode         "$amode" \
        --arg  archive_db   "$archive_db" \
        --arg  archive_table "$archive_tbl" \
        --argjson batch_size "$batch_size" \
        --argjson max_batches "$max_batches" \
        '{name:$name,conn_idx:$conn_idx,database:$database,table:$table,date_column:$date_column,retention_days:$retention_days,mode:$mode,archive_db:$archive_db,archive_table:$archive_table,batch_size:$batch_size,max_batches:$max_batches}')
    local tmp; tmp=$(mktemp)
    jq --argjson r "$new_rule" '. += [$r]' "$ARCHIVE_CONFIG" > "$tmp" && mv "$tmp" "$ARCHIVE_CONFIG"
    log_info "归档规则 \"$rule_name\" 已保存"
}

# ── 列出归档规则 ──────────────────────────────────────────────────
archive_list_rules() {
    log_title "归档规则列表"
    init_archive_config
    local count; count=$(jq 'length' "$ARCHIVE_CONFIG")
    if [ "$count" -eq 0 ]; then log_warn "暂无归档规则"; return; fi
    local i=0
    while [ $i -lt "$count" ]; do
        local name db tbl date_col ret mode adb atbl bs
        name=$(jq -r ".[$i].name" "$ARCHIVE_CONFIG")
        db=$(jq -r ".[$i].database" "$ARCHIVE_CONFIG")
        tbl=$(jq -r ".[$i].table" "$ARCHIVE_CONFIG")
        date_col=$(jq -r ".[$i].date_column" "$ARCHIVE_CONFIG")
        ret=$(jq -r ".[$i].retention_days" "$ARCHIVE_CONFIG")
        mode=$(jq -r ".[$i].mode" "$ARCHIVE_CONFIG")
        bs=$(jq -r ".[$i].batch_size // 5000" "$ARCHIVE_CONFIG")
        local conn_idx; conn_idx=$(jq -r ".[$i].conn_idx" "$ARCHIVE_CONFIG")
        local conn_alias; conn_alias=$(jq -r ".[$conn_idx].alias // \"未知连接\"" "$DB_CONFIG_FILE" 2>/dev/null)
        echo -e "  ${GREEN}[$i]${NC} ${BOLD}$name${NC}"
        echo -e "      连接: $conn_alias | 库表: $db.$tbl | 时间字段: $date_col"
        echo -e "      保留: ${ret}天 | 模式: $mode | 批次: ${bs}行/批"
        if [ "$mode" = "move" ]; then
            local adb atbl
            adb=$(jq -r ".[$i].archive_db // \"\"" "$ARCHIVE_CONFIG")
            atbl=$(jq -r ".[$i].archive_table // \"\"" "$ARCHIVE_CONFIG")
            echo -e "      归档目标: ${adb}.${atbl}"
        fi
        ((i++))
    done
}

# ── 删除归档规则 ──────────────────────────────────────────────────
archive_delete_rule() {
    log_title "删除归档规则"
    archive_list_rules
    local count; count=$(jq 'length' "$ARCHIVE_CONFIG")
    [ "$count" -eq 0 ] && return
    read -rp "请输入要删除的规则序号: " sel
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -ge "$count" ]; then
        log_error "无效序号"; return 1
    fi
    local name; name=$(jq -r ".[$sel].name" "$ARCHIVE_CONFIG")
    read -rp "确认删除规则 \"$name\"? [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && return
    local tmp; tmp=$(mktemp)
    jq "del(.[$sel])" "$ARCHIVE_CONFIG" > "$tmp" && mv "$tmp" "$ARCHIVE_CONFIG"
    log_info "规则 \"$name\" 已删除"
}

# ── 手动执行归档 ──────────────────────────────────────────────────
archive_run_menu() {
    log_title "执行归档"
    archive_list_rules
    local count; count=$(jq 'length' "$ARCHIVE_CONFIG")
    [ "$count" -eq 0 ] && { press_enter; return; }
    echo -e "  ${GREEN}[a]${NC} 执行全部规则"
    read -rp "请输入规则序号或 a: " sel
    if [ "$sel" = "a" ]; then
        local i=0
        while [ $i -lt "$count" ]; do
            do_archive_rule "$i" 1; ((i++))
        done
    elif [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -lt "$count" ]; then
        do_archive_rule "$sel" 1
    else
        log_error "无效输入"
    fi
    press_enter
}

# ── 归档定时任务管理 ──────────────────────────────────────────────
archive_cron_add() {
    log_title "添加归档定时任务"
    archive_list_rules
    local count; count=$(jq 'length' "$ARCHIVE_CONFIG")
    [ "$count" -eq 0 ] && { log_warn "请先添加归档规则"; press_enter; return; }
    read -rp "请输入规则序号 (或 a=全部): " sel
    local rule_arg
    if [ "$sel" = "a" ]; then
        rule_arg="__ALL__"
    elif [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -lt "$count" ]; then
        rule_arg="$sel"
    else
        log_error "无效序号"; return
    fi

    echo -e "\n执行频率:\n  ${GREEN}[1]${NC} 每天定时  ${GREEN}[2]${NC} 每周定时  ${GREEN}[3]${NC} 自定义 cron"
    read -rp "选择: " freq
    local cron_expr
    case "$freq" in
        1) read -rp "几点执行 [0-23, 默认3]: " hr; hr="${hr:-3}"
           cron_expr="0 $hr * * *" ;;
        2) read -rp "星期几 [0=周日..6=周六, 默认0]: " wd; wd="${wd:-0}"
           read -rp "几点 [默认3]: " hr; hr="${hr:-3}"
           cron_expr="0 $hr * * $wd" ;;
        3) read -rp "cron 表达式 (分 时 日 月 周): " cron_expr ;;
        *) log_error "无效选择"; return ;;
    esac

    local script_path; script_path=$(realpath "$0")
    local cron_cmd="$cron_expr bash $script_path --cron-archive \"$rule_arg\" >> $BACKUP_DIR/archive.log 2>&1"
    (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab -
    log_info "归档定时任务已添加: $cron_expr | 规则: $rule_arg"
}

archive_cron_list() {
    log_title "归档定时任务"
    local tasks; tasks=$(crontab -l 2>/dev/null | grep "db_manager.sh --cron-archive")
    [ -z "$tasks" ] && { log_warn "暂无归档定时任务"; press_enter; return; }
    echo "$tasks"
    press_enter
}

archive_cron_delete() {
    log_title "删除归档定时任务"
    local tasks; tasks=$(crontab -l 2>/dev/null | grep "db_manager.sh --cron-archive")
    [ -z "$tasks" ] && { log_warn "暂无任务"; press_enter; return; }
    local i=0; declare -A amap
    while IFS= read -r line; do
        echo -e "  ${GREEN}[$i]${NC} $line"; amap[$i]="$line"; ((i++))
    done <<< "$tasks"
    read -rp "请选择要删除的序号: " sel
    local target="${amap[$sel]:-}"
    [ -z "$target" ] && { log_error "无效序号"; return; }
    local escaped; escaped=$(printf '%s\n' "$target" | sed 's/[[\.*^$()+?{|]/\\&/g')
    crontab -l 2>/dev/null | grep -v "$escaped" | crontab -
    log_info "归档任务已删除"
    press_enter
}

# ── cron 静默归档入口 ─────────────────────────────────────────────
cron_archive_run() {
    local rule_arg="$1"
    init_config; init_archive_config
    local count; count=$(jq 'length' "$ARCHIVE_CONFIG")
    if [ "$rule_arg" = "__ALL__" ]; then
        local i=0
        while [ $i -lt "$count" ]; do
            do_archive_rule "$i" 0; ((i++))
        done
    elif [[ "$rule_arg" =~ ^[0-9]+$ ]] && [ "$rule_arg" -lt "$count" ]; then
        do_archive_rule "$rule_arg" 0
    else
        log_error "cron-archive: 无效规则参数 '$rule_arg'"; exit 1
    fi
}

# ── 归档管理主菜单 ────────────────────────────────────────────────
archive_menu() {
    init_archive_config
    while true; do
        log_title "数据表归档管理"
        echo -e "  ${GREEN}[1]${NC} 添加归档规则"
        echo -e "  ${GREEN}[2]${NC} 查看归档规则"
        echo -e "  ${GREEN}[3]${NC} 删除归档规则"
        echo -e "  ${GREEN}[4]${NC} 立即执行归档"
        echo -e "  ${GREEN}[5]${NC} 定时归档 — 添加任务"
        echo -e "  ${GREEN}[6]${NC} 定时归档 — 查看任务"
        echo -e "  ${GREEN}[7]${NC} 定时归档 — 删除任务"
        echo -e "  ${GREEN}[0]${NC} 返回主菜单"
        read -rp "请选择: " ch
        case "$ch" in
            1) archive_add_rule;    press_enter ;;
            2) archive_list_rules;  press_enter ;;
            3) archive_delete_rule; press_enter ;;
            4) archive_run_menu ;;
            5) archive_cron_add;    press_enter ;;
            6) archive_cron_list ;;
            7) archive_cron_delete ;;
            0) break ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

# ── 主菜单 ────────────────────────────────────────────────────────
main_menu() {
    check_jq
    init_config
    while true; do
        clear
        echo -e "${BOLD}${CYAN}"
        echo "  ╔══════════════════════════════════════╗"
        echo "  ║   数据库管理工具 v2.1              ║"
        echo "  ║  MySQL / PostgreSQL 备份恢复管理     ║"
        echo "  ║  支持 Host 直连和 Docker 容器模式    ║"
        echo "  ╚══════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e "  ${GREEN}[1]${NC} 备份数据库"
        echo -e "  ${GREEN}[2]${NC} 恢复数据库"
        echo -e "  ${GREEN}[3]${NC} 管理数据库连接配置"
        echo -e "  ${GREEN}[4]${NC} 定时备份管理"
        echo -e "  ${GREEN}[5]${NC} 数据表归档管理"
        echo -e "  ${RED}[0]${NC} 退出"
        echo ""
        read -rp "请选择操作: " choice
        case "$choice" in
            1) backup_menu ;;
            2) restore_submenu ;;
            3) config_menu ;;
            4) cron_menu ;;
            5) archive_menu ;;
            0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) log_warn "无效选项，请重新选择" ;;
        esac
    done
}

# ── 入口判断 ──────────────────────────────────────────────────────
case "$1" in
    --cron-backup)
        check_jq
        init_config
        cron_backup_run "$2" "$3"
        ;;
    --cron-archive)
        check_jq
        cron_archive_run "$2"
        ;;
    *)
        main_menu
        ;;
esac
