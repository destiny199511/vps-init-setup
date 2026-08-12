# ===== CONFIGURATION MANAGEMENT =====
# List of configuration variables that should be persisted
# Format: VARIABLE_NAME "Description"
CONFIG_VARS="
USERNAME 'Username for the non-root user'
HOSTNAME 'System hostname'
TIMEZONE 'System timezone (e.g., Asia/Shanghai)'
LOCALE 'System locale (e.g., zh_CN.UTF-8)'
PRIMARY_DNS 'Primary DNS server (e.g., 1.1.1.1)'
SECONDARY_DNS 'Secondary DNS server (e.g., 8.8.8.8)'
SSH_PORT 'SSH port number'
SSH_KEEP_LEGACY_PORT 'Keep the previous SSH port open during migration (true/false)'
PERMIT_ROOT_LOGIN 'Allow root login via SSH (yes/no)'
PASSWORD_AUTH 'Allow password authentication via SSH (yes/no)'
SSH_PUBKEY_AUTHENTICATION 'Allow public key authentication via SSH (yes/no)'
SSH_PUBKEY_AUTH 'Whether SSH public key auth was chosen in wizard (yes/no)'
SSH_PUBKEY 'Optional SSH public key content'
USER_FULLNAME 'Full name for the non-root user'
USER_SHELL 'Login shell for the non-root user'
CREATE_HOME 'Whether to create the user home directory (true/false)'
ADD_TO_SUDO 'Whether to grant sudo access (true/false)'
SETUP_SSH 'Whether to configure user SSH access (true/false)'
SSH_PERMIT_EMPTY_PASSWORDS 'Allow empty passwords via SSH (yes/no)'
SSH_MAX_AUTH_TRIES 'Maximum authentication attempts'
SSH_MAX_SESSIONS 'Maximum multiplexed sessions'
SSH_CLIENT_ALIVE_INTERVAL 'Client alive interval (seconds)'
SSH_CLIENT_ALIVE_COUNT_MAX 'Client alive count max'
SSH_LOGIN_GRACE_TIME 'Login grace time (seconds)'
ALLOWED_PORTS 'Comma-separated list of additional ports to allow'
HTTP_PORT 'HTTP port number'
HTTPS_PORT 'HTTPS port number'
INSTALL_DOCKER 'Whether to install Docker (true/false)'
INSTALL_NPM 'Whether to install NPM (Node Package Manager) (true/false)'
DOCKER_INSTALL_METHOD 'Docker package-manager installation method'
DOCKER_CGROUP_DRIVER 'Docker cgroup driver'
DOCKER_LOG_DRIVER 'Docker log driver'
DOCKER_LOG_OPTS 'Docker log options'
DOCKER_INSECURE_REGISTRIES 'Comma-separated Docker insecure registries'
DOCKER_REGISTRY_MIRRORS 'Comma-separated Docker registry mirrors'
DOCKER_LIVE_RESTORE 'Whether to enable Docker live restore (true/false)'
DOMAIN 'Domain name for reverse proxy'
INSTALL_NODE_EXPORTER 'Whether to install node exporter (true/false)'
INSTALL_FAIL2BAN 'Whether to install Fail2ban (true/false)'
INSTALL_AUDITD 'Whether to install auditd (true/false)'
ENABLE_SELINUX_CHECK 'Whether to check SELinux/AppArmor (true/false)'
ENABLE_BACKUP 'Whether to enable backup system (true/false)'
BACKUP_SCHEDULE 'Five-field cron schedule for backups'
BACKUP_DIRECTORIES 'Space-separated absolute backup source directories'
BACKUP_RETENTION 'Backup retention in days'
BACKUP_COMPRESSION 'Backup compression (gzip/bzip2/xz/none)'
BACKUP_ENCRYPTION 'Whether to encrypt backups (true/false)'
BACKUP_GPG_RECIPIENT 'GPG recipient for encrypted backups'
BACKUP_DESTINATION 'Absolute local backup destination directory'
BACKUP_RUN_INITIAL 'Whether to run an initial backup (true/false)'
ENABLE_MONITORING 'Whether to enable monitoring tools (true/false)'
MONITORING_NETDATA_ENABLED 'Whether to install Netdata (true/false)'
MONITORING_PROMETHEUS_NODE_ENABLED 'Whether to install Node Exporter (true/false)'
BACKEND_STORAGE 'Backup backend storage (e.g., rclone://remote/backup)'
ENABLE_SWAP 'Whether to create swap (true/false)'
SWAP_SIZE 'Swap size (e.g., 2G, 4G, 8G)'
SWAP_FILE 'Swap file path (e.g., /swapfile)'
SWAPPINESS 'VM swappiness value (0-100)'
VFS_CACHE_PRESSURE 'VM vfs_cache_pressure value (0-1000)'
REMOVE_SNAP 'Whether to remove snap (true/false)'
CLEAN_PKG_CACHE 'Whether to clean package cache (true/false)'
CLEAN_JOURNAL 'Whether to clean journal logs (true/false)'
JOURNAL_MAX_SIZE 'Maximum journal storage size (e.g., 200M)'
DISABLE_SERVICES 'Whether to disable unused services (true/false)'
CLEAN_TEMP 'Whether to clean temporary files (true/false)'
OPTIMIZE_FSTAB 'Whether to review filesystem optimizations (true/false)'
"

