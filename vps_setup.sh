#!/bin/bash
#
# VPS一键装机 — 生产级通用版 (带可视化配置界面)
# 一行命令启动，随后进入可视化配置，完成后自动执行安装
#
# 依赖: bash shell，用于命令行交互式配置
# 核心库: core.sh (日志、状态、系统检测) 和 common.sh (配置管理)
#

# ===== 初始化 =====
set -euo pipefail

# 脚本根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/common.sh"

# 确保目录存在
mkdir -p "${CONFIG_DIR}" "${PROFILES_DIR}" "${LOGS_DIR}" "${BACKUPS_DIR}"

# 全局变量
INTERACTIVE_MODE=true
NON_INTERACTIVE=false
DRY_RUN=false
FORCE_MODE=false
ACTION="install" # install, rollback, status
SELECTED_MODULES=() # 如果为空则表示所有模块
CONFIG_FILE="${CONFIG_DIR}/vps_config.conf"

# 模块定义 (顺序重要)
MODULES=(
    "00_preflight:System preflight check"
    "01_hostname:Hostname and /etc/hosts"
    "02_locale_timezone:Locale and timezone"
    "03_dns:DNS resolution"
    "04_user:Non-root user creation"
    "05_ssh:SSH hardening"
    "06_firewall:Firewall configuration"
    "07_fail2ban:Fail2ban intrusion prevention"
    "08_docker:Docker engine installation"
    "09_network:Network optimization (BBR, TCP tuning)"
    "10_backup:Automated backup system"
    "11_monitoring:System monitoring tools"
    "12_security:Security scanning and auditing"
    "13_cleanup:System cleanup and optimization (swap, snap, cache)"
)

# 模块名称到文件名的映射（去掉前缀序号）
declare -A MODULE_FILES
for module in "${MODULES[@]}"; do
    name="${module%%:*}"
    # 假设文件名为 modules/xx_name.sh 其中 xx 是两位数序号
    # 我们通过前两个字符匹配
    num="${name:0:2}"
    name_without_num="${name:3}"
    MODULE_FILES["$name"]="modules/${num}_${name_without_num}.sh"
done

# ===== 辅助函数 =====

# 用户交互提示函数
NON_INTERACTIVE=false
prompt_or_default() {
    local __var="$1" __prompt="$2" __default="$3" __env="${4:-$1}"
    if [ "$NON_INTERACTIVE" = true ]; then
        printf -v "$__var" '%s' "${!__env:-$__default}"
    else
        local answer
        read -rp "$__prompt [$__default]: " answer
        if [ -z "$answer" ]; then
            answer="$__default"
        fi
        printf -v "$__var" '%s' "$answer"
    fi
}

msg_box() {
    local title="$1"
    local text="$2"
    echo
    echo "=== $title ==="
    echo "$text"
    echo
}

yesno_box() {
    local prompt
    if [ $# -eq 1 ]; then
        prompt="$1"
    else
        prompt="$2"
    fi
    local default="y"
    local env_name=""
    if [ $# -ge 3 ]; then
        env_name="$3"
    fi

    if [ "$NON_INTERACTIVE" = true ]; then
        local answer="${!env_name:-$default}"
        case "$answer" in
            [Yy1]|[Yy][eE][sS]) return 0 ;;
            *) return 1 ;;
        esac
    else
        local answer
        while true; do
            read -rp "$prompt [y/n] ($default): " answer
            if [ -z "$answer" ]; then
                answer="$default"
            fi
            case "$answer" in
                [Yy]|[Yy][eE][sS]) return 0 ;;
                [Nn]|[Nn][oO]) return 1 ;;
                *) echo "请输入 y 或 n" ;;
            esac
        done
    fi
}

input_box() {
    local title="$1"
    local prompt="$2"
    local default="$3"
    local var
    prompt_or_default var "$prompt" "$default"
    printf '%s' "$var"
}

password_box() {
    local prompt="$1"
    local env_name="${2:-}"

    if [ "$NON_INTERACTIVE" = true ]; then
        if [ -n "$env_name" ]; then
            printf '%s' "${!env_name:-}"
        else
            echo
        fi
    else
        local password
        read -rsp "$prompt: " password
        echo
        printf '%s' "$password"
    fi
}

