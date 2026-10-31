#!/usr/bin/env bash
#
# Network Module - Optimize kernel network parameters (BBR, TCP tuning)
#

network_info() {
    echo "Kernel network optimization (BBR, TCP tuning, buffers)"
}

network_prerequisites() {
    return 0
}

restore_sysctl_config() {
    local sysctl_config="$1"
    restore_tracked_path "$sysctl_config"
}

network_validate_integer() {
    local name="$1"
    local value="$2"
    local minimum="$3"
    local maximum="$4"

    if [[ ! "$value" =~ ^[0-9]{1,10}$ ]] || \
       (( 10#$value < minimum || 10#$value > maximum )); then
        log_error "$name must be an integer between $minimum and $maximum"
        return 1
    fi
}

network_main() {
    log_info "Starting kernel network optimization..."

    # Determine settings (use configured values or defaults)
    local ip_forward="${IP_FORWARD:-auto}"
    if [ "$ip_forward" = "auto" ] || [ -z "$ip_forward" ]; then
        if [ "${INSTALL_DOCKER:-false}" = "true" ] || command -v docker >/dev/null 2>&1; then
            ip_forward="1"
            log_info "Docker detected/enabled; setting ip_forward=1 for container networking"
        else
            ip_forward="0"
        fi
    fi
    local tcp_fin_timeout="${TCP_FIN_TIMEOUT:-30}"
    local tcp_keepalive_time="${TCP_KEEPALIVE_TIME:-1200}"
    local tcp_keepalive_intvl="${TCP_KEEPALIVE_INTVL:-30}"
    local tcp_keepalive_probes="${TCP_KEEPALIVE_PROBES:-3}"
    local tcp_max_syn_backlog="${TCP_MAX_SYN_BACKLOG:-8192}"
    local tcp_tw_reuse="${TCP_TW_REUSE:-1}"
    local tcp_max_tw_buckets="${TCP_MAX_TW_BUCKETS:-360000}"
    local tcp_syncookies="${TCP_SYNCOOKIES:-1}"
    local tcp_fastopen="${TCP_FASTOPEN:-3}"
    local netdev_max_backlog="${NETDEV_MAX_BACKLOG:-5000}"
    local somaxconn="${SOMAXCONN:-65535}"
    local enable_bbr="${ENABLE_BBR:-true}"
    local sysctl_config="${SYSCTL_CONFIG_FILE:-/etc/sysctl.d/99-vps-network.conf}"
    local sysctl_dir sysctl_candidate
    sysctl_dir="$(dirname "$sysctl_config")"

    case "$ip_forward" in
        0|1) ;;
        *)
            log_error "IP_FORWARD must be 0 or 1"
            return 1
            ;;
    esac
    case "$enable_bbr" in
        true|false) ;;
        *)
            log_error "ENABLE_BBR must be true or false: $enable_bbr"
            return 1
            ;;
    esac
    network_validate_integer TCP_FIN_TIMEOUT "$tcp_fin_timeout" 1 2147483647 || return 1
    network_validate_integer TCP_KEEPALIVE_TIME "$tcp_keepalive_time" 1 2147483647 || return 1
    network_validate_integer TCP_KEEPALIVE_INTVL "$tcp_keepalive_intvl" 1 2147483647 || return 1
    network_validate_integer TCP_KEEPALIVE_PROBES "$tcp_keepalive_probes" 1 255 || return 1
    network_validate_integer TCP_MAX_SYN_BACKLOG "$tcp_max_syn_backlog" 1 2147483647 || return 1
    network_validate_integer TCP_TW_REUSE "$tcp_tw_reuse" 0 1 || return 1
    network_validate_integer TCP_MAX_TW_BUCKETS "$tcp_max_tw_buckets" 1 2147483647 || return 1
    network_validate_integer TCP_SYNCOOKIES "$tcp_syncookies" 0 1 || return 1
    network_validate_integer TCP_FASTOPEN "$tcp_fastopen" 0 7 || return 1
    network_validate_integer NETDEV_MAX_BACKLOG "$netdev_max_backlog" 1 2147483647 || return 1
    network_validate_integer SOMAXCONN "$somaxconn" 1 2147483647 || return 1

    # Backup current sysctl config
    if ! backup_file "$sysctl_config" >/dev/null; then
        log_error "Failed to back up sysctl configuration: $sysctl_config"
        return 1
    fi
    sysctl_candidate="$(mktemp "${sysctl_dir}/.$(basename "$sysctl_config").XXXXXX")" || {
        log_error "Failed to create temporary sysctl configuration"
        return 1
    }

    # Create new sysctl configuration
    log_info "Applying kernel network parameters..."
    {
        echo "# VPS Auto-Setup - Kernel Network Optimization"
        echo "# Generated: $(date)"
        echo ""
        echo "# IP forwarding"
        echo "net.ipv4.ip_forward = $ip_forward"
        echo "net.ipv6.conf.all.forwarding = $ip_forward"
        echo ""
        echo "# TCP keepalive"
        echo "net.ipv4.tcp_keepalive_time = $tcp_keepalive_time"
        echo "net.ipv4.tcp_keepalive_intvl = $tcp_keepalive_intvl"
        echo "net.ipv4.tcp_keepalive_probes = $tcp_keepalive_probes"
        echo ""
        echo "# TCP buffers"
        echo "net.ipv4.tcp_fin_timeout = $tcp_fin_timeout"
        echo "net.ipv4.tcp_max_syn_backlog = $tcp_max_syn_backlog"
        echo "net.core.netdev_max_backlog = $netdev_max_backlog"
        echo "net.core.somaxconn = $somaxconn"
        echo ""
        echo "# TCP reuse options"
        echo "net.ipv4.tcp_tw_reuse = $tcp_tw_reuse"
        echo "net.ipv4.tcp_max_tw_buckets = $tcp_max_tw_buckets"
        echo ""
        echo "# TCP syncookies"
        echo "net.ipv4.tcp_syncookies = $tcp_syncookies"
        echo ""
        echo "# TCP Fast Open"
        echo "net.ipv4.tcp_fastopen = $tcp_fastopen"
        echo ""
        echo "# Security Hardening - Anti-Spoofing & Anti-DDoS"
        echo "net.ipv4.conf.all.rp_filter = 1"
        echo "net.ipv4.conf.default.rp_filter = 1"
        echo "net.ipv4.conf.all.accept_source_route = 0"
        echo "net.ipv6.conf.all.accept_source_route = 0"
        echo "net.ipv4.conf.all.accept_redirects = 0"
        echo "net.ipv6.conf.all.accept_redirects = 0"
        echo "net.ipv4.conf.all.send_redirects = 0"
        echo "net.ipv4.icmp_echo_ignore_broadcasts = 1"
        echo "net.ipv4.icmp_ignore_bogus_error_responses = 1"
        echo "fs.protected_hardlinks = 1"
        echo "fs.protected_symlinks = 1"
        echo "fs.suid_dumpable = 0"
        if [ "$enable_bbr" = "true" ]; then
            echo ""
            echo "# BBR congestion control"
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        fi
    } > "$sysctl_candidate"

    if [ "$enable_bbr" = "true" ]; then
        log_info "Enabling BBR congestion control..."
        modprobe tcp_bbr 2>/dev/null || true
    fi
    if ! chmod 644 "$sysctl_candidate" || ! mv -f "$sysctl_candidate" "$sysctl_config"; then
        rm -f "$sysctl_candidate"
        log_error "Failed to install sysctl configuration: $sysctl_config"
        return 1
    fi
    rm -f "$sysctl_candidate"
    if ! sysctl -p "$sysctl_config" >/dev/null 2>&1; then
        log_error "Failed to apply sysctl configuration; restoring the previous file"
        if ! restore_sysctl_config "$sysctl_config"; then
            log_error "Failed to restore sysctl configuration snapshot: $sysctl_config"
        fi
        if ! sysctl --system >/dev/null 2>&1; then
            log_error "Failed to reapply the restored sysctl configuration set; runtime kernel values may need manual review"
        fi
        return 1
    fi

    audit "NETWORK_OPTIMIZED" "bbr=$enable_bbr ip_forward=$ip_forward"
    state_mark "network" "completed"
    log_info "Kernel network optimization completed"
}

# Allow sourcing without execution
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

# If executed directly, run the main function
network_main "$@"