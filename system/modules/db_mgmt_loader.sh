#!/bin/bash

# =================================================================
# 模块名称: db_mgmt_loader.sh
# 描述: 数据库管理模块适配加载器 (Linux-ops-box 专用)
# 职责: 映射 db_mgmt.sh 逻辑到 ck_sysinit TUI 菜单
# =================================================================

# 模块级路径变量
DB_MOD_DIR="$BASE_DIR/db_manager"
DB_MGMT_SCRIPT="$DB_MOD_DIR/db_mgmt.sh"

# 1. 注入/覆盖 db_mgmt.sh 中的路径变量，强制其使用 Linux-ops-box 的模块目录
# 这样 db_mgmt.sh 内部的 SCRIPT_DIR 会指向正确的 modules/db_manager
export SCRIPT_DIR="$DB_MOD_DIR"

# 2. source 核心脚本 (仅加载函数定义，不执行菜单)
# db_mgmt.sh 末尾用 BASH_SOURCE 守卫入口，source 时不会触发 main_menu
if [ -f "$DB_MGMT_SCRIPT" ]; then
    source "$DB_MGMT_SCRIPT"
else
    _log_err "数据库管理脚本缺失: $DB_MGMT_SCRIPT"
fi

# 3. ck_sysinit 菜单入口对接函数
db_management_center() {
    # 检查 jq 依赖 (common.sh 已有部分依赖检查，这里调用 db_mgmt.sh 的 check_jq)
    check_jq
    
    # 初始化配置
    init_config
    
    # 进入数据库管理主菜单
    # 因为 db_mgmt.sh 的 main_menu 有 while true 循环，这里直接接管
    main_menu
}
