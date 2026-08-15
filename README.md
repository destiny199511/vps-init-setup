# VPS一键装机 — 生产级通用版

[![ShellCheck](https://img.shields.io/badge/shellcheck-validated-brightgreen)]()
[![License](https://img.shields.io/badge/license-MIT-blue)]()
[![Shell](https://img.shields.io/badge/shell-bash-grey)]()

VPS 一键装机是一个面向 Linux VPS 的自动化初始化工具，旨在帮助用户在新的服务器上快速完成基础环境配置、安全加固、服务安装和日常运维准备。

该项目参考了 `du_setup`、`linux-ssh-init-sh` 和 `server_init_harden` 的实践经验，采用模块化、幂等和可回滚的设计思路，提供交互式向导与无人值守两种使用方式。

## 项目概览

- 支持 Ubuntu、Debian、CentOS、Rocky 与 AlmaLinux 等主流发行版
- 自动检测系统环境、包管理器和初始化系统
- 提供交互式配置向导与非交互式执行模式
- 采用模块化结构，支持按需安装和分步执行
- 对关键配置修改提供日志记录、备份与回滚能力

## 快速开始

### 1. 安装

#### 快速一键安装（推荐）：

在 VPS 上运行以下命令直接从 `main` 分支一键安装或更新：

```bash
curl -fsSL https://raw.githubusercontent.com/destiny199511/vps-init-setup/main/install.sh | sudo bash
```

#### 生产环境发布标签安装：

在生产环境中，推荐使用不可变的发布标签（Tag）并进行 SHA-256 校验。

```bash
# 1. 使用指定 Release Tag 安装（要求 GitHub 上已发布该标签）：
curl -fsSL https://raw.githubusercontent.com/destiny199511/vps-init-setup/main/install.sh \
  | sudo bash -s -- --ref v1.0.0

# 2. 带外指定 SHA-256 校验固定安装（增强安全性）：
curl -fsSL https://raw.githubusercontent.com/destiny199511/vps-init-setup/main/install.sh \
  | sudo bash -s -- --ref v1.0.0 --sha256 替换为实际的64位SHA256哈希
```

> **参数说明与注意事项**：
> 1. `--ref <tag>`：使用的 Tag 必须已在 GitHub Release 中发布。若标签尚未发布，请直接使用上面的快速一键安装命令。
> 2. `--sha256 <hash>`：请将参数中的哈希替换为实际的 64 位 HEX 字符串（**切勿包含 `<>` 尖括号**，否则 Shell 会将其识别为输入重定向而报语法错误）。


### 2. 本地运行

```bash
# 交互式向导
sudo ./vps_setup.sh

# 无人值守安装
sudo ./vps_setup.sh -n

# 仅执行指定模块
sudo ./vps_setup.sh -n --modules 05_ssh,06_firewall

# 预览将要执行的操作
sudo ./vps_setup.sh -n -d

# 查看模块执行状态
sudo ./vps_setup.sh --status

# 强制重新执行已完成的模块
sudo ./vps_setup.sh -f -n

# 回滚已完成的变更
sudo ./vps_setup.sh --rollback

# 查看帮助信息
./vps_setup.sh --help
```

## 使用说明

### 使用前准备

在正式执行安装前，请确认以下事项：

- 服务器已安装受支持的 Linux 发行版
- 你已拥有 root 权限，或能够通过 `sudo` 执行命令
- 建议先备份当前系统配置，尤其是 SSH、防火墙和 DNS 相关设置
- 如果部署环境为生产环境，建议先在测试环境中验证一次

### 交互式安装

在本地或远程服务器上执行以下命令，即可进入配置向导：

```bash
sudo ./vps_setup.sh
```

脚本将引导你完成主机名、用户、SSH、安全加固、Docker、备份和监控等配置。

### 无人值守安装

无人值守模式应先准备受 root 保护的配置文件。配置文件是严格的 `KEY=VALUE` 数据文件，不会也不能执行 shell 命令；请以 [examples/example_user_config.conf](examples/example_user_config.conf) 为起点。若关闭密码认证，必须提供有效的 `SSH_PUBKEY`，否则在写入 SSH 配置前中止。

```bash
sudo install -m 600 examples/example_user_config.conf config/vps_config.conf
sudo ./vps_setup.sh -n
```

### 更新现有安装

通过压缩包安装的目录不包含 `.git`，不能使用 `git pull`。请重新运行安装器，并显式指定要更新的分支；安装器会保留现有的 `config/`、`logs/` 和 `backups/` 内容：

```bash
curl -fsSL https://raw.githubusercontent.com/destiny199511/vps-init-setup/main/install.sh \
  | sudo bash -s -- --ref main --install-dir /opt/vps-init-setup --update-only
```

  安装目录必须是 root 所有且不可被组或其他用户写入的专用目录，且仅允许位于 `/opt`、`/srv` 或 `/usr/local/src`。更新会保留目标主机的 `config/`、`logs/`、`backups/`，不会覆盖它们。

  更新后，先在已有 SSH 会话保持连接的情况下验证当前状态，再按需重跑访问控制模块：

```bash
cd /opt/vps-init-setup
sudo ./vps_setup.sh -n -a -f --modules 05_ssh,06_firewall,07_fail2ban
```

不要对压缩包安装目录使用 `git pull`。如需使用 Git 工作流，请在专用开发目录中执行，并在生产环境通过已发布的标签更新。

### 注意事项

- 脚本会修改系统配置，包括 SSH、用户、DNS、防火墙和服务安装
- 运行 SSH、防火墙或 Fail2ban 前，请保持一个已验证的 SSH 会话；脚本会拒绝在目标用户没有公钥或密码认证凭据时修改访问控制
- 检测到非本工具托管的 nftables 规则时，防火墙模块会拒绝覆盖它们；请先手动迁移或保持原有防火墙
- 部分模块会安装较大的软件包，例如 Docker、Fail2ban 和 Netdata
- 建议在执行前确认服务器资源充足，尤其是磁盘空间和网络状态
- 如需先查看将要执行的内容，可使用 `-d` 预览模式：

```bash
sudo ./vps_setup.sh -n -d
```

## 设计原则

| 原则 | 说明 |
|------|------|
| **安全优先** | 所有变更可逆、可审计，默认最小权限 |
| **幂等可重入** | 已完成模块自动跳过，安全重跑 |
| **可回滚** | 关键配置修改前自动备份，可按备份登记恢复 |
| **模块化** | 每个功能独立模块，按数字序号 00-12 顺序执行 |
| **多发行版** | Ubuntu/Debian/CentOS/Rocky/AlmaLinux 自动适配 |
| **输入校验** | 主机名、端口、数字等严格校验，防止注入 |
| **完整审计** | 所有写操作记录至 audit log，含时间戳和变更详情 |

## 项目结构

```
vps-init-setup/
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
| **04_user** | 非root用户创建、SSH公钥或密码认证配置、sudo 权限；不会在服务器生成或打印私钥 |

### 安全加固

| 模块 | 功能 |
|------|------|
| **05_ssh** | SSH端口修改、迁移期默认保留旧端口、禁止root登录、禁用密码认证、MaxAuthTries、ClientAlive、LoginGraceTime，配置前 `sshd -t` 验证，并适配 `ssh.socket` |
| **06_firewall** | UFW / FirewallD / iptables 自动配置；nftables 仅管理带专属标记的规则，保护既有 VPN、容器和云管理规则 |
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

## 交互式主菜单与配置向导

默认运行 `./vps_setup.sh` 时，进入**主菜单**，提供 6 个编号操作与退出：

```
═══════════════════════════════════════════
     VPS 一键装机 v2.0.0 — 主菜单
═══════════════════════════════════════════
请选择需要执行的操作:
  1) 完整向导配置 (Guided Setup Wizard) [默认推荐]
  2) 模块化分项配置 (Configure by Section)
  3) 预览当前配置 (Review Configuration)
  4) 加载 / 重置配置文件 (Manage Config File)
  5) 开始执行安装 (Start Installation)
  6) 查看模块执行状态 (Check Module Status)
  0) 退出程序 (Exit)
