#!/bin/sh
#
# Network Module - Optimize kernel network parameters (BBR, TCP tuning)
#

network_info() {
    echo "Kernel network optimization (BBR, TCP tuning, buffers)"
}

network_prerequisites() {
    return 0
}

network_main() {
    log_info "Starting kernel network optimization..."

    # Determine settings (use configured values or defaults)
    local ip_forward="${IP_FORWARD:-0}"
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

    # Backup current sysctl config
    backup_file "/etc/sysctl.conf" >/dev/null 2>&1 || true

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
    } > /etc/sysctl.d/99-vps-network.conf

    # Apply settings
    sysctl -p /etc/sysctl.d/99-vps-network.conf >/dev/null 2>&1

    # Enable BBR if configured
    if [ "$enable_bbr" = "true" ]; then
        log_info "Enabling BBR congestion control..."
        {
            echo ""
            echo "# BBR congestion control"
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        } >> /etc/sysctl.d/99-vps-network.conf
        modprobe tcp_bbr 2>/dev/null || true
        sysctl -p /etc/sysctl.d/99-vps-network.conf >/dev/null 2>&1
    fi

    audit "NETWORK_OPTIMIZED" "bbr=$enable_bbr ip_forward=$ip_forward"
    state_mark "network" "completed"
    log_info "Kernel network optimization completed"
}

# Allow sourcing without execution
if [ "${0##*/}" != "network.sh" ] && [ "${0##*/}" != "bash" ] && [ "${0##*/}" != "sh" ]; then
    return 0
fi

# If executed directly, run the main function
network_main "$@"