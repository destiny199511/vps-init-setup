#!/bin/sh
#
# Preflight Module - System and Dependency Checks
# Validates system compatibility and prepares for setup
#

preflight_info() {
    echo "System and dependency validation"
}

preflight_prerequisites() {
    # Must be run as root
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: This script must be run as root"
        return 1
    fi
    
    # Check for required commands
    local required_commands="awk sed grep cut tr xargs"
    for cmd in $required_commands; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found"
            return 1
        fi
    done
    
    return 0
}

preflight_main() {
    log_info "Starting preflight checks..."

    local issues_found=0

    # 1. Check if running as root
    log_info "Checking root privileges..."
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        issues_found=$((issues_found + 1))
    fi

    # 2. Check OS compatibility
    log_info "Checking OS compatibility..."
    local os_name
    os_name=$(detect_os)
    log_info "Detected OS: $os_name"

    case "$os_name" in
        ubuntu|debian|centos|rhel|rocky|almalinux|amazon|suse|arch|alpine|gentoo)
            log_info "OS '$os_name' is compatible"
            ;;
        *)
            log_warn "OS '$os_name' is not officially supported"
            log_warn "Setup may still work, but compatibility is not guaranteed"
            if [ "${FORCE:-false}" != "true" ] && [ "${NON_INTERACTIVE:-false}" = "false" ]; then
                printf '\033[1;33m'
                read -r -p "Continue anyway? [y/N] " choice
                printf '\033[0m\n'
                case "$choice" in
                    [yY][eE][sS]|[yY]) ;;
                    *) return 1 ;;
                esac
            fi
            ;;
    esac

    # 3. Check disk space
    log_info "Checking disk space..."
    local available_space
    available_space=$(df -k / | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 524288 ]; then  # 512MB minimum
        log_error "Insufficient disk space: $(echo $available_space | awk '{printf "%.1f GB", $1/1024/1024}')"
        log_error "Need at least 512MB free on /"
        issues_found=$((issues_found + 1))
    else
        log_info "Sufficient disk space available ($(echo $available_space | awk '{printf "%.1f GB", $1/1024/1024}') free)"
    fi

    # 4. Check available memory
    log_info "Checking available memory..."
    if command -v free >/dev/null 2>&1; then
        local total_mem
        total_mem=$(free -m | awk '/^Mem:/ {print $2}')
        if [ "$total_mem" -lt 256 ]; then
            log_error "Insufficient memory: ${total_mem}MB, need at least 256MB"
            issues_found=$((issues_found + 1))
        else
            log_info "Sufficient memory available (${total_mem}MB)"
        fi
    fi

    # 5. Check network connectivity
    log_info "Checking network connectivity..."
    if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1; then
        log_info "Network connectivity OK"
    else
        log_warn "Network connectivity test failed"
        log_warn "Some modules may not function without internet access"
    fi

    # 6. Check virtualization/container platform
    if [ -d /proc/vz ] || [ -f /proc/user_beancounters ]; then
        log_info "Running in OpenVZ/Virtuozzo environment"
    elif [ -f /proc/1/environ ] && grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        log_info "Running in LXC container"
    elif [ -f /.dockerenv ]; then
        log_info "Running in Docker container"
    fi

    # Report findings
    if [ "$issues_found" -gt 0 ]; then
        log_error "Preflight check found $issues_found issue(s)"
        return 1
    fi

    log_info "Preflight checks passed"
    state_mark "preflight" "completed"
    return 0
}

# Allow sourcing without execution
if [ "${0##*/}" != "preflight.sh" ] && [ "${0##*/}" != "bash" ] && [ "${0##*/}" != "sh" ]; then
    return 0
fi

# If executed directly, run the main function
preflight_main "$@"