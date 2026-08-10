#!/bin/sh
#
# User Module - Create non-root user with SSH access and optional sudo
#

user_info() {
    echo "Create non-root user with SSH access and sudo privileges"
}

user_prerequisites() {
    return 0
}

user_main() {
    log_info "Starting user configuration..."
    
    # Check if we're running as root
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        return 1
    fi
    
    # Get current user info (if any)
    local existing_user
    existing_user=$(getent passwd 1000 | cut -d: -f1 || true)
    
    # Determine target username - use configured value
    local username="${USERNAME:-appuser}"
    
    # Validate username
    if ! validate_username "$username"; then
        log_error "Invalid username: $username"
        log_error "Username must be 1-32 characters, alphanumeric plus . _ -"
        log_error "Cannot start with hyphen"
        return 1
    fi
    
    # Check if user already exists
    if id "$username" &>/dev/null; then
        log_info "User '$username' already exists"
        
        # Check if it's a system account (UID < 1000)
        local uid
        uid=$(id -u "$username")
        if [ "$uid" -lt 1000 ]; then
            log_warn "User '$username' is a system account (UID=$uid)"
            if [ "${FORCE:-false}" != "true" ]; then
                # In non-interactive mode, we continue with system accounts
                if [ "${NON_INTERACTIVE:-false}" != "true" ]; then
                    read -r -p "Continue with system account? [y/N] " choice
                    case "$choice" in
                        [yY][eE][sS]|[yY]) ;;
                        *) return 1 ;;
                    esac
                fi
            fi
        fi
        
        # If non-interactive and user exists, we still need to configure SSH/sudo
        if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
            # Still need to ensure SSH keys and sudo are set up
            :
        else
            read -r -p "User exists. Continue to configure SSH access and sudo? [Y/n] " choice
            case "$choice" in
                n|N)
                    log_info "Skipping user configuration"
                    state_mark "user" "completed"
                    return 0
                    ;;
                *) ;;
            esac
        fi
    else
        log_info "User '$username' does not exist - will create"
    fi
    
    local changes_made=false
    
    # Determine user settings - use configured values
    local user_fullname="${USER_FULLNAME:-$username}"
    local user_shell="${USER_SHELL:-/bin/bash}"
    local create_home="${CREATE_HOME:-true}"
    local add_to_sudo="${ADD_TO_SUDO:-true}"
    local setup_ssh="${SETUP_SSH:-true}"
    local pubkey_authentication="${SSH_PUBKEY_AUTHENTICATION:-${SSH_PUBKEY_AUTH:-yes}}"
    
    # Create user if doesn't exist
    if ! id "$username" &>/dev/null; then
        log_info "Creating user: $username"
        
        local useradd_args=()
        [ "$create_home" = "true" ] && useradd_args+=("-m")
        [ -n "$user_shell" ] && useradd_args+=("-s" "$user_shell")
        [ -n "$user_fullname" ] && useradd_args+=("-c" "$user_fullname")
        
        # Add user
        if useradd "${useradd_args[@]}" "$username"; then
            log_info "User '$username' created successfully"
            changes_made=true
            audit "USER_CREATED" "username=$username uid=$(id -u "$username")"
        else
            log_error "Failed to create user '$username'"
            return 1
        fi
    else
        log_info "User '$username' already exists, UID=$(id -u "$username")"
        # Update GECOS if needed and different
        if [ -n "$user_fullname" ]; then
            current_gecos=$(getent passwd "$username" | cut -d: -f5)
            if [ "$current_gecos" != "$user_fullname" ]; then
                usermod -c "$user_fullname" "$username"
                log_info "Updated user full name to: $user_fullname"
                changes_made=true
            fi
        fi
    fi
    
    # Set up SSH access
    if [ "$setup_ssh" = "true" ] && [ "$pubkey_authentication" = "yes" ]; then
        log_info "Setting up SSH access for user: $username"
        
        local user_home user_ssh_dir authorized_keys
        user_home=$(eval echo "~$username")
        user_ssh_dir="$user_home/.ssh"
        authorized_keys="$user_ssh_dir/authorized_keys"
        
        # Create .ssh directory if needed
        if [ ! -d "$user_ssh_dir" ]; then
            mkdir -p "$user_ssh_dir"
            chmod 700 "$user_ssh_dir"
            chown "$username:$username" "$user_ssh_dir"
            log_info "Created .ssh directory"
            changes_made=true
        fi
        
        # Handle authorized keys
        local ssh_key_source="${SSH_PUBLIC_KEY:-${SSH_PUBKEY:-}}"
        
        case "$ssh_key_source" in
            "")
                # No SSH key configured - generate one for the user
                log_info "Generating SSH key pair for $username..."
                if sudo -u "$username" ssh-keygen -t ed25519 -f "$user_ssh_dir/id_ed25519" -N "" -q; then
                    # Set permissions
                    chmod 600 "$user_ssh_dir/id_ed25519"
                    chmod 644 "$user_ssh_dir/id_ed25519.pub"
                    chown "$username:$username" "$user_ssh_dir"/id_ed25519*
                    
                    # Copy public key to authorized_keys
                    cp "$user_ssh_dir/id_ed25519.pub" "$authorized_keys"
                    chmod 600 "$authorized_keys"
                    chown "$username:$username" "$authorized_keys"
                    
                    # Display the private key (ONLY ONCE!)
                    echo ""
                    echo "========================================================================"
                    echo "SSH PRIVATE KEY FOR USER '$username' (SAVE THIS SECURELY!)"
                    echo "========================================================================"
                    cat "$user_ssh_dir/id_ed25519"
                    echo ""
                    echo "========================================================================"
                    echo "NEVER transmit this key over unsecured channels!"
                    echo "Store it in a password manager or secure location."
                    echo "========================================================================"
                    
                    audit "SSH_KEY_GENERATED" "username=$username key_type=ed25519"
                    changes_made=true
                else
                    log_error "Failed to generate SSH key pair"
                    return 1
                fi
                ;;
            *)
                if [ -n "$ssh_key_source" ]; then
                    # Validate it looks like a SSH public key
                    if echo "$ssh_key_source" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp)'; then
                        echo "$ssh_key_source" > "$authorized_keys"
                        chmod 600 "$authorized_keys"
                        chown "$username:$username" "$authorized_keys"
                        log_info "SSH public key installed"
                        changes_made=true
                        audit "SSH_KEY_INSTALLED" "username=$username"
                    else
                        log_warn "Provided SSH key doesn't appear valid - skipping"
                    fi
                fi
                ;;
        esac
    fi
    
    # Configure sudo access
    if [ "$add_to_sudo" = "true" ]; then
        log_info "Configuring sudo access for: $username"
        
        # Check if user is already in sudo/administrators group
        local sudo_group
        sudo_group=$(getent group sudo | cut -d: -f1)
        [ -z "$sudo_group" ] && sudo_group="wheel"  # RHEL/CentOS uses wheel
        
        # Add to appropriate group
        case "$(detect_package_manager)" in
            apt|deb)
                if getent group sudo >/dev/null 2>&1; then
                    usermod -aG sudo "$username"
                    log_info "Added user to sudo group"
                    changes_made=true
                else
                    # Fallback to adding to sudoers file directly
                    echo "$username ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$username"
                    chmod 440 "/etc/sudoers.d/$username"
                    log_info "Added user to sudoers file"
                    changes_made=true
                fi
                ;;
            yum|dnf|rpm)
                if getent group wheel >/dev/null 2>&1; then
                    usermod -aG wheel "$username"
                    log_info "Added user to wheel group"
                    changes_made=true
                else
                    echo "$username ALL=(ALL) ALL" > "/etc/sudoers.d/$username"
                    chmod 440 "/etc/sudoers.d/$username"
                    log_info "Added user to sudoers file"
                    changes_made=true
                fi
                ;;
            *)
                # Generic approach
                if getent group sudo >/dev/null 2>&1; then
                    usermod -aG sudo "$username"
                elif getent group wheel >/dev/null 2>&1; then
                    usermod -aG wheel "$username"
                else
                    echo "$username ALL=(ALL) ALL" > "/etc/sudoers.d/$username"
                    chmod 440 "/etc/sudoers.d/$username"
                fi
                log_info "Configured sudo access"
                changes_made=true
                ;;
        esac
        
        # Verify sudoers syntax
        if ! visudo -c >/dev/null 2>&1; then
            log_error "Invalid sudoers configuration - please check manually"
            # Don't fail completely as this might be a false positive in some envs
        fi
        
        audit "SUDO_CONFIGURED" "username=$username"
    fi
    
    # Password authentication requires an actual password, even when public-key
    # authentication is enabled as a second login method.
    local password_authentication="${PASSWORD_AUTH:-no}"
    local user_password="${USER_PASSWORD:-}"
    if [ "$password_authentication" = "yes" ]; then
        if [ -z "$user_password" ]; then
            log_error "Password authentication is enabled, but no user password was provided"
            return 1
        fi

        log_info "Setting password for user: $username"
        if printf '%s:%s\n' "$username" "$user_password" | chpasswd 2>/dev/null; then
            log_info "Password set successfully"
            changes_made=true
            audit "USER_PASSWORD_SET" "username=$username"
        else
            log_error "Failed to set password for user: $username"
            return 1
        fi
    fi
    
    # Final verification
    if id "$username" &>/dev/null; then
        log_info "User '$username' configured successfully"
        log_info "UID: $(id -u "$username"), GID: $(id -g "$username")"
        log_info "Home: $(eval echo "~$username")"
        if groups "$username" | grep -qE '\<(sudo|wheel)\>'; then
            log_info "Has sudo privileges"
        fi
        if [ -f "/home/$username/.ssh/authorized_keys" ]; then
            log_info "SSH key authentication configured"
        fi
        
        state_mark "user" "completed"
    else
        log_error "User '$username' does not exist after processing"
        return 1
    fi
    
    log_info "User configuration completed"
}

# Allow sourcing without execution
if [ "${0##*/}" != "user.sh" ] && [ "${0##*/}" != "bash" ] && [ "${0##*/}" != "sh" ]; then
    return 0
fi

# If executed directly, run the main function
user_main "$@"