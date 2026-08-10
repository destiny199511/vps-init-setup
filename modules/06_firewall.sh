#!/bin/sh
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
    local ssh_port http_port https_port
    
    # Get SSH port from SSH config (which should already be set by SSH module)
    ssh_port=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')
    ssh_port="${ssh_port:-${SSH_PORT:-22}}"
    
    # HTTP/HTTPS ports (can be overridden via config)
    http_port="${HTTP_PORT:-80}"
    https_port="${HTTPS_PORT:-443}"
    
    # Additional ports from config
    local open_additional_ports="${ADDITIONAL_PORTS:-${ALLOWED_PORTS:-}}"
    
    # Validate ports
    if ! validate_port "$ssh_port"; then
        log_error "Invalid SSH port: $ssh_port"
        return 1
    fi
    
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
            if ufw status | grep -q "Status: active"; then
                # Check if our essential ports are allowed
                if ufw status | grep -q "$ssh_port/tcp.*ALLOW" && \
                   ufw status | grep -q "$http_port/tcp.*ALLOW" && \
                   ufw status | grep -q "$https_port/tcp.*ALLOW"; then
                    already_configured=true
                fi
            fi
            ;;
        firewalld)
            if firewall-cmd --state 2>/dev/null | grep -q "running"; then
                if firewall-cmd --list-ports | grep -q "$ssh_port/tcp" && \
                   firewall-cmd --list-ports | grep -q "$http_port/tcp" && \
                   firewall-cmd --list-ports | grep -q "$https_port/tcp"; then
                    already_configured=true
                fi
            fi
            ;;
        iptables)
            if iptables -L INPUT -v -n 2>/dev/null | grep -q "dpt:$ssh_port" && \
               iptables -L INPUT -v -n 2>/dev/null | grep -q "dpt:$http_port" && \
               iptables -L INPUT -v -n 2>/dev/null | grep -q "dpt:$https_port"; then
                already_configured=true
            fi
            ;;
        nftables)
            if nft list chain inet filter input 2>/dev/null | grep -q "dport $ssh_port" && \
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
            
            # Ensure UFW is installed
            if ! command -v ufw >/dev/null 2>&1; then
                log_info "Installing UFW..."
                install_package ufw
            fi
            
            # Reset to known state
            ufw --force reset
            
            # Set default policies
            ufw default deny incoming
            ufw default allow outgoing
            
            # Allow essential services
            ufw allow "$ssh_port"/tcp comment 'SSH'
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
            echo "y" | ufw enable
            
            # Verify status
            if ufw status | grep -q "Status: active"; then
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
            
            # Add our services
            firewall-cmd --permanent --zone=drop --add-port="$ssh_port"/tcp
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
            
            # Flush existing rules
            iptables -F
            iptables -X
            iptables -t nat -F
            iptables -t nat -X
            iptables -t mangle -F
            iptables -t mangle -X
            
            # Set default policies
            iptables -P INPUT DROP
            iptables -P FORWARD DROP
            iptables -P OUTPUT ACCEPT
            
            # Allow loopback traffic
            iptables -A INPUT -i lo -j ACCEPT
            iptables -A OUTPUT -o lo -j ACCEPT
            
            # Allow established and related connections
            iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
            
            # Allow incoming SSH, HTTP, HTTPS
            iptables -A INPUT -p tcp --dport "$ssh_port" -m state --state NEW -j ACCEPT
            iptables -A INPUT -p tcp --dport "$http_port" -m state --state NEW -j ACCEPT
            iptables -A INPUT -p tcp --dport "$https_port" -m state --state NEW -j ACCEPT
            
            # Allow ping (ICMP echo request)
            iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
            
            # Additional ports
            if [ -n "$open_additional_ports" ]; then
                IFS=',' read -ra PORTS <<< "$open_additional_ports"
                for port in "${PORTS[@]}"; do
                    port=$(echo "$port" | xargs)
                    if validate_port "$port"; then
                        iptables -A INPUT -p tcp --dport "$port" -m state --state NEW -j ACCEPT
                        log_info "Added additional port: $port/tcp"
                    else
                        log_warn "Skipping invalid port: $port"
                    fi
                done
            fi
            
            # Save rules
            if command -v iptables-save >/dev/null 2>&1; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            fi
            
            # Make persistent if on Debian/Ubuntu
            if [ "$(detect_os_id)" = "ubuntu" ] || [ "$(detect_os_id)" = "debian" ]; then
                if [ ! -d /etc/iptables ]; then
                    mkdir -p /etc/iptables
                fi
                iptables-save > /etc/iptables/rules.v4
                ip6tables-save > /etc/iptables/rules.v6
                
                # Ensure netfilter-persistent is installed
                if ! dpkg -l netfilter-persistent >/dev/null 2>&1; then
                    install_package netfilter-persistent
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
            
            # Flush existing rules
            nft flush ruleset
            
            # Create new ruleset
            {
                echo "#!/usr/sbin/nft -f"
                echo "# nftables configuration - Generated by VPS Auto-Setup"
                echo "# Generated: $(date)"
                echo ""
                echo "flush ruleset"
                echo ""
                echo "table inet filter {"
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
                echo "        tcp dport $ssh_port ct state new accept"
                echo "        tcp dport $http_port ct state new accept"
                echo "        tcp dport $https_port ct state new accept"
                echo ""
                echo "        # Allow ICMP (ping)"
                echo "        icmp type echo-request accept"
                echo "        icmp type destination-unreachable accept"
                echo "        icmp type time-exceeded accept"
                echo "        icmp type parameter-problem accept"
                echo ""
                echo "        # Optional: Limit new connections to prevent SYN flood"
                echo "        tcp flags syn/fctr,ack,psh,rst,urg,fin ctr & 1 drop"
                echo "        tcp flags syn/fctr,ack,psh,rst,urg,fin gt 100 ctr & 1 drop"
                echo "        tcp dport $ssh_port ct state new limit rate 20/second burst 100 packets accept"
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
            } > /etc/nftables.conf
            
            # Additional ports
            if [ -n "$open_additional_ports" ]; then
                # This is more complex to add dynamically - for now just note it
                log_warn "Additional ports not automatically added to nftables - please edit /etc/nftables.conf manually"
            fi
            
            # Enable and start nftables
            systemctl enable --now nftables 2>/dev/null || true
            
            # Load the ruleset
            nft -f /etc/nftables.conf
            
            # Verify
            if nft list ruleset | grep -q "table inet filter"; then
                log_info "nftables firewall configured successfully"
                changes_made=true
                audit "FIREWALL_CONFIGURED" "type=nftables ssh_port=$ssh_port http=$http_port https=$https_port"
            else
                log_error "Failed to load nftables ruleset"
                return 1
            fi
            ;;
            
        *)
            log_error "Unsupported or no firewall system detected: $firewall_type"
            log_error "Please configure firewall manually or install ufw, firewalld, iptables, or nftables"
            return 1
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
if [ "${0##*/}" != "firewall.sh" ] && [ "${0##*/}" != "bash" ] && [ "${0##*/}" != "sh" ]; then
    return 0
fi

# If executed directly, run the main function
firewall_main "$@"