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

# HOSTNAME is commonly pre-populated by the shell; configuration must come from
# VPS_SETUP_HOSTNAME, the config file, or the interactive wizard instead.
if [ -z "${VPS_SETUP_HOSTNAME:-}" ]; then
    unset HOSTNAME
fi

# 确保目录存在
mkdir -p "${CONFIG_DIR}" "${PROFILES_DIR}" "${LOGS_DIR}" "${BACKUPS_DIR}"

# 全局变量
INTERACTIVE_MODE=true
NON_INTERACTIVE=false
DRY_RUN=false
FORCE_MODE=false
FORCE=false
AUTO_YES="${AUTO_YES:-false}"
ACTION="install" # install, rollback, status
SELECTED_MODULES=() # 如果为空则表示所有模块
CONFIG_FILE="${CONFIG_DIR}/vps_config.conf"
WIZARD_TOTAL_STEPS=7

# 模块定义 (顺序重要)
MODULES=(
    "00_preflight:System preflight check"
    "01_hostname:Hostname and /etc/hosts"
    "13_cleanup:System cleanup and optimization (swap, snap, cache)"
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

# prompt_or_default VAR_NAME "提示文案" "默认值" [ENV_NAME]
prompt_or_default() {
    local __var="$1" __prompt="$2" __default="$3" __env="${4:-$1}"
    if [ "$NON_INTERACTIVE" = true ]; then
        printf -v "$__var" '%s' "${!__env:-$__default}"
        return 0
    else
        local answer
        read -r -p "$__prompt [默认: $__default] (输入 b 返回): " answer
        if [ "$answer" = "b" ] || [ "$answer" = "back" ]; then
            return 2
        fi
        if [ -z "$answer" ]; then
            answer="$__default"
        fi
        printf -v "$__var" '%s' "$answer"
        return 0
    fi
}

msg_box() {
    local title="$1"
    local text="$2"
    print_section "${title}"
    # 支持字面量 \n 与真实换行
    printf '%b\n' "${text}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo
}

# yesno_box "标题" "提示文案" [default_yn]
# default: y/Y/1/true/yes = 默认是; n/N/0/false/no = 默认否
yesno_box() {
    local title="$1"
    local prompt="${2:-$1}"
    local default="${3:-y}"

    # 规范化默认值为 y/n 用于显示
    local default_display
    case "${default,,}" in
        y|yes|1|t|true) default_display="y" ;;
        *) default_display="n" ;;
    esac

    if [ "$NON_INTERACTIVE" = true ]; then
        case "$default" in
            [Yy1]|[Yy][eE][sS]|[Tt][Rr][Uu][Ee]) return 0 ;;
            *) return 1 ;;
        esac
    else
        local answer
        local hint="[Y/n]"
        [ "$default_display" = "n" ] && hint="[y/N]"
        echo -e "${CYAN}--- ${title} ---${NC}"
        echo -e "  1) 是 (Yes)"
        echo -e "  2) 否 (No)"
        echo -e "  b) 返回上一步"
        while true; do
            read -r -p "$prompt (选择 1/2 或 $hint, 默认: $default_display): " answer
            if [ "$answer" = "b" ] || [ "$answer" = "back" ]; then
                return 2
            fi
            if [ -z "$answer" ]; then
                answer="$default_display"
            fi
            case "$answer" in
                1|[Yy]|[Yy][eE][sS]) return 0 ;;
                2|[Nn]|[Nn][oO]) return 1 ;;
                *) echo -e "${RED}请输入 1(是) 或 2(否)，或输入 b 返回${NC}" ;;
            esac
        done
    fi
}

# input_box VAR_NAME "提示文案" "默认值"
input_box() {
    local __var="$1"
    local prompt="$2"
    local default="$3"
    prompt_or_default "$__var" "$prompt" "$default"
}

# password_box VAR_NAME "提示文案"
password_box() {
    local __var="$1"
    local prompt="$2"

    if [ "$NON_INTERACTIVE" = true ]; then
        printf -v "$__var" '%s' ""
        return 0
    else
        local password
        read -rsp "$prompt (输入 b 返回): " password
        echo
        if [ "$password" = "b" ] || [ "$password" = "back" ]; then
            return 2
        fi
        printf -v "$__var" '%s' "$password"
        return 0
    fi
}

# menu_select VAR_NAME "标题" "提示文案" default_index option1 option2 ...
menu_select() {
    local __var="$1"
    local title="$2"
    local prompt="$3"
    local default_idx="$4"
    shift 4
    local options=("$@")

    if [ "$NON_INTERACTIVE" = true ]; then
        local def_val="${options[$((default_idx - 1))]}"
        printf -v "$__var" '%s' "$def_val"
        return 0
    else
        echo -e "${CYAN}=== ${title} ===${NC}"
        echo "$prompt"
        local index=1
        for opt in "${options[@]}"; do
            local mark=""
            if [ "$index" -eq "$default_idx" ]; then
                mark=" [默认]"
            fi
            echo -e "  $index) $opt$mark"
            index=$((index + 1))
        done
        echo -e "  b) 返回上一步"

        local choice
        while true; do
            read -r -p "请选择 [1-$((index - 1))] (默认: $default_idx, 输入 b 返回): " choice
            if [ "$choice" = "b" ] || [ "$choice" = "back" ]; then
                return 2
            fi
            if [ -z "$choice" ]; then
                choice="$default_idx"
            fi
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$index" ]; then
                local selected_val="${options[$((choice - 1))]}"
                printf -v "$__var" '%s' "$selected_val"
                return 0
            fi
            echo -e "${RED}请输入有效的数字编号 (1-$((index - 1))) 或输入 b 返回${NC}"
        done
    fi
}