menu_select() {
    local title="$1"
    local prompt="$2"
    shift 2
    local options=("$@")
    if [ "$NON_INTERACTIVE" = true ]; then
        printf '%s' "${options[0]}"
    else
        echo "$prompt"
        local index=1
        for opt in "${options[@]}"; do
            echo "  $index) $opt"
            index=$((index + 1))
        done
        local choice
        while true; do
            read -rp "请选择 [1-$((index - 1))] (默认: 1): " choice
            if [ -z "$choice" ]; then
                choice=1
            fi
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$index" ]; then
                printf '%s' "${options[choice-1]}"
                return 0
            fi
            echo "请输入有效的数字。"
        done
    fi
}


# ===== 配置向导函数 =====

# 配置系统设置
configure_system() {
    local hostname timezone locale primary_dns secondary_dns
    
    hostname=$(input_box "系统主机名" "请输入主机名:" "${HOSTNAME:-my-vps-server}")
    [ $? -ne 0 ] && return 1
    
    timezone=$(input_box "时区" "请输入时区 (例如: Asia/Shanghai):" "${TIMEZONE:-Asia/Shanghai}")
    [ $? -ne 0 ] && return 1
    
    locale=$(input_box "语言环境" "请输入语言环境 (例如: zh_CN.UTF-8):" "${LOCALE:-zh_CN.UTF-8}")
    [ $? -ne 0 ] && return 1
    
    primary_dns=$(input_box "首选DNS" "请输入首选DNS服务器:" "${PRIMARY_DNS:-1.1.1.1}")
    [ $? -ne 0 ] && return 1
    
    secondary_dns=$(input_box "备用DNS" "请输入备用DNS服务器:" "${SECONDARY_DNS:-8.8.8.8}")
    [ $? -ne 0 ] && return 1
    
    # 导出变量供模块使用
    export HOSTNAME="$hostname"
    export TIMEZONE="$timezone"
    export LOCALE="$locale"
    export PRIMARY_DNS="$primary_dns"
    export SECONDARY_DNS="$secondary_dns"
    
    return 0
}

# 配置用户设置
configure_user() {
    local username ssh_pubkey_password_auth ssh_pubkey
    
    username=$(input_box "普通用户名" "请输入普通用户名:" "${USERNAME:-appadmin}")
    [ $? -ne 0 ] && return 1
    
    # SSH 公钥选项
    if yesno_box "SSH公钥认证" "是否使用SSH公钥认证？(如果选择否，将使用密码认证)" ; then
        ssh_pubkey_auth="yes"
        # 让用户输入或粘贴公钥
        ssh_pubkey=$(input_box "SSH公钥" "请输入SSH公钥（可以为空，则自动生成密钥对）:" "")
        [ $? -ne 0 ] && return 1
    else
        ssh_pubkey_auth="no"
        ssh_pubkey=""
    fi
    
    # 密码认证
    if [ "$ssh_pubkey_auth" = "no" ]; then
        password_auth="yes"
    else
        if yesno_box "密码认证" "是否允许密码认证？（不推荐，但有时必要）" ; then
            password_auth="yes"
        else
            password_auth="no"
        fi
    fi
    
    export USERNAME="$username"
    export SSH_PUBKEY_AUTHENTICATION="yes"
    export SSH_PUBKEY="$ssh_pubkey"
    export PASSWORD_AUTH="yes"
    export SSH_PUBKEY_AUTH="$ssh_pubkey_auth"

    return 0
}

