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

# --- 颜色定义（兼容非tty）---
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
    BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; BOLD=''; NC=''
fi

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
log_debug() { log "DEBUG" "$*"; echo -e "${BLUE}[DEBUG]${NC} $*"; }
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
    if [[ "${AUTO_YES}" == "true" ]]; then
        return 0
    fi
    if [[ "${default}" == "Y" ]]; then
        read -p "${prompt} (Y/n): " resp
        [[ -z "${resp}" || "${resp}" =~ ^[yY] ]] && return 0 || return 1
    else
        read -p "${prompt} (y/N): " resp
        [[ "${resp}" =~ ^[yY] ]] && return 0 || return 1
    fi
}

# prompt_with_default: 带默认值的输入
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    if [[ -n "${AUTO_ANSWERS[key]:-}" ]]; then
        echo "${AUTO_ANSWERS[key]}"
        return 0
    fi
    read -p "${prompt} (默认: ${default}): " resp
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

#===============================================================================
# 8. 令牌桶（用于状态展示/进度）
#===============================================================================

# print_header: 打印带边框的标题
print_header() {
    local text="$1"
    local width=60
    local pad=$(( (width - ${#text}) / 2 - 2 ))
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "${BLUE}  %*s%s%*s${NC}\n" ${pad} '' "${text}" ${pad} ''
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# print_step: 步骤提示
print_step() {
    local num="$1"; shift
    echo -e "\n${CYAN}[Step ${num}]${NC} ${BOLD}$*${NC}"
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