═══════════════════════════════════════════
```

### 1) 完整向导配置 — 分步收集所有参数

选择 1 进入 7 步向导，每步对应一组相关配置：

| 步骤 | 内容 | 关键项 |
|------|------|--------|
| Step 1 | 系统基础 | 主机名、时区、Locale、DNS |
| Step 2 | 用户账户 | 用户名、SSH 公钥/密码、sudo |
| Step 3 | 清理与优化 | Swap、Snap、包缓存、Journal、无用服务 |
| Step 4 | SSH 加固 | 端口、禁止 root、认证方式、保活 |
| Step 5 | 安全组件 | Fail2ban、auditd、MAC 策略 |
| Step 6 | 可选服务 | Docker、Node.js 与 npm |
| Step 7 | 备份与监控 | 自动备份、Node Exporter |

**导航键**：
- `回车` / 直接输入数字 — 确认默认值或选择项
- `b` 或 `back` — **返回上一步**（向导中），或**取消向导回主菜单**（第一步）
- `数字编号` — 菜单类提示中直接输入编号选择

配置完成后自动保存至 `config/vps_config.conf`，返回主菜单可继续执行安装。

### 2) 模块化分项配置 — 单独修改某类配置

选择 2 进入分项菜单，可独立编辑 7 大类中的任意一项：

```
═══════════════════════════════════════════
     模块化分项配置菜单