# 配置SSH设置
configure_ssh() {
    local ssh_port permit_root_login max_auth_tries client_alive_interval client_alive_count_max login_grace_time

    ssh_port=$(input_box "SSH端口" "请输入SSH端口号 (默认: 24822):" "${SSH_PORT:-24822}")
    if ! validate_port "$ssh_port" 2>/dev/null; then
        msg_box "错误" "端口号无效"
        return 1
    fi
    
    if yesno_box "是否允许root通过SSH登录?"; then
        permit_root_login="yes"
    else
        permit_root_login="no"
    fi
    
    max_auth_tries=$(input_box "最大认证尝试次数" "请输入最大认证尝试次数 (默认: 3):" "${SSH_MAX_AUTH_TRIES:-3}")
    [ $? -ne 0 ] && ! validate_number "$max_auth_tries" && { msg_box "错误" "请输入有效数字"; return 1; }
    
    client_alive_interval=$(input_box "客户端保活间隔" "请输入客户端保活间隔(秒) (默认: 300):" "${SSH_CLIENT_ALIVE_INTERVAL:-300}")
    [ $? -ne 0 ] && ! validate_number "$client_alive_interval" && { msg_box "错误" "请输入有效数字"; return 1; }
    
    client_alive_count_max=$(input_box "客户端保活计数最大值" "请输入客户端保活计数最大值 (默认: 2):" "${SSH_CLIENT_ALIVE_COUNT_MAX:-2}")
    [ $? -ne 0 ] && ! validate_number "$client_alive_count_max" && { msg_box "错误" "请输入有效数字"; return 1; }
    
    login_grace_time=$(input_box "登录宽限时间" "请输入登录宽限时间(秒) (默认: 60):" "${SSH_LOGIN_GRACE_TIME:-60}")

    export SSH_PORT="$ssh_port"
    export PERMIT_ROOT_LOGIN="$permit_root_login"
    export SSH_MAX_AUTH_TRIES="$max_auth_tries"
    export SSH_CLIENT_ALIVE_INTERVAL="$client_alive_interval"
    export SSH_CLIENT_ALIVE_COUNT_MAX="$client_alive_count_max"
    export SSH_LOGIN_GRACE_TIME="$login_grace_time"
    
    return 0
}

# 配置安全设置
configure_security() {
    local install_fail2ban install_auditd enable_selinux_check
    
    if yesno_box "安装Fail2Ban" "是否安装并配置Fail2Ban来防暴力破解？" ; then
        install_fail2ban="true"
    else
        install_fail2ban="false"
    fi
    
    if yesno_box "启用审计日志" "是否启用auditd来记录系统调用和用户行为？" ; then
        install_auditd="true"
    else
        install_auditd="false"
    fi
    
    if yesno_box "检查SELinux/AppArmor" "是否检查并配置MAC策略（SELinux/AppArmor）？" ; then
        enable_selinux_check="true"
    else
        enable_selinux_check="false"
    fi
    
    export INSTALL_FAIL2BAN="$install_fail2ban"
    export INSTALL_AUDITD="$install_auditd"
    export ENABLE_SELINUX_CHECK="$enable_selinux_check"
    
    return 0
}

# 配置服务设置
configure_services() {
    local install_docker install_npm
    
    if yesno_box "安装Docker" "是否安装Docker引擎？" ; then
        install_docker="true"
    else
        install_docker="false"
    fi
    
    if yesno_box "安装NPM" "是否安装Node.js包管理器（Node.js和npm）？" ; then
        install_npm="true"
    else
        install_npm="false"
    fi
    
    export INSTALL_DOCKER="$install_docker"
    export INSTALL_NPM="$install_npm"
    
    return 0
}

# 配置备份和监控
configure_backup_monitoring() {
    local enable_backup enable_monitoring
    
    if yesno_box "启用备份" "是否启用自动备份系统？" ; then
        enable_backup="true"
    else
        enable_backup="false"
    fi
    
    if yesno_box "启用监控" "是否安装系统监控工具（如Netdata或Node Exporter）？" ; then
        enable_monitoring="true"
    else
        enable_monitoring="false"
    fi
    
    export ENABLE_BACKUP="$enable_backup"
    export ENABLE_MONITORING="$enable_monitoring"

    return 0
}

# 配置系统清洗和优化
configure_cleanup() {
    local enable_swap remove_snap clean_pkg_cache clean_journal disable_services clean_temp

    if yesno_box "创建Swap" "是否自动创建Swap交换分区？（内存≤2G推荐创建）" ; then
        enable_swap="true"
    else
        enable_swap="false"
    fi

    if yesno_box "卸载Snap" "是否卸载snap并阻止其重新安装？（仅Ubuntu）" ; then
        remove_snap="true"
    else
        remove_snap="false"
    fi

    if yesno_box "清理包缓存" "是否清理包管理器缓存并移除旧内核？" ; then
        clean_pkg_cache="true"
    else
        clean_pkg_cache="false"
    fi

    if yesno_box "清理日志" "是否清理systemd日志并限制其最大容量（200MB/7天）？" ; then
        clean_journal="true"
    else
        clean_journal="false"
    fi

    if yesno_box "禁用无用服务" "是否禁用不必要的服务以节省资源？" ; then
        disable_services="true"
    else
        disable_services="false"
    fi

    if yesno_box "清理临时文件" "是否清理/tmp和旧日志文件？" ; then
        clean_temp="true"
    else
        clean_temp="false"
    fi

    export ENABLE_SWAP="$enable_swap"
    export REMOVE_SNAP="$remove_snap"
    export CLEAN_PKG_CACHE="$clean_pkg_cache"
    export CLEAN_JOURNAL="$clean_journal"
    export DISABLE_SERVICES="$disable_services"
    export CLEAN_TEMP="$clean_temp"

    return 0
}