# ===== 配置向导函数 =====

# 配置系统设置
configure_system() {
    print_step "1/${WIZARD_TOTAL_STEPS}" "系统基础配置"
    echo -e "${DIM}设置主机名、时区、语言环境与 DNS (输入 b 可随时返回)${NC}"

    local sub_step=1
    local hostname="${HOSTNAME:-my-vps-server}"
    local timezone="${TIMEZONE:-Asia/Shanghai}"
    local locale="${LOCALE:-zh_CN.UTF-8}"
    local primary_dns="${PRIMARY_DNS:-1.1.1.1}"
    local secondary_dns="${SECONDARY_DNS:-8.8.8.8}"
    local res=0

    while [ "$sub_step" -ge 1 ] && [ "$sub_step" -le 5 ]; do
        case "$sub_step" in
            1)
                res=0
                input_box hostname "请输入主机名:" "$hostname" || res=$?
                [ "$res" -eq 2 ] && return 2
                if ! validate_hostname "$hostname" 2>/dev/null; then
                    echo -e "${RED}主机名格式无效，请重试。${NC}"
                    continue
                fi
                sub_step=2
                ;;
            2)
                res=0
                local tz_choice=""
                menu_select tz_choice "系统时区" "请选择系统时区:" 1 \
                    "Asia/Shanghai (中国标准时间)" \
                    "UTC (协调世界时)" \
                    "America/New_York (美国东部时间)" \
                    "Europe/London (英国时间)" \
                    "手动输入自定义时区" || res=$?
                [ "$res" -eq 2 ] && { sub_step=1; continue; }
                case "$tz_choice" in
                    "Asia/Shanghai"*) timezone="Asia/Shanghai" ;;
                    "UTC"*) timezone="UTC" ;;
                    "America/New_York"*) timezone="America/New_York" ;;
                    "Europe/London"*) timezone="Europe/London" ;;
                    "手动输入"*)
                        res=0
                        input_box timezone "请输入自定义时区:" "$timezone" || res=$?
                        [ "$res" -eq 2 ] && { sub_step=2; continue 2; }
                        ;;
                esac
                sub_step=3
                ;;
            3)
                res=0
                local loc_choice=""
                menu_select loc_choice "语言环境" "请选择 Locale:" 1 \
                    "zh_CN.UTF-8 (中文简体)" \
                    "en_US.UTF-8 (English)" \
                    "手动输入自定义 Locale" || res=$?
                [ "$res" -eq 2 ] && { sub_step=2; continue; }
                case "$loc_choice" in
                    "zh_CN.UTF-8"*) locale="zh_CN.UTF-8" ;;
                    "en_US.UTF-8"*) locale="en_US.UTF-8" ;;
                    "手动输入"*)
                        res=0
                        input_box locale "请输入自定义 Locale:" "$locale" || res=$?
                        [ "$res" -eq 2 ] && continue
                        ;;
                esac
                sub_step=4
                ;;
            4)
                res=0
                input_box primary_dns "请输入首选 DNS 服务器:" "$primary_dns" || res=$?
                [ "$res" -eq 2 ] && { sub_step=3; continue; }
                sub_step=5
                ;;
            5)
                res=0
                input_box secondary_dns "请输入备用 DNS 服务器:" "$secondary_dns" || res=$?
                [ "$res" -eq 2 ] && { sub_step=4; continue; }
                sub_step=6
                ;;
        esac
    done

    export HOSTNAME="$hostname"
    export TIMEZONE="$timezone"
    export LOCALE="$locale"
    export PRIMARY_DNS="$primary_dns"
    export SECONDARY_DNS="$secondary_dns"

    return 0
}

# 配置用户设置
configure_user() {
    print_step "2/${WIZARD_TOTAL_STEPS}" "用户账户配置"
    echo -e "${DIM}创建非 root 管理用户，并配置登录机制 (输入 b 可返回)${NC}"

    local sub_step=1
    local username="${USERNAME:-appadmin}"
    local ssh_pubkey_auth="${SSH_PUBKEY_AUTH:-yes}"
    local ssh_pubkey="${SSH_PUBKEY:-}"
    local password_auth="${PASSWORD_AUTH:-no}"
    local user_password="${USER_PASSWORD:-}"
    local password_confirmation=""
    local res=0

    while [ "$sub_step" -ge 1 ] && [ "$sub_step" -le 3 ]; do
        case "$sub_step" in
            1)
                res=0
                input_box username "请输入普通用户名:" "$username" || res=$?
                [ "$res" -eq 2 ] && return 2
                sub_step=2
                ;;
            2)
                res=0
                local auth_choice=""
                menu_select auth_choice "SSH 认证模式" "请选择 SSH 登录验证机制:" 1 \
                    "使用 SSH 公钥认证 (推荐安全方案)" \
                    "使用密码认证 (不推荐)" \
                    "同时允许公钥与密码认证" || res=$?
                [ "$res" -eq 2 ] && { sub_step=1; continue; }
                case "$auth_choice" in
                    "使用 SSH 公钥认证"*)
                        ssh_pubkey_auth="yes"
                        password_auth="no"
                        user_password=""
                        ;;
                    "使用密码认证"*)
                        ssh_pubkey_auth="no"
                        password_auth="yes"
                        ;;
                    "同时允许"*)
                        ssh_pubkey_auth="yes"
                        password_auth="yes"
                        ;;
                esac
                sub_step=3
                ;;
            3)
                res=0
                if [ "$password_auth" = "yes" ]; then
                    while true; do
                        res=0
                        password_box user_password "请输入 ${username} 的 SSH 登录密码" || res=$?
                        [ "$res" -eq 2 ] && { sub_step=2; continue 2; }
                        if [ -z "$user_password" ]; then
                            echo -e "${RED}密码不能为空；选择密码认证时必须设置登录密码。${NC}"
                            continue
                        fi
                        res=0
                        password_box password_confirmation "请再次输入密码确认" || res=$?
                        [ "$res" -eq 2 ] && { sub_step=2; continue 2; }
                        if [ "$user_password" != "$password_confirmation" ]; then
                            echo -e "${RED}两次输入的密码不一致，请重试。${NC}"
                            continue
                        fi
                        break
                    done
                else
                    user_password=""
                fi
                if [ "$ssh_pubkey_auth" = "yes" ]; then
                    input_box ssh_pubkey "请输入 SSH 公钥 (留空则安装时自动生成密钥对):" "$ssh_pubkey" || res=$?
                    [ "$res" -eq 2 ] && { sub_step=2; continue; }
                else
                    ssh_pubkey=""
                fi
                sub_step=4
                ;;
        esac
    done

    export USERNAME="$username"
    export SSH_PUBKEY_AUTHENTICATION="$ssh_pubkey_auth"
    export SSH_PUBKEY="$ssh_pubkey"
    export PASSWORD_AUTH="$password_auth"
    export SSH_PUBKEY_AUTH="$ssh_pubkey_auth"
    export USER_PASSWORD="$user_password"

    return 0
}

