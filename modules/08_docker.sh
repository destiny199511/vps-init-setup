#!/usr/bin/env bash
#
# Docker Module - Install and configure Docker Engine
#

docker_info() {
    echo "Install and configure Docker Engine with security best practices"
}

docker_prerequisites() {
    # Check if running in a container (nested Docker may not work well)
    if grep -q docker /proc/1/cgroup 2>/dev/null || grep -q docker /proc/self/cgroup 2>/dev/null; then
        log_warn "Running inside a container - Docker installation may not work as expected"
    fi
    return 0
}

DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

restore_docker_apt_repository() {
    local key_file="$1"
    local source_file="$2"
    local key_backup="$3"
    local source_backup="$4"
    local key_existed="$5"
    local source_existed="$6"

    if [ "$key_existed" = "true" ]; then
        cp -p "$key_backup" "$key_file"
    else
        rm -f "$key_file"
    fi
    if [ "$source_existed" = "true" ]; then
        cp -p "$source_backup" "$source_file"
    else
        rm -f "$source_file"
    fi
}

docker_configure_apt_repository() {
    local os_id keyring_dir key_file source_file key_tmp key_candidate source_candidate
    local key_backup="" source_backup="" key_existed=false source_existed=false
    local fingerprint expected_fingerprint codename architecture

    os_id="$(detect_os_id)"
    keyring_dir="${DOCKER_APT_KEYRING_DIR:-/etc/apt/keyrings}"
    key_file="${DOCKER_APT_KEY_FILE:-${keyring_dir}/docker.gpg}"
    source_file="${DOCKER_APT_SOURCE_FILE:-/etc/apt/sources.list.d/docker.list}"
    expected_fingerprint="${DOCKER_GPG_FINGERPRINT^^}"
    codename="$(lsb_release -cs)"
    architecture="$(dpkg --print-architecture)"

    mkdir -p "$keyring_dir" "$(dirname "$source_file")" || return 1
    if [ -f "$key_file" ]; then
        key_existed=true
        key_backup="$(mktemp "${keyring_dir}/.docker.gpg.backup.XXXXXX")" || return 1
        cp -p "$key_file" "$key_backup" || return 1
    fi
    if [ -f "$source_file" ]; then
        source_existed=true
        source_backup="$(mktemp "$(dirname "$source_file")/.docker.list.backup.XXXXXX")" || return 1
        cp -p "$source_file" "$source_backup" || return 1
    fi

    key_tmp="$(mktemp "${keyring_dir}/.docker.gpg.download.XXXXXX")" || return 1
    key_candidate="$(mktemp "${keyring_dir}/.docker.gpg.candidate.XXXXXX")" || {
        rm -f "$key_tmp" "$key_backup" "$source_backup"
        return 1
    }
    source_candidate="$(mktemp "$(dirname "$source_file")/.docker.list.candidate.XXXXXX")" || {
        rm -f "$key_tmp" "$key_candidate" "$key_backup" "$source_backup"
        return 1
    }

    if ! curl --connect-timeout 10 --max-time 60 --retry 2 --retry-all-errors -fsSL \
        "https://download.docker.com/linux/${os_id}/gpg" -o "$key_tmp"; then
        log_error "Failed to download Docker repository signing key"
        rm -f "$key_tmp" "$key_candidate" "$source_candidate" "$key_backup" "$source_backup"
        return 1
    fi
    fingerprint="$(gpg --batch --show-keys --with-colons "$key_tmp" 2>/dev/null | awk -F: '$1 == "fpr" {print toupper($10); exit}')"
    if [ "$fingerprint" != "$expected_fingerprint" ]; then
        log_error "Docker repository signing key fingerprint verification failed"
        rm -f "$key_tmp" "$key_candidate" "$source_candidate" "$key_backup" "$source_backup"
        return 1
    fi
    if ! gpg --batch --yes --dearmor --output "$key_candidate" "$key_tmp"; then
        log_error "Failed to convert verified Docker repository signing key"
        rm -f "$key_tmp" "$key_candidate" "$source_candidate" "$key_backup" "$source_backup"
        return 1
    fi
    printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' \
        "$architecture" "$key_file" "$os_id" "$codename" > "$source_candidate"
    if ! install -m 644 "$key_candidate" "$key_file" || ! install -m 644 "$source_candidate" "$source_file"; then
        log_error "Failed to install Docker APT repository files"
        restore_docker_apt_repository "$key_file" "$source_file" "$key_backup" "$source_backup" "$key_existed" "$source_existed"
        rm -f "$key_tmp" "$key_candidate" "$source_candidate" "$key_backup" "$source_backup"
        return 1
    fi
    if ! apt_update; then
        log_error "APT update failed after adding Docker repository; restoring previous repository files"
        restore_docker_apt_repository "$key_file" "$source_file" "$key_backup" "$source_backup" "$key_existed" "$source_existed"
        rm -f "$key_tmp" "$key_candidate" "$source_candidate" "$key_backup" "$source_backup"
        return 1
    fi
    rm -f "$key_tmp" "$key_candidate" "$source_candidate" "$key_backup" "$source_backup"
    return 0
}