# 主配置向导
run_configuration_wizard() {
    local ret=0
    
    msg_box "欢迎使用VPS一键装机" "欢迎使用VPS一键装机向导\n\n本向导将帮助您配置系统的各项参数。\n请按提示输入，回车以接受默认值。"
    
    # 系统设置
    if ! configure_system; then
        msg_box "错误" "系统配置过程中发生错误。"
        return 1
    fi
    
    # 用户设置
    if ! configure_user; then
        msg_box "错误" "用户配置过程中发生错误。"
        return 1
    fi
    
    # SSH设置
    if ! configure_ssh; then
        msg_box "错误" "SSH配置过程中发生错误。"
        return 1
    fi
    
    # 安全设置
    if ! configure_security; then
        msg_box "错误" "安全配置过程中发生错误。"
        return 1
    fi
    
    # 服务设置
    if ! configure_services; then
        msg_box "错误" "服务配置过程中发生错误。"
        return 1
    fi
    
    # 备份和监控设置
    if ! configure_backup_monitoring; then
        msg_box "错误" "备份和监控配置过程中发生错误。"
        return 1
    fi

    # 系统清洗和优化设置
    if ! configure_cleanup; then
        msg_box "错误" "清洗优化配置过程中发生错误。"
        return 1
    fi

    msg_box "配置完成" "所有配置已完成！\\n系统将保存配置并开始安装过程。"
    
    return 0
}

# ===== 主程序 =====

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  -h, --help              显示此帮助信息"
            echo "  -n, --non-interactive   非交互模式（使用现有配置或默认值）"
            echo "  -a, --auto              自动模式（非交互+使用默认值跳过所有提示）"
            echo "  -d, --dry-run           试运行（仅显示将要执行的操作，不实际执行）"
            echo "  -f, --force             强制重新执行已完成的模块"
            echo "  --modules <list>        仅执行指定的模块，用逗号分隔 (例如: 01_hostname,05_ssh)"
            echo "  --rollback              回滚已完成的更改（恢复备份的配置文件）"
            echo "  --status                显示各模块的执行状态"
            exit 0
            ;;
        -n|--non-interactive)
            INTERACTIVE_MODE=false
            NON_INTERACTIVE=true
            shift
            ;;
        -a|--auto)
            INTERACTIVE_MODE=false
            NON_INTERACTIVE=true
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -f|--force)
            FORCE_MODE=true
            shift
            ;;
        --modules)
            IFS=',' read -ra MODS <<< "$2"
            SELECTED_MODULES=()
            for mod in "${MODS[@]}"; do
                # 去除空格
                mod=$(echo "$mod" | xargs)
                SELECTED_MODULES+=("$mod")
            done
            shift 2
            ;;
        --rollback)
            ACTION="rollback"
            shift
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        *)
            echo "未知选项: $1"
            echo "使用 -h 查看帮助"
            exit 1
            ;;
    esac
done

# 如果是非交互模式，尝试加载配置
if [ "$NON_INTERACTIVE" = true ]; then
    if [ -f "$CONFIG_FILE" ]; then
        log_info "从配置文件加载配置: $CONFIG_FILE"
        load_config "$CONFIG_FILE"
        apply_config_defaults
    else
        log_warn "配置文件不存在，将使用默认值。"
        apply_config_defaults
    fi
fi

# 如果是交互模式，运行向导
if [ "$ACTION" = "install" ] && [ "$INTERACTIVE_MODE" = true ]; then
    if ! run_configuration_wizard; then
        log_error "配置向导失败，退出。"
        exit 1
    fi
    # 保存配置
    save_config "$CONFIG_FILE" $(get_config_var_names)
    log_info "配置已保存到 $CONFIG_FILE"
fi

# 确保所有变量都有默认值
apply_config_defaults

# 打印配置摘要（调试用）
log_debug "=== 配置摘要 ==="
for var in $(get_config_var_names); do
    log_debug "$var=${!var}"
done
log_debug "=================="