# 配置SSH设置
configure_ssh() {
    print_step "4/${WIZARD_TOTAL_STEPS}" "SSH 加固配置"
    echo -e "${DIM}建议使用非 22 端口，并限制 root 密码登录 (输入 b 可返回)${NC}"

    local sub_step=1
    local ssh_port="${SSH_PORT:-24822}"
    local permit_root_login="${PERMIT_ROOT_LOGIN:-no}"
    local max_auth_tries="${SSH_MAX_AUTH_TRIES:-3}"
    local client_alive_interval="${SSH_CLIENT_ALIVE_INTERVAL:-300}"
    local client_alive_count_max="${SSH_CLIENT_ALIVE_COUNT_MAX:-2}"
    local login_grace_time="${SSH_LOGIN_GRACE_TIME:-60}"
    local res=0

    while [ "$sub_step" -ge 1 ] && [ "$sub_step" -le 6 ]; do
        case "$sub_step" in
            1)
                res=0
                input_box ssh_port "请输入 SSH 端口号 (1-65535):" "$ssh_port" || res=$?
                [ "$res" -eq 2 ] && return 2
                if ! validate_port "$ssh_port" 2>/dev/null; then
                    echo -e "${RED}端口号无效（必须在 1-65535 之间），请重试。${NC}"
                    continue
                fi
                sub_step=2
                ;;
            2)
                res=0
                local root_choice=""
                menu_select root_choice "Root 登录权限" "是否允许 root 用户通过 SSH 直接登录？" 1 \
                    "禁止 root 登录 (no) [推荐生产安全]" \
                    "允许 root 登录 (yes)" || res=$?
                [ "$res" -eq 2 ] && { sub_step=1; continue; }
                if [[ "$root_choice" =~ "允许" ]]; then
                    permit_root_login="yes"
                else
                    permit_root_login="no"
                fi
                sub_step=3
                ;;
            3)
                res=0
                input_box max_auth_tries "请输入最大认证尝试次数 (MaxAuthTries):" "$max_auth_tries" || res=$?
                [ "$res" -eq 2 ] && { sub_step=2; continue; }
                if ! validate_number "$max_auth_tries" 2>/dev/null; then
                    echo -e "${RED}请输入有效数字。${NC}"
                    continue
                fi
                sub_step=4
                ;;
            4)
                res=0
                input_box client_alive_interval "请输入客户端保活间隔 (ClientAliveInterval, 秒):" "$client_alive_interval" || res=$?
                [ "$res" -eq 2 ] && { sub_step=3; continue; }
                if ! validate_number "$client_alive_interval" 2>/dev/null; then
                    echo -e "${RED}请输入有效数字。${NC}"
                    continue
                fi
                sub_step=5
                ;;
            5)
                res=0
                input_box client_alive_count_max "请输入保活探测最大次数 (ClientAliveCountMax):" "$client_alive_count_max" || res=$?
                [ "$res" -eq 2 ] && { sub_step=4; continue; }
                if ! validate_number "$client_alive_count_max" 2>/dev/null; then
                    echo -e "${RED}请输入有效数字。${NC}"
                    continue
                fi
                sub_step=6
                ;;
            6)
                res=0
                input_box login_grace_time "请输入登录宽限时间 (LoginGraceTime, 秒):" "$login_grace_time" || res=$?
                [ "$res" -eq 2 ] && { sub_step=5; continue; }
                if ! validate_number "$login_grace_time" 2>/dev/null; then
                    echo -e "${RED}请输入有效数字。${NC}"
                    continue
                fi
                sub_step=7
                ;;
        esac
    done

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
    print_step "5/${WIZARD_TOTAL_STEPS}" "安全组件配置"
    echo -e "${DIM}Fail2ban / 审计系统 / 强制访问控制策略 (输入 b 可返回)${NC}"

    local sub_step=1
    local install_fail2ban="${INSTALL_FAIL2BAN:-true}"
    local install_auditd="${INSTALL_AUDITD:-false}"
    local enable_selinux_check="${ENABLE_SELINUX_CHECK:-true}"
    local res=0

    while [ "$sub_step" -ge 1 ] && [ "$sub_step" -le 3 ]; do
        case "$sub_step" in
            1)
                res=0
                local fb_default="y"
                [ "$install_fail2ban" = "false" ] && fb_default="n"
                yesno_box "Fail2ban 防爆破" "是否安装配置 Fail2ban 防暴力破解工具？" "$fb_default" || res=$?
                [ "$res" -eq 2 ] && return 2
                [ "$res" -eq 0 ] && install_fail2ban="true" || install_fail2ban="false"
                sub_step=2
                ;;
            2)
                res=0
                local ad_default="n"
                [ "$install_auditd" = "true" ] && ad_default="y"
                yesno_box "auditd 审计" "是否安装并启用 auditd 系统审计框架？" "$ad_default" || res=$?
                [ "$res" -eq 2 ] && { sub_step=1; continue; }
                [ "$res" -eq 0 ] && install_auditd="true" || install_auditd="false"
                sub_step=3
                ;;
            3)
                res=0
                local mac_default="y"
                [ "$enable_selinux_check" = "false" ] && mac_default="n"
                yesno_box "MAC 策略检查" "是否检查并配置 SELinux / AppArmor 安全策略？" "$mac_default" || res=$?
                [ "$res" -eq 2 ] && { sub_step=2; continue; }
                [ "$res" -eq 0 ] && enable_selinux_check="true" || enable_selinux_check="false"
                sub_step=4
                ;;
        esac
    done

    export INSTALL_FAIL2BAN="$install_fail2ban"
    export INSTALL_AUDITD="$install_auditd"
    export ENABLE_SELINUX_CHECK="$enable_selinux_check"

    return 0
}

