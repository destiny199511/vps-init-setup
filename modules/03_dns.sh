#!/usr/bin/env bash
#
# DNS Module - Configure DNS resolution (systemd-resolved or traditional)
#

dns_info() {
    echo "Configure DNS resolution settings"
}

dns_prerequisites() {
    return 0
}

dns_main() {
    log_info "Starting DNS configuration..."
    
    # Detect current DNS configuration
    local dns_mode resolv_conf
    resolv_conf="/etc/resolv.conf"
    
    # Configure systemd-resolved only when it is actually serving DNS. A stale
    # runtime directory is not proof that the service can own resolv.conf.
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        dns_mode="systemd-resolved"
        log_info "systemd-resolved is active"
    else
        dns_mode="traditional"
        log_info "Using traditional DNS configuration"
    fi
    
    # Get current nameservers
    local current_nameservers
    if [ -f "$resolv_conf" ]; then
        current_nameservers=$(grep '^nameserver' "$resolv_conf" | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
    fi
    log_info "Current nameservers: ${current_nameservers:-none}"
    
    # Determine target DNS servers
    local primary_dns secondary_dns
    
    if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
        # Non-interactive mode: use config or defaults
        primary_dns="${PRIMARY_DNS:-1.1.1.1}"
        secondary_dns="${SECONDARY_DNS:-8.8.8.8}"
    else
        # Interactive mode
        printf '\033[1;33m'
        read -r -p "Primary DNS server (current: ${current_nameservers%%,*}): " primary_dns
        printf '\033[0m\n'
        
        if [ -z "$primary_dns" ]; then
            # Extract first from current or use default
            primary_dns=$(echo "$current_nameservers" | cut -d',' -f1)
            [ -z "$primary_dns" ] && primary_dns="1.1.1.1"
        fi
        
        printf '\033[1;33m'
        read -r -p "Secondary DNS server (current: ${current_nameservers#*,}): " secondary_dns
        printf '\033[0m\n'
        
        if [ -z "$secondary_dns" ]; then
            # Extract second from current or use default
            secondary_dns=$(echo "$current_nameservers" | cut -d',' -f2)
            [ -z "$secondary_dns" ] && secondary_dns="8.8.8.8"
        fi
    fi
    
    # Validate DNS servers
    if ! validate_ip "$primary_dns"; then
        log_error "Invalid primary DNS IP: $primary_dns"
        return 1
    fi
    
    if ! validate_ip "$secondary_dns"; then
        log_error "Invalid secondary DNS IP: $secondary_dns"
        return 1
    fi
    
    # Skip if already configured correctly
    if [ "$dns_mode" = "systemd-resolved" ]; then
        # Check current systemd-resolved settings
        if command -v resolvectl >/dev/null 2>&1; then
            current_dns=$(resolvectl dns 2>/dev/null | grep 'Current DNS Server:' | awk '{print $4}' | head -1)
            if [ "$current_dns" = "$primary_dns" ]; then
                log_info "systemd-resolved already configured with primary DNS: $primary_dns"
                # Still need to configure fallback
            fi
        fi
    else
        # Traditional: check resolv.conf
        if [ -f "$resolv_conf" ]; then
            if grep -q "^nameserver $primary_dns" "$resolv_conf" && \
               grep -q "^nameserver $secondary_dns" "$resolv_conf"; then
                log_info "DNS servers already configured correctly"
                state_mark "dns" "completed"
                return 0
            fi
        fi
    fi
    
    # Backup current configuration
    local resolv_backup resolved_conf_backup
    resolv_backup=$(backup_file "/etc/resolv.conf") || true
    resolved_conf_backup=$(backup_file "/etc/systemd/resolved.conf") || true
    
    local changes_made=false
    
    # Configure based on mode
    if [ "$dns_mode" = "systemd-resolved" ]; then
        log_info "Configuring systemd-resolved..."

        local resolved_candidate
        resolved_candidate=$(mktemp)
        {
            echo "[Resolve]"
            echo "DNS=$primary_dns $secondary_dns"
            echo "# FallbackDNS=1.0.0.1 8.8.4.4"
            echo "# Domains="
            echo "# LLMNR=yes"
            echo "# MulticastDNS=yes"
            echo "# DNSSEC=allow-downgrade"
            echo "# Cache=yes"
            echo "# DNSStubListener=yes"
            echo "# ReadEtcHosts=yes"
        } > "$resolved_candidate"

        install -m 644 "$resolved_candidate" /etc/systemd/resolved.conf
        rm -f "$resolved_candidate"

        if ! systemctl restart systemd-resolved; then
            log_error "Failed to restart systemd-resolved; restoring previous configuration"
            if [ -n "$resolved_conf_backup" ] && [ -f "$resolved_conf_backup" ]; then
                cp -p "$resolved_conf_backup" /etc/systemd/resolved.conf
            else
                rm -f /etc/systemd/resolved.conf
            fi
            systemctl restart systemd-resolved 2>/dev/null || true
            return 1
        fi
        sleep 2
        
        # Verify configuration
        if command -v resolvectl >/dev/null 2>&1; then
            current_dns=$(resolvectl dns 2>/dev/null | awk '$1 == "Global:" {for (i = 2; i <= NF; i++) print $i}' | tr '\n' ' ')
            if printf '%s\n' "$current_dns" | grep -qw "$primary_dns" && \
               printf '%s\n' "$current_dns" | grep -qw "$secondary_dns"; then
                log_info "systemd-resolved DNS configured successfully"
                changes_made=true
                audit "DNS_CONFIGURED" "mode=systemd-resolved primary=$primary_dns secondary=$secondary_dns"
            else
                log_error "Could not verify systemd-resolved DNS configuration; restoring previous configuration"
                if [ -n "$resolved_conf_backup" ] && [ -f "$resolved_conf_backup" ]; then
                    cp -p "$resolved_conf_backup" /etc/systemd/resolved.conf
                else
                    rm -f /etc/systemd/resolved.conf
                fi
                systemctl restart systemd-resolved 2>/dev/null || true
                return 1
            fi
        else
            log_error "resolvectl is required to verify systemd-resolved configuration"
            if [ -n "$resolved_conf_backup" ] && [ -f "$resolved_conf_backup" ]; then
                cp -p "$resolved_conf_backup" /etc/systemd/resolved.conf
            else
                rm -f /etc/systemd/resolved.conf
            fi
            systemctl restart systemd-resolved 2>/dev/null || true
            return 1
        fi
        
    else
        # Traditional resolv.conf configuration
        log_info "Configuring traditional DNS (/etc/resolv.conf)..."
        if [ -L "$resolv_conf" ]; then
            log_error "$resolv_conf is managed through a symbolic link while systemd-resolved is inactive"
            log_error "Start the owning resolver service or replace the link deliberately before using this module"
            return 1
        fi
        
        # Create new resolv.conf
        {
            echo "# Generated by VPS Auto-Setup"
            echo "nameserver $primary_dns"
            echo "nameserver $secondary_dns"
            echo ""
            echo "# Optional: Add more servers or search domains below"
            echo "# nameserver 8.8.4.4"
            echo "# nameserver 1.0.0.1"
            echo "# search example.com"
        } > /etc/resolv.conf
        
        # Make it immutable if requested (optional)
        # chattr +i /etc/resolv.conf  # Uncomment if you want to prevent changes
        
        log_info "Traditional DNS configured successfully"
        changes_made=true
        audit "DNS_CONFIGURED" "mode=traditional primary=$primary_dns secondary=$secondary_dns"
    fi
    
    # Test DNS resolution
    log_info "Testing DNS resolution..."
    if getent ahostsv4 one.one.one.one >/dev/null 2>&1 || \
       getent ahostsv6 one.one.one.one >/dev/null 2>&1; then
        log_info "DNS resolution test successful"
    else
        log_error "DNS resolution test failed; restoring the previous configuration"
        if [ "$dns_mode" = "systemd-resolved" ]; then
            if [ -n "$resolved_conf_backup" ] && [ -f "$resolved_conf_backup" ]; then
                cp -p "$resolved_conf_backup" /etc/systemd/resolved.conf
            else
                rm -f /etc/systemd/resolved.conf
            fi
            systemctl restart systemd-resolved 2>/dev/null || true
        elif [ -n "$resolv_backup" ] && [ -f "$resolv_backup" ]; then
            cp -p "$resolv_backup" "$resolv_conf"
        else
            rm -f "$resolv_conf"
        fi
        return 1
    fi
    
    # Mark completion
    [ "$changes_made" = "true" ] || log_info "DNS configuration already matched the requested state"
    state_mark "dns" "completed"
    
    log_info "DNS configuration completed"
}

# Allow sourcing without execution
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

# If executed directly, run the main function
dns_main "$@"