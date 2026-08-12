#!/usr/bin/env bash
#
# Firewall Module - Configure system firewall (UFW, FirewallD, iptables, nftables)
#

firewall_info() {
    echo "Configure system firewall with sensible defaults"
}

firewall_prerequisites() {
    return 0
}

firewall_main() {
    log_info "Starting firewall configuration..."
    
    # Detect available firewall systems
    local firewall_type
    firewall_type=$(detect_firewall)
    log_info "Detected firewall system: $firewall_type"

    # Backup current firewall state if possible
    case "$firewall_type" in
        ufw)
            # UFW doesn't have a simple backup, but we can copy rules
            cp -r /etc/ufw /etc/ufw.backup.$(date +%s) 2>/dev/null || true
            ;;
        firewalld)
            firewall-cmd --runtime-to-permanent would be ideal but we want to backup current state
            mkdir -p /etc/firewalld.backup.$(date +%s)
            cp -r /etc/firewalld/* /etc/firewalld.backup.$(date +%s)/ 2>/dev/null || true
            ;;
        iptables)
            # Save current rules
            iptables-save > /etc/iptables.backup.$(date +%s).rules 2>/dev/null || true
            ip6tables-save > /etc/ip6tables.backup.$(date +%s).rules 2>/dev/null || true
            ;;
        nftables)
            nft list ruleset > /etc/nftables.backup.$(date +%s).conf 2>/dev/null || true
            ;;
    esac
    
    # Determine what ports to open - use standardized variable names
    local ssh_ports ssh_port http_port https_port
    
    # Get SSH port from SSH config (which should already be set by SSH module)
    ssh_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | awk '!seen[$0]++' | paste -sd ' ' -)
    ssh_ports="${ssh_ports:-${SSH_PORT:-22}}"
    ssh_port="${ssh_ports%% *}"
    
    # HTTP/HTTPS ports (can be overridden via config)
    http_port="${HTTP_PORT:-80}"
    https_port="${HTTPS_PORT:-443}"
    
    # Additional ports from config
    local open_additional_ports="${ADDITIONAL_PORTS:-${ALLOWED_PORTS:-}}"
    
    # Validate ports
    for configured_ssh_port in $ssh_ports; do
        if ! validate_port "$configured_ssh_port"; then
            log_error "Invalid SSH port: $configured_ssh_port"
            return 1
        fi
    done
    
    if ! validate_port "$http_port"; then
        log_error "Invalid HTTP port: $http_port"
        return 1
    fi
    
    if ! validate_port "$https_port"; then
        log_error "Invalid HTTPS port: $https_port"
        return 1
    fi
    
    # Check if firewall already configured similarly
    local already_configured=false
    
    case "$firewall_type" in
        ufw)
            if ufw status 2>/dev/null | grep -qiE '^Status:[[:space:]]+active'; then
                # Check if our essential ports are allowed
                    ssh_ports_allowed=true
                    for configured_ssh_port in $ssh_ports; do
                        if ! ufw status | awk -v port="$configured_ssh_port/tcp" '$1 == port && $2 == "ALLOW" {found=1} END {exit !found}'; then
                            ssh_ports_allowed=false
                        fi
                    done
                    if [ "$ssh_ports_allowed" = "true" ] && \
                   ufw status | grep -q "$http_port/tcp.*ALLOW" && \
                   ufw status | grep -q "$https_port/tcp.*ALLOW"; then
                    already_configured=true
                fi
            fi
            ;;
        firewalld)
            if firewall-cmd --state 2>/dev/null | grep -q "running"; then
                ssh_ports_allowed=true
                for configured_ssh_port in $ssh_ports; do
                    if ! firewall-cmd --list-ports | grep -q "$configured_ssh_port/tcp"; then
                        ssh_ports_allowed=false
                    fi
                done
                if [ "$ssh_ports_allowed" = "true" ] && \
                   firewall-cmd --list-ports | grep -q "$http_port/tcp" && \
                   firewall-cmd --list-ports | grep -q "$https_port/tcp"; then
                    already_configured=true
                fi
            fi
            ;;
        iptables)
            ssh_ports_allowed=true
            for configured_ssh_port in $ssh_ports; do
                if ! iptables -L INPUT -v -n 2>/dev/null | grep -q "dpt:$configured_ssh_port"; then
                    ssh_ports_allowed=false
                fi
            done
                if [ "$ssh_ports_allowed" = "true" ] && \
                    iptables -L INPUT -v -n 2>/dev/null | grep -q "dpt:$http_port" && \
                    iptables -L INPUT -v -n 2>/dev/null | grep -q "dpt:$https_port" && \
                    iptables -S INPUT 2>/dev/null | grep -q -- '-P INPUT DROP' && \
                    { ! command -v ip6tables >/dev/null 2>&1 || ip6tables -S INPUT 2>/dev/null | grep -q -- '-P INPUT DROP'; }; then
                already_configured=true
            fi
            ;;
        nftables)
            ssh_ports_allowed=true
            for configured_ssh_port in $ssh_ports; do
                if ! nft list chain inet filter input 2>/dev/null | grep -q "dport $configured_ssh_port"; then
                    ssh_ports_allowed=false
                fi
            done
            if [ "$ssh_ports_allowed" = "true" ] && \
               nft list chain inet filter input 2>/dev/null | grep -q "dport $http_port" && \
               nft list chain inet filter input 2>/dev/null | grep -q "dport $https_port"; then
                already_configured=true
            fi
            ;;
    esac
    
    if [ "$already_configured" = "true" ]; then
        # In non-interactive mode, we might still want to add additional ports
        if [ "${NON_INTERACTIVE:-false}" = "true" ] && [ -n "$open_additional_ports" ]; then
            # Will process additional ports below
            :
        else
            log_info "Firewall already configured with essential ports"
            state_mark "firewall" "completed"
            return 0
        fi
    fi
    
    # Ask for confirmation in interactive mode
    if [ "${NON_INTERACTIVE:-false}" = "false" ]; then
        echo "This will configure the firewall to:"
        echo "  - Allow incoming SSH on port $ssh_port"
        echo "  - Allow incoming HTTP on port $http_port"
        echo "  - Allow incoming HTTPS on port $https_port"
        [ -n "$open_additional_ports" ] && echo "  - Additionally allow: $open_additional_ports"
        echo ""
        echo "NOTE: This will REPLACE existing firewall rules with a secure baseline!"
        
        printf '\033[1;33m'
        read -r -p "Proceed with firewall configuration? [y/N] " choice
        printf '\033[0m\n'
        
        case "$choice" in
            y|Y|yes|Yes) ;;
            *)
                log_info "Firewall configuration cancelled by user"
                return 0
                ;;
        esac
    fi
    
    local changes_made=false
    
    # Apply firewall configuration based on type
    case "$firewall_type" in
        ufw)
            log_info "Configuring UFW firewall..."
            local ufw_was_active=false
            if ufw status 2>/dev/null | grep -qiE '^Status:[[:space:]]+active'; then
                ufw_was_active=true
            fi
            
            # Ensure UFW is installed
            if ! command -v ufw >/dev/null 2>&1; then
                log_info "Installing UFW..."
                install_package ufw
            fi
            
            # Set default policies
            ufw default deny incoming
            ufw default allow outgoing
            
            # Allow every active SSH listener during port migration.
            for configured_ssh_port in $ssh_ports; do
                ufw allow "$configured_ssh_port"/tcp comment 'SSH'
            done
            ufw allow "$http_port"/tcp comment 'HTTP'
            ufw allow "$https_port"/tcp comment 'HTTPS'
            
            # Allow loopback
            ufw allow in on lo
            ufw allow out on lo
            
            # Additional ports from environment
            if [ -n "$open_additional_ports" ]; then
                IFS=',' read -ra PORTS <<< "$open_additional_ports"
                for port in "${PORTS[@]}"; do
                    port=$(echo "$port" | xargs)  # trim
                    if validate_port "$port"; then
                        ufw allow "$port"/tcp
                        log_info "Added additional port: $port/tcp"
                    else
                        log_warn "Skipping invalid port: $port"
                    fi
                done
            fi
            
            # Enable UFW
            if [ "$ufw_was_active" != "true" ]; then
                if ! printf 'y\n' | ufw enable 2>&1; then
                    log_error "Failed to enable UFW; leaving it inactive without disabling another firewall"
                    return 1
                fi
            fi
            
            # Verify status
            if ufw status 2>/dev/null | grep -qiE '^Status:[[:space:]]+active'; then
                log_info "UFW enabled and configured successfully"
                changes_made=true
                audit "FIREWALL_CONFIGURED" "type=ufw ssh_port=$ssh_port http=$http_port https=$https_port"
            else
                log_error "Failed to enable UFW"
                return 1
            fi
            ;;
            
        firewalld)
            log_info "Configuring FirewallD..."
            
            # Ensure firewalld is installed
            if ! command -v firewall-cmd >/dev/null 2>&1; then
                log_info "Installing firewalld..."
                install_package firewalld
            fi
            
            # Start and enable firewalld
            systemctl enable --now firewalld 2>/dev/null || true
            
            # Set default zone to drop (most secure)
            firewall-cmd --set-default-zone=drop
            
            # Configure the default zone
            firewall-cmd --permanent --zone=drop --add-service=dhcpv6-client
            firewall-cmd --permanent --zone=drop --add-source=127.0.0.1/8
            firewall-cmd --permanent --zone=drop --add-source=::1/128
            
            # Add every active SSH listener during port migration.
            for configured_ssh_port in $ssh_ports; do
                firewall-cmd --permanent --zone=drop --add-port="$configured_ssh_port"/tcp
            done
            firewall-cmd --permanent --zone=drop --add-port="$http_port"/tcp
            firewall-cmd --permanent --zone=drop --add-port="$https_port"/tcp
            
            # Add loopback interface traffic
            firewall-cmd --permanent --zone=drop --add-interface=lo
            
            # Additional ports
            if [ -n "$open_additional_ports" ]; then
                IFS=',' read -ra PORTS <<< "$open_additional_ports"
                for port in "${PORTS[@]}"; do
                    port=$(echo "$port" | xargs)
                    if validate_port "$port"; then
                        firewall-cmd --permanent --zone=drop --add-port="$port"/tcp
                        log_info "Added additional port: $port/tcp"
                    else
                        log_warn "Skipping invalid port: $port"
                    fi
                done
            fi
            
            # Reload to apply
            firewall-cmd --reload
            
            # Verify
            if firewall-cmd --state 2>/dev/null | grep -q "running"; then
                log_info "FirewallD configured and reloaded successfully"
                changes_made=true
                audit "FIREWALL_CONFIGURED" "type=firewalld ssh_port=$ssh_port http=$http_port https=$https_port"
            else
                log_error "FirewallD is not running"
                return 1
            fi
            ;;
            
        iptables)
            log_info "Configuring iptables firewall..."
            
            # Preserve existing rules and Docker chains; only add missing
            # baseline rules required for this setup.
            iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT -i lo -j ACCEPT
            iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

            # Allow incoming SSH, HTTP, HTTPS without flushing active rules.
            for configured_ssh_port in $ssh_ports; do
                iptables -C INPUT -p tcp --dport "$configured_ssh_port" -m state --state NEW -j ACCEPT 2>/dev/null || \
                    iptables -I INPUT -p tcp --dport "$configured_ssh_port" -m state --state NEW -j ACCEPT
            done
            iptables -C INPUT -p tcp --dport "$http_port" -m state --state NEW -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -p tcp --dport "$http_port" -m state --state NEW -j ACCEPT
            iptables -C INPUT -p tcp --dport "$https_port" -m state --state NEW -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -p tcp --dport "$https_port" -m state --state NEW -j ACCEPT
            
            # Allow ping (ICMP echo request)
            iptables -C INPUT -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -p icmp --icmp-type echo-request -j ACCEPT

            # Apply the restrictive host policy only after all recovery rules
            # are present. Keep Docker forwarding intact when its chains exist.
            iptables -P INPUT DROP
            if ! iptables-save 2>/dev/null | grep -q '^-A FORWARD .*DOCKER'; then
                iptables -P FORWARD DROP
            fi
            iptables -P OUTPUT ACCEPT

            if command -v ip6tables >/dev/null 2>&1; then
                ip6tables -C INPUT -i lo -j ACCEPT 2>/dev/null || ip6tables -I INPUT -i lo -j ACCEPT
                ip6tables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
                    ip6tables -I INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
                for configured_ssh_port in $ssh_ports; do
                    ip6tables -C INPUT -p tcp --dport "$configured_ssh_port" -m state --state NEW -j ACCEPT 2>/dev/null || \
                        ip6tables -I INPUT -p tcp --dport "$configured_ssh_port" -m state --state NEW -j ACCEPT
                done
                ip6tables -C INPUT -p tcp --dport "$http_port" -m state --state NEW -j ACCEPT 2>/dev/null || \
                    ip6tables -I INPUT -p tcp --dport "$http_port" -m state --state NEW -j ACCEPT
                ip6tables -C INPUT -p tcp --dport "$https_port" -m state --state NEW -j ACCEPT 2>/dev/null || \
                    ip6tables -I INPUT -p tcp --dport "$https_port" -m state --state NEW -j ACCEPT
                ip6tables -C INPUT -p ipv6-icmp -j ACCEPT 2>/dev/null || \
                    ip6tables -I INPUT -p ipv6-icmp -j ACCEPT
                ip6tables -P INPUT DROP
                if ! ip6tables-save 2>/dev/null | grep -q '^-A FORWARD .*DOCKER'; then
                    ip6tables -P FORWARD DROP
                fi
                ip6tables -P OUTPUT ACCEPT
            fi
            
            # Additional ports
            if [ -n "$open_additional_ports" ]; then
                IFS=',' read -ra PORTS <<< "$open_additional_ports"
                for port in "${PORTS[@]}"; do
                    port=$(echo "$port" | xargs)
                    if validate_port "$port"; then
                        iptables -C INPUT -p tcp --dport "$port" -m state --state NEW -j ACCEPT 2>/dev/null || \
                            iptables -I INPUT -p tcp --dport "$port" -m state --state NEW -j ACCEPT
                        log_info "Added additional port: $port/tcp"
                    else
                        log_warn "Skipping invalid port: $port"
                    fi
                done
            fi
            
            # Persist rules only after ensuring the target directory exists.
            mkdir -p /etc/iptables
            if command -v iptables-save >/dev/null 2>&1; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            fi
            
            # Make persistent if on Debian/Ubuntu
            if [ "$(detect_os_id)" = "ubuntu" ] || [ "$(detect_os_id)" = "debian" ]; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4
                ip6tables-save > /etc/iptables/rules.v6
                
                # Ensure netfilter-persistent is installed
                if ! dpkg -l netfilter-persistent >/dev/null 2>&1; then
                    install_package netfilter-persistent iptables-persistent 2>/dev/null || install_package iptables-persistent 2>/dev/null || true
                fi
                invoke-rc.d netfilter-persistent save 2>/dev/null || true
            fi
            
            # Make persistent if on RHEL/CentOS
            if [ "$(detect_os_id)" = "centos" ] || [ "$(detect_os_id)" = "rhel" ] || [ "$(detect_os_id)" = "rocky" ] || [ "$(detect_os_id)" = "almalinux" ]; then
                service iptables save 2>/dev/null || true
                service ip6tables save 2>/dev/null || true
            fi
            
            log_info "iptables firewall configured successfully"
            changes_made=true
            audit "FIREWALL_CONFIGURED" "type=iptables ssh_port=$ssh_port http=$http_port https=$https_port"
            ;;
            
        nftables)
            log_info "Configuring nftables firewall..."

            local nft_config="/etc/nftables.conf"
            local nft_marker="# Managed by vps-init-setup"
            local nft_rules nft_config_managed=false nft_legacy_managed=false
            nft_rules="$(nft list ruleset 2>/dev/null || true)"
            if [ -f "$nft_config" ] && grep -Fqx "$nft_marker" "$nft_config"; then
                nft_config_managed=true
            elif [ -f "$nft_config" ] && grep -Fq '# nftables configuration - Generated by VPS Auto-Setup' "$nft_config"; then
                nft_config_managed=true
                nft_legacy_managed=true
            fi
            if { [ -n "$nft_rules" ] || [ -s "$nft_config" ]; } && [ "$nft_config_managed" != "true" ]; then
                log_error "Existing nftables rules are not managed by this tool; refusing to replace them"
                log_error "Keep the existing firewall or migrate its rules to a dedicated managed configuration first"
                return 1
            fi

            local nft_candidate
            nft_candidate=$(mktemp)
            {
                echo "$nft_marker"
                echo "# nftables configuration generated by VPS Auto-Setup"
                echo "# Generated: $(date)"
                echo ""
                echo "table inet vps_init_setup {"
                echo "    chain input {"
                echo "        type filter hook input priority 0; policy drop;"
                echo ""
                echo "        # Accept loopback traffic"
                echo "        iif lo accept"
                echo ""
                echo "        # Accept established and related connections"
                echo "        ct state established,related accept"
                echo ""
                echo "        # Allow SSH, HTTP, HTTPS"
                for configured_ssh_port in $ssh_ports; do
                    echo "        tcp dport $configured_ssh_port ct state new accept"
                done
                echo "        tcp dport $http_port ct state new accept"
                echo "        tcp dport $https_port ct state new accept"
                if [ -n "$open_additional_ports" ]; then
                    IFS=',' read -ra PORTS <<< "$open_additional_ports"
                    for port in "${PORTS[@]}"; do
                        port=$(echo "$port" | xargs)
                        if validate_port "$port"; then
                            echo "        tcp dport $port ct state new accept"
                        else
                            log_warn "Skipping invalid nftables additional port: $port"
                        fi
                    done
                fi
                echo ""
                echo "        ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded, parameter-problem } accept"
                echo "        ip6 nexthdr icmpv6 icmpv6 type { echo-request, destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } accept"
                echo "    }"
                echo ""
                echo "    chain forward {"
                echo "        type filter hook forward priority 0; policy drop;"
                echo "    }"
                echo ""
                echo "    chain output {"
                echo "        type filter hook output priority 0; policy accept;"
                echo "    }"
                echo "}"
            } > "$nft_candidate"

            if ! nft -c -f "$nft_candidate"; then
                log_error "Generated nftables configuration failed validation"
                rm -f "$nft_candidate"
                return 1
            fi

            backup_file "$nft_config" >/dev/null 2>&1 || true
            if [ "$nft_legacy_managed" = "true" ]; then
                nft delete table inet filter 2>/dev/null || true
            fi
            nft delete table inet vps_init_setup 2>/dev/null || true
            if ! nft -f "$nft_candidate"; then
                log_error "Failed to load validated nftables configuration"
                rm -f "$nft_candidate"
                return 1
            fi
            install -m 600 "$nft_candidate" "$nft_config"
            rm -f "$nft_candidate"
            systemctl enable nftables 2>/dev/null || true
            
            # Verify
            if nft list ruleset | grep -q "table inet vps_init_setup"; then
                log_info "nftables firewall configured successfully"
                changes_made=true
                audit "FIREWALL_CONFIGURED" "type=nftables ssh_port=$ssh_port http=$http_port https=$https_port"
            else
                log_error "Failed to load nftables ruleset"
                return 1
            fi
            ;;
            
        *)
            log_warn "No supported active firewall detected; leaving firewall unchanged"
            state_mark "firewall" "skipped"
            return 0
            ;;
    esac
    
    # Final verification and messaging
    if [ "$changes_made" = "true" ]; then
        state_mark "firewall" "completed"
        log_info "Firewall configuration completed successfully"
        
        # Show summary
        echo ""
        echo "Firewall Configuration Summary:"
        echo "------------------------------"
        echo "SSH Access:      TCP/$ssh_port"
        echo "HTTP Access:     TCP/$http_port"
        echo "HTTPS Access:    TCP/$https_port"
        [ -n "$open_additional_ports" ] && echo "Additional:      $open_additional_ports"
        echo ""
        echo "IMPORTANT: Test your SSH connection in a new terminal before closing this one!"
        echo ""
    else
        state_mark "firewall" "completed"
        log_info "Firewall configuration completed (no changes needed)"
    fi
}

# Allow sourcing without execution
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

# If executed directly, run the main function
firewall_main "$@"