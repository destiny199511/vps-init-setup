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

firewalld_active_interfaces() {
    local active_zones permanent_zones active_interfaces permanent_interfaces
    local zone zone_sources zone_interfaces
    active_zones="$(firewall-cmd --get-active-zones)" || {
        log_error "Failed to inspect active FirewallD zones"
        return 1
    }

    if printf '%s\n' "$active_zones" | awk '/^[[:space:]]*sources:/ && NF > 1 { found = 1 } END { exit !found }'; then
        log_error "FirewallD source-based zone bindings are unsupported; refusing to leave them outside the drop policy"
        return 1
    fi

    permanent_zones="$(firewall-cmd --permanent --get-zones)" || {
        log_error "Failed to inspect permanent FirewallD zones"
        return 1
    }
    permanent_interfaces=""
    for zone in $permanent_zones; do
        if [[ ! "$zone" =~ ^[A-Za-z0-9_-]+$ ]]; then
            log_error "Unexpected FirewallD zone name; refusing to change zone assignments"
            return 1
        fi
        zone_sources="$(firewall-cmd --permanent --zone="$zone" --list-sources)" || {
            log_error "Failed to inspect source bindings in FirewallD zone $zone"
            return 1
        }
        if [ -n "$zone_sources" ]; then
            log_error "FirewallD source-based zone bindings are unsupported; refusing to leave them outside the drop policy"
            return 1
        fi
        zone_interfaces="$(firewall-cmd --permanent --zone="$zone" --list-interfaces)" || {
            log_error "Failed to inspect interface bindings in FirewallD zone $zone"
            return 1
        }
        permanent_interfaces+="$zone_interfaces"$'\n'
    done
    active_interfaces="$(printf '%s\n' "$active_zones" | awk '/^[[:space:]]*interfaces:/ { for (i = 2; i <= NF; i++) print $i }')"
    printf '%s\n%s\n' "$active_interfaces" "$permanent_interfaces" | awk 'NF' | sort -u
}

ufw_restore_configuration() {
    local was_active="$1"
    if ! restore_tracked_path /etc/ufw; then
        log_error "Failed to restore the previous UFW configuration"
        return 1
    fi
    if [ "$was_active" = "true" ]; then
        if ! ufw reload; then
            log_error "Failed to reload the restored UFW configuration"
            return 1
        fi
    elif ! ufw --force disable; then
        log_error "Failed to keep UFW disabled after restoring its previous configuration"
        return 1
    fi
}

ufw_abort_configuration() {
    local reason="$1"
    local was_active="$2"
    log_error "$reason"
    ufw_restore_configuration "$was_active" || log_error "UFW rollback was incomplete"
    return 1
}

firewalld_restore_configuration() {
    if ! restore_tracked_path /etc/firewalld; then
        log_error "Failed to restore the previous FirewallD configuration"
        return 1
    fi
    if ! firewall-cmd --reload; then
        log_error "Failed to reload the restored FirewallD configuration"
        return 1
    fi
}

firewalld_abort_configuration() {
    local reason="$1"
    log_error "$reason"
    firewalld_restore_configuration || log_error "FirewallD rollback was incomplete"
    return 1
}

