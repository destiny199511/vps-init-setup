#!/usr/bin/env bash
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

configure_ssh_socket_ports() {
    local socket_unit socket_dir socket_dropin configured_port

    command -v systemctl >/dev/null 2>&1 || return 0

    for socket_unit in ssh.socket sshd.socket; do
        if ! systemctl is-active --quiet "$socket_unit" 2>/dev/null && \
           ! systemctl is-enabled --quiet "$socket_unit" 2>/dev/null; then
            continue
        fi

        socket_dir="/etc/systemd/system/${socket_unit}.d"
        socket_dropin="${socket_dir}/10-vps-init-setup.conf"
        if [ -f "$socket_dropin" ]; then
            backup_file "$socket_dropin" >/dev/null 2>&1 || true
        fi
        mkdir -p "$socket_dir"
        {
            echo "[Socket]"
            echo "ListenStream="
            for configured_port in $ssh_ports; do
                echo "ListenStream=$configured_port"
            done
        } > "$socket_dropin"

        systemctl daemon-reload
        if ! systemctl restart "$socket_unit"; then
            log_error "Failed to restart $socket_unit after updating ListenStream"
            return 1
        fi
        log_info "Updated $socket_unit ListenStream ports: $ssh_ports"
    done
}

verify_ssh_runtime() {
    local expected_ports="$1"
    local expected_port
    local effective_ports

    if ! command -v sshd >/dev/null 2>&1; then
        log_error "sshd is not available; cannot verify the SSH runtime"
        return 1
    fi
    if ! sshd -t >/dev/null 2>&1; then
        log_error "The active SSH configuration failed sshd -t"
        sshd -t 2>&1 | while read -r line; do
            log_error "sshd validation: $line"
        done
        return 1
    fi

    effective_ports="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | paste -sd ' ' -)"
    for expected_port in $expected_ports; do
        echo "$effective_ports" | grep -Eq "(^|[[:space:]])${expected_port}([[:space:]]|$)" || {
            log_error "Effective SSH configuration does not include port $expected_port"
            return 1
        }
        if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${expected_port}$"; then
            log_error "SSH is not listening on port $expected_port"
            return 1
        fi
        if command -v ssh-keyscan >/dev/null 2>&1; then
            local banner_verified=false
            timeout 5 ssh-keyscan -T 3 -p "$expected_port" 127.0.0.1 >/dev/null 2>&1 && banner_verified=true
            if [ "$banner_verified" != "true" ]; then
                timeout 5 ssh-keyscan -T 3 -p "$expected_port" ::1 >/dev/null 2>&1 && banner_verified=true
            fi
            if [ "$banner_verified" != "true" ]; then
                log_error "SSH on port $expected_port did not return a banner/key on local IPv4 or IPv6"
                journalctl -u ssh -u sshd --no-pager -n 20 2>/dev/null | while read -r line; do
                    log_error "SSH runtime: $line"
                done
                return 1
            fi
        fi
    done
    return 0
}

