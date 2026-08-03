#!/bin/sh
#
# SSH Hardening Module - Secure SSH configuration
#

ssh_info() {
    echo "Harden SSH configuration (port, key auth, disable root login, etc)"
}

ssh_prerequisites() {
    # Check if SSH is installed
    if ! command -v sshd >/dev/null 2>&1 && ! command -v /usr/sbin/sshd >/dev/null 2>&1; then
        log_warn "SSH server not detected - installing openssh-server"
        # Don't fail here, let the module handle installation if needed
    fi
    return 0
}

ssh_main() {
    log_info "Starting SSH hardening..."
    
    # Backup SSH config
    local sshd_config_backup
    sshd_config_backup=$(backup_file "/etc/ssh/sshd_config") || true
    
    # Get current SSH port
    local current_port
    current_port=$(grep '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    log_info "Current SSH port: $current_port"
    
    # Determine target SSH port - use configured value
    local target_port="${SSH_PORT:-22}"
    
    # Validate port
    if ! validate_port "$target_port"; then
        log_error "Invalid SSH port: $target_port"
        log_error "Port must be between 1 and 65535"
        return 1
    fi
    
    # Check if port is already in use (basic check)
    if [ "$target_port" -ne 22 ]; then
        if ss -tlnp | grep -q ":$target_port "; then
            log_warn "Port $target_port appears to be already in use"
            if [ "${FORCE:-false}" != "true" ]; then
                # In non-interactive mode with force, we continue anyway
                if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
                    log_warn "Continuing anyway due to non-interactive mode"
                else
                    printf '\033[1;33m'
                    read -r -p "Continue anyway? [y/N] " choice
                    printf '\033[0m\n'
                    case "$choice" in
                        [yY][eE][sS]|[yY]) ;;
                        *) return 1 ;;
                    esac
                fi
            fi
        fi
    fi
    
    # Determine other SSH settings - use configured values
    local permit_root_login="${PERMIT_ROOT_LOGIN:-no}"
    local password_authentication="${PASSWORD_AUTH:-no}"
    local pubkey_authentication="${SSH_PUBKEY_AUTHENTICATION:-yes}"
    local permit_empty_passwords="${SSH_PERMIT_EMPTY_PASSWORDS:-no}"
    local max_auth_tries="${SSH_MAX_AUTH_TRIES:-3}"
    local max_sessions="${SSH_MAX_SESSIONS:-10}"
    local client_alive_interval="${SSH_CLIENT_ALIVE_INTERVAL:-300}"
    local client_alive_count_max="${SSH_CLIENT_ALIVE_COUNT_MAX:-2}"
    local login_grace_time="${SSH_LOGIN_GRACE_TIME:-60}"
    
    # Validate numeric settings
    if ! echo "$max_auth_tries" | grep -qE '^[0-9]+$' || [ "$max_auth_tries" -lt 1 ] || [ "$max_auth_tries" -gt 10 ]; then
        log_warn "Invalid MaxAuthTries: $max_auth_tries, using 3"
        max_auth_tries=3
    fi
    
    if ! echo "$max_sessions" | grep -qE '^[0-9]+$' || [ "$max_sessions" -lt 1 ] || [ "$max_sessions" -gt 50 ]; then
        log_warn "Invalid MaxSessions: $max_sessions, using 10"
        max_sessions=10
    fi
    
    if ! echo "$client_alive_interval" | grep -qE '^[0-9]+$' || [ "$client_alive_interval" -lt 0 ]; then
        log_warn "Invalid ClientAliveInterval: $client_alive_interval, using 300"
        client_alive_interval=300
    fi
    
    if ! echo "$client_alive_count_max" | grep -qE '^[0-9]+$' || [ "$client_alive_count_max" -lt 0 ] || [ "$client_alive_count_max" -gt 10 ]; then
        log_warn "Invalid ClientAliveCountMax: $client_alive_count_max, using 2"
        client_alive_count_max=2
    fi
    
    if ! echo "$login_grace_time" | grep -qE '^[0-9]+$' || [ "$login_grace_time" -lt 0 ]; then
        log_warn "Invalid LoginGraceTime: $login_grace_time, using 60"
        login_grace_time=60
    fi
    
    # Check if changes are needed
    local needs_update=false
    changes_made=false
    
    # Check port
    if [ "$target_port" != "$current_port" ]; then
        needs_update=true
    fi
    
    # Check other settings by reading current config
    if grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
        current_root_login=$(grep "^PermitRootLogin" /etc/ssh/sshd_config | awk '{print $2}')
    else
        current_root_login="yes"  # Default
    fi
    
    if [ "$permit_root_login" != "$current_root_login" ]; then
        needs_update=true
    fi
    
    if grep -q "^PasswordAuthentication" /etc/ssh/sshd_config; then
        current_pw_auth=$(grep "^PasswordAuthentication" /etc/ssh/sshd_config | awk '{print $2}')
    else
        current_pw_auth="yes"  # Default
    fi
    
    if [ "$password_authentication" != "$current_pw_auth" ]; then
        needs_update=true
    fi
    
    if grep -q "^PubkeyAuthentication" /etc/ssh/sshd_config; then
        current_pubkey_auth=$(grep "^PubkeyAuthentication" /etc/ssh/sshd_config | awk '{print $2}')
    else
        current_pubkey_auth="yes"  # Default
    fi
    
    if [ "$pubkey_authentication" != "$current_pubkey_auth" ]; then
        needs_update=true
    fi
    
    if [ "$needs_update" = "false" ]; then
        # Check other settings too
        for setting in PermitEmptyPasswords MaxAuthTries MaxSessions ClientAliveInterval ClientAliveCountMax LoginGraceTime; do
            current_val=$(grep "^$setting" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "DEFAULT")
            case "$setting" in
                PermitEmptyPasswords) desired_val="$permit_empty_passwords" ;;
                MaxAuthTries) desired_val="$max_auth_tries" ;;
                MaxSessions) desired_val="$max_sessions" ;;
                ClientAliveInterval) desired_val="$client_alive_interval" ;;
                ClientAliveCountMax) desired_val="$client_alive_count_max" ;;
                LoginGraceTime) desired_val="$login_grace_time" ;;
            esac
            if [ "$current_val" != "DEFAULT" ] && [ "$desired_val" != "$current_val" ]; then
                needs_update=true
                break
            fi
        done
    fi
    
    if [ "$needs_update" = "false" ]; then
        log_info "SSH configuration already matches desired settings"
        state_mark "ssh" "completed"
        return 0
    fi
    
    # Apply changes
    log_info "Applying SSH hardening configuration..."
    
    # Create new sshd_config
    {
        echo "# SSH Configuration - Generated by VPS Auto-Setup"
        echo "# Generated: $(date)"
        echo ""
        
        # Port
        echo "Port $target_port"
        echo ""
        
        # Authentication
        echo "PermitRootLogin $permit_root_login"
        echo "PubkeyAuthentication $pubkey_authentication"
        echo "PasswordAuthentication $password_authentication"
        echo "PermitEmptyPasswords $permit_empty_passwords"
        echo ""
        
        # Security settings
        echo "MaxAuthTries $max_auth_tries"
        echo "MaxSessions $max_sessions"
        echo ""
        
        # Timeouts
        echo "LoginGraceTime $login_grace_time"
        echo "ClientAliveInterval $client_alive_interval"
        echo "ClientAliveCountMax $client_alive_count_max"
        echo ""
        
        # Logging
        echo "SyslogFacility AUTH"
        echo "LogLevel INFO"
        echo ""
        
        # Security hardening
        echo "PermitUserEnvironment no"
        echo "IgnoreRhosts yes"
        echo "HostbasedAuthentication no"
        echo "PermitTunnel no"
        echo "GatewayPorts no"
        echo "X11Forwarding no"
        echo "AllowTcpForwarding no"
        echo "PermitTTY yes"
        echo "PrintMotd yes"
        echo "PrintLastLog yes"
        echo "TCPKeepAlive yes"
        echo ""
        
        # Include system crypto policies if applicable
        if [ -f /etc/ssh/sshd_config.d/00-default.conf ] || [ -f /etc/ssh/sshd_config.d/05-redhat.conf ]; then
            echo "# Include distribution-specific configuration"
            echo "Include /etc/ssh/sshd_config.d/*.conf"
        fi
        
        # Include user-defined config if exists
        if [ -d /etc/ssh/sshd_config.d ] && [ "$(ls -A /etc/ssh/sshd_config.d/ 2>/dev/null)" ]; then
            echo "Include /etc/ssh/sshd_config.d/*.conf"
        fi
        
        # Subsystem
        echo ""
        echo "Subsystem sftp /usr/lib/openssh/sftp-server"
    } > /etc/ssh/sshd_config.new
    
    # Validate the new config
    if sshd -t -f /etc/ssh/sshd_config.new; then
        mv /etc/ssh/sshd_config.new /etc/ssh/sshd_config
        log_info "SSH configuration updated successfully"
        
        # Restart SSH service
        log_info "Restarting SSH service..."
        if systemctl is-active --quiet sshd; then
            systemctl restart sshd
        elif service sshd status >/dev/null 2>&1; then
            service sshd restart
        else
            # Fallback
            pkill -HUP sshd 2>/dev/null || true
            sleep 2
        fi
        
        # Verify SSH is still responsive
        sleep 3
        if ! sshd -t; then
            log_error "SSH configuration test failed after restart - attempting rollback"
            if [ -n "$sshd_config_backup" ] && [ -f "$sshd_config_backup" ]; then
                cp -p "$sshd_config_backup" /etc/ssh/sshd_config
                systemctl reload sshd 2>/dev/null || service sshd reload 2>/dev/null || true
                log_info "Rolled back SSH configuration"
            fi
            return 1
        fi
        
        # Update firewall if port changed
        if [ "$target_port" != "$current_port" ]; then
            log_info "Updating firewall rules for SSH port change: $current_port -> $target_port"
            
            # Remove old rule (if exists)
            case "$(detect_firewall)" in
                ufw)
                    ufw delete allow "$current_port"/tcp 2>/dev/null || true
                    ufw allow "$target_port"/tcp
                    ;;
                firewalld)
                    firewall-cmd --remove-port="$current_port"/tcp --permanent 2>/dev/null || true
                    firewall-cmd --add-port="$target_port"/tcp --permanent
                    firewall-cmd --reload
                    ;;
                iptables)
                    iptables -D INPUT -p tcp --dport "$current_port" -j ACCEPT 2>/dev/null || true
                    iptables -I INPUT -p tcp --dport "$target_port" -j ACCEPT
                    ;;
                nftables)
                    # nftables is more complex, skip for now
                    logger "Manual nftables rule update needed for port $target_port"
                    ;;
            esac
            
            audit "SSH_PORT_CHANGED" "from=$current_port to=$target_port"
        fi
        
        # Log all changes
        audit "SSH_CONFIGURED" "port=$target_port root_login=$permit_root_login password_auth=$password_authentication pubkey_auth=$pubkey_authentication"
        
        changes_made=true
        state_mark "ssh" "completed"
        log_info "SSH hardening completed successfully"
    else
        log_error "SSH configuration test failed - not applying changes"
        rm -f /etc/ssh/sshd_config.new
        
        # Show the errors
        sshd -t -f /etc/ssh/sshd_config.new 2>&1 | while read -r line; do
            log_error "sshd config error: $line"
        done
        
        return 1
    fi
}

# Allow sourcing without execution
if [ "${0##*/}" != "ssh.sh" ] && [ "${0##*/}" != "bash" ] && [ "${0##*/}" != "sh" ]; then
    return 0
fi

# If executed directly, run the main function
ssh_main "$@"