firewall_main() {
    log_info "Starting firewall configuration..."
    
    # Detect available firewall systems
    local firewall_type
    firewall_type=$(detect_firewall)
    log_info "Detected firewall system: $firewall_type"

    # If no active or installed firewall was detected, choose and install a sensible default:
    # - Debian / Ubuntu: ufw
    # - RHEL / CentOS / Rocky / AlmaLinux / Fedora: firewalld
    # - Others: iptables
    if [ "$firewall_type" = "none" ]; then
        local os_family
        os_family=$(detect_os_id)
        case "$os_family" in
            debian|ubuntu)
                log_info "No active firewall detected. Selected UFW for Debian/Ubuntu system."
                if install_package ufw; then
                    firewall_type="ufw"
                else
                    log_warn "Failed to install UFW, falling back to iptables"
                    firewall_type="iptables"
                fi
                ;;
            rhel|centos|rocky|almalinux|fedora)
                log_info "No active firewall detected. Selected FirewallD for RHEL-family system."
                if install_package firewalld; then
                    firewall_type="firewalld"
                else
                    log_warn "Failed to install firewalld, falling back to iptables"
                    firewall_type="iptables"
                fi
                ;;
            *)
                if command -v ufw >/dev/null 2>&1; then
                    firewall_type="ufw"
                elif command -v firewall-cmd >/dev/null 2>&1; then
                    firewall_type="firewalld"
                elif command -v nft >/dev/null 2>&1; then
                    firewall_type="nftables"
                else
                    firewall_type="iptables"
                fi
                log_info "No active firewall detected. Selected $firewall_type for host."
                ;;
        esac
    fi

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
            if LC_ALL=C ufw status 2>/dev/null | grep -qiE '^Status:[[:space:]]+active'; then
                # Check if our essential ports are allowed
                    ssh_ports_allowed=true
                    for configured_ssh_port in $ssh_ports; do
                        if ! LC_ALL=C ufw status | awk -v port="$configured_ssh_port/tcp" '$1 == port && $2 == "ALLOW" {found=1} END {exit !found}'; then
                            ssh_ports_allowed=false
                        fi
                    done
                    if [ "$ssh_ports_allowed" = "true" ] && \
                   LC_ALL=C ufw status | grep -q "$http_port/tcp.*ALLOW" && \
                   LC_ALL=C ufw status | grep -q "$https_port/tcp.*ALLOW"; then
                    already_configured=true
                fi
            fi
            ;;
        firewalld)
            if firewall-cmd --state 2>/dev/null | grep -Fxq "running"; then
                ssh_ports_allowed=true
                if [ "$(firewall-cmd --get-default-zone 2>/dev/null)" != "drop" ]; then
                    ssh_ports_allowed=false
                fi
                for configured_ssh_port in $ssh_ports; do
                    if ! firewall-cmd --list-ports --zone=drop | tr ' ' '\n' | grep -Fxq "$configured_ssh_port/tcp"; then
                        ssh_ports_allowed=false
                    fi
                done
                if [ "$ssh_ports_allowed" = "true" ] && \
                   firewall-cmd --list-ports --zone=drop | tr ' ' '\n' | grep -Fxq "$http_port/tcp" && \
                   firewall-cmd --list-ports --zone=drop | tr ' ' '\n' | grep -Fxq "$https_port/tcp"; then
                    already_configured=true
                fi
                if [ "$already_configured" = "true" ]; then
                    local configured_interfaces configured_iface
                    configured_interfaces="$(firewalld_active_interfaces)" || return 1
                    while IFS= read -r configured_iface; do
                        [ -n "$configured_iface" ] || continue
                        [ "$configured_iface" = "lo" ] && continue
                        if [ "$(firewall-cmd --get-zone-of-interface="$configured_iface" 2>/dev/null)" != "drop" ]; then
                            already_configured=false
                            break
                        fi
                    done <<< "$configured_interfaces"
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
            if ! backup_file /etc/ufw >/dev/null; then
                log_error "Failed to back up UFW configuration"
                return 1
            fi
            local ufw_was_active=false
            if LC_ALL=C ufw status 2>/dev/null | grep -qiE '^Status:[[:space:]]+active'; then
                ufw_was_active=true
            fi
            
            # Ensure UFW is installed
            if ! command -v ufw >/dev/null 2>&1; then
                log_info "Installing UFW..."
                if ! install_package ufw; then
                    log_error "Failed to install UFW package"
                    return 1
                fi
            fi
            
            # Establish the SSH recovery path before restricting inbound traffic.
            for configured_ssh_port in $ssh_ports; do
                ufw allow "$configured_ssh_port"/tcp comment 'SSH' || \
                    ufw_abort_configuration "Failed to allow SSH port $configured_ssh_port/tcp in UFW" "$ufw_was_active" || return 1
            done
            ufw default deny incoming || \
                ufw_abort_configuration "Failed to set the UFW inbound default policy" "$ufw_was_active" || return 1
            ufw default allow outgoing || \
                ufw_abort_configuration "Failed to set the UFW outbound default policy" "$ufw_was_active" || return 1
            ufw allow "$http_port"/tcp comment 'HTTP' || \
                ufw_abort_configuration "Failed to allow HTTP in UFW" "$ufw_was_active" || return 1
            ufw allow "$https_port"/tcp comment 'HTTPS' || \
                ufw_abort_configuration "Failed to allow HTTPS in UFW" "$ufw_was_active" || return 1
            
            # Allow loopback
            ufw allow in on lo || \
                ufw_abort_configuration "Failed to allow inbound loopback traffic in UFW" "$ufw_was_active" || return 1
            ufw allow out on lo || \
                ufw_abort_configuration "Failed to allow outbound loopback traffic in UFW" "$ufw_was_active" || return 1
            
            # Additional ports from environment
            if [ -n "$open_additional_ports" ]; then
                IFS=',' read -ra PORTS <<< "$open_additional_ports"
                for port in "${PORTS[@]}"; do
                    port=$(echo "$port" | xargs)  # trim
                    if validate_port "$port"; then
                        ufw allow "$port"/tcp || \
                            ufw_abort_configuration "Failed to allow additional UFW port $port/tcp" "$ufw_was_active" || return 1
                        log_info "Added additional port: $port/tcp"
                    else
                        log_warn "Skipping invalid port: $port"
                    fi
                done
            fi
            
            # Enable UFW
            if [ "$ufw_was_active" != "true" ]; then
                if ! printf 'y\n' | ufw enable 2>&1; then
                    ufw_abort_configuration "Failed to enable UFW" "$ufw_was_active" || return 1
                fi
            fi
            
            # Verify status
            if LC_ALL=C ufw status 2>/dev/null | grep -qiE '^Status:[[:space:]]+active'; then
                log_info "UFW enabled and configured successfully"
                changes_made=true
                audit "FIREWALL_CONFIGURED" "type=ufw ssh_port=$ssh_port http=$http_port https=$https_port"
            else
                ufw_abort_configuration "UFW is not active after configuration" "$ufw_was_active" || return 1
            fi
            ;;
            
        firewalld)
            log_info "Configuring FirewallD..."

            if ! backup_file /etc/firewalld >/dev/null; then
                log_error "Failed to back up FirewallD configuration"
                return 1
            fi
            
            # Ensure firewalld is installed
            if ! command -v firewall-cmd >/dev/null 2>&1; then
                log_info "Installing firewalld..."
                if ! install_package firewalld; then
                    log_error "Failed to install firewalld package"
                    return 1
                fi
            fi
            
            # Do not activate a previously stopped firewall before the SSH
            # recovery rules are installed; that can drop the current session.
            if ! firewall-cmd --state 2>/dev/null | grep -Fxq "running"; then
                log_error "FirewallD is not running; refusing to start it before recovery rules can be installed"
                log_error "Start FirewallD through a verified out-of-band session, then rerun this module"
                return 1
            fi
            if command -v systemctl >/dev/null 2>&1 && ! systemctl enable firewalld; then
                log_error "Failed to enable FirewallD at boot"
                return 1
            fi

            local active_interfaces active_iface permanent_zone permanent_zone_interfaces required_port
            active_interfaces="$(firewalld_active_interfaces)" || return 1
            
            # Add runtime and persistent SSH recovery rules before using drop.
            for configured_ssh_port in $ssh_ports; do
                firewall-cmd --zone=drop --add-port="$configured_ssh_port"/tcp || \
                    firewalld_abort_configuration "Failed to add SSH recovery port to FirewallD drop zone" || return 1
                firewall-cmd --permanent --zone=drop --add-port="$configured_ssh_port"/tcp || \
                    firewalld_abort_configuration "Failed to persist SSH recovery port in FirewallD drop zone" || return 1
            done

            firewall-cmd --permanent --zone=drop --add-service=dhcpv6-client || \
                firewalld_abort_configuration "Failed to configure DHCPv6 client service in FirewallD drop zone" || return 1
            for required_port in "$http_port" "$https_port"; do
                firewall-cmd --zone=drop --add-port="$required_port"/tcp || \
                    firewalld_abort_configuration "Failed to add required port to FirewallD drop zone" || return 1
                firewall-cmd --permanent --zone=drop --add-port="$required_port"/tcp || \
                    firewalld_abort_configuration "Failed to persist required port in FirewallD drop zone" || return 1
            done

            if [ -n "$active_interfaces" ]; then
                while IFS= read -r active_iface; do
                    [ -n "$active_iface" ] || continue
                    [ "$active_iface" = "lo" ] && continue
                    if [[ ! "$active_iface" =~ ^[A-Za-z0-9_.:@-]+$ ]]; then
                        firewalld_abort_configuration "Unexpected active FirewallD interface name; refusing to change zones" || return 1
                    fi
                    permanent_zone="$(firewall-cmd --permanent --get-zone-of-interface="$active_iface")" || \
                        firewalld_abort_configuration "Failed to inspect permanent FirewallD zone for $active_iface" || return 1
                    if [ -n "$permanent_zone" ] && [ "$permanent_zone" != "drop" ]; then
                        if [[ ! "$permanent_zone" =~ ^[A-Za-z0-9_-]+$ ]]; then
                            firewalld_abort_configuration "Unexpected permanent FirewallD zone for $active_iface" || return 1
                        fi
                        permanent_zone_interfaces="$(firewall-cmd --permanent --zone="$permanent_zone" --list-interfaces)" || \
                            firewalld_abort_configuration "Failed to inspect permanent zone $permanent_zone for $active_iface" || return 1
                        if [[ " $permanent_zone_interfaces " == *" $active_iface "* ]] && \
                           ! firewall-cmd --permanent --zone="$permanent_zone" --remove-interface="$active_iface"; then
                            firewalld_abort_configuration "Failed to detach $active_iface from its previous permanent FirewallD zone" || return 1
                        fi
                    fi
                    firewall-cmd --permanent --zone=drop --add-interface="$active_iface" || \
                        firewalld_abort_configuration "Failed to assign $active_iface to the FirewallD drop zone" || return 1
                done <<< "$active_interfaces"
            fi
            
            # Additional ports
            if [ -n "$open_additional_ports" ]; then
                IFS=',' read -ra PORTS <<< "$open_additional_ports"
                for port in "${PORTS[@]}"; do
                    port=$(echo "$port" | xargs)
                    if validate_port "$port"; then
                        firewall-cmd --zone=drop --add-port="$port"/tcp || \
                            firewalld_abort_configuration "Failed to add additional port to FirewallD drop zone" || return 1
                        firewall-cmd --permanent --zone=drop --add-port="$port"/tcp || \
                            firewalld_abort_configuration "Failed to persist additional port in FirewallD drop zone" || return 1
                        log_info "Added additional port: $port/tcp"
                    else
                        log_warn "Skipping invalid port: $port"
                    fi
                done
            fi
            
            firewall-cmd --set-default-zone=drop || \
                firewalld_abort_configuration "Failed to set FirewallD default zone to drop" || return 1

            # Reload to apply
            firewall-cmd --reload || \
                firewalld_abort_configuration "Failed to reload FirewallD configuration" || return 1
            
            # Verify
            if ! firewall-cmd --state 2>/dev/null | grep -Fxq "running"; then
                firewalld_abort_configuration "FirewallD is not running after configuration" || return 1
            fi
            for required_port in "$ssh_ports" "$http_port" "$https_port"; do
                for configured_ssh_port in $required_port; do
                    if ! firewall-cmd --list-ports --zone=drop 2>/dev/null | tr ' ' '\n' | grep -Fxq "$configured_ssh_port/tcp"; then
                        firewalld_abort_configuration "FirewallD drop zone is missing expected port $configured_ssh_port/tcp" || return 1
                    fi
                done
            done
            if [ -n "$active_interfaces" ]; then
                while IFS= read -r active_iface; do
                    [ -n "$active_iface" ] || continue
                    [ "$active_iface" = "lo" ] && continue
                    if [ "$(firewall-cmd --get-zone-of-interface="$active_iface" 2>/dev/null)" != "drop" ]; then
                        firewalld_abort_configuration "Active interface $active_iface is not protected by the FirewallD drop zone" || return 1
                    fi
                done <<< "$active_interfaces"
            fi
            log_info "FirewallD configured and reloaded successfully"
            changes_made=true
            audit "FIREWALL_CONFIGURED" "type=firewalld ssh_port=$ssh_port http=$http_port https=$https_port"
            ;;
            
        iptables)
            log_info "Configuring iptables firewall..."
            
            # Ensure iptables tools are installed
            if ! command -v iptables >/dev/null 2>&1; then
                log_info "Installing iptables..."
                if ! install_package iptables; then
                    log_error "Failed to install iptables package"
                    return 1
                fi
            fi
            
            # Preserve existing rules and Docker chains; only add missing
            # baseline rules required for this setup.
            iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT -i lo -j ACCEPT
            iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
                iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

            # Allow incoming SSH, HTTP, HTTPS without flushing active rules.
            for configured_ssh_port in $ssh_ports; do
                iptables -C INPUT -p tcp --dport "$configured_ssh_port" -j ACCEPT 2>/dev/null || \
                    iptables -I INPUT -p tcp --dport "$configured_ssh_port" -j ACCEPT
            done
            iptables -C INPUT -p tcp --dport "$http_port" -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -p tcp --dport "$http_port" -j ACCEPT
            iptables -C INPUT -p tcp --dport "$https_port" -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -p tcp --dport "$https_port" -j ACCEPT
            
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
                ip6tables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
                    ip6tables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
                    ip6tables -I INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
                    ip6tables -I INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
                for configured_ssh_port in $ssh_ports; do
                    ip6tables -C INPUT -p tcp --dport "$configured_ssh_port" -j ACCEPT 2>/dev/null || \
                        ip6tables -I INPUT -p tcp --dport "$configured_ssh_port" -j ACCEPT
                done
                ip6tables -C INPUT -p tcp --dport "$http_port" -j ACCEPT 2>/dev/null || \
                    ip6tables -I INPUT -p tcp --dport "$http_port" -j ACCEPT
                ip6tables -C INPUT -p tcp --dport "$https_port" -j ACCEPT 2>/dev/null || \
                    ip6tables -I INPUT -p tcp --dport "$https_port" -j ACCEPT
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
                        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
                            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
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

            # Ensure nftables is installed
            if ! command -v nft >/dev/null 2>&1; then
                log_info "Installing nftables..."
                if ! install_package nftables; then
                    log_error "Failed to install nftables package"
                    return 1
                fi
            fi

            local nft_config="/etc/nftables.conf"
            local nft_marker="# Managed by vps-init-setup"
            local nft_rules nft_config_managed=false nft_legacy_managed=false
            nft_rules="$(nft list ruleset 2>/dev/null)" || {
                log_error "Failed to inspect the existing nftables ruleset"
                return 1
            }
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

            local nft_candidate nft_apply_candidate
            nft_candidate="$(mktemp /etc/.nftables.conf.XXXXXX)" || {
                log_error "Failed to stage nftables configuration"
                return 1
            }
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

            nft_apply_candidate="$(mktemp /etc/.nftables.apply.XXXXXX)" || {
                rm -f "$nft_candidate"
                log_error "Failed to stage nftables runtime transaction"
                return 1
            }
            {
                if [ "$nft_legacy_managed" = "true" ] && nft list table inet filter >/dev/null 2>&1; then
                    echo "delete table inet filter"
                fi
                if nft list table inet vps_init_setup >/dev/null 2>&1; then
                    echo "delete table inet vps_init_setup"
                fi
                cat "$nft_candidate"
            } > "$nft_apply_candidate" || {
                rm -f "$nft_candidate" "$nft_apply_candidate"
                log_error "Failed to stage nftables runtime transaction"
                return 1
            }

            if ! nft -c -f "$nft_apply_candidate"; then
                log_error "Generated nftables configuration failed validation"
                rm -f "$nft_candidate" "$nft_apply_candidate"
                return 1
            fi

            if ! backup_file "$nft_config" >/dev/null; then
                rm -f "$nft_candidate" "$nft_apply_candidate"
                log_error "Failed to back up nftables configuration"
                return 1
            fi
            if ! chmod 600 "$nft_candidate" || ! mv -f "$nft_candidate" "$nft_config"; then
                rm -f "$nft_candidate" "$nft_apply_candidate"
                log_error "Failed to atomically install nftables configuration"
                return 1
            fi
            if command -v systemctl >/dev/null 2>&1 && ! systemctl enable nftables 2>/dev/null; then
                restore_tracked_path "$nft_config" || \
                    log_error "Failed to restore nftables configuration"
                rm -f "$nft_apply_candidate"
                log_error "Failed to enable nftables persistence"
                return 1
            fi
            if ! nft -f "$nft_apply_candidate"; then
                restore_tracked_path "$nft_config" || \
                    log_error "Failed to restore nftables configuration"
                rm -f "$nft_apply_candidate"
                log_error "Failed to apply validated nftables transaction"
                return 1
            fi
            rm -f "$nft_apply_candidate"
            
            # Verify
            if nft list ruleset | grep -q "table inet vps_init_setup"; then
                log_info "nftables firewall configured successfully"
                changes_made=true
                audit "FIREWALL_CONFIGURED" "type=nftables ssh_port=$ssh_port http=$http_port https=$https_port"
            else
                restore_tracked_path "$nft_config" || \
                    log_error "Failed to restore nftables configuration"
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