ssh_main() {
    log_info "Starting SSH hardening..."

    local ssh_service=""
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files ssh.service --no-legend 2>/dev/null | grep -q '^ssh\.service'; then
            ssh_service="ssh"
        elif systemctl list-unit-files sshd.service --no-legend 2>/dev/null | grep -q '^sshd\.service'; then
            ssh_service="sshd"
        fi
    fi
    if [ -z "$ssh_service" ] && command -v service >/dev/null 2>&1; then
        if service ssh status >/dev/null 2>&1; then
            ssh_service="ssh"
        elif service sshd status >/dev/null 2>&1; then
            ssh_service="sshd"
        fi
    fi
    
    # Backup SSH config
    local sshd_config_backup
    sshd_config_backup=$(backup_file "/etc/ssh/sshd_config") || true
    
    # Get current SSH ports from sshd and socket activation.
    local current_ports current_port
    current_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | paste -sd ' ' -)
    current_ports="${current_ports:-22}"
    current_port="${current_ports%% *}"
    log_info "Current SSH ports: $current_ports"
    
    # Determine target SSH port - use configured value
    local target_port="${SSH_PORT:-22}"
    local keep_legacy_port="${SSH_KEEP_LEGACY_PORT:-true}"
    local ssh_ports="$target_port"
    if [ "$keep_legacy_port" = "true" ] && [ "$current_ports" != "$target_port" ]; then
        case " $current_ports " in
            *" $target_port "*) ssh_ports="$current_ports" ;;
            *) ssh_ports="$current_ports $target_port" ;;
        esac
    fi
    
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
        log_info "SSH configuration already matches desired settings; verifying runtime"
        if verify_ssh_runtime "$ssh_ports"; then
            state_mark "ssh" "completed"
            return 0
        fi
        log_error "SSH configuration appears unchanged, but runtime verification failed"
        return 1
    fi
    
    # Apply changes
    log_info "Applying SSH hardening configuration..."

    # Open every migration port before changing sshd so a port migration cannot
    # lock out the current session while the firewall module is still pending.
    if [ "$target_port" != "$current_port" ]; then
        log_info "Pre-opening firewall ports for SSH migration: $ssh_ports"
        for migration_port in $ssh_ports; do
            case "$(detect_firewall)" in
                ufw) ufw allow "$migration_port"/tcp >/dev/null 2>&1 || true ;;
                firewalld)
                    firewall-cmd --permanent --add-port="$migration_port"/tcp >/dev/null 2>&1 || true
                    firewall-cmd --reload >/dev/null 2>&1 || true
                    ;;
                iptables) iptables -C INPUT -p tcp --dport "$migration_port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$migration_port" -j ACCEPT 2>/dev/null || true ;;
            esac
        done
    fi
    
    # Create new sshd_config
    {
        echo "# SSH Configuration - Generated by VPS Auto-Setup"
        echo "# Generated: $(date)"
        echo ""
        
        # Keep the old listener during migration unless explicitly disabled.
        for configured_port in $ssh_ports; do
            echo "Port $configured_port"
        done
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

        if ! configure_ssh_socket_ports; then
            log_error "SSH socket activation could not be updated - attempting rollback"
            rm -f /etc/systemd/system/ssh.socket.d/10-vps-init-setup.conf \
                  /etc/systemd/system/sshd.socket.d/10-vps-init-setup.conf
            systemctl daemon-reload 2>/dev/null || true
            if [ -n "$sshd_config_backup" ] && [ -f "$sshd_config_backup" ]; then
                cp -p "$sshd_config_backup" /etc/ssh/sshd_config
            fi
            return 1
        fi
        
        # Reload the correct service unit first; reload preserves the active session
        # while allowing sshd to bind the new port. Restart only as a fallback.
        log_info "Reloading SSH service${ssh_service:+ ($ssh_service)}..."
        if [ -n "$ssh_service" ] && command -v systemctl >/dev/null 2>&1; then
            systemctl reload "$ssh_service" 2>/dev/null || systemctl restart "$ssh_service"
        elif [ -n "$ssh_service" ] && command -v service >/dev/null 2>&1; then
            service "$ssh_service" reload >/dev/null 2>&1 || service "$ssh_service" restart
        else
            pkill -HUP sshd 2>/dev/null || true
        fi

        # Verify the effective configuration and that the target port is listening.
        local effective_ssh_config_ok=true
        local sshd_test_output effective_ports
        sshd_test_output=$(sshd -t 2>&1) || effective_ssh_config_ok=false
        effective_ports=$(sshd -T 2>&1 | awk '$1 == "port" {print $2}' | paste -sd ',' -)
        for expected_port in $ssh_ports; do
            echo "$effective_ports" | tr ',' '\n' | grep -qx "$expected_port" || effective_ssh_config_ok=false
        done
        if [ "$effective_ssh_config_ok" != "true" ]; then
            log_error "SSH configuration validation failed after reload - attempting rollback"
            [ -n "$sshd_test_output" ] && log_error "sshd validation: $sshd_test_output"
            log_error "Effective SSH ports: ${effective_ports:-none}; expected: $target_port"
            if [ -n "$sshd_config_backup" ] && [ -f "$sshd_config_backup" ]; then
                cp -p "$sshd_config_backup" /etc/ssh/sshd_config
                if [ -n "$ssh_service" ]; then
                    systemctl reload "$ssh_service" 2>/dev/null || service "$ssh_service" reload 2>/dev/null || true
                fi
                log_info "Rolled back SSH configuration"
            fi
            return 1
        fi

          if [ -n "$ssh_service" ] && command -v systemctl >/dev/null 2>&1 && \
              ! systemctl is-active --quiet "$ssh_service" && \
              ! systemctl is-active --quiet ssh.socket 2>/dev/null && \
              ! systemctl is-active --quiet sshd.socket 2>/dev/null; then
            log_error "SSH service $ssh_service is not active after reload - attempting rollback"
            if [ -n "$sshd_config_backup" ] && [ -f "$sshd_config_backup" ]; then
                cp -p "$sshd_config_backup" /etc/ssh/sshd_config
                systemctl restart "$ssh_service" 2>/dev/null || true
                log_info "Rolled back SSH configuration"
            fi
            return 1
        fi

        local ssh_ready=false
        local all_ssh_ports_ready=true
        for _ in 1 2 3 4 5; do
            all_ssh_ports_ready=true
            for expected_port in $ssh_ports; do
                if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${expected_port}$"; then
                    all_ssh_ports_ready=false
                    break
                fi
            done
            if [ "$all_ssh_ports_ready" = "true" ]; then
                ssh_ready=true
                break
            fi
            sleep 1
        done
        if [ "$ssh_ready" != "true" ]; then
            log_error "SSH is not listening on all expected ports ($ssh_ports) - attempting rollback"
            if [ -n "$sshd_config_backup" ] && [ -f "$sshd_config_backup" ]; then
                cp -p "$sshd_config_backup" /etc/ssh/sshd_config
                if [ -n "$ssh_service" ]; then
                    systemctl reload "$ssh_service" 2>/dev/null || service "$ssh_service" reload 2>/dev/null || true
                fi
                log_info "Rolled back SSH configuration"
            fi
            return 1
        fi
        
        # Update firewall if port changed
        if [ "$target_port" != "$current_port" ]; then
            log_info "Updating firewall rules for SSH port change: $current_port -> $target_port"

            # Add all confirmed listeners. The old port is removed only when the
            # operator explicitly disables SSH_KEEP_LEGACY_PORT.
            for migration_port in $ssh_ports; do
                case "$(detect_firewall)" in
                    ufw) ufw allow "$migration_port"/tcp >/dev/null 2>&1 || true ;;
                    firewalld)
                        firewall-cmd --permanent --add-port="$migration_port"/tcp >/dev/null 2>&1 || true
                        firewall-cmd --reload >/dev/null 2>&1 || true
                        ;;
                    iptables) iptables -C INPUT -p tcp --dport "$migration_port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$migration_port" -j ACCEPT 2>/dev/null || true ;;
                esac
            done
            if [ "$keep_legacy_port" != "true" ]; then
                case "$(detect_firewall)" in
                    ufw) ufw delete allow "$current_port"/tcp 2>/dev/null || true ;;
                    firewalld) firewall-cmd --remove-port="$current_port"/tcp --permanent 2>/dev/null || true; firewall-cmd --reload >/dev/null 2>&1 || true ;;
                    iptables) iptables -D INPUT -p tcp --dport "$current_port" -j ACCEPT 2>/dev/null || true ;;
                esac
            else
                log_warn "Keeping legacy SSH port $current_port open for connection recovery"
            fi
            
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
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

# If executed directly, run the main function
ssh_main "$@"