docker_json_list() {
    local values="$1"
    local value trimmed first=true
    local -a entries

    IFS=',' read -ra entries <<< "$values"
    printf '['
    for value in "${entries[@]}"; do
        trimmed="$(echo "$value" | xargs)"
        [ -n "$trimmed" ] || continue
        if [[ ! "$trimmed" =~ ^[A-Za-z0-9._:/@+=-]+$ ]]; then
            log_error "Unsupported character in Docker list value: $trimmed"
            return 1
        fi
        if [ "$first" = false ]; then
            printf ', '
        fi
        printf '"%s"' "$trimmed"
        first=false
    done
    printf ']'
}

docker_json_log_options() {
    local values="$1"
    local value key setting first=true
    local -a entries

    IFS=',' read -ra entries <<< "$values"
    printf '{'
    for value in "${entries[@]}"; do
        setting="$(echo "$value" | xargs)"
        [ -n "$setting" ] || continue
        if [[ ! "$setting" =~ ^([A-Za-z][A-Za-z0-9_.-]*)=([A-Za-z0-9._:/@+=-]+)$ ]]; then
            log_error "Invalid Docker log option: $setting"
            return 1
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        if [ "$first" = false ]; then
            printf ', '
        fi
        printf '"%s": "%s"' "$key" "$value"
        first=false
    done
    printf '}'
}

docker_write_daemon_config() {
    local config_path="$1"
    local cgroup_driver="$2"
    local log_driver="$3"
    local log_opts="$4"
    local insecure_registries="$5"
    local registry_mirrors="$6"
    local live_restore="$7"
    local log_opts_json insecure_registries_json registry_mirrors_json candidate

    case "$cgroup_driver" in
        systemd|cgroupfs) ;;
        *)
            log_error "Unsupported Docker cgroup driver: $cgroup_driver"
            return 1
            ;;
    esac
    case "$log_driver" in
        json-file|local|journald|syslog|gelf|fluentd|awslogs|splunk|gcplogs|none) ;;
        *)
            log_error "Unsupported Docker log driver: $log_driver"
            return 1
            ;;
    esac
    case "$live_restore" in
        true|false) ;;
        *)
            log_error "Docker live-restore must be true or false"
            return 1
            ;;
    esac
    if ! log_opts_json="$(docker_json_log_options "$log_opts")" || \
       ! insecure_registries_json="$(docker_json_list "$insecure_registries")" || \
       ! registry_mirrors_json="$(docker_json_list "$registry_mirrors")"; then
        return 1
    fi

    mkdir -p "$(dirname "$config_path")"
    candidate="$(mktemp "$(dirname "$config_path")/.daemon.json.XXXXXX")"
    {
        echo "{"
        echo "  \"log-driver\": \"$log_driver\","
        echo "  \"log-opts\": $log_opts_json,"
        echo "  \"storage-driver\": \"overlay2\","
        echo "  \"insecure-registries\": $insecure_registries_json,"
        echo "  \"registry-mirrors\": $registry_mirrors_json,"
        echo "  \"live-restore\": $live_restore,"
        echo "  \"userland-proxy\": false,"
        echo "  \"exec-opts\": [\"native.cgroupdriver=$cgroup_driver\"]"
        echo "}"
    } > "$candidate"
    chmod 600 "$candidate"

    if ! dockerd --validate --config-file "$candidate" >/dev/null 2>&1; then
        log_error "Generated Docker configuration failed dockerd validation"
        rm -f "$candidate"
        return 1
    fi
    mv -f "$candidate" "$config_path"
}

