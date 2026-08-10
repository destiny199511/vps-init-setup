#!/bin/bash
#===============================================================================
# VPS一键装机 — 核心函数库 (core.sh)
# 基于 du_setup / linux-ssh-init-sh / server_init_harden 最佳实践重构
# 功能: 颜色输出、日志、错误处理、系统检测、配置持久化、回滚、状态追踪、审计
#===============================================================================

# --- 严格模式 ---
# 注意: 不在此处设 set -euo pipefail，由各模块自行控制
# 但定义核心变量

# --- 版本 ---
VPS_TOOL_VERSION="2.0.0"

# --- 路径变量 ---
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${SCRIPT_ROOT}/config"
PROFILES_DIR="${SCRIPT_ROOT}/profiles"
LOGS_DIR="${SCRIPT_ROOT}/logs"
BACKUPS_DIR="${SCRIPT_ROOT}/backups"
MODULES_DIR="${SCRIPT_ROOT}/modules"
STATE_FILE="${CONFIG_DIR}/.state"

# 确保核心目录存在
mkdir -p "${CONFIG_DIR}" "${PROFILES_DIR}" "${LOGS_DIR}" "${BACKUPS_DIR}"

# --- 日志文件 ---
SESSION_ID="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOGS_DIR}/vps_setup_${SESSION_ID}.log"
AUDIT_LOG="${LOGS_DIR}/audit_${SESSION_ID}.log"
ROLLBACK_LOG="${LOGS_DIR}/rollback_${SESSION_ID}.log"

# --- 颜色定义（兼容非tty；FORCE_COLOR=1 可强制开启）---
if [[ -t 1 || "${FORCE_COLOR:-0}" == "1" ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
    BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# 自动确认（-a/--auto 时置 true）
: "${AUTO_YES:=false}"
INSTALL_RESULT_FILE="${CONFIG_DIR}/install-result.env"

#===============================================================================
# 1. 日志 & 输出
#===============================================================================

# log: 基础日志，写入文件 + 控制台
log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${level}] ${msg}" >> "${LOG_FILE}"
}