# 配置服务设置
configure_services() {
    print_step "6/${WIZARD_TOTAL_STEPS}" "可选服务配置"
    echo -e "${DIM}Docker / Node.js(npm) 基础运行时环境 (输入 b 可返回)${NC}"

    local sub_step=1
    local install_docker="${INSTALL_DOCKER:-true}"
    local install_npm="${INSTALL_NPM:-false}"
    local res=0

    while [ "$sub_step" -ge 1 ] && [ "$sub_step" -le 2 ]; do
        case "$sub_step" in
            1)
                res=0
                local dk_default="y"
                [ "$install_docker" = "false" ] && dk_default="n"
                yesno_box "Docker 引擎" "是否自动安装与配置 Docker 容器引擎？" "$dk_default" || res=$?
                [ "$res" -eq 2 ] && return 2
                [ "$res" -eq 0 ] && install_docker="true" || install_docker="false"
                sub_step=2
                ;;
            2)
                res=0
                local npm_default="n"
                [ "$install_npm" = "true" ] && npm_default="y"
                yesno_box "Node.js & npm" "是否安装 Node.js 与 npm 包管理器？" "$npm_default" || res=$?
                [ "$res" -eq 2 ] && { sub_step=1; continue; }
                [ "$res" -eq 0 ] && install_npm="true" || install_npm="false"
                sub_step=3
                ;;
        esac
    done

    export INSTALL_DOCKER="$install_docker"
    export INSTALL_NPM="$install_npm"

    return 0
}

# 配置备份和监控
configure_backup_monitoring() {
    print_step "7/${WIZARD_TOTAL_STEPS}" "备份与监控配置"
    echo -e "${DIM}系统定时备份、Node Exporter 监控组件 (输入 b 可返回)${NC}"

    local sub_step=1
    local enable_backup="${ENABLE_BACKUP:-false}"
    local enable_monitoring="${ENABLE_MONITORING:-false}"
    local res=0

    while [ "$sub_step" -ge 1 ] && [ "$sub_step" -le 2 ]; do
        case "$sub_step" in
            1)
                res=0
                local bk_default="n"
                [ "$enable_backup" = "true" ] && bk_default="y"
                yesno_box "定时备份" "是否配置自动化备份任务？" "$bk_default" || res=$?
                [ "$res" -eq 2 ] && return 2
                [ "$res" -eq 0 ] && enable_backup="true" || enable_backup="false"
                sub_step=2
                ;;
            2)
                res=0
                local mon_default="n"
                [ "$enable_monitoring" = "true" ] && mon_default="y"
                yesno_box "监控组件" "是否部署 Prometheus Node Exporter 系统监控组件？" "$mon_default" || res=$?
                [ "$res" -eq 2 ] && { sub_step=1; continue; }
                if [ "$res" -eq 0 ]; then
                    enable_monitoring="true"
                    export INSTALL_NODE_EXPORTER="true"
                else
                    enable_monitoring="false"
                    export INSTALL_NODE_EXPORTER="false"
                fi
                sub_step=3
                ;;
        esac
    done

    export ENABLE_BACKUP="$enable_backup"
    export ENABLE_MONITORING="$enable_monitoring"

    return 0
}

