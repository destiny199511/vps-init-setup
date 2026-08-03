#!/bin/sh
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

docker_main() {
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
        
        # In non-interactive mode, we might still want to configure
        if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
            # Still need to ensure configuration is applied
            :
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
    
    case "$(detect_os)" in
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
            log_warn "Unsupported distribution for automated Docker install: $(detect_os)"
            log_info "Will attempt to use convenience script (less secure)"
            install_method="script"
            ;;
    esac
    
    # Override for non-interactive if specified
    if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
        install_method="${DOCKER_INSTALL_METHOD:-$install_method}"
    fi
    
    local changes_made=false
    
    # Install Docker based on method
    case "$install_method" in
        apt)
            log_info "Installing Docker via APT repository..."
            
            # Install prerequisites
            install_package ca-certificates curl gnupg lsb-release
            
            # Add Docker's official GPG key
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$(detect_os)/gpg | \
                gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            
            # Set up the repository
            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(detect_os) \
              $(lsb_release -cs) stable" | \
                tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # Update package index
            apt_update
            
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
            
        script)
            log_warn "Using Docker convenience script (less secure - not recommended for production)"
            log_warn "For production, consider manual repository installation"
            
            if [ "${NON_INTERACTIVE:-false}" = "false" ]; then
                printf '\033[1;33m'
                read -r -p "Continue with convenience script installation? [y/N] " choice
                printf '\033[0m\n'
                case "$choice" in
                    y|Y|yes|Yes) ;;
                    *) 
                        log_info "Docker installation cancelled"
                        return 0
                        ;;
                esac
            fi
            
            # Download and run the convenience script
            curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
            sh /tmp/get-docker.sh
            rm -f /tmp/get-docker.sh
            
            changes_made=true
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
    
    # Create daemon.json
    {
        echo "{"
        echo "  \"log-driver\": \"$log_driver\","
        if [ "$log_driver" != "none" ] && [ -n "$log_opts" ]; then
            echo "  \"log-opts\": { $log_opts },"
        fi
        echo "  \"storage-driver\": \"overlay2\","
        echo "  \"insecure-registries\": [ $(echo "$insecure_registries" | tr ',' ',' | sed 's/,$//' | sed 's/^,$//' | awk -v RS='[^,]+' '{gsub(/^[ \t]+|[ \t]+$/, ""); printf "%s\"%s\"", sep, $0; sep=", "} END {if (sep=="") print ""; else print substr(sep, 1, length(sep)-2)}') ],"
        echo "  \"registry-mirrors\": [ $(echo "$registry_mirrors" | tr ',' ',' | sed 's/,$//' | sed 's/^,$//' | awk -v RS='[^,]+' '{gsub(/^[ \t]+|[ \t]+$/, ""); printf "%s\"%s\"", sep, $0; sep=", "} END {if (sep=="") print ""; else print substr(sep, 1, length(sep)-2)}') ],"
        echo "  \"live-restore\": $(if [ "$live_restore" = "true" ]; then echo "true"; else echo "false"; fi),"
        echo "  \"userland-proxy\": false,"
        echo "  \"no-new-privileges\": true,"
        echo "  \"cgroup-driver\": \"$cgroup_driver\""
        echo "}"
    } > /etc/docker/daemon.json
    
    # Restart Docker to apply configuration
    log_info "Restarting Docker daemon to apply configuration..."
    systemctl reload-or-restart docker 2>/dev/null || service docker restart 2>/dev/null || true
    
    # Verify configuration is applied
    sleep 2
    if docker info >/dev/null 2>&1; then
        log_info "Docker daemon configured successfully"
        changes_made=true
        audit "DOCKER_CONFIGURED" "version=$(docker --version | cut -d' ' -f3) cgroup_driver=$cgroup_driver log_driver=$log_driver"
    else
        log_warn "Docker daemon restart issue - checking status"
        systemctl status docker 2>/dev/null || service docker status 2>/dev/null || true
    fi
    
    # Add current user to docker group (if not root and user specified)
    if [ "$(id -u)" -ne 0 ] && [ -n "${SUDO_USER:-}" ]; then
        local docker_user="${SUDO_USER}"
        if ! groups "$docker_user" | grep -q '\bdocker\b'; then
            log_info "Adding user $docker_user to docker group"
            usermod -aG docker "$docker_user"
            log_info "User $docker_user added to docker group (will take effect after relogin)"
            changes_made=true
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
if [ "${0##*/}" != "docker.sh" ] && [ "${0##*/}" != "bash" ] && [ "${0##*/}" != "sh" ]; then
    return 0
fi

# If executed directly, run the main function
docker_main "$@"