log_info()  { log "INFO" "$*"; echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { log "WARN" "$*"; echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { log "ERROR" "$*"; echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_debug() {
    log "DEBUG" "$*"
    if [[ "${DEBUG:-0}" == "1" || "${VERBOSE:-0}" == "1" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*"
    fi
}
log_ok()    { log "OK" "$*"; echo -e "${GREEN}[OK]${NC} $*"; }

# audit: 审计日志，记录所有操作供后续审查
audit() {
    local action_code="$1"; shift
    local detail="$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ${action_code} | ${detail}" >> "${AUDIT_LOG}"
}

#===============================================================================
# 2. 错误处理
#===============================================================================

# die: 致命错误，退出
die() {
    log_error "$*"
    audit "DIE" "$*"
    exit 1
}

# warn_continue: 警告后继续
warn_continue() {
    log_warn "$*"
    audit "WARN" "$*"
}

# require_root: 必须root运行
require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "此操作必须以root用户运行"
    fi
}

# require_non_root: 需普通用户运行
require_non_root() {
    if [[ $EUID -eq 0 ]]; then
        die "此操作不应以root用户运行"
    fi
}

#===============================================================================
# 3. 系统检测
#===============================================================================

OS_ID=""; OS_VERSION_ID=""; OS_NAME=""; OS_PRETTY=""
PKG_MGR=""; PKG_UPDATE=""; PKG_INSTALL=""; PKG_REMOVE=""
SVC_MGR="systemctl"
ARCH=""

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION_ID="${VERSION_ID}"
        OS_NAME="${NAME}"
        OS_PRETTY="${PRETTY_NAME}"
    elif [[ -f /etc/lsb-release ]]; then
        . /etc/lsb-release
        OS_ID="${DISTRIB_ID,,}"
        OS_VERSION_ID="${DISTRIB_RELEASE}"
        OS_NAME="${DISTRIB_DESCRIPTION}"
    else
        OS_ID="unknown"
        OS_VERSION_ID="0"
        OS_NAME="Unknown Linux"
    fi
    OS_PRETTY="${OS_PRETTY:-${OS_NAME} ${OS_VERSION_ID}}"
    ARCH="$(uname -m)"
    log_info "系统检测: ${OS_PRETTY} | ${ARCH}"
}

# detect_os_id: 返回标准化 OS ID，供命令替换使用，避免捕获日志文本
detect_os_id() {
    detect_os >/dev/null
    printf '%s\n' "${OS_ID}"
}

detect_pkg_manager() {
    if   command -v apt-get &>/dev/null; then
        PKG_MGR="apt"; PKG_UPDATE="apt-get update -qq"
        PKG_INSTALL="apt-get install -y -qq"
        PKG_REMOVE="apt-get remove -y -qq"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"; PKG_UPDATE="dnf check-update -q || true"
        PKG_INSTALL="dnf install -y -q"
        PKG_REMOVE="dnf remove -y -q"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"; PKG_UPDATE="yum check-update -q || true"
        PKG_INSTALL="yum install -y -q"
        PKG_REMOVE="yum remove -y -q"
    elif command -v zypper &>/dev/null; then
        PKG_MGR="zypper"; PKG_UPDATE="zypper refresh"
        PKG_INSTALL="zypper install -y"
        PKG_REMOVE="zypper remove -y"
    elif command -v pacman &>/dev/null; then
        PKG_MGR="pacman"
        PKG_UPDATE="pacman -Sy"
        PKG_INSTALL="pacman -S --noconfirm"
        PKG_REMOVE="pacman -Rs --noconfirm"
    elif command -v apk &>/dev/null; then
        PKG_MGR="apk"; PKG_UPDATE="apk update"
        PKG_INSTALL="apk add"
        PKG_REMOVE="apk del"
    else
        die "不支持的包管理器"
    fi
    log_info "包管理器: ${PKG_MGR}"
}

detect_service_manager() {
    if command -v systemctl &>/dev/null; then
        SVC_MGR="systemctl"
    elif command -v service &>/dev/null; then
        SVC_MGR="service"
    elif command -v rc-service &>/dev/null; then
        SVC_MGR="rc-service"
    else
        SVC_MGR="auto"
    fi
    log_info "服务管理器: ${SVC_MGR}"
}

# 兼容模块使用的旧检测接口
detect_package_manager() {
    [ -n "${PKG_MGR:-}" ] || detect_pkg_manager >/dev/null
    printf '%s\n' "${PKG_MGR}"
}

detect_init_system() {
    case "${SVC_MGR:-auto}" in
        systemctl) printf '%s\n' "systemd" ;;
        service) printf '%s\n' "sysvinit" ;;
        rc-service) printf '%s\n' "openrc" ;;
        *) printf '%s\n' "${SVC_MGR:-auto}" ;;
    esac
}

detect_environment() {
    # 检测是否为容器
    if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc\|container' /proc/1/cgroup 2>/dev/null; then
        echo "container"
    # 检测云平台
    elif dmidecode -s system-manufacturer 2>/dev/null | grep -qiE 'oracle|amazon|google|microsoft|vmware|qemu'; then
        echo "cloud"
    elif systemd-detect-virt --vm 2>/dev/null; then
        echo "vm"
    else
        echo "baremetal"
    fi
}

# install_pkg: 跨发行版安装软件包
install_pkg() {
    local pkg="$1"
    log_info "安装软件包: ${pkg}"
    if [[ "${PKG_UPDATE}" ]]; then
        eval "${PKG_UPDATE}" || true
    fi
    eval "${PKG_INSTALL} ${pkg}" || die "软件包安装失败: ${pkg}"
    audit "PKG_INSTALL" "${pkg}"
}

# 兼容模块使用的旧安装接口
install_package() {
    local package_name
    for package_name in "$@"; do
        install_pkg "$package_name"
    done
}

apt_update() {
    if [[ -n "${PKG_UPDATE:-}" ]]; then
        eval "${PKG_UPDATE}"
    fi
}

# remove_pkg: 跨发行版卸载软件包
remove_pkg() {
    local pkg="$1"
    log_info "卸载软件包: ${pkg}"
    eval "${PKG_REMOVE} ${pkg}" || true
    audit "PKG_REMOVE" "${pkg}"
}

# command_exists: 命令是否存在
command_exists() {
    command -v "$1" &>/dev/null
}

