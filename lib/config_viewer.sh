#!/bin/bash
#===============================================================================
# VPS Setup — 常用系统配置查看模块 (lib/config_viewer.sh)
# 支持查看: 用户/Sudo、SSH、防火墙与端口、Docker、备份、监控、系统优化与内核
#===============================================================================

# 确保核心依赖已加载
if [ -z "${TUI_CYAN:-}" ]; then
    CYAN='\033[0;36m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
fi

# ==============================================================================
# 1. 用户与权限配置查看 (User, Sudo & SSH Keys)
# ==============================================================================
view_config_user() {
    local target_user="${1:-${USERNAME:-appadmin}}"
    print_section "$(t '用户与权限配置 / User & Permission Configuration')"
    
    print_kv "$(t '目标用户名:')" "$target_user"
    
    if id "$target_user" >/dev/null 2>&1; then
        local uid gid groups_list shell_path home_dir
        uid=$(id -u "$target_user")
        gid=$(id -g "$target_user")
        groups_list=$(id -nG "$target_user" 2>/dev/null | tr ' ' ', ')
        shell_path=$(getent passwd "$target_user" | cut -d: -f7)
        home_dir=$(getent passwd "$target_user" | cut -d: -f6)
        
        print_kv "$(t '账号状态:')" "${GREEN}$(t '已存在')${NC} (UID=$uid, GID=$gid)"
        print_kv "$(t '用户附加组:')" "$groups_list"
        print_kv "$(t '登录 Shell:')" "$shell_path"
        
        # 家目录权限
        if [ -d "$home_dir" ]; then
            local home_perm home_owner
            home_perm=$(stat -c '%a' "$home_dir" 2>/dev/null || stat -f '%p' "$home_dir" 2>/dev/null || echo "unknown")
            home_owner=$(stat -c '%U:%G' "$home_dir" 2>/dev/null || echo "unknown")
            print_kv "$(t '用户主目录:')" "$home_dir ($home_owner, $home_perm)"
        else
            print_kv "$(t '用户主目录:')" "${YELLOW}$home_dir ($(t '目录不存在'))${NC}"
        fi
        
        # Sudo 权限检查
        local sudoers_file="/etc/sudoers.d/$target_user"
        local alt_sudoers="/etc/sudoers.d/99-vps-setup-$target_user"
        local sudo_status="无独立配置"
        if [ -f "$sudoers_file" ]; then
            if grep -qi "NOPASSWD" "$sudoers_file" 2>/dev/null; then
                sudo_status="${YELLOW}NOPASSWD:ALL ($(t '免密 Root 特权'))${NC}"
            else
                sudo_status="${GREEN}ALL=(ALL) ALL ($(t '需密码验证'))${NC}"
            fi
        elif [ -f "$alt_sudoers" ]; then
            if grep -qi "NOPASSWD" "$alt_sudoers" 2>/dev/null; then
                sudo_status="${YELLOW}NOPASSWD:ALL ($(t '免密 Root 特权'))${NC}"
            else
                sudo_status="${GREEN}ALL=(ALL) ALL ($(t '需密码验证'))${NC}"
            fi
        elif groups "$target_user" 2>/dev/null | grep -qE '\<(sudo|wheel)\>'; then
            sudo_status="${GREEN}$(t '属于系统 sudo/wheel 组')${NC}"
        else
            sudo_status="${DIM}$(t '未分配 sudo 特权')${NC}"
        fi
        print_kv "$(t 'Sudo 提权规则:')" "$sudo_status"
        
        # 密码状态
        local pass_status
        if command -v passwd >/dev/null 2>&1 && [ "${EUID:-$(id -u)}" -eq 0 ]; then
            local p_info
            p_info=$(passwd -S "$target_user" 2>/dev/null | awk '{print $2}' || true)
            case "$p_info" in
                P) pass_status="${GREEN}$(t '已设定可用密码')${NC}" ;;
                L) pass_status="${YELLOW}$(t '已锁定 (Locked)')${NC}" ;;
                NP) pass_status="${RED}$(t '无密码 (No Password)')${NC}" ;;
                *) pass_status="${DIM}${p_info:-未知}${NC}" ;;
            esac
        else
            pass_status="${DIM}$(t '需 root 权限查询')${NC}"
        fi
        print_kv "$(t '密码认证状态:')" "$pass_status"
        
        # SSH authorized_keys 公钥状态
        local auth_keys="$home_dir/.ssh/authorized_keys"
        if [ -f "$auth_keys" ] && [ -s "$auth_keys" ]; then
            local key_count
            key_count=$(grep -cE '^(ssh-|ecdsa-sha2-|sk-)' "$auth_keys" 2>/dev/null || echo 0)
            print_kv "$(t 'SSH 授权公钥:')" "${GREEN}${key_count} $(t '个有效公钥')${NC} ($auth_keys)"
            if command -v ssh-keygen >/dev/null 2>&1; then
                while read -r line; do
                    [ -n "$line" ] && echo -e "  \033[1;36m│\033[0m   ${DIM}▸ ${line}${NC}"
                done < <(ssh-keygen -lf "$auth_keys" 2>/dev/null || true)
            fi
        else
            print_kv "$(t 'SSH 授权公钥:')" "${YELLOW}$(t '未配置任何公钥')${NC}"
        fi
    else
        print_kv "$(t '账号状态:')" "${RED}$(t '用户在系统中不存在')${NC}"
    fi
    echo -e "  \033[1;36m╰──────────────────────────────────────────────────────────\033[0m"
}