# 配置系统清洗和优化
configure_cleanup() {
    print_step "3/${WIZARD_TOTAL_STEPS}" "系统清理与优化"
    echo -e "${DIM}Swap 交换空间 / Snap / 软件包缓存 / 日志限制 (输入 b 可返回)${NC}"

    local sub_step=1
    local enable_swap="${ENABLE_SWAP:-true}"
    local swap_size="${SWAP_SIZE:-}"
    local swap_file="${SWAP_FILE:-/swapfile}"
    local swappiness="${SWAPPINESS:-10}"
    local vfs_cache_pressure="${VFS_CACHE_PRESSURE:-50}"
    local remove_snap="${REMOVE_SNAP:-false}"
    local clean_pkg_cache="${CLEAN_PKG_CACHE:-true}"
    local clean_journal="${CLEAN_JOURNAL:-true}"
    local disable_services="${DISABLE_SERVICES:-false}"
    local clean_temp="${CLEAN_TEMP:-true}"
    local res=0

    while [ "$sub_step" -ge 1 ] && [ "$sub_step" -le 10 ]; do
        case "$sub_step" in
            1)
                res=0
                local sw_default="y"
                [ "$enable_swap" = "false" ] && sw_default="n"
                yesno_box "Swap 交换空间" "是否自动分配与配置 Swap 交换分区？(内存 ≤2G 推荐)" "$sw_default" || res=$?
                [ "$res" -eq 2 ] && return 2
                [ "$res" -eq 0 ] && enable_swap="true" || enable_swap="false"
                sub_step=2
                ;;
            2)
                # 仅当启用 swap 时才询问大小/路径/参数
                if [ "$enable_swap" = "true" ]; then
                    res=0
                    input_box swap_size "请输入 Swap 大小 (如 2G, 4G, 8G，留空自动按内存计算):" "$swap_size" || res=$?
                    [ "$res" -eq 2 ] && { sub_step=1; continue; }
                    if [ -n "$swap_size" ] && [[ ! "$swap_size" =~ ^[1-9][0-9]*[KMG]$ ]]; then
                        echo -e "${RED}Swap 大小必须使用正整数加 K/M/G 单位，例如 2G；留空表示自动计算${NC}"
                        continue
                    fi
                    sub_step=3
                else
                    sub_step=6
                fi
                ;;
            3)
                if [ "$enable_swap" = "true" ]; then
                    res=0
                    input_box swap_file "请输入 Swap 文件路径:" "$swap_file" || res=$?
                    [ "$res" -eq 2 ] && { sub_step=2; continue; }
                    sub_step=4
                else
                    sub_step=6
                fi
                ;;
            4)
                if [ "$enable_swap" = "true" ]; then
                    res=0
                    input_box swappiness "请输入 swappiness 值 (0-100，越小越少用 swap，推荐 10):" "$swappiness" || res=$?
                    [ "$res" -eq 2 ] && { sub_step=3; continue; }
                    if ! validate_number "$swappiness" 2>/dev/null || [ "$swappiness" -lt 0 ] || [ "$swappiness" -gt 100 ]; then
                        echo -e "${RED}swappiness 必须为 0-100 之间的数字${NC}"
                        continue
                    fi
                    sub_step=5
                else
                    sub_step=6
                fi
                ;;
            5)
                if [ "$enable_swap" = "true" ]; then
                    res=0
                    input_box vfs_cache_pressure "请输入 vfs_cache_pressure 值 (0-1000，推荐 50):" "$vfs_cache_pressure" || res=$?
                    [ "$res" -eq 2 ] && { sub_step=4; continue; }
                    if ! validate_number "$vfs_cache_pressure" 2>/dev/null || [ "$vfs_cache_pressure" -lt 0 ] || [ "$vfs_cache_pressure" -gt 1000 ]; then
                        echo -e "${RED}vfs_cache_pressure 必须为 0-1000 之间的数字${NC}"
                        continue
                    fi
                    sub_step=6
                else
                    sub_step=6
                fi
                ;;
            6)
                res=0
                local snap_default="n"
                [ "$remove_snap" = "true" ] && snap_default="y"
                yesno_box "Snap 卸载" "是否彻底卸载 Snap 软件包管理器？(仅 Ubuntu 有效)" "$snap_default" || res=$?
                if [ "$res" -eq 2 ]; then
                    if [ "$enable_swap" = "true" ]; then
                        sub_step=5
                    else
                        sub_step=1
                    fi
                    continue
                fi
                [ "$res" -eq 0 ] && remove_snap="true" || remove_snap="false"
                sub_step=7
                ;;
            7)
                res=0
                local pkg_default="y"
                [ "$clean_pkg_cache" = "false" ] && pkg_default="n"
                yesno_box "包缓存清理" "是否清理 APT/YUM 包管理器缓存并移除旧内核？" "$pkg_default" || res=$?
                [ "$res" -eq 2 ] && { sub_step=6; continue; }
                [ "$res" -eq 0 ] && clean_pkg_cache="true" || clean_pkg_cache="false"
                sub_step=8
                ;;
            8)
                res=0
                local jrn_default="y"
                [ "$clean_journal" = "false" ] && jrn_default="n"
                yesno_box "systemd 日志限制" "是否清理旧日志并将日志上限限制为 200MB/7天？" "$jrn_default" || res=$?
                [ "$res" -eq 2 ] && { sub_step=7; continue; }
                [ "$res" -eq 0 ] && clean_journal="true" || clean_journal="false"
                sub_step=9
                ;;
            9)
                res=0
                local ds_default="n"
                [ "$disable_services" = "true" ] && ds_default="y"
                yesno_box "无用服务禁用" "是否自动停用与禁用不必要的后台服务？" "$ds_default" || res=$?
                [ "$res" -eq 2 ] && { sub_step=8; continue; }
                [ "$res" -eq 0 ] && disable_services="true" || disable_services="false"
                sub_step=10
                ;;
            10)
                res=0
                local tmp_default="y"
                [ "$clean_temp" = "false" ] && tmp_default="n"
                yesno_box "临时文件清理" "是否清理 /tmp 临时文件及系统临时日志？" "$tmp_default" || res=$?
                [ "$res" -eq 2 ] && { sub_step=9; continue; }
                [ "$res" -eq 0 ] && clean_temp="true" || clean_temp="false"
                sub_step=11
                ;;
        esac
    done

    export ENABLE_SWAP="$enable_swap"
    export SWAP_SIZE="$swap_size"
    export SWAP_FILE="$swap_file"
    export SWAPPINESS="$swappiness"
    export VFS_CACHE_PRESSURE="$vfs_cache_pressure"
    export REMOVE_SNAP="$remove_snap"
    export CLEAN_PKG_CACHE="$clean_pkg_cache"
    export CLEAN_JOURNAL="$clean_journal"
    export DISABLE_SERVICES="$disable_services"
    export CLEAN_TEMP="$clean_temp"

    return 0
}