# service_active: 服务是否活跃
service_active() {
    if [[ "${SVC_MGR}" == "systemctl" ]]; then
        systemctl is-active --quiet "$1" 2>/dev/null
    elif [[ "${SVC_MGR}" == "service" ]]; then
        service "$1" status &>/dev/null
    else
        return 1
    fi
}

# service_enable: 启用/启动服务
service_enable_start() {
    local svc="$1"
    if [[ "${SVC_MGR}" == "systemctl" ]]; then
        systemctl enable --now "${svc}" 2>/dev/null || \
        systemctl start "${svc}" 2>/dev/null
    elif [[ "${SVC_MGR}" == "service" ]]; then
        update-rc.d "${svc}" defaults 2>/dev/null || true
        service "${svc}" start 2>/dev/null
    fi
}

# service_restart: 重启服务
service_restart() {
    local svc="$1"
    if [[ "${SVC_MGR}" == "systemctl" ]]; then
        systemctl restart "${svc}" 2>/dev/null
    elif [[ "${SVC_MGR}" == "service" ]]; then
        service "${svc}" restart 2>/dev/null
    fi
}

#===============================================================================
# 4. 备份 & 回滚
#===============================================================================

BACKUP_REGISTRY="${BACKUPS_DIR}/registry.txt"

# backup_file: 备份文件
backup_file() {
    local src="$1"
    if [[ ! -f "${src}" ]]; then
        return 0
    fi
    local ts="$(date +%Y%m%d_%H%M%S)"
    local dest="${BACKUPS_DIR}/$(echo "${src}" | tr '/' '_')_${ts}"
    cp -a "${src}" "${dest}"
    echo "${src}|${dest}" >> "${BACKUP_REGISTRY}"
    log_debug "已备份: ${src} → ${dest}"
}

# restore_file: 从最新备份恢复
restore_file() {
    local src="$1"
    if [[ ! -f "${BACKUP_REGISTRY}" ]]; then
        log_warn "无备份记录，无法恢复: ${src}"
        return 1
    fi
    local latest_backup
    latest_backup=$(grep "^${src}|" "${BACKUP_REGISTRY}" | tail -1 | cut -d'|' -f2)
    if [[ -n "${latest_backup}" && -f "${latest_backup}" ]]; then
        cp -a "${latest_backup}" "${src}"
        log_ok "已恢复: ${src} ← ${latest_backup}"
        audit "RESTORE" "${src} ← ${latest_backup}"
    else
        log_warn "未找到备份文件: ${src}"
        return 1
    fi
}

# rollback_all: 回滚当前会话所有修改
rollback_all() {
    log_warn "开始回滚所有更改..."
    audit "ROLLBACK_START" "用户触发回滚"
    if [[ ! -f "${BACKUP_REGISTRY}" ]]; then
        log_warn "无可回滚的操作"
        return 0
    fi
    local count=0
    while IFS='|' read -r src dest; do
        if [[ -f "${dest}" ]]; then
            cp -a "${dest}" "${src}" 2>/dev/null && count=$((count + 1))
        fi
    done < "${BACKUP_REGISTRY}"
    log_ok "回滚完成: 已恢复 ${count} 个文件"
    audit "ROLLBACK_DONE" "已恢复 ${count} 个文件"
}

#===============================================================================
# 5. 配置持久化
#===============================================================================

CONFIG_LOADED=false

# config_save: 保存配置到文件（可指定profile）
config_save() {
    local key="$1"
    local value="$2"
    local profile="${3:-default}"
    local profile_file="${PROFILES_DIR}/${profile}.conf"

    # 如果文件已存在且包含该key，更新；否则追加
    if [[ -f "${profile_file}" ]] && grep -q "^${key}=" "${profile_file}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${profile_file}"
    else
        echo "${key}=${value}" >> "${profile_file}"
    fi
    log_debug "配置保存 [${profile}]: ${key}=${value}"
}

# config_get: 读取配置
config_get() {
    local key="$1"
    local profile="${2:-default}"
    local profile_file="${PROFILES_DIR}/${profile}.conf"
    if [[ -f "${profile_file}" ]]; then
        grep "^${key}=" "${profile_file}" | tail -1 | cut -d'=' -f2-
    fi
}