# Get list of configuration variable names
get_config_var_names() {
    echo "$CONFIG_VARS" | grep -v "^$" | awk '{print $1}'
}

# Load configuration from file and environment variables
load_config() {
    local config_file="$1"
    local config_var_names config_owner config_mode key value line
    local loaded_count=0
    HOSTNAME_FROM_CONFIG="${HOSTNAME_FROM_CONFIG:-false}"

    # Configuration is data, not shell code. Do not source this file: it can be
    # preserved across root-run updates and must never execute commands.
    if [ -f "$config_file" ]; then
        if [ "${EUID:-$(id -u)}" -eq 0 ]; then
            config_owner="$(stat -c '%u' "$config_file" 2>/dev/null || true)"
            config_mode="$(stat -c '%a' "$config_file" 2>/dev/null || true)"
            if [ "$config_owner" != "0" ] || [ -z "$config_mode" ] || (( (8#$config_mode) & 022 )); then
                log_error "Refusing unsafe configuration file ownership or permissions: $config_file"
                return 1
            fi
        fi
        config_var_names=" $(get_config_var_names | tr '\n' ' ') "
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            case "$line" in
                ''|'#'*) continue ;;
            esac
            if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
                log_warn "Ignoring malformed configuration line in $config_file"
                continue
            fi
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # Support the legacy %q form used by releases before v2.1 for
            # space-containing data such as SSH public keys. This is decoding,
            # never evaluation.
            value="${value//\\ / }"
            value="${value//\\\\/\\}"
            case "$config_var_names" in
                *" $key "*) ;;
                *)
                    log_warn "Ignoring unsupported configuration key: $key"
                    continue
                    ;;
            esac
            export "$key=$value"
            loaded_count=$((loaded_count + 1))
            if [ "$key" = "HOSTNAME" ]; then
                HOSTNAME_FROM_CONFIG=true
            fi
        done < "$config_file"
        log_info "Loaded $loaded_count configuration value(s) from $config_file"
    fi

    # Override with environment variables (VPS_SETUP_ prefix)
    for var in $(get_config_var_names); do
        env_var="VPS_SETUP_$var"
        if [ -n "${!env_var:-}" ]; then
            export "$var"="${!env_var}"
            if [ "$var" = "HOSTNAME" ]; then
                HOSTNAME_FROM_CONFIG=true
            fi
            log_debug "Overrode $var with environment variable $env_var"
        fi
    done
    export HOSTNAME_FROM_CONFIG
}

# Save current configuration to file
save_config() {
    local config_file="$1"
    local config_dir config_tmp
    shift
    
    # If no variables specified, save all configured variables
    if [ $# -eq 0 ]; then
        set -- $(get_config_var_names)
    fi
    
    config_dir="$(dirname "$config_file")"
    mkdir -p "$config_dir"
    if [ -L "$config_file" ]; then
        log_error "Refusing to write configuration through symbolic link: $config_file"
        return 1
    fi
    config_tmp="$(mktemp "$config_dir/.vps_config.XXXXXX")"
    {
        printf '# VPS Auto-Setup Configuration\n'
        printf '# Generated: %s\n' "$(date)"
        printf '# Do not edit manually unless you know what you are doing\n\n'
        for var in "$@"; do
            if [ -n "${!var:-}" ]; then
                printf '%s=%s\n' "$var" "${!var}"
            fi
        done
    } > "$config_tmp"
    chmod 600 "$config_tmp"
    mv -f "$config_tmp" "$config_file"
    
    log_info "Configuration saved to $config_file"
}

# Prompt for a configuration value if not already set (in interactive mode)
prompt_config() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="${3:-}"
    local validate_func="${4:-}"
    
    # Skip if in non-interactive mode and value is already set
    if [ "${NON_INTERACTIVE:-false}" = "true" ] && [ -n "${!var_name:-}" ]; then
        return 0
    fi
    
    local value="${!var_name:-}"
    
    # If we have a value already (from config/env), use it in non-interactive mode
    if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
        if [ -z "$value" ]; then
            value="$default_value"
            export "$var_name"="$value"
            log_info "Using default for $var_name: $value"
        fi
        return 0
    fi
    
    # Interactive mode - prompt for value
    while true; do
        if [ -n "$value" ]; then
            printf '\033[1;33m'
            read -r -p "$prompt_text [$value]: " new_value
            printf '\033[0m\n'
            
            if [ -z "$new_value" ]; then
                new_value="$value"
            fi
        else
            printf '\033[1;33m'
            read -r -p "$prompt_text: " new_value
            printf '\033[0m\n'
            
            # Use default if provided and input is empty
            if [ -z "$new_value" ] && [ -n "$default_value" ]; then
                new_value="$default_value"
            fi
        fi
        
        # Validate if validator function provided
        if [ -n "$validate_func" ] && ! "$validate_func" "$new_value"; then
            printf '\033[1;31mInvalid value. Please try again.\033[0m\n'
            continue
        fi
        
        export "$var_name"="$new_value"
        break
    done
}