# 主配置向导
run_configuration_wizard() {
    local current_step=1
    local total_steps="${WIZARD_TOTAL_STEPS:-7}"

    print_section "欢迎使用 VPS 一键装机配置向导"
    echo -e "本向导将分 ${total_steps} 步收集系统配置。"
    echo -e "提示：直接回车 = 选择 [默认值]；输入 'b' 或 'back' 可随时返回上一步。"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"

    while [ "$current_step" -ge 1 ] && [ "$current_step" -le "$total_steps" ]; do
        local res=0
        case "$current_step" in
            1) configure_system || res=$? ;;
            2) configure_user || res=$? ;;
            3) configure_cleanup || res=$? ;;
            4) configure_ssh || res=$? ;;
            5) configure_security || res=$? ;;
            6) configure_services || res=$? ;;
            7) configure_backup_monitoring || res=$? ;;
        esac

        if [ "$res" -eq 2 ]; then
            if [ "$current_step" -gt 1 ]; then
                current_step=$((current_step - 1))
                echo -e "\n${YELLOW}<< 已返回上一步 (Step ${current_step})${NC}"
            else
                echo -e "\n${YELLOW}已处于第一步开头，返回主菜单。${NC}"
                return 2
            fi
        elif [ "$res" -ne 0 ]; then
            msg_box "错误" "配置向导提前结束。"
            return 1
        else
            current_step=$((current_step + 1))
        fi
    done

    print_section "配置采集完成"
    echo -e "所有 ${total_steps} 个步骤已完成！系统已更新配置。"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    return 0
}

# 模块化分项配置子菜单
configure_by_sections() {
    while true; do
        print_section "模块化分项配置菜单"
        echo -e "请选择需要单独配置或修改的项目:"
        echo -e "  1) 系统基础配置 (Step 1: Hostname / Timezone / DNS)"
        echo -e "  2) 用户账户配置 (Step 2: Username / SSH Key / Password)"
        echo -e "  3) 清理与优化配置 (Step 3: Swap / Snap / Cache / Journal)"
        echo -e "  4) SSH 加固配置 (Step 4: SSH Port / Root Login)"
        echo -e "  5) 安全组件配置 (Step 5: Fail2ban / Auditd / MAC)"
        echo -e "  6) 可选服务配置 (Step 6: Docker / Node.js & NPM)"
        echo -e "  7) 备份与监控配置 (Step 7: Backup / Node Exporter)"
        echo -e "  0) 返回主菜单"
        echo -e "${GREEN}═══════════════════════════════════════════${NC}"

        local choice
        read -r -p "请选择 [0-7] (默认: 0): " choice
        choice="${choice:-0}"

        local res=0
        case "$choice" in
            1) configure_system || res=$? ;;
            2) configure_user || res=$? ;;
            3) configure_cleanup || res=$? ;;
            4) configure_ssh || res=$? ;;
            5) configure_security || res=$? ;;
            6) configure_services || res=$? ;;
            7) configure_backup_monitoring || res=$? ;;
            0|b|back) break ;;
            *) echo -e "${RED}无效选项，请输入 0-7${NC}" ;;
        esac

        if [ "$res" -eq 2 ]; then
            echo -e "\n${YELLOW}<< 已取消当前模块修改，返回分项配置菜单。${NC}"
        fi

        # 保存变更
        # shellcheck disable=SC2046
        save_config "$CONFIG_FILE" $(get_config_var_names)
    done
}

# 交互式主菜单
show_main_menu() {
    while true; do
        print_section "VPS 一键装机 v${VPS_TOOL_VERSION} — 主菜单"
        echo -e "请选择需要执行的操作:"
        echo -e "  1) 完整向导配置 (Guided Setup Wizard) [默认推荐]"
        echo -e "  2) 模块化分项配置 (Configure by Section)"
        echo -e "  3) 预览当前配置 (Review Configuration)"
        echo -e "  4) 加载 / 重置配置文件 (Manage Config File)"
        echo -e "  5) 开始执行安装 (Start Installation)"
        echo -e "  6) 查看模块执行状态 (Check Module Status)"
        echo -e "  0) 退出程序 (Exit)"
        echo -e "${GREEN}═══════════════════════════════════════════${NC}"

        local choice
        read -r -p "请选择 [0-6] (默认: 1): " choice
        choice="${choice:-1}"

        case "$choice" in
            1)
                local wizard_res=0
                run_configuration_wizard || wizard_res=$?
                if [ "$wizard_res" -eq 0 ]; then
                    # shellcheck disable=SC2046
                    save_config "$CONFIG_FILE" $(get_config_var_names)
                    log_info "向导配置已保存至 $CONFIG_FILE"
                elif [ "$wizard_res" -eq 2 ]; then
                    echo -e "\n${YELLOW}<< 已取消完整向导，返回主菜单。${NC}"
                fi
                ;;
            2)
                configure_by_sections
                ;;
            3)
                print_review_card "${#MODULES[@]}"
                ;;
            4)
                if [ -f "$CONFIG_FILE" ]; then
                    load_config "$CONFIG_FILE"
                    apply_config_defaults
                    log_info "已重新加载配置文件: $CONFIG_FILE"
                else
                    apply_config_defaults
                    log_info "无已有配置文件，已应用默认配置。"
                fi
                ;;
            5)
                # 跳出主菜单，继续执行安装
                return 0
                ;;
            6)
                print_status_table MODULES
                ;;
            0|q|exit)
                log_info "用户退出系统。"
                exit 0
                ;;
            *)
                echo -e "${RED}请输入有效的数字选项 [0-6]${NC}"
                ;;
        esac
    done
}
confirm_configuration_review() {
    local modules_count="$1"
    print_review_card "${modules_count}"

    if [ "$NON_INTERACTIVE" = true ] || [ "$AUTO_YES" = true ]; then
        log_info "非交互/自动模式：跳过 Review 确认，继续安装。"
        return 0
    fi

    local answer
    while true; do
        read -rp "确认开始安装？[Y=开始 / n=取消]: " answer
        answer="${answer:-Y}"
        case "$answer" in
            [Yy]|[Yy][eE][sS]) return 0 ;;
            [Nn]|[Nn][oO]) return 1 ;;
            *) echo "请输入 Y 或 n" ;;
        esac
    done
}