# config_list_profiles: 列出所有profile
config_list_profiles() {
    ls -1 "${PROFILES_DIR}"/*.conf 2>/dev/null | while read -r f; do
        basename "${f}" .conf
    done
}

# config_export: 导出所有配置
config_export() {
    local profile="${1:-default}"
    local profile_file="${PROFILES_DIR}/${profile}.conf"
    if [[ -f "${profile_file}" ]]; then
        cat "${profile_file}"
    else
        log_warn "profile 不存在: ${profile}"
    fi
}

# confirm: 确认提示
confirm() {
    local prompt="$1"
    local default="${2:-N}"
    # -a/--auto: 全部自动确认
    if [[ "${AUTO_YES}" == "true" ]]; then
        return 0
    fi
    # 纯非交互：按默认值决定
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        [[ "${default}" == "Y" || "${default}" == "y" ]] && return 0 || return 1
    fi
    if [[ "${default}" == "Y" || "${default}" == "y" ]]; then
        read -r -p "${prompt} (Y/n): " resp
        [[ -z "${resp}" || "${resp}" =~ ^[yY] ]] && return 0 || return 1
    else
        read -r -p "${prompt} (y/N): " resp
        [[ "${resp}" =~ ^[yY] ]] && return 0 || return 1
    fi
}

# prompt_with_default: 带默认值的输入
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local auto_key="${3:-}"
    if [[ -n "${auto_key}" && -n "${AUTO_ANSWERS[${auto_key}]:-}" ]]; then
        echo "${AUTO_ANSWERS[${auto_key}]}"
        return 0
    fi
    if [[ "${NON_INTERACTIVE:-false}" == "true" || "${AUTO_YES}" == "true" ]]; then
        echo "${default}"
        return 0
    fi
    local resp
    read -r -p "${prompt} (默认: ${default}): " resp
    echo "${resp:-${default}}"
}

# prompt_choice: 选项选择
prompt_choice() {
    local prompt="$1"
    shift
    local choices=("$@")
    local auto_key="${FUNCNAME[1]}_choice"
    if [[ -n "${AUTO_ANSWERS[${auto_key}]:-}" ]]; then
        echo "${AUTO_ANSWERS[${auto_key}]}"
        return 0
    fi
    echo "${prompt}"
    for i in "${!choices[@]}"; do
        echo "  $((i+1))) ${choices[$i]}"
    done
    read -p "请选择 [1-${#choices[@]}]: " sel
    if [[ "${sel}" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#choices[@]} )); then
        echo "${sel}"
    else
        echo "1"
    fi
}

#===============================================================================
# 6. 状态追踪
#===============================================================================

# state_set: 记录模块完成状态
state_set() {
    local module="$1"
    local status="$2"  # done | skipped | failed
    local ts="$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ -f "${STATE_FILE}" ]] && grep -q "^${module}=" "${STATE_FILE}" 2>/dev/null; then
        sed -i "s|^${module}=.*|${module}=${status}|" "${STATE_FILE}"
    else
        echo "${module}=${status}" >> "${STATE_FILE}"
    fi
    log_debug "状态追踪 [${module}]: ${status}"
}

# state_mark: 兼容旧模块接口；completed 统一映射为 done
state_mark() {
    local module="$1"
    local status="$2"
    [ "$status" = "completed" ] && status="done"
    state_set "$module" "$status"
}

# state_get: 获取模块状态
state_get() {
    local module="$1"
    if [[ -f "${STATE_FILE}" ]]; then
        grep "^${module}=" "${STATE_FILE}" | tail -1 | cut -d'=' -f2
    fi
}

# state_is_done: 模块是否已完成
state_is_done() {
    [[ "$(state_get "$1")" == "done" ]]
}

# state_reset: 重置所有状态
state_reset() {
    > "${STATE_FILE}"
    log_info "状态已重置"
}

# state_show: 显示所有状态
state_show() {
    if [[ -f "${STATE_FILE}" ]]; then
        echo -e "${BOLD}模块执行状态:${NC}"
        while IFS='=' read -r module status; do
            case "${status}" in
                done)    echo -e "  ${GREEN}✓${NC} ${module}" ;;
                skipped) echo -e "  ${YELLOW}~${NC} ${module}" ;;
                failed)  echo -e "  ${RED}✗${NC} ${module}" ;;
                *)       echo -e "  ${BLUE}?${NC} ${module}: ${status}" ;;
            esac
        done < "${STATE_FILE}"
    else
        log_info "暂无状态记录"
    fi
}

#===============================================================================
# 7. 输入验证
#===============================================================================

# validate_hostname: 验证主机名格式
validate_hostname() {
    local name="$1"
    [[ "${name}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]]
}

# validate_port: 验证端口号
validate_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

# validate_ip: 验证IPv4地址
validate_ip() {
    local ip="$1"
    [[ "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && \
    local IFS='.'; set -- ${ip}
    (( $1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255 ))
}

# validate_email: 简单邮箱验证
validate_email() {
    local email="$1"
    [[ "${email}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# validate_number: 正整数验证
validate_number() {
    local value="$1"
    [[ "${value}" =~ ^[0-9]+$ ]]
}

#===============================================================================
# 8. 可视化展示（3x-ui 风格分区/步骤/完成卡片）
#===============================================================================

# format_duration: 秒 -> 可读耗时
format_duration() {
    local total="${1:-0}"
    local hours=$((total / 3600))
    local minutes=$(( (total % 3600) / 60 ))
    local seconds=$((total % 60))
    if (( hours > 0 )); then
        printf '%dh%02dm%02ds' "${hours}" "${minutes}" "${seconds}"
    elif (( minutes > 0 )); then
        printf '%dm%02ds' "${minutes}" "${seconds}"
    else
        printf '%ds' "${seconds}"
    fi
}

# print_separator: 分隔线
print_separator() {
    local char="${1:-═}"
    local width="${2:-43}"
    local line
    printf -v line '%*s' "${width}" ''
    line="${line// /${char}}"
    echo -e "${GREEN}${line}${NC}"
}

# print_header: 启动/大标题横幅
print_header() {
    local text="$1"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  ${text}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# print_section: 3x-ui 风格分区标题
print_section() {
    local title="$1"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN}     ${title}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
}

# print_step: 步骤提示（支持 3/7 形式）
print_step() {
    local num="$1"; shift
    echo -e "\n${CYAN}[Step ${num}]${NC} ${BOLD}$*${NC}"
}

# print_kv: 对齐的键值展示
print_kv() {
    local key="$1"
    local value="$2"
    local color="${3:-$GREEN}"
    printf "  ${color}%-14s${NC} %s\n" "${key}" "${value}"
}

# print_module_progress: 模块执行进度行
print_module_progress() {
    local index="$1"
    local total="$2"
    local name="$3"
    local desc="$4"
    echo ""
    echo -e "${CYAN}[Module ${index}/${total}]${NC} ${BOLD}${name}${NC} — ${desc}"
}

# print_module_result: 模块结果行
print_module_result() {
    local status="$1"
    local name="$2"
    local detail="${3:-}"
    case "${status}" in
        done|success|ok)
            echo -e "  ${GREEN}✓${NC} ${name} 完成${detail:+ — ${detail}}"
            ;;
        failed|error)
            echo -e "  ${RED}✗${NC} ${name} 失败${detail:+ — ${detail}}"
            ;;
        skipped)
            echo -e "  ${YELLOW}~${NC} ${name} 跳过${detail:+ — ${detail}}"
            ;;
        *)
            echo -e "  ${BLUE}?${NC} ${name}: ${status}${detail:+ — ${detail}}"
            ;;
    esac
}

# detect_server_ip: 尽力探测公网 IPv4（失败返回空）
detect_server_ip() {
    local ip_address http_code ip_result response
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://4.ident.me"
    )
    for ip_address in "${URL_lists[@]}"; do
        response="$(curl -s -w "\n%{http_code}" --max-time 2 "${ip_address}" 2>/dev/null || true)"
        http_code="$(echo "${response}" | tail -n1)"
        ip_result="$(echo "${response}" | sed '$d' | tr -d '[:space:]"')"
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "${ip_result}"
            return 0
        fi
    done
    hostname -I 2>/dev/null | awk '{print $1}'
}

# print_review_card: 安装前配置确认
print_review_card() {
    local modules_count="${1:-0}"
    print_section "配置确认 / Review"
    print_kv "主机名:" "${HOSTNAME:-}"
    print_kv "管理用户:" "${USERNAME:-}"
    print_kv "时区:" "${TIMEZONE:-}"
    print_kv "语言:" "${LOCALE:-}"
    print_kv "DNS:" "${PRIMARY_DNS:-} / ${SECONDARY_DNS:-}"
    print_kv "SSH 端口:" "${SSH_PORT:-}"
    print_kv "Root 登录:" "${PERMIT_ROOT_LOGIN:-}"
    print_kv "密码认证:" "${PASSWORD_AUTH:-}"
    print_kv "公钥认证:" "${SSH_PUBKEY_AUTH:-${SSH_PUBKEY_AUTHENTICATION:-}}"
    print_kv "Fail2ban:" "${INSTALL_FAIL2BAN:-}"
    print_kv "Docker:" "${INSTALL_DOCKER:-}"
    print_kv "NPM:" "${INSTALL_NPM:-}"
    print_kv "备份:" "${ENABLE_BACKUP:-}"
    print_kv "监控:" "${ENABLE_MONITORING:-${INSTALL_NODE_EXPORTER:-}}"
    print_kv "清理优化:" "swap=${ENABLE_SWAP:-} snap=${REMOVE_SNAP:-}"
    print_kv "将执行模块:" "${modules_count} 个"
    print_kv "配置文件:" "${CONFIG_FILE:-${CONFIG_DIR}/vps_config.conf}"
    print_kv "日志文件:" "${LOG_FILE}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "${YELLOW}⚠ 请确认以上配置；开始后将按模块顺序执行系统变更。${NC}"
}

# write_install_result: 落盘可 source 的安装结果（权限 600）
write_install_result() {
    local result_file="${1:-${INSTALL_RESULT_FILE}}"
    local server_ip="${2:-}"
    local elapsed="${3:-0}"
    local prev_umask
    prev_umask="$(umask)"
    umask 077
    mkdir -p "$(dirname "${result_file}")"
    {
        printf 'VPS_SETUP_VERSION=%q\n' "${VPS_TOOL_VERSION}"
        printf 'VPS_SETUP_USERNAME=%q\n' "${USERNAME:-}"
        printf 'VPS_SETUP_HOSTNAME=%q\n' "${HOSTNAME:-}"
        printf 'VPS_SETUP_SSH_PORT=%q\n' "${SSH_PORT:-}"
        printf 'VPS_SETUP_PERMIT_ROOT_LOGIN=%q\n' "${PERMIT_ROOT_LOGIN:-}"
        printf 'VPS_SETUP_PASSWORD_AUTH=%q\n' "${PASSWORD_AUTH:-}"
        printf 'VPS_SETUP_SERVER_IP=%q\n' "${server_ip}"
        printf 'VPS_SETUP_SSH_COMMAND=%q\n' "ssh -p ${SSH_PORT:-22} ${USERNAME:-root}@${server_ip:-SERVER_IP}"
        printf 'VPS_SETUP_LOG_FILE=%q\n' "${LOG_FILE}"
        printf 'VPS_SETUP_CONFIG_FILE=%q\n' "${CONFIG_FILE:-${CONFIG_DIR}/vps_config.conf}"
        printf 'VPS_SETUP_ELAPSED_SECONDS=%q\n' "${elapsed}"
        printf 'VPS_SETUP_INSTALL_DOCKER=%q\n' "${INSTALL_DOCKER:-}"
        printf 'VPS_SETUP_INSTALL_FAIL2BAN=%q\n' "${INSTALL_FAIL2BAN:-}"
        printf 'VPS_SETUP_ENABLE_BACKUP=%q\n' "${ENABLE_BACKUP:-}"
        printf 'VPS_SETUP_ENABLE_MONITORING=%q\n' "${ENABLE_MONITORING:-}"
    } > "${result_file}"
    umask "${prev_umask}"
    chmod 600 "${result_file}" 2>/dev/null || true
    log_ok "安装结果已写入 ${result_file}"
}

# print_completion_card: 安装完成信息卡片
print_completion_card() {
    local elapsed="${1:-0}"
    local dry_run="${2:-false}"
    local server_ip="${3:-}"
    local module_summary="${4:-}"
    local duration
    duration="$(format_duration "${elapsed}")"

    if [[ "${dry_run}" == "true" ]]; then
        print_section "试运行完成 / Dry-Run Complete"
    else
        print_section "安装完成 / Setup Complete"
    fi

    print_kv "耗时:" "${duration}"
    print_kv "主机名:" "${HOSTNAME:-}"
    print_kv "管理用户:" "${USERNAME:-}"
    print_kv "SSH 端口:" "${SSH_PORT:-}"
    print_kv "Root 登录:" "${PERMIT_ROOT_LOGIN:-}"
    print_kv "密码认证:" "${PASSWORD_AUTH:-}"
    if [[ -n "${server_ip}" ]]; then
        print_kv "服务器 IP:" "${server_ip}"
        print_kv "登录命令:" "ssh -p ${SSH_PORT:-22} ${USERNAME:-root}@${server_ip}"
    else
        print_kv "登录命令:" "ssh -p ${SSH_PORT:-22} ${USERNAME:-root}@SERVER_IP"
    fi
    print_kv "Fail2ban:" "${INSTALL_FAIL2BAN:-}"
    print_kv "Docker:" "${INSTALL_DOCKER:-}"
    print_kv "备份:" "${ENABLE_BACKUP:-}"
    print_kv "监控:" "${ENABLE_MONITORING:-}"
    print_kv "配置文件:" "${CONFIG_FILE:-${CONFIG_DIR}/vps_config.conf}"
    print_kv "结果文件:" "${INSTALL_RESULT_FILE}"
    print_kv "完整日志:" "${LOG_FILE}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"

    if [[ -n "${module_summary}" ]]; then
        echo -e "${BOLD}模块结果:${NC}"
        echo -e "${module_summary}"
        echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    fi

    if [[ "${dry_run}" != "true" ]]; then
        echo -e "${YELLOW}⚠ 请立即保存 SSH 端口与登录信息；更改端口后请先新开终端验证再断开当前会话。${NC}"
    fi

    echo -e "${BOLD}下一步 / 常用命令:${NC}"
    cat <<EOF
┌───────────────────────────────────────────────────────┐
│  sudo ./vps_setup.sh --status                         │
│  sudo ./vps_setup.sh -n --modules 05_ssh              │
│  sudo ./vps_setup.sh -d -n                            │
│  tail -f ${LOG_FILE}
└───────────────────────────────────────────────────────┘
EOF
}

# print_status_table: 美化模块状态表
print_status_table() {
    local -n _modules_ref=$1
    print_section "模块执行状态"
    local module name desc status icon color
    for module in "${_modules_ref[@]}"; do
        name="${module%%:*}"
        desc="${module#*:}"
        status="$(state_get "${name}")"
        if [[ -z "${status}" ]]; then
            status="pending"
        fi
        case "${status}" in
            done)    icon="✓"; color="${GREEN}" ;;
            skipped) icon="~"; color="${YELLOW}" ;;
            failed)  icon="✗"; color="${RED}" ;;
            pending|未运行) icon="·"; color="${DIM}"; status="未运行" ;;
            *)       icon="?"; color="${BLUE}" ;;
        esac
        printf "  ${color}%s${NC} %-18s %-36s [%s]\n" "${icon}" "${name}" "${desc}" "${status}"
    done
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
}

#===============================================================================
# 9. 初始化
#===============================================================================

init_system() {
    detect_os
    detect_pkg_manager
    detect_service_manager
    CONFIG_LOADED=true
    log_info "VPS一键装机 v${VPS_TOOL_VERSION} 已初始化"
    log_info "系统: ${OS_PRETTY} | 包管理: ${PKG_MGR} | 服务管理: ${SVC_MGR}"
}

# print_startup_banner: 启动页
print_startup_banner() {
    local mode_label="${1:-交互式配置向导}"
    print_header "VPS 一键装机 v${VPS_TOOL_VERSION}"
    print_kv "系统:" "${OS_PRETTY:-unknown} | ${ARCH:-$(uname -m)}"
    print_kv "包管理:" "${PKG_MGR:-unknown}"
    print_kv "服务管理:" "${SVC_MGR:-unknown}"
    print_kv "模式:" "${mode_label}"
    print_kv "日志:" "${LOG_FILE}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}