═══════════════════════════════════════════
请选择需要单独配置或修改的项目:
  1) 系统基础配置 (Step 1: Hostname / Timezone / DNS)
  2) 用户账户配置 (Step 2: Username / SSH Key / Password)
  3) 清理与优化配置 (Step 3: Swap / Snap / Cache / Journal)
  4) SSH 加固配置 (Step 4: SSH Port / Root Login)
  5) 安全组件配置 (Step 5: Fail2ban / Auditd / MAC)
  6) 可选服务配置 (Step 6: Docker / Node.js & NPM)
  7) 备份与监控配置 (Step 7: Backup / Node Exporter)
  0) 返回主菜单
═══════════════════════════════════════════
```

**导航键**：
- `1-7` — 进入对应配置子流程
- `b` / `back` / `0` — **返回上一级菜单**（分项菜单 → 主菜单；配置子流程 → 分项菜单）
- 子流程内同样支持 `b` 逐级返回

修改即时保存，适合微调单项后直接执行安装。

### 3) 预览当前配置 — 只读 Review Card

选择 3 显示当前所有配置摘要，不做任何修改：

```
┌──────────────────────────────────────────┐
│           配置预览 Review Card           │
├──────────────────────────────────────────┤
│ Hostname:          my-vps-server         │
│ Timezone:          Asia/Shanghai         │
│ Locale:            zh_CN.UTF-8           │
│ SSH Port:          24822                 │
│ SSH Root Login:    false                 │
│ Install Docker:    true                  │
│ Enable Monitoring: true                  │
│ ...                                        │
└──────────────────────────────────────────┘
```

### 4) 加载 / 重置配置文件

选择 4 可：
- 重新加载 `config/vps_config.conf`（覆盖当前内存配置）
- 若无配置文件，应用内置默认值

### 5) 开始执行安装

选择 5 跳出主菜单，按顺序执行所有已启用模块（或 `--modules` 指定的子集）。执行前会再次弹出 **最终确认 Review**，输入 `Y` 继续，`n` 取消回主菜单。

### 6) 查看模块执行状态 — `--status` 效果等同

选择 6 或直接运行 `./vps_setup.sh --status`，输出各模块的执行状态表：

```
═══════════════════════════════════════════
     模块执行状态 (13 modules)
═══════════════════════════════════════════
  00_preflight:         ✓ done
  01_hostname:          ✓ done
  02_locale_timezone:   ✓ done
  03_dns:               ✓ done
  04_user:              ~ skipped
  05_ssh:               ✗ failed
  06_firewall:          ~ pending
  ...
  13_cleanup:           ~ pending
═══════════════════════════════════════════
  合计: ✓ 4  ✗ 1  ~ 8
```

| 符号 | 含义 |
|------|------|
| `✓` | 已完成（幂等跳过） |
| `✗` | 执行失败（查看日志排查） |
| `~` | 待执行 / 跳过 / dry-run |

配合 `-f` 强制重跑、`--modules` 指定子集、`-d` 预览模式使用。

---

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

若 TUI 工具未安装，脚本会自动降级为纯文本交互模式（通过 `read` 进行确认）。

## 配置体系

配置优先级从高到低：

| 方式 | 优先级 | 示例 |
|------|--------|------|
| 环境变量 | 高 | `VPS_SETUP_SSH_PORT=2222 ./vps_setup.sh -n` |
| 配置文件 | 中 | `config/vps_config.conf`（首次交互后自动持久化） |
| 内置默认值 | 低 | `SSH_PORT=24822`、`LOCALE=zh_CN.UTF-8` |

首次交互过程中收集到的配置会被持久化保存，后续执行 `./vps_setup.sh -n` 时可以直接复用，无需再次输入。

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

## 开发与贡献

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

### 相关文件说明

- **运行日志**：`logs/vps_setup_YYYYMMDD_HHMMSS.log`
- **审计日志**：`logs/audit_YYYYMMDD_HHMMSS.log`（记录所有写操作）
- **配置备份**：`backups/`（配置文件修改前的自动快照）
- **状态文件**：`config/.state`（模块执行状态，支持断点续做）

## 致谢

本项目参考了以下开源项目的实现思路：

| 项目 | 吸收的长处 | 避免的短处 |
|------|-----------|-----------|
| [du_setup](https://github.com/buildplan/du_setup) | 全面功能集、环境检测、交互式体验 | 单体文件 6000+ 行、仅 Debian |
| [linux-ssh-init-sh](https://github.com/247like/linux-ssh-init-sh) | 18 轮红队审计、完整回滚、POSIX 兼容、审计日志 | 范围狭窄（仅 SSH 加固） |
| [server_init_harden](https://github.com/pratiktri/server_init_harden) | 多 OS 支持、简洁架构 | 无交互模式、无测试 |

## 许可证

MIT