module_requires_runtime_check() {
    case "$1" in
        05_ssh|06_firewall|07_fail2ban) return 0 ;;
        *) return 1 ;;
    esac
}

validate_access_configuration() {
    local username="${USERNAME:-appadmin}"
    local password_enabled="${PASSWORD_AUTH:-no}"
    local pubkey_enabled="${SSH_PUBKEY_AUTHENTICATION:-${SSH_PUBKEY_AUTH:-no}}"
    local has_password=false
    local has_pubkey=false
    local authorized_keys=""

    if [ "$password_enabled" != "yes" ] && [ "$pubkey_enabled" != "yes" ]; then
        log_error "SSH authentication is disabled: enable password or public-key authentication"
        return 1
    fi

    if [ -n "${USER_PASSWORD:-}" ]; then
        has_password=true
    elif id "$username" >/dev/null 2>&1 && command -v passwd >/dev/null 2>&1 && \
         passwd -S "$username" 2>/dev/null | awk '$2 ~ /^P/ {found=1} END {exit !found}'; then
        has_password=true
    fi

    if id "$username" >/dev/null 2>&1; then
        authorized_keys="$(getent passwd "$username" | cut -d: -f6)/.ssh/authorized_keys"
        if [ -s "$authorized_keys" ] && grep -qE '^(ssh-|ecdsa-sha2-)' "$authorized_keys"; then
            has_pubkey=true
        fi
    elif [ -n "${SSH_PUBKEY:-}" ] && echo "$SSH_PUBKEY" | grep -qE '^(ssh-|ecdsa-sha2-)'; then
        has_pubkey=true
    fi

    if [ "$password_enabled" = "yes" ] && [ "$has_password" != "true" ]; then
        log_error "Password authentication is enabled, but $username has no usable password"
        log_error "Set it with: sudo passwd $username, then rerun the setup"
        return 1
    fi
    if [ "$pubkey_enabled" = "yes" ] && [ "$has_pubkey" != "true" ] && [ "$password_enabled" != "yes" ]; then
        log_error "Public-key authentication is enabled, but no authorized SSH public key is available"
        return 1
    fi
    if [ "$has_password" != "true" ] && [ "$has_pubkey" != "true" ]; then
        log_error "No usable SSH authentication method is available for $username"
        return 1
    fi
    return 0
}

# ===== 主程序 =====

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            print_header "VPS 一键装机 v${VPS_TOOL_VERSION}"
            cat <<EOF
用法: $0 [选项]

选项:
  -h, --help              显示此帮助信息
  -n, --non-interactive   非交互模式（使用现有配置或默认值）
  -a, --auto              自动模式（非交互 + 跳过确认提示）
  -d, --dry-run           试运行（仅显示将要执行的操作，不实际执行）
  -f, --force             强制重新执行已完成的模块
  --modules <list>        仅执行指定模块，逗号分隔 (例如: 01_hostname,05_ssh)
  --rollback              回滚已完成的更改（恢复备份的配置文件）
  --status                显示各模块的执行状态

示例:
  sudo $0                 # 交互式向导
  sudo $0 -n -d           # 非交互试运行
  sudo $0 -a              # 全自动默认配置安装
  sudo $0 --status        # 查看模块状态
EOF
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
            AUTO_YES=true
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

FORCE="$FORCE_MODE"
export FORCE

# 初始化系统探测与启动横幅
MODE_LABEL="交互式配置向导"
if [ "$ACTION" = "status" ]; then
    MODE_LABEL="状态查询"
elif [ "$ACTION" = "rollback" ]; then
    MODE_LABEL="回滚"
elif [ "$DRY_RUN" = true ] && [ "$NON_INTERACTIVE" = true ]; then
    MODE_LABEL="非交互试运行"
elif [ "$DRY_RUN" = true ]; then
    MODE_LABEL="试运行"
elif [ "$AUTO_YES" = true ]; then
    MODE_LABEL="自动安装"
elif [ "$NON_INTERACTIVE" = true ]; then
    MODE_LABEL="非交互安装"
fi

init_system
print_startup_banner "$MODE_LABEL"

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

# 如果是交互模式，运行主菜单
if [ "$ACTION" = "install" ] && [ "$INTERACTIVE_MODE" = true ]; then
    show_main_menu
    # 保存全部已知配置键
    # shellcheck disable=SC2046
    save_config "$CONFIG_FILE" $(get_config_var_names)
    log_info "配置已保存到 $CONFIG_FILE"
fi

# 确保所有变量都有默认值
apply_config_defaults

# 打印配置摘要（调试用）
log_debug "=== 配置摘要 ==="
for var in $(get_config_var_names); do
    log_debug "$var=${!var:-}"
done
log_debug "=================="

# 根据操作执行相应任务
case "$ACTION" in
    status)
        print_status_table MODULES
        exit 0
        ;;
    rollback)
        log_info "开始回滚操作..."
        msg_box "回滚" "回滚功能尚未完全实现。\n请手动从备份目录恢复文件:\n${BACKUPS_DIR}"
        exit 0
        ;;
    install)
        :
        ;;
    *)
        echo "未知操作: $ACTION"
        exit 1
        ;;