# Validate functions for common inputs
validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

validate_yes_no() {
    local value="$1"
    case "$value" in
        [yY][eE][sS]|[yY]|[nN][oO]|[nN])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_true_false() {
    local value="$1"
    case "$value" in
        [tT][rR][uU][eE]|[fF][aA][lL][sSeE])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_hostname() {
    local hostname="$1"
    # RFC 1123 compliant hostname validation
    if [[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$ ]] && [ ${#hostname} -le 253 ]; then
        return 0
    else
        return 1
    fi
}

# Apply configuration values to variables with defaults
apply_config_defaults() {
    # Set defaults for variables that don't have values yet
    : "${USERNAME:=appadmin}"
    : "${HOSTNAME:=my-vps-server}"
    : "${TIMEZONE:=Asia/Shanghai}"
    : "${LOCALE:=zh_CN.UTF-8}"
    : "${PRIMARY_DNS:=1.1.1.1}"
    : "${SECONDARY_DNS:=8.8.8.8}"
    : "${SSH_PORT:=24822}"
    : "${SSH_KEEP_LEGACY_PORT:=true}"
    : "${PERMIT_ROOT_LOGIN:=no}"
    : "${PASSWORD_AUTH:=no}"
    : "${SSH_PUBKEY_AUTHENTICATION:=yes}"
    : "${SSH_PERMIT_EMPTY_PASSWORDS:=no}"
    : "${SSH_MAX_AUTH_TRIES:=3}"
    : "${SSH_MAX_SESSIONS:=10}"
    : "${SSH_CLIENT_ALIVE_INTERVAL:=300}"
    : "${SSH_CLIENT_ALIVE_COUNT_MAX:=2}"
    : "${SSH_LOGIN_GRACE_TIME:=60}"
    : "${ALLOWED_PORTS:=}"
    : "${INSTALL_DOCKER:=true}"
    : "${INSTALL_NPM:=false}"
    : "${DOMAIN:=example.com}"
    : "${HTTP_PORT:=80}"
    : "${HTTPS_PORT:=443}"
    : "${INSTALL_NODE_EXPORTER:=false}"
    : "${INSTALL_FAIL2BAN:=true}"
    : "${INSTALL_AUDITD:=false}"
    : "${ENABLE_SELINUX_CHECK:=true}"
    : "${ENABLE_BACKUP:=false}"
    : "${BACKUP_SCHEDULE:=0 2 * * *}"
    : "${BACKUP_DIRECTORIES:=/etc /var/www /home}"
    : "${BACKUP_RETENTION:=30}"
    : "${BACKUP_COMPRESSION:=gzip}"
    : "${BACKUP_ENCRYPTION:=false}"
    : "${BACKUP_GPG_RECIPIENT:=}"
    : "${BACKUP_DESTINATION:=/var/backups/vps-init-setup}"
    : "${BACKUP_RUN_INITIAL:=false}"
    : "${ENABLE_MONITORING:=false}"
    : "${BACKEND_STORAGE:=rclone://remote/backup}"
    : "${SSH_PUBKEY_AUTH:=yes}"
    : "${SSH_PUBKEY:=}"
    : "${ENABLE_SWAP:=true}"
    : "${SWAP_SIZE:=}"
    : "${SWAP_FILE:=/swapfile}"
    : "${SWAPPINESS:=10}"
    : "${VFS_CACHE_PRESSURE:=50}"
    : "${REMOVE_SNAP:=false}"
    : "${CLEAN_PKG_CACHE:=true}"
    : "${CLEAN_JOURNAL:=true}"
    : "${JOURNAL_MAX_SIZE:=200M}"
    : "${DISABLE_SERVICES:=false}"
    : "${CLEAN_TEMP:=true}"
    : "${OPTIMIZE_FSTAB:=true}"
}