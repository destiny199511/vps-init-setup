# VPS 一键装机 — 生产级通用版

[![ShellCheck](https://img.shields.io/badge/shellcheck-validated-brightgreen)]()
[![License](https://img.shields.io/badge/license-MIT-blue)]()
[![Shell](https://img.shields.io/badge/shell-bash-grey)]()

**VPS 一键装机** 是一个面向主流 Linux VPS 的自动化系统初始化与安全加固工具。帮助你在新服务器上快速完成基础环境配置、SSH 与防火墙安全加固、系统深度清理、Docker 部署及日常运维准备。

### 核心特性

- **多发行版适配**：支持 Ubuntu (22.04/24.04)、Debian (11/12)、CentOS Stream 9、Rocky Linux 9、AlmaLinux 9 等。
- **灵活交互与自动化**：提供卡片式 TUI 交互向导、分项配置主菜单以及零干预的无人值守（Non-interactive）模式。
- **安全与最小权限**：非 root 用户管理、SSH 密钥认证加固、Fail2ban 防爆破、UFW/Firewalld 规则隔离。
- **模块化与幂等设计**：00–13 独立功能模块，支持按需单跑、断点续跑与配置回滚。

---

## 快速开始

### 1. 一键在线安装

在全新服务器上以 root 或 sudo 运行：

```bash
curl -fsSL https://raw.githubusercontent.com/destiny199511/vps-init-setup/main/install.sh | sudo bash
```

> **提示**：安装完成后会自动启动交互式主菜单。脚本默认安装在 `/opt/vps-init-setup`。

### 2. 常用操作命令

进入安装目录后，可按需执行以下命令：

```bash
cd /opt/vps-init-setup

# 交互式向导 / 主菜单
sudo ./vps_setup.sh

# 无人值守安装（使用配置文件或默认值）
sudo ./vps_setup.sh -n

# 试运行预览（Dry-Run，仅展示将要执行的变更，不修改系统）
sudo ./vps_setup.sh -n -d

# 仅执行指定模块（例如仅配置 SSH 与防火墙）
sudo ./vps_setup.sh -n --modules 05_ssh,06_firewall

# 查看各模块执行状态
sudo ./vps_setup.sh --status

# 强制重新执行已完成的模块
sudo ./vps_setup.sh -f -n

# 回滚配置文件修改
sudo ./vps_setup.sh --rollback
```

---

## 使用指南

### 1. 交互式主菜单与向导

直接运行 [vps_setup.sh](vps_setup.sh) 即可进入主菜单：
- **1) 完整向导配置**：引导完成 7 大配置项（系统基础、用户、清理、SSH、安全、服务、备份监控）。
- **2) 模块化分项配置**：单独修改指定类别的参数。
- **3) 预览当前配置**：查看即将生效的配置卡片（Review Card）。
- **4) 开始执行安装**：确认后按序执行系统配置与组件安装。

**快捷操作键**：
| 按键 | 说明 |
|---|---|
| `↑` / `↓` | 在选项间移动高亮焦点 |
| `Enter` | 确认当前输入或选择默认值 |
| `b` / `Esc` | 返回上一步或返回主菜单 |
| `1`–`9` | 直接跳转到对应编号选项 |

> 终端宽度 $\ge 60$ 列且为 TTY 环境时自动启用卡片式 TUI，窄终端或非 TTY 自动降级为标准命令行文本菜单。

### 2. 无人值守与自动化部署

在 CI/CD 或批量装机场景中，可提前准备配置文件 [config/vps_config.conf](examples/example_user_config.conf)：

```bash
# 从示例模板创建配置
sudo install -m 600 examples/example_user_config.conf config/vps_config.conf

# 一键静默安装
sudo ./vps_setup.sh -n -a
```

### 3. 在线更新

重新运行安装器即可在线拉取最新版本（保留已有的 `config/`、`logs/` 与 `backups/`）：

```bash
curl -fsSL https://raw.githubusercontent.com/destiny199511/vps-init-setup/main/install.sh \
  | sudo bash -s -- --ref main --update-only
```

---

## 功能模块列表

| 序号 | 模块名称 | 核心功能说明 |
|---|---|---|
| **00** | `00_preflight` | 权限检查、系统兼容性验证、磁盘/内存/网络连通性预检、APT 锁等待 |
| **01** | `01_hostname` | 主机名设置与 `/etc/hosts` 自动绑定更新 |
| **02** | `02_locale_timezone` | 语言环境（UTF-8）、时区设置与 Chrony/NTP 时间同步 |
| **03** | `03_dns` | 优选公共 DNS（Cloudflare/Google/阿里）配置与解析验证 |
| **04** | `04_user` | 创建专用 Sudo 普通管理用户，配置 SSH 登录凭据 |
| **05** | `05_ssh` | SSH 端口修改、禁止 Root 登录、禁用密码认证、保活参数调优 |
| **06** | `06_firewall` | 自动配置 UFW / Firewalld / Iptables，放行必要端口 |
| **07** | `07_fail2ban` | 部署 Fail2ban 防暴力破解，启用 SSH 封禁与 Recidive 长期封禁规则 |
| **08** | `08_docker` | 官方源安装 Docker Engine 与 Compose，优化 Daemon 参数及日志上限 |
| **09** | `09_network` | 启用 BBR 拥塞控制、TCP Keepalive、FastOpen 与网络内核参数调优 |
| **10** | `10_backup` | 配置 Restic / Rclone 定时备份机制与保留策略 |
| **11** | `11_monitoring` | 部署 htop/iotop/ncdu 及 Prometheus Node Exporter 监控端 |
| **12** | `12_security` | 启用 Auditd 安全审计、Lynis 安全基线扫描与 Rootkit 检测 |
| **13** | `13_cleanup` | 内存自适应 Swap 创建、卸载 Snap、清理包缓存/旧内核、限制 Journal 日志 |

---

## CLI 参数速查

```
用法: ./vps_setup.sh [选项]

选项:
  -h, --help              显示帮助信息
  -n, --non-interactive   非交互模式（使用现有配置或默认值）
  -a, --auto              自动模式（跳过确认提示）
  -d, --dry-run           试运行（仅显示将要执行的操作，不实际修改系统）
  -f, --force             强制重新执行已完成的模块
  --modules <list>        仅执行指定模块，逗号分隔 (例: 01_hostname,05_ssh)
  --rollback              回滚已完成的更改（恢复备份的配置文件）
  --status                显示各模块的执行状态
```

---

## 注意事项

1. **保持 SSH 会话**：在修改 SSH 端口或防火墙规则后，请先**新建一个终端窗口测试登录**，确认无误后再关闭当前连接窗口。
2. **APT 锁自动等待**：新开机 VPS 系统常会自动运行后台更新；脚本内置了锁检测与自动等待机制（默认最多等待 300 秒，可通过 `APT_LOCK_WAIT=600` 调整）。
3. **支持的发行版**：
   - Ubuntu 22.04 / 24.04 LTS
   - Debian 11 / 12
   - CentOS Stream 9 / Rocky Linux 9 / AlmaLinux 9
4. **日志与审计**：
   - 运行日志：`logs/vps_setup_*.log`
   - 安全审计日志：`logs/audit_*.log`
   - 备份目录：`backups/`（关键配置修改前自动快照）

## 许可证

本项目采用 [MIT License](LICENSE) 开源。
