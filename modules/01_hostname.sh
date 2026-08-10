#!/bin/sh
#
# Hostname Module - Configure system hostname and /etc/hosts
#

hostname_info() {
    echo "Configure system hostname and /etc/hosts entries"
}

hostname_prerequisites() {
    return 0
}

hostname_main() {
    log_info "Starting hostname configuration..."
    
    # Get current hostname
    local current_hostname
    current_hostname=$(hostname)
    log_info "Current hostname: $current_hostname"
    
    # Determine target hostname - use the configured value
    local target_hostname="${HOSTNAME:-}"
    
    # If not set, generate a default based on distro and timestamp
    if [ -z "$target_hostname" ]; then
        local distro timestamp
        distro=$(detect_os_id)
        timestamp=$(date '+%Y%m%d%H%M%S')
        target_hostname="${distro}-vps-${timestamp}"
        log_info "No hostname configured, using generated: $target_hostname"
    fi
    
    # Validate hostname
    if ! validate_hostname "$target_hostname"; then
        log_error "Invalid hostname format: $target_hostname"
        log_error "Hostname must contain only letters, numbers, hyphens, and dots"
        log_error "Cannot start or end with hyphen, max 255 characters"
        return 1
    fi
    
    # Skip if already set correctly
    if [ "$target_hostname" = "$current_hostname" ]; then
        log_info "Hostname already set to $target_hostname, skipping"
        state_mark "hostname" "completed"
        return 0
    fi
    
    # Backup current configuration
    local hosts_backup etc_hostname_backup
    hosts_backup=$(backup_file "/etc/hosts") || true
    etc_hostname_backup=$(backup_file "/etc/hostname") || true
    
    # Set new hostname
    log_info "Setting hostname to: $target_hostname"
    
    case "$(detect_init_system)" in
        systemd)
            hostnamectl set-hostname "$target_hostname"
            ;;
        *)
            printf '%s\n' "$target_hostname" > /etc/hostname
            hostname "$target_hostname"
            ;;
    esac
    
    # Update /etc/hosts
    log_info "Updating /etc/hosts..."
    
    # Get IP addresses
    local ipv4 ipv6
    ipv4=$(ip -4 addr show scope global 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1 | head -1)
    ipv6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2}' | cut -d/ -f1 | head -1 | grep -v '^fe80')
    
    # Create new hosts content
    {
        echo "127.0.0.1       localhost"
        echo "127.0.1.1       $target_hostname"
        
        # Add IPv4 if available
        if [ -n "$ipv4" ] && [ "$ipv4" != "127.0.0.1" ]; then
            echo "$ipv4       $target_hostname"
        fi
        
        # Add IPv6 if available
        if [ -n "$ipv6" ]; then
            echo "$ipv6       $target_hostname"
        fi
        
        echo ""
        echo "# The following lines are desirable for IPv6 capable hosts"
        echo "::1     localhost ip6-localhost ip6-loopback"
        echo "ff02::1 ip6-allnodes"
        echo "ff02::2 ip6-allrouters"
    } > /etc/hosts.new
    
    # Preserve any custom entries from the original hosts file
    if [ -n "$hosts_backup" ] && [ -f "$hosts_backup" ]; then
        # Extract non-localhost/127.0.0.1 entries from backup
        grep -vE '^(127\.0\.0\.1|::1|localhost)' "$hosts_backup" | \
            grep -v '^$' >> /etc/hosts.new
    fi
    
    mv /etc/hosts.new /etc/hosts
    
    # Verify the change
    local new_hostname
    new_hostname=$(hostname)
    if [ "$new_hostname" = "$target_hostname" ]; then
        log_info "Hostname successfully changed to: $new_hostname"
        
        # Audit the change
        audit "HOSTNAME_CHANGED" "from=$current_hostname to=$target_hostname"
        
        # Mark completion
        state_mark "hostname" "completed"
    else
        log_error "Failed to set hostname. Current: $new_hostname, Expected: $target_hostname"
        
        # Attempt rollback
        if [ -n "$etc_hostname_backup" ] && [ -f "$etc_hostname_backup" ]; then
            cp -p "$etc_hostname_backup" /etc/hostname
            hostname "$current_hostname"
            log_info "Rolled back hostname to: $current_hostname"
        fi
        
        if [ -n "$hosts_backup" ] && [ -f "$hosts_backup" ]; then
            cp -p "$hosts_backup" /etc/hosts
            log_info "Rolled back /etc/hosts"
        fi
        
        return 1
    fi
}

# Allow sourcing without execution
if [ "${0##*/}" != "hostname.sh" ] && [ "${0##*/}" != "bash" ] && [ "${0##*/}" != "sh" ]; then
    return 0
fi

# If executed directly, run the main function
hostname_main "$@"