# ==============================================================================
# 2. SSH 服务与安全配置查看 (SSH Service & Security)
# ==============================================================================
view_config_ssh() {
    print_section "$(t 'SSH 服务与安全配置 / SSH Service & Security')"
    
    # 服务状态
    local ssh_svc="ssh"
    if systemctl list-unit-files >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
        ssh_svc="sshd"
    fi
    local svc_active="inactive"
    if systemctl is-active --quiet "$ssh_svc" >/dev/null 2>&1 || service "$ssh_svc" status >/dev/null 2>&1; then
        svc_active="${GREEN}$(t '运行中 (active)')${NC}"
    else
        svc_active="${RED}$(t '未运行 (inactive)')${NC}"
    fi
    print_kv "$(t 'SSH 服务守护:')" "$ssh_svc ($svc_active)"
    
    # 监听端口
    local live_ports
    live_ports=$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':[0-9]+$' | sed 's/.*://' | sort -un | tr '\n' ' ' || true)
    local ssh_live_ports=""
    for p in $(grep -E '^[# ]*Port ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | sort -un); do
        if [[ " $live_ports " =~ [[:space:]]"$p"[[:space:]] ]]; then
            ssh_live_ports="${ssh_live_ports}${GREEN}${p}(监听中)${NC} "
        else
            ssh_live_ports="${ssh_live_ports}${YELLOW}${p}(配置未生效)${NC} "
        fi
    done
    [ -z "$ssh_live_ports" ] && ssh_live_ports="${DIM}22(默认)${NC}"
    print_kv "$(t 'SSH 监听端口:')" "$ssh_live_ports"
    
    # 解析核心安全策略
    local permit_root="" pass_auth="" pubkey_auth="" max_tries="" client_alive="" legacy_rsa="已禁用"
    if command -v sshd >/dev/null 2>&1; then
        local sshd_t_eval
        sshd_t_eval=$(sshd -T 2>/dev/null || true)
        if [ -n "$sshd_t_eval" ]; then
            permit_root=$(echo "$sshd_t_eval" | grep -i '^permitrootlogin ' | awk '{print $2}')
            pass_auth=$(echo "$sshd_t_eval" | grep -i '^passwordauthentication ' | awk '{print $2}')
            pubkey_auth=$(echo "$sshd_t_eval" | grep -i '^pubkeyauthentication ' | awk '{print $2}')
            max_tries=$(echo "$sshd_t_eval" | grep -i '^maxauthtries ' | awk '{print $2}')
            local c_int c_max
            c_int=$(echo "$sshd_t_eval" | grep -i '^clientaliveinterval ' | awk '{print $2}')
            c_max=$(echo "$sshd_t_eval" | grep -i '^clientalivecountmax ' | awk '{print $2}')
            client_alive="${c_int}s / ${c_max}次"
            if echo "$sshd_t_eval" | grep -i '^pubkeyacceptedalgorithms ' | grep -q 'ssh-rsa'; then
                legacy_rsa="${YELLOW}开启 (+ssh-rsa)${NC}"
            else
                legacy_rsa="${GREEN}禁用 (安全SHA-2/ed25519)${NC}"
            fi
        fi
    fi

    # 若未获取到 sshd -T 输出（非 root 运行），从 sshd_config 解析配置回退
    if [ -z "$permit_root" ]; then
        permit_root=$(grep -E -i '^[# ]*PermitRootLogin ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tail -1 | awk '{print $2}' || true)
        [ -z "$permit_root" ] && permit_root="prohibit-password(默认)"
    fi
    if [ -z "$pass_auth" ]; then
        pass_auth=$(grep -E -i '^[# ]*PasswordAuthentication ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tail -1 | awk '{print $2}' || true)
        [ -z "$pass_auth" ] && pass_auth="yes(默认)"
    fi
    if [ -z "$pubkey_auth" ]; then
        pubkey_auth=$(grep -E -i '^[# ]*PubkeyAuthentication ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tail -1 | awk '{print $2}' || true)
        [ -z "$pubkey_auth" ] && pubkey_auth="yes(默认)"
    fi
    if [ -z "$max_tries" ]; then
        max_tries=$(grep -E -i '^[# ]*MaxAuthTries ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tail -1 | awk '{print $2}' || true)
        [ -z "$max_tries" ] && max_tries="6(默认)"
    fi
    if [ -z "$client_alive" ]; then
        local cf_int cf_max
        cf_int=$(grep -E -i '^[# ]*ClientAliveInterval ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tail -1 | awk '{print $2}' || true)
        cf_max=$(grep -E -i '^[# ]*ClientAliveCountMax ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tail -1 | awk '{print $2}' || true)
        if [ -n "$cf_int" ]; then
            client_alive="${cf_int}s / ${cf_max:-3}次"
        else
            client_alive="0s(未设置)"
        fi
    fi
    
    local root_color="${GREEN}"
    [ "$permit_root" = "yes" ] && root_color="${RED}"
    print_kv "$(t 'Root 远程登录:')" "${root_color}${permit_root}${NC}"
    
    local pass_color="${GREEN}"
    [ "$pass_auth" = "yes" ] && pass_color="${YELLOW}"
    print_kv "$(t '密码认证登录:')" "${pass_color}${pass_auth}${NC}"
    
    print_kv "$(t '公钥认证登录:')" "${GREEN}${pubkey_auth}${NC}"
    print_kv "$(t '最大重试限制:')" "${max_tries}"
    print_kv "$(t '空闲超时断开:')" "${client_alive}"
    print_kv "$(t '弱公钥签名算法:')" "${legacy_rsa}"
    
    # 语法健康度
    if command -v sshd >/dev/null 2>&1; then
        if sshd -t >/dev/null 2>&1; then
            print_kv "$(t 'sshd 配置语法:')" "${GREEN}✔ $(t '语法检测正常')${NC}"
        else
            print_kv "$(t 'sshd 配置语法:')" "${RED}✖ $(t '配置存在语法错误')${NC}"
        fi
    fi
    echo -e "  \033[1;36m╰──────────────────────────────────────────────────────────\033[0m"
}

# ==============================================================================
# 3. 防火墙与网络开放端口 (Firewall & Open Ports)
# ==============================================================================
view_config_firewall() {
    print_section "$(t '防火墙与开放端口 / Firewall & Network Ports')"
    
    local fw_type="none" fw_status="${RED}$(t '未启用')${NC}"
    if command -v ufw >/dev/null 2>&1; then
        fw_type="UFW"
        if ufw status 2>/dev/null | grep -qi "status: active"; then
            fw_status="${GREEN}$(t '已激活 (active)')${NC}"
        else
            fw_status="${YELLOW}$(t '未激活 (inactive)')${NC}"
        fi
    elif command -v firewall-cmd >/dev/null 2>&1; then
        fw_type="Firewalld"
        if firewall-cmd --state >/dev/null 2>&1; then
            fw_status="${GREEN}$(t '已激活 (running)')${NC}"
        else
            fw_status="${YELLOW}$(t '未激活 (not running)')${NC}"
        fi
    elif command -v nft >/dev/null 2>&1 && nft list tables 2>/dev/null | grep -q .; then
        fw_type="nftables"
        fw_status="${GREEN}$(t '已激活 (active rules)')${NC}"
    elif command -v iptables >/dev/null 2>&1; then
        fw_type="iptables"
        if iptables -S 2>/dev/null | grep -q '^-A'; then
            fw_status="${GREEN}$(t '已加载规则 (active rules)')${NC}"
        else
            fw_status="${YELLOW}$(t '无自定义规则')${NC}"
        fi
    fi
    print_kv "$(t '防火墙引擎:')" "$fw_type"
    print_kv "$(t '防火墙状态:')" "$fw_status"
    
    # 默认策略与规则概要
    if [ "$fw_type" = "UFW" ]; then
        local ufw_in ufw_out
        ufw_in=$(ufw status verbose 2>/dev/null | grep -i "Default:" | awk '{print $2}' || true)
        ufw_out=$(ufw status verbose 2>/dev/null | grep -i "Default:" | awk '{print $4}' || true)
        [ -n "$ufw_in" ] && print_kv "$(t '默认出入站策略:')" "Incoming: $ufw_in, Outgoing: $ufw_out"
    elif [ "$fw_type" = "Firewalld" ] && firewall-cmd --state >/dev/null 2>&1; then
        local def_zone
        def_zone=$(firewall-cmd --get-default-zone 2>/dev/null || true)
        [ -n "$def_zone" ] && print_kv "$(t '默认区域 (Zone):')" "$def_zone"
    elif [ "$fw_type" = "iptables" ]; then
        local ipt_in
        ipt_in=$(iptables -S INPUT 2>/dev/null | head -n1 | sed 's/-P INPUT //' || true)
        [ -n "$ipt_in" ] && print_kv "$(t 'INPUT 默认策略:')" "$ipt_in"
    fi
    
    # 开放的防火墙规则概要
    if [ "$fw_type" = "UFW" ] && ufw status 2>/dev/null | grep -qi "status: active"; then
        echo -e "  \033[1;36m│\033[0m  ${CYAN}$(t 'UFW 放行规则列表:')${NC}"
        while read -r rule; do
            [ -n "$rule" ] && echo -e "  \033[1;36m│\033[0m   ${DIM}▸ ${rule}${NC}"
        done < <(ufw status numbered 2>/dev/null | grep -E '\[ *[0-9]+\]' || true)
    fi
    
    # 系统实际监听端口列表
    echo -e "  \033[1;36m│\033[0m  ${CYAN}$(t '系统当前对外监听网络端口 (ss -tulpn):')${NC}"
    while read -r proto port proc; do
        if [ -n "$port" ]; then
            printf "  \033[1;36m│\033[0m   ${GREEN}●${NC} \033[1;37m%-6s\033[0m \033[38;5;51m%-18s\033[0m ${DIM}%s${NC}\n" "$proto" "$port" "$proc"
        fi
    done < <(ss -tulnpH 2>/dev/null | awk '{
        proto = $1
        local_addr = $5
        proc = $7
        sub(/^users:\(\("/, "", proc)
        sub(/".*$/, "", proc)
        print proto, local_addr, proc
    }' | sort -u || true)
    
    echo -e "  \033[1;36m╰──────────────────────────────────────────────────────────\033[0m"
}

# ==============================================================================
# 4. Docker 容器配置查看 (Docker Daemon & Configuration)
# ==============================================================================
view_config_docker() {
    print_section "$(t 'Docker 容器环境配置 / Docker Engine & Runtime')"
    
    if ! command -v docker >/dev/null 2>&1; then
        print_kv "$(t 'Docker 引擎状态:')" "${YELLOW}$(t '未安装 Docker')${NC}"
        echo -e "  \033[1;36m╰──────────────────────────────────────────────────────────\033[0m"
        return 0
    fi
    
    local d_active
    if systemctl is-active --quiet docker >/dev/null 2>&1 || service docker status >/dev/null 2>&1; then
        d_active="${GREEN}$(t '运行中 (active)')${NC}"
    else
        d_active="${RED}$(t '未运行 (inactive)')${NC}"
    fi
    print_kv "$(t 'Docker 服务状态:')" "$d_active"
    
    local d_version compose_version
    d_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || docker --version | awk '{print $3}' | tr -d ',' || echo "unknown")
    compose_version=$(docker compose version 2>/dev/null | awk '{print $4}' || echo "not installed")
    print_kv "$(t 'Docker Engine 版本:')" "$d_version"
    print_kv "$(t 'Docker Compose 版本:')" "$compose_version"
    
    # 守护进程配置 /etc/docker/daemon.json
    local daemon_json="/etc/docker/daemon.json"
    if [ -f "$daemon_json" ]; then
        local log_driver cgroup_driver live_restore mirrors
        log_driver=$(grep -o '"log-driver": *"[^"]*"' "$daemon_json" | cut -d'"' -f4 || echo "default")
        cgroup_driver=$(grep -o '"exec-opts": *\[ *"native.cgroupdriver=[^"]*"' "$daemon_json" | cut -d'=' -f2 | tr -d '"] ' || echo "default")
        live_restore=$(grep -o '"live-restore": *[a-z]*' "$daemon_json" | awk '{print $2}' || echo "default")
        mirrors=$(grep -o '"registry-mirrors": *\[[^]]*\]' "$daemon_json" | tr -d '\n\t ' || echo "none")
        
        print_kv "$(t '日志驱动 (log-driver):')" "$log_driver"
        print_kv "$(t 'Cgroup 驱动:')" "${cgroup_driver:-cgroupfs}"
        print_kv "$(t '热重启 (live-restore):')" "$live_restore"
        print_kv "$(t '镜像加速器 (mirrors):')" "$mirrors"
    else
        print_kv "$(t 'daemon.json 配置:')" "${DIM}$(t '未配置 (采用官方默认值)')${NC}"
    fi
    
    # Docker 组权限
    local docker_members
    docker_members=$(getent group docker | cut -d: -f4 || true)
    if [ -n "$docker_members" ]; then
        print_kv "$(t 'Docker 用户组清单:')" "${YELLOW}$docker_members (${t '具备免密提权特性'})${NC}"
    else
        print_kv "$(t 'Docker 用户组清单:')" "${DIM}$(t '组内无普通用户 (安全)')${NC}"
    fi
    
    # 容器与镜像概要
    if docker info >/dev/null 2>&1; then
        local running_c total_c image_count
        running_c=$(docker ps -q 2>/dev/null | wc -l)
        total_c=$(docker ps -aq 2>/dev/null | wc -l)
        image_count=$(docker images -q 2>/dev/null | sort -u | wc -l)
        print_kv "$(t '容器运行总览:')" "${GREEN}${running_c} 运行中${NC} / 共 ${total_c} 个容器 (${image_count} 个本地镜像)"
    fi
    echo -e "  \033[1;36m╰──────────────────────────────────────────────────────────\033[0m"
}

# ==============================================================================
# 5. 系统定时备份配置查看 (Backup Tasks & Archives)
# ==============================================================================
view_config_backup() {
    print_section "$(t '系统备份任务配置 / System Backup & Archive Configuration')"
    
    local cron_job="/etc/cron.d/backup-system"
    local backup_script="/usr/local/sbin/backup-system.sh"
    
    if [ -f "$cron_job" ]; then
        local schedule
        schedule=$(grep -v '^#' "$cron_job" | head -1 | awk '{print $1,$2,$3,$4,$5}' || true)
        print_kv "$(t 'Cron 定时任务:')" "${GREEN}$(t '已启用')${NC} ($schedule)"
    else
        print_kv "$(t 'Cron 定时任务:')" "${YELLOW}$(t '未启用定时任务')${NC}"
    fi
    
    if [ -f "$backup_script" ]; then
        local script_perm
        script_perm=$(stat -c '%a' "$backup_script" 2>/dev/null || stat -f '%p' "$backup_script" 2>/dev/null || echo "unknown")
        print_kv "$(t '备份执行脚本:')" "${GREEN}已生成${NC} ($backup_script, 权限: $script_perm)"
        
        # 提取脚本中的策略配置
        local b_dir b_sources b_retention b_comp b_enc
        b_dir=$(grep '^BACKUP_DIR=' "$backup_script" | cut -d'"' -f2 || true)
        b_sources=$(grep '^SOURCES=' "$backup_script" | cut -d'"' -f2 || true)
        b_retention=$(grep '^RETENTION_DAYS=' "$backup_script" | cut -d'=' -f2 || true)
        b_comp=$(grep '^COMPRESSION=' "$backup_script" | cut -d'"' -f2 || true)
        b_enc=$(grep '^ENCRYPTION=' "$backup_script" | cut -d'"' -f2 || true)
        
        print_kv "$(t '备份存储目录:')" "$b_dir"
        print_kv "$(t '备份数据源路径:')" "$b_sources"
        print_kv "$(t '保留时间 (天):')" "${b_retention} 天"
        print_kv "$(t '压缩格式:')" "$b_comp"
        if [ "$b_enc" = "true" ]; then
            print_kv "$(t 'GPG 加密归档:')" "${GREEN}$(t '已启用加密')${NC}"
        else
            print_kv "$(t 'GPG 加密归档:')" "${YELLOW}$(t '未加密 (采用 0600 严格权限保护)')${NC}"
        fi
        
        # 统计已有备份文件
        if [ -d "$b_dir" ]; then
            local count total_size
            count=$(find "$b_dir" -maxdepth 1 -type f -name 'backup_*' 2>/dev/null | wc -l)
            total_size=$(du -sh "$b_dir" 2>/dev/null | awk '{print $1}' || echo "0")
            print_kv "$(t '已有历史归档:')" "${count} 个文件 (总占用: $total_size)"
        fi
    else
        print_kv "$(t '备份执行脚本:')" "${DIM}$(t '未配置备份脚本')${NC}"
    fi
    echo -e "  \033[1;36m╰──────────────────────────────────────────────────────────\033[0m"
}

# ==============================================================================
# 6. 系统监控配置查看 (Monitoring & Metrics)
# ==============================================================================
view_config_monitoring() {
    print_section "$(t '系统监控与指标探针 / System Monitoring & Probes')"
    
    # 基础排障工具
    local tools=("htop" "iotop" "iftop" "ncdu" "sysstat" "dstat")
    local installed_tools="" missing_tools=""
    for t in "${tools[@]}"; do
        if command -v "$t" >/dev/null 2>&1; then
            installed_tools="${installed_tools}${GREEN}$t${NC} "
        else
            missing_tools="${missing_tools}${DIM}$t${NC} "
        fi
    done
    print_kv "$(t '基础运维工具集:')" "$installed_tools"
    
    # Netdata
    local nd_status="${DIM}$(t '未安装')${NC}"
    if command -v netdata >/dev/null 2>&1; then
        if systemctl is-active --quiet netdata >/dev/null 2>&1 || service netdata status >/dev/null 2>&1; then
            local nd_bind="0.0.0.0"
            if grep -E '^[# ]*bind to =' /etc/netdata/netdata.conf 2>/dev/null | grep -q '127.0.0.1'; then
                nd_bind="127.0.0.1 (本地绑定，安全)"
            fi
            nd_status="${GREEN}$(t '运行中')${NC} [${nd_bind}:19999]"
        else
            nd_status="${YELLOW}$(t '已安装但未运行')${NC}"
        fi
    fi
    print_kv "$(t 'Netdata 性能面板:')" "$nd_status"
    
    # Prometheus Node Exporter
    local pne_status="${DIM}$(t '未安装')${NC}"
    local pne_svc="prometheus-node-exporter"
    if systemctl list-unit-files >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^node_exporter'; then
        pne_svc="node_exporter"
    fi
    
    if systemctl is-active --quiet "$pne_svc" >/dev/null 2>&1 || service "$pne_svc" status >/dev/null 2>&1; then
        local pne_bind="127.0.0.1"
        if ss -tlnp 2>/dev/null | grep -q '127.0.0.1:9100'; then
            pne_bind="127.0.0.1 (本地绑定，安全)"
        elif ss -tlnp 2>/dev/null | grep -q ':9100'; then
            pne_bind="${YELLOW}0.0.0.0:9100 (公网可达，需加固)${NC}"
        fi
        pne_status="${GREEN}$(t '运行中')${NC} [$pne_bind]"
    fi
    print_kv "$(t 'Node Exporter 探针:')" "$pne_status"
    
    # 实时系统指标快照
    local load_avg mem_usage disk_usage
    load_avg=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | sed 's/^ //' || echo "N/A")
    mem_usage=$(free -h 2>/dev/null | awk '/^Mem:/ {printf "%s / %s (已用 %s)", $3, $2, $3}' || echo "N/A")
    disk_usage=$(df -h / 2>/dev/null | awk 'NR==2 {printf "%s / %s (使用率 %s)", $3, $2, $5}' || echo "N/A")
    print_kv "$(t '当前系统负载:')" "$load_avg"
    print_kv "$(t '内存使用快照:')" "$mem_usage"
    print_kv "$(t '磁盘根分区使用:')" "$disk_usage"
    
    echo -e "  \033[1;36m╰──────────────────────────────────────────────────────────\033[0m"
}

# ==============================================================================
# 7. 系统优化与内核参数查看 (Optimization, Swap & Sysctl)
# ==============================================================================
view_config_optimization() {
    print_section "$(t '系统优化与内核调优 / System Optimization & Kernel')"
    
    # Swap 状态
    local swap_file="/swapfile"
    local swap_status="${DIM}$(t '未启用')${NC}"
    if swapon --show 2>/dev/null | grep -q '/'; then
        local swap_size
        swap_size=$(free -h 2>/dev/null | awk '/^Swap:/ {print $2}')
        local swappiness vfs_press
        swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "60")
        vfs_press=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo "100")
        swap_status="${GREEN}已激活 (${swap_size})${NC} [swappiness=${swappiness}, vfs_cache_pressure=${vfs_press}]"
    fi
    print_kv "$(t '虚拟内存 (Swap):')" "$swap_status"
    
    # BBR 拥塞控制
    local tcp_cc qdisc
    tcp_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "fq_codel")
    if [ "$tcp_cc" = "bbr" ]; then
        print_kv "$(t 'TCP 拥塞控制:')" "${GREEN}BBR (已激活)${NC} [qdisc: $qdisc]"
    else
        print_kv "$(t 'TCP 拥塞控制:')" "${YELLOW}$tcp_cc (未启用 BBR)${NC}"
    fi
    
    # 核心内核网络参数
    local ip_fwd syn_cookies fin_timeout somaxconn
    ip_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    syn_cookies=$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo "0")
    fin_timeout=$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null || echo "60")
    somaxconn=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "128")
    
    local fwd_label="${DIM}0 (禁用)${NC}"
    [ "$ip_fwd" = "1" ] && fwd_label="${GREEN}1 (已开启，支持容器转发)${NC}"
    print_kv "$(t 'IP 路由转发 (Forward):')" "$fwd_label"
    print_kv "$(t 'SYN Flood 防护:')" "$([ "$syn_cookies" = "1" ] && echo -e "${GREEN}开启 (tcp_syncookies=1)${NC}" || echo -e "${YELLOW}关闭${NC}")"
    print_kv "$(t 'TCP Fin 超时:')" "${fin_timeout}s"
    print_kv "$(t '最大连接队列 (somaxconn):')" "${somaxconn}"
    
    # 日志与 Snap
    local journal_size="N/A"
    if command -v journalctl >/dev/null 2>&1; then
        journal_size=$(journalctl --disk-usage 2>/dev/null | awk '{print $NF}' || echo "N/A")
    fi
    print_kv "$(t 'Journal 日志占用:')" "$journal_size"
    
    local snap_info="${DIM}$(t '未安装 Snap')${NC}"
    if command -v snap >/dev/null 2>&1; then
        local snap_c
        snap_c=$(snap list 2>/dev/null | wc -l || echo 0)
        snap_info="${YELLOW}$(t '已安装 Snap')${NC} ($snap_c 个包)"
    fi
    print_kv "$(t 'Snap 包管理状态:')" "$snap_info"
    
    echo -e "  \033[1;36m╰──────────────────────────────────────────────────────────\033[0m"
}

# ==============================================================================
# 8. 统一分发与总览 (Unified Dispatcher & All)
# ==============================================================================
view_config_all() {
    print_header "$(t 'VPS 常用配置与实时系统状态总览')"
    view_config_user
    view_config_ssh
    view_config_firewall
    view_config_docker
    view_config_backup
    view_config_monitoring
    view_config_optimization
    echo ""
}

view_config_by_name() {
    local target="${1:-all}"
    case "$target" in
        user|users|04_user)
            view_config_user
            ;;
        ssh|05_ssh|sshd)
            view_config_ssh
            ;;
        firewall|ufw|iptables|06_firewall|port|ports)
            view_config_firewall
            ;;
        docker|08_docker|container)
            view_config_docker
            ;;
        backup|09_backup|10_backup)
            view_config_backup
            ;;
        monitoring|monitor|11_monitoring)
            view_config_monitoring
            ;;
        optimization|opt|sysctl|swap|13_cleanup|09_network)
            view_config_optimization
            ;;
        all|*)
            view_config_all
            ;;
    esac
}