esac

# 确定要运行的模块列表
if [ ${#SELECTED_MODULES[@]} -eq 0 ]; then
    MODULES_TO_RUN=("${MODULES[@]}")
else
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

if [ ${#MODULES_TO_RUN[@]} -eq 0 ]; then
    log_error "没有指定要运行的模块。"
    exit 1
fi

# 安装前 Review
# A complete run can create the user in 04_user. SSH-only runs must already
# have a usable credential, while dry-run remains a no-change preview.
requires_existing_access=false
for module in "${MODULES_TO_RUN[@]}"; do
    case "${module%%:*}" in
        05_ssh|06_firewall|07_fail2ban)
            requires_existing_access=true
            ;;
        04_user)
            requires_existing_access=false
            break
            ;;
    esac
done
if [ "$DRY_RUN" != "true" ] && [ "$requires_existing_access" = "true" ] && \
   ! validate_access_configuration; then
    log_error "安全检查失败，未执行任何模块以避免锁死 SSH 访问"
    exit 1
fi

if ! confirm_configuration_review "${#MODULES_TO_RUN[@]}"; then
    log_warn "用户取消安装。"
    exit 1
fi

# 配置确认后执行模块时复用向导结果，避免模块再次询问已确认的参数
NON_INTERACTIVE=true
INTERACTIVE_MODE=false

# 记录开始时间与结果计数
START_TIME=$(date +%s)
MODULE_TOTAL=${#MODULES_TO_RUN[@]}
MODULE_INDEX=0
DONE_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
MODULE_SUMMARY_LINES=""

print_section "开始执行模块"
echo -e "共 ${MODULE_TOTAL} 个模块；失败将标记后继续。"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"

# 按顺序执行每个模块
for module in "${MODULES_TO_RUN[@]}"; do
    name="${module%%:*}"
    desc="${module#*:}"
    MODULE_INDEX=$((MODULE_INDEX + 1))

    print_module_progress "$MODULE_INDEX" "$MODULE_TOTAL" "$name" "$desc"

    # 检查是否已经完成（除非强制模式）
     if [ "$FORCE_MODE" = false ] && [ "$(state_get "$name")" = "done" ] && \
         ! module_requires_runtime_check "$name"; then
        print_module_result "skipped" "$name" "已完成"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        MODULE_SUMMARY_LINES+="  ${YELLOW}~${NC} ${name}"$'\n'
        continue
    fi

    module_file="${MODULE_FILES[$name]}"
    if [ ! -f "$module_file" ]; then
        log_error "模块文件不存在: $module_file"
        state_set "$name" "failed"
        print_module_result "failed" "$name" "模块文件缺失"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        MODULE_SUMMARY_LINES+="  ${RED}✗${NC} ${name}"$'\n'
        continue
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "[试运行] 将执行模块: $module_file"
        print_module_result "skipped" "$name" "dry-run"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        MODULE_SUMMARY_LINES+="  ${YELLOW}~${NC} ${name} (dry-run)"$'\n'
        continue
    fi

    if ! source "$module_file"; then
        log_error "无法加载模块文件: $module_file"
        state_set "$name" "failed"
        print_module_result "failed" "$name" "加载失败"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        MODULE_SUMMARY_LINES+="  ${RED}✗${NC} ${name}"$'\n'
        continue
    fi

    # 定位模块函数前缀，例如 00_preflight -> preflight
    function_prefix="${name:3}"

    if declare -f "${function_prefix}_prerequisites" > /dev/null; then
        if ! "${function_prefix}_prerequisites"; then
            log_warn "模块 $name 的先决条件检查失败，跳过该模块。"
            state_set "$name" "skipped"
            print_module_result "skipped" "$name" "先决条件失败"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            MODULE_SUMMARY_LINES+="  ${YELLOW}~${NC} ${name}"$'\n'
            continue
        fi
    fi

    if declare -f "${function_prefix}_main" > /dev/null; then
        if "${function_prefix}_main"; then
            state_set "$name" "done"
            print_module_result "done" "$name"
            DONE_COUNT=$((DONE_COUNT + 1))
            MODULE_SUMMARY_LINES+="  ${GREEN}✓${NC} ${name}"$'\n'
        else
            state_set "$name" "failed"
            print_module_result "failed" "$name" "详见日志"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            MODULE_SUMMARY_LINES+="  ${RED}✗${NC} ${name}"$'\n'
        fi
    else
        log_warn "模块 $name 没有定义 _main 函数，跳过。"
        state_set "$name" "skipped"
        print_module_result "skipped" "$name" "无 _main"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        MODULE_SUMMARY_LINES+="  ${YELLOW}~${NC} ${name}"$'\n'
    fi
done

# 计算耗时
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

MODULE_SUMMARY_LINES+=$'\n'"  合计: ${GREEN}✓ ${DONE_COUNT}${NC}  ${RED}✗ ${FAILED_COUNT}${NC}  ${YELLOW}~ ${SKIPPED_COUNT}${NC}"

# 探测 IP 并写结果文件
SERVER_IP="$(detect_server_ip || true)"
if [ "$DRY_RUN" = false ]; then
    write_install_result "${INSTALL_RESULT_FILE}" "${SERVER_IP}" "${ELAPSED}"
fi

# 完成卡片
print_completion_card "${ELAPSED}" "${DRY_RUN}" "${SERVER_IP}" "${MODULE_SUMMARY_LINES}"

if [ "$FAILED_COUNT" -gt 0 ] && [ "$DRY_RUN" = false ]; then
    exit 1
fi

exit 0