docker_install_nodejs_npm() {
    log_info "Installing Node.js and npm..."
    case "$(detect_package_manager)" in
        apt|deb)
            install_package nodejs npm || install_package nodejs
            ;;
        yum|dnf|rpm)
            install_package nodejs npm || install_package nodejs
            ;;
        apk)
            install_package nodejs npm
            ;;
        pacman)
            install_package nodejs npm
            ;;
        *)
            log_warn "Unsupported package manager for automatic Node.js/npm installation"
            return 0
            ;;
    esac
    if command -v node >/dev/null 2>&1 || command -v npm >/dev/null 2>&1; then
        log_info "Node.js/npm installed: node $(node -v 2>/dev/null || echo 'N/A'), npm $(npm -v 2>/dev/null || echo 'N/A')"
        audit "NODEJS_NPM_INSTALLED" "node=$(node -v 2>/dev/null || echo 'N/A') npm=$(npm -v 2>/dev/null || echo 'N/A')"
    fi
}

docker_main() {
    local install_docker="${INSTALL_DOCKER:-true}"
    local install_npm="${INSTALL_NPM:-false}"

    # If Node.js/npm is requested, install it
    if [ "$install_npm" = "true" ] || [ "$install_npm" = "yes" ]; then
        docker_install_nodejs_npm
    fi

    # Check if Docker installation was requested
    if [ "$install_docker" != "true" ] && [ "$install_docker" != "yes" ]; then
        log_info "Docker installation skipped by configuration (INSTALL_DOCKER=$install_docker)"
        state_mark "docker" "completed"
        return 0
    fi

    log_info "Starting Docker installation and configuration..."
    
    # Check if Docker is already installed
    local docker_version
    if docker_version=$(docker --version 2>/dev/null); then
        log_info "Docker already installed: $docker_version"
        
        # Check if daemon is running
        if docker info >/dev/null 2>&1; then
            log_info "Docker daemon is running"
        else
            log_warn "Docker installed but daemon not running - attempting to start"
            systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
        fi
        
        # Already installed and running: skip reinstall unless forced.
        if [ "${FORCE:-false}" != "true" ] && [ "${FORCE_MODE:-false}" != "true" ]; then
            if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
                log_info "Docker already installed and running - skipping reinstall"
                state_mark "docker" "completed"
                return 0
            else
                read -r -p "Docker already installed. Reconfigure/upgrade? [y/N] " choice
                case "$choice" in
                    y|Y|yes|Yes) ;;
                    *)
                        log_info "Skipping Docker installation"
                        state_mark "docker" "completed"
                        return 0
                        ;;
                esac
            fi
        fi
    else
        log_info "Docker not found - will install"
    fi
    
    # Backup existing Docker config if present
    local docker_backup
    if [ -d /etc/docker ]; then
        docker_backup=$(backup_file "/etc/docker/daemon.json") || true
        docker_backup=$(backup_file "/etc/docker") || true
    fi
    
    # Determine installation method
    local install_method
    
    case "$(detect_os_id)" in
        ubuntu|debian)
            install_method="apt"
            ;;
        centos|rhel|rocky|almalinux)
            install_method="yum"
            ;;
        fedora)
            install_method="dnf"
            ;;
        alpine)
            install_method="apk"
            ;;
        arch)
            install_method="pacman"
            ;;
        *)
            log_error "Unsupported distribution for production Docker installation: $(detect_os_id)"
            log_error "Install Docker from a verified distribution repository, then rerun this module to configure it"
            return 1
            ;;
    esac
    
    # Override for non-interactive if specified
    if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
        install_method="${DOCKER_INSTALL_METHOD:-$install_method}"
    fi

    # Map "official" to the distro-native package installation method
    if [ "$install_method" = "official" ] || [ -z "$install_method" ]; then
        case "$(detect_os_id)" in
            ubuntu|debian)
                install_method="apt"
                ;;
            centos|rhel|rocky|almalinux)
                install_method="yum"
                ;;
            fedora)
                install_method="dnf"
                ;;
            alpine)
                install_method="apk"
                ;;
            arch)
                install_method="pacman"
                ;;
            *)
                install_method="apt"
                ;;
        esac
    fi
    
    local changes_made=false
    
    # Install Docker based on method
    case "$install_method" in
        apt)
            log_info "Installing Docker via APT repository..."
            
            # Install prerequisites
            install_package ca-certificates curl gnupg lsb-release
            
                        docker_configure_apt_repository || return 1
            
            # Install Docker Engine
            install_package docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            
            changes_made=true
            ;;
            
        yum)
            log_info "Installing Docker via YUM repository..."
            
            # Install required packages
            install_package yum-utils
            
            # Set up the repository
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            
            # Install Docker Engine
            install_package docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            
            changes_made=true
            ;;
            
        dnf)
            log_info "Installing Docker via DNF repository..."
            
            # Install required packages
            install_package dnf-plugins-core
            
            # Set up the repository
            dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            
            # Install Docker Engine
            install_package docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            
            changes_made=true
            ;;
            
        apk)
            log_info "Installing Docker via APK..."
            
            # Install Docker
            install_package docker docker-cli docker-buildx docker-compose
            
            changes_made=true
            ;;
            
        pacman)
            log_info "Installing Docker via Pacman..."
            
            # Install Docker
            install_package docker
            
            changes_made=true
            ;;
            
        *)
            log_error "Unsupported Docker installation method: $install_method"
            return 1
            ;;
    esac
    
    # Start and enable Docker service
    if [ "$changes_made" = "true" ] || [ "${FORCE_CONFIGURE:-false}" = "true" ]; then
        log_info "Starting and enabling Docker service..."
        
        systemctl enable --now docker 2>/dev/null || \
            service docker enable && service docker start 2>/dev/null || \
            update-rc.d docker defaults && service docker start 2>/dev/null || true
        
        # Verify Docker is working
        sleep 3
        if ! docker info >/dev/null 2>&1; then
            log_error "Docker installed but daemon not responding"
            # Try to get logs
            journalctl -u docker --no-pager -n 20 2>/dev/null || true
            return 1
        fi
        
        log_info "Docker installed and running successfully"
        
        # Show version
        docker_version=$(docker --version)
        log_info "Docker version: $docker_version"
    fi
    
    # Configure Docker daemon
    log_info "Configuring Docker daemon..."
    
    # Determine daemon configuration
    local cgroup_driver log_driver log_opts
    
    if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
        cgroup_driver="${DOCKER_CGROUP_DRIVER:-systemd}"
        log_driver="${DOCKER_LOG_DRIVER:-json-file}"
        log_opts="${DOCKER_LOG_OPTS:-max-size=100m,max-file=3}"
        insecure_registries="${DOCKER_INSECURE_REGISTRIES:-}"
        registry_mirrors="${DOCKER_REGISTRY_MIRRORS:-}"
        live_restore="${DOCKER_LIVE_RESTORE:-true}"
    else
        echo "Docker Daemon Configuration:"
        echo "---------------------------"
        
        # Cgroup driver
        echo "Cgroup driver options: systemd, cgroupfs"
        printf '\033[1;33m'
        read -r -p "Cgroup driver [systemd]: " choice
        printf '\033[0m\n'
        [ -z "$choice" ] && choice="systemd"
        cgroup_driver="$choice"
        
        # Log driver
        echo "Log driver options: json-file, syslog, journald, gelf, fluentd, awslogs, splunk, etwlogs, gcplogs, none"
        read -r -p "Log driver [json-file]: " choice
        [ -z "$choice" ] && choice="json-file"
        log_driver="$choice"
        
        if [ "$log_driver" = "json-file" ] || [ "$log_driver" = "gelf" ] || [ "$log_driver" = "fluentd" ] || [ "$log_driver" = "awslogs" ] || [ "$log_driver" = "splunk" ] || [ "$log_driver" = "etwlogs" ] || [ "$log_driver" = "gcplogs" ]; then
            read -r -p "Log options [max-size=100m,max-file=3]: " choice
            [ -z "$choice" ] && choice="max-size=100m,max-file=3"
            log_opts="$choice"
        fi
        
        # Insecure registries
        read -r -p "Insecure registries (comma-separated) [none]: " choice
        [ -z "$choice" ] && choice=""
        insecure_registries="$choice"
        
        # Registry mirrors
        read -r -p "Registry mirrors (comma-separated) [none]: " choice
        [ -z "$choice" ] && choice=""
        registry_mirrors="$choice"
        
        # Live restore
        read -r -p "Enable live restore? [Y/n]: " choice
        case "$choice" in
            n|N|no|NO) live_restore=false ;;
            *) live_restore=true ;;
        esac
    fi
    
    local daemon_config="/etc/docker/daemon.json"
    local daemon_config_backup=""
    local daemon_config_existed=false
    if [ -f "$daemon_config" ]; then
        daemon_config_existed=true
        daemon_config_backup="$(mktemp)"
        cp -p "$daemon_config" "$daemon_config_backup"
    fi
    if ! docker_write_daemon_config "$daemon_config" "$cgroup_driver" "$log_driver" "$log_opts" \
        "$insecure_registries" "$registry_mirrors" "$live_restore"; then
        rm -f "$daemon_config_backup"
        return 1
    fi
    
    # Restart Docker to apply configuration
    log_info "Restarting Docker daemon to apply configuration..."
    if ! systemctl reload-or-restart docker 2>/dev/null && ! service docker restart 2>/dev/null; then
        log_error "Docker restart failed after configuration update"
        if [ "$daemon_config_existed" = "true" ]; then
            cp -p "$daemon_config_backup" "$daemon_config"
        else
            rm -f "$daemon_config"
        fi
        systemctl restart docker 2>/dev/null || service docker restart 2>/dev/null || true
        rm -f "$daemon_config_backup"
        return 1
    fi
    rm -f "$daemon_config_backup"
    
    # Verify configuration is applied
    sleep 2
    if docker info >/dev/null 2>&1; then
        log_info "Docker daemon configured successfully"
        changes_made=true
        audit "DOCKER_CONFIGURED" "version=$(docker --version | cut -d' ' -f3) cgroup_driver=$cgroup_driver log_driver=$log_driver"
    else
        log_error "Docker daemon did not become ready after configuration update"
        systemctl status docker 2>/dev/null || service docker status 2>/dev/null || true
        return 1
    fi
    
    # Add user to docker group (requires explicit opt-in via DOCKER_ADD_USER=true)
    local docker_target_user="${DOCKER_USER:-${SUDO_USER:-${USERNAME:-}}}"
    if [ -n "$docker_target_user" ] && [ "$docker_target_user" != "root" ] && id "$docker_target_user" &>/dev/null; then
        if [ "${DOCKER_ADD_USER:-false}" = "true" ]; then
            log_warn "SECURITY WARNING: Adding user '$docker_target_user' to the docker group is equivalent to granting root permissions!"
            if ! groups "$docker_target_user" 2>/dev/null | grep -q '\bdocker\b'; then
                log_info "Adding user $docker_target_user to docker group"
                usermod -aG docker "$docker_target_user"
                log_info "User $docker_target_user added to docker group (will take effect after relogin)"
                changes_made=true
            fi
        else
            log_info "Skipping adding '$docker_target_user' to docker group to avoid privilege escalation (set DOCKER_ADD_USER=true to allow)"
        fi
    fi
    
    # Test Docker with a simple container
    log_info "Testing Docker installation..."
    if docker run --rm hello-world >/dev/null 2>&1; then
        log_info "Docker installation verified successfully"
    else
        log_warn "Docker test container failed - this might be OK if network is limited"
        # Don't fail the whole module for this
    fi
    
    # Mark completion
    if [ "$changes_made" = "true" ]; then
        state_mark "docker" "completed"
    else
        state_mark "docker" "completed"  # Already installed and configured
    fi
    
    log_info "Docker installation and configuration completed"
}

# Allow sourcing without execution
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

# If executed directly, run the main function
docker_main "$@"