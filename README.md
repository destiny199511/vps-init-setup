# VPS一键装机 — 生产级通用版

[![ShellCheck](https://img.shields.io/badge/shellcheck-passing-brightgreen)]()
[![License](https://img.shields.io/badge/license-MIT-blue)]()
[![Shell](https://img.shields.io/badge/shell-bash%20%2F%20sh-grey)]()

吸收 `du_setup`、`linux-ssh-init-sh`、`server_init_harden` 三大开源 VPS 装机脚本的实践精华，以模块化、幂等、可回滚为设计理念，提供终端可视化配置向导的一键 VPS 初始化方案。

用户只需一行命令即可进入交互式配置界面，通过方向键和回车完成主机名、用户、SSH、安全、服务等全部选项的配置，配置完成自动执行安装。

## 快速开始

```bash
# 交互式向导（一行命令，可视化配置 UI）
sudo ./vps_setup.sh

# 无人值守安装（使用已有配置或默认值）
sudo ./vps_setup.sh -n

# 指定模块安装
sudo ./vps_setup.sh -n --modules 05_ssh,06_firewall

# 预览模式（不实际执行，查看将做什么）
sudo ./vps_setup.sh -n -d

# 查看各模块执行状态
sudo ./vps_setup.sh --status

# 强制重做已完成的模块
sudo ./vps_setup.sh -f -n

# 回滚已完成的更改
sudo ./vps_setup.sh --rollback

# 查看帮助
./vps_setup.sh --help
```

## 设计原则

| 原则 | 说明 |
|------|------|
| **安全优先** | 所有变更可逆、可审计，默认最小权限 |
| **幂等可重入** | 已完成模块自动跳过，安全重跑 |
| **可回滚** | 配置文件修改前自动备份，支持一键恢复 |
| **模块化** | 每个功能独立模块，按数字序号 00-12 顺序执行 |
| **多发行版** | Ubuntu/Debian/CentOS/Rocky/AlmaLinux 自动适配 |
| **输入校验** | 主机名、端口、数字等严格校验，防止注入 |
| **完整审计** | 所有写操作记录至 audit log，含时间戳和变更详情 |

## 项目结构

```
vps-auto-setup/
├── vps_setup.sh            # 入口：交互式向导 + CLI自动化
├── lib/
│   ├── core.sh             # 核心库：系统检测、日志、状态追踪、审计、备份回滚
│   └── common.sh           # 公共库：配置管理、验证函数
├── modules/                # 功能模块（数字前缀严格排序）
│   ├── 00_preflight.sh     # 系统预检
│   ├── 01_hostname.sh      # 主机名配置
│   ├── 02_locale_timezone.sh # 语言和时区
│   ├── 03_dns.sh           # DNS配置
│   ├── 04_user.sh          # 非root用户创建
│   ├── 05_ssh.sh           # SSH安全加固
│   ├── 06_firewall.sh      # 防火墙配置
│   ├── 07_fail2ban.sh      # Fail2ban入侵防护
│   ├── 08_docker.sh        # Docker引擎安装
│   ├── 09_network.sh      # 网络优化（BBR/TCP）
│   ├── 10_backup.sh        # 自动备份系统
│   ├── 11_monitoring.sh    # 系统监控
│   ├── 12_security.sh      # 安全审计扫描
│   └── 13_cleanup.sh       # 系统清洗和优化（swap/snap/缓存/journal）
├── config/                 # 状态文件 + 持久化配置
├── profiles/               # 配置profile目录
├── logs/                   # 运行日志 + 审计日志
└── backups/                # 配置文件备份（自动生成）
```

## 功能模块详情

### 系统基础

| 模块 | 功能 |
|------|------|
| **00_preflight** | root权限检查、OS兼容性验证、磁盘≥512MB/内存≥256MB、网络连通性、虚拟化环境检测 |
| **01_hostname** | 主机名设置 + `/etc/hosts` 更新，自动检测IP，保留原有自定义条目，失败回滚 |
| **02_locale_timezone** | locale配置（含 zh_CN.UTF-8 支持）、时区设置、chrony/NTP 时间同步 |
| **03_dns** | systemd-resolved 或传统 `resolv.conf`，多DNS方案，含解析验证 |
| **04_user** | 非root用户创建、SSH密钥配置（自动生成 ed25519 或手动提供公钥）、sudo 权限 |

### 安全加固

| 模块 | 功能 |
|------|------|
| **05_ssh** | SSH端口修改、禁止root登录、禁用密码认证、MaxAuthTries、ClientAlive、LoginGraceTime，配置前 `sshd -t` 验证 |
| **06_firewall** | UFW / FirewallD / iptables / nftables 四选一自动检测，默认 deny incoming，开放 SSH/HTTP/HTTPS，支持额外端口 |
| **07_fail2ban** | 安装Fail2ban，SSH保护jail，三级封禁策略（含 recidive 1周封禁） |

### 应用与网络

| 模块 | 功能 |
|------|------|
| **08_docker** | 官方仓库安装Docker Engine、daemon参数优化、容器健康检查、安全最佳实践 |
| **09_network** | BBR拥塞控制、TCP keepalive、syncookies、TCP FastOpen、netdev/somaxconn 调优 |

### 运维管理

| 模块 | 功能 |
|------|------|
| **10_backup** | Restic / Rclone / rsync 三选一，cron 定时备份，保留策略，自动清理 |
| **11_monitoring** | htop/iotop/ncdu 基础工具 + Netdata 仪表盘 或 Prometheus Node Exporter |
| **12_security** | Lynis 安全扫描、rkhunter Rootkit检测、auditd 系统审计（sudo/passwd/内核模块） |

### 系统清洗与优化

| 模块 | 功能 |
|------|------|
| **13_cleanup** | 创建/调整 Swap（自动按内存比例分配）、卸载 snap 并阻止重装、清理包管理器缓存/旧内核、清理 systemd journal 并限容、禁用不必要服务、清理 /tmp 和旧日志、启用 SSD TRIM |

## CLI 参数

```
用法: ./vps_setup.sh [选项]

选项:
  -h, --help              显示此帮助信息
  -n, --non-interactive   非交互模式（使用现有配置或默认值）
  -a, --auto              自动模式（非交互 + 默认值，跳过所有提示）
  -d, --dry-run           试运行（仅显示将要执行的操作，不实际执行）
  -f, --force             强制重新执行已完成的模块
  --modules <list>        仅执行指定模块，逗号分隔 (如: 01_hostname,05_ssh)
  --rollback              回滚已完成的更改（恢复备份的配置文件）
  --status                显示各模块的执行状态
```

## 交互式可视化向导

默认运行 `./vps_setup.sh` 会自动检测 `whiptail`（优先）或 `dialog`（备用），依次弹出可视化配置界面：

```
┌──────── 欢迎使用VPS一键装机 ────────┐
│ 本向导将帮助您配置系统的各项参数。 │
│ 请使用方向键导航，回车键确认，      │
│ 空格键选择/取消选择。              │
│                                  │
│           <  确定  >              │
└─────────────────────────────────────┘
```

配置流程：

1. **系统设置** — 主机名、时区、语言环境、首选/备用 DNS
2. **用户配置** — 用户名、SSH 公钥认证开关、密码策略
3. **SSH 配置** — 端口、root 登录策略、认证次数、保活参数
4. **安全设置** — Fail2ban、auditd、SELinux/AppArmor 检查
5. **服务安装** — Docker、NPM
6. **备份和监控** — 自动备份、Netdata/Node Exporter
7. **系统清洗和优化** — 创建 Swap、卸载 Snap、清理缓存/日志/临时文件、禁用无用服务

配置完成后自动保存至 `config/vps_config.conf`，后续非交互模式可直接复用。

### TUI 依赖安装

大多数发行版预装了 `whiptail`（随 `newt` 库）。如未安装：

```bash
# Debian/Ubuntu
sudo apt-get install -y whiptail

# RHEL/CentOS/Rocky
sudo dnf install -y newt

# Alpine
sudo apk add newt
```

未安装 TUI 工具时，脚本会自动降级为纯文本交互模式（read 回车确认）。

## 配置体系

配置优先级从高到低：

| 方式 | 优先级 | 示例 |
|------|--------|------|
| 环境变量 | 高 | `VPS_SETUP_SSH_PORT=2222 ./vps_setup.sh -n` |
| 配置文件 | 中 | `config/vps_config.conf`（首次交互后自动持久化） |
| 内置默认值 | 低 | `SSH_PORT=24822`、`LOCALE=zh_CN.UTF-8` |

首次交互收集的配置自动持久化，后续 `./vps_setup.sh -n` 直接复用，无需重新回答。

## 支持的系统

| 发行版 | 状态 | 说明 |
|--------|------|------|
| Ubuntu 22.04 / 24.04 LTS | ✅ 完整支持 | apt + systemd |
| Debian 11 / 12 | ✅ 完整支持 | apt + systemd |
| CentOS Stream 9 | ✅ 完整支持 | dnf + systemd |
| Rocky Linux 9 | ✅ 完整支持 | dnf + systemd |
| AlmaLinux 9 | ✅ 完整支持 | dnf + systemd |
| Alpine Linux | ⚠️ 部分支持 | 无 systemd，部分模块受限 |

自动检测包管理器（apt/yum/dnf/apk）和 init 系统（systemd/SysVinit/OpenRC）。

## 开发

### 语法检查

```bash
# 检查所有脚本
for f in vps_setup.sh lib/*.sh modules/*.sh; do
    bash -n "$f" && echo "✓ $f" || echo "✗ $f"
done
```

### 模块接口规范

每个模块须提供三个函数，命名格式为 `{模块名}_{类型}`：

```bash
# 返回模块描述
module_info() {
    echo "模块功能描述"
}

# 先决条件检查（返回非0则跳过该模块）
module_prerequisites() {
    return 0
}

# 主执行逻辑（返回0为成功，非0为失败）
module_main() {
    log_info "执行模块..."
    # ... 实际操作 ...
    return 0
}
```

### 添加新模块

1. 在 `modules/` 下创建 `NN_name.sh`（NN 为两位序号，如 `13_panel.sh`）
2. 实现 `name_info()`、`name_prerequisites()`、`name_main()` 三个函数
3. 在 `vps_setup.sh` 的 `MODULES` 数组中添加条目

### 日志与审计

- **运行日志**：`logs/vps_setup_YYYYMMDD_HHMMSS.log`
- **审计日志**：`logs/audit_YYYYMMDD_HHMMSS.log`（记录所有写操作）
- **配置备份**：`backups/`（配置文件修改前的自动快照）
- **状态文件**：`config/.state`（模块执行状态，支持断点续做）

## 致谢

本项目吸收了以下开源项目的实践精华：

| 项目 | 吸收的长处 | 避免的短处 |
|------|-----------|-----------|
| [du_setup](https://github.com/buildplan/du_setup) | 全面功能集、环境检测、交互式体验 | 单体文件 6000+ 行、仅 Debian |
| [linux-ssh-init-sh](https://github.com/247like/linux-ssh-init-sh) | 18 轮红队审计、完整回滚、POSIX 兼容、审计日志 | 范围狭窄（仅 SSH 加固） |
| [server_init_harden](https://github.com/pratiktri/server_init_harden) | 多 OS 支持、简洁架构 | 无交互模式、无测试 |

## 许可证

MIT