# 交互式菜单查看
view_config_menu() {
    while true; do
        local choice=""
        if tui_is_supported; then
            local items=(
                "查看全部系统配置总览 (View All Configurations)"
                "用户与权限配置 (User, Sudo & SSH Keys)"
                "SSH 服务与安全策略 (SSH Service & Security)"
                "防火墙与网络开放端口 (Firewall & Open Ports)"
                "Docker 容器运行环境 (Docker Daemon & Users)"
                "定时备份任务与归档 (Backup Tasks & Archives)"
                "系统监控与指标探针 (Monitoring & Probes)"
                "系统优化与内核调优 (Optimization, Swap & Sysctl)"
                "返回主菜单 (Back to Main Menu)"
            )
            local item_choice=""
            if ! tui_menu_select item_choice "系统常用配置查看菜单" "请选择要查看的配置模块 (↑/↓ 移动, Enter 查看):" 1 "${items[@]}"; then
                return 0
            fi
            case "$item_choice" in
                "查看全部"*) choice="1" ;;
                "用户与"*) choice="2" ;;
                "SSH"*) choice="3" ;;
                "防火墙"*) choice="4" ;;
                "Docker"*) choice="5" ;;
                "定时备份"*) choice="6" ;;
                "系统监控"*) choice="7" ;;
                "系统优化"*) choice="8" ;;
                "返回"*) return 0 ;;
                *) choice="1" ;;
            esac
        else
            print_section "$(t '系统常用配置查看菜单 / System Configuration Inspector')"
            echo -e "  \033[1;36m│\033[0m   1) 查看全部配置总览 (View All Configurations)"
            echo -e "  \033[1;36m│\033[0m   2) 用户与权限配置 (User, Sudo & SSH Keys)"
            echo -e "  \033[1;36m│\033[0m   3) SSH 服务与安全策略 (SSH Service & Security)"
            echo -e "  \033[1;36m│\033[0m   4) 防火墙与网络端口 (Firewall & Open Ports)"
            echo -e "  \033[1;36m│\033[0m   5) Docker 容器环境 (Docker Daemon & Users)"
            echo -e "  \033[1;36m│\033[0m   6) 系统备份任务 (Backup Tasks & Archives)"
            echo -e "  \033[1;36m│\033[0m   7) 系统监控与探针 (Monitoring & Metrics)"
            echo -e "  \033[1;36m│\033[0m   8) 系统优化与内核 (Optimization & Kernel)"
            echo -e "  \033[1;36m│\033[0m   0) 返回主菜单 (Back to Main Menu)"
            echo -e "  \033[1;36m╰──────────────────────────────────────────────────────────\033[0m"
            read -r -p "  请选择 [0-8] (默认: 1): " choice
            choice="${choice:-1}"
        fi

        case "$choice" in
            1) view_config_all ;;
            2) view_config_user ;;
            3) view_config_ssh ;;
            4) view_config_firewall ;;
            5) view_config_docker ;;
            6) view_config_backup ;;
            7) view_config_monitoring ;;
            8) view_config_optimization ;;
            0|q|back) return 0 ;;
            *) echo -e "${RED}请输入有效选项 [0-8]${NC}" ;;
        esac

        echo ""
        read -r -p "按回车键继续查看其他配置..." _dummy || true
    done
}