# 根据操作执行相应任务
case "$ACTION" in
    status)
        echo "=== 模块状态 ==="
        for module in "${MODULES[@]}"; do
            name="${module%%:*}"
            desc="${module#*:}"
            status=$(state_get "$name")
            if [ -z "$status" ]; then
                status="未运行"
            fi
            printf "%-25s %-40s [%s]\n" "$name" "$desc" "$status"
        done
        exit 0
        ;;
    rollback)
        log_info "开始回滚操作..."
        # TODO: 实现回滚逻辑（恢复备份的文件，重置状态等）
        # 为了简单，这里只提示
        msg_box "回滚" "回滚功能尚未完全实现。\\n请手动从备份目录恢复文件。"
        exit 0
        ;;
    install)
        # 正常安装流程
        :
        ;;
    *)
        echo "未知操作: $ACTION"
        exit 1
        ;;
esac

# 确定要运行的模块列表
if [ ${#SELECTED_MODULES[@]} -eq 0 ]; then
    # 如果未指定具体模块，则使用所有模块
    MODULES_TO_RUN=("${MODULES[@]}")
else
    # 过滤出用户指定的模块
    MODULES_TO_RUN=()
    for module in "${MODULES[@]}"; do
        name="${module%%:*}"
        for selected in "${SELECTED_MODULES[@]}"; do
            if [ "$name" = "$selected" ]; then
                MODULES_TO_RUN+=("$module")
                break
            fi
        done
    done
fi

# 如果没有模块要运行，退出
if [ ${#MODULES_TO_RUN[@]} -eq 0 ]; then
    log_error "没有指定要运行的模块。"
    exit 1
fi

# 记录开始时间
START_TIME=$(date +%s)

# 按顺序执行每个模块
for module in "${MODULES_TO_RUN[@]}"; do
    name="${module%%:*}"
    desc="${module#*:}"
    
    # 检查是否已经完成（除非强制模式）
    if [ "$FORCE_MODE" = false ] && [ "$(state_get "$name")" = "done" ]; then
        log_info "跳过模块 $name: 已完成 ($desc)"
        continue
    fi
    
    log_info "开始执行模块: $name - $desc"
    
    # 导入模块文件
    module_file="${MODULE_FILES[$name]}"
    if [ ! -f "$module_file" ]; then
        log_error "模块文件不存在: $module_file"
        continue
    fi
    
    # 在子shell中源模块以隔离环境（但我们需要变量可见，所以直接source）
    # 实际上，我们希望模块在当前shell中执行，以便它们可以修改状态和访问导出的变量
    if [ "$DRY_RUN" = true ]; then
        log_info "[试运行] 将执行模块: $module_file"
        # 这里我们可以尝试只 source 但不执行 main 函数？简单起见，我们只提示
        continue
    fi
    
    # source 模块
    # 注意：模块应该定义了 _info, _prerequisites, _main 函数
    # 我们假设它们已经通过 source 加载到当前shell中
    if ! source "$module_file"; then
        log_error "无法加载模块文件: $module_file"
        continue
    fi

    # 定位模块函数前缀，例如 00_preflight -> preflight
    function_prefix="${name:3}"

    # 调用先决条件（如果存在）
    if declare -f "${function_prefix}_prerequisites" > /dev/null; then
        if ! "${function_prefix}_prerequisites"; then
            log_warn "模块 $name 的先决条件检查失败，跳过该模块。"
            continue
        fi
    fi

    # 执行主函数
    if declare -f "${function_prefix}_main" > /dev/null; then
        if "${function_prefix}_main"; then
            state_set "$name" "done"
            log_info "模块 $name 执行成功"
        else
            state_set "$name" "failed"
            log_error "模块 $name 执行失败"
            # 根据需求决定是否继续还是退出
            # 这里我们继续执行其他模块
        fi
    else
        log_warn "模块 $name 没有定义 _main 函数，跳过。"
    fi
done

# 计算耗时
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
HOURS=$((ELAPSED / 3600))
MINUTES=$(( (ELAPSED % 3600) / 60 ))
SECONDS=$((ELAPSED % 60))

# 显示完成摘要
if [ "$DRY_RUN" = false ]; then
    msg_box "安装完成" "所有选定的模块已处理完毕！\\n\\n总耗时: ${HOURS}小时 ${MINUTES}分钟 ${SECONDS}秒\\n\\n详细日志请查看: $LOG_FILE"
else
    msg_box "试运行完成" "试运行已完成。未实际执行任何修改。"
fi

exit 0
