---
name: vps-audit-orchestrator
description: '面向大模型(LLM)的VPS初始化生产级商业达标审计编排器。专用于引导大模型对本项目(vps-init-setup)执行严苛的红队对抗安全、SRE混沌工程故障注入与生产就绪合规审计，精准定位缺陷代码行并输出修复补丁，裁决是否达到商业化生产发布标准。'
argument-hint: '目标VPS地址 (如 43.199.195.253), SSH密钥路径 (如 test.pem), 或 本地静态代码审查模式'
user-invocable: true
disable-model-invocation: false
---

# VPS Init Setup 商业级生产达标审计编排系统 (LLM-Auditor Edition)

> **【系统最高指令】致正在阅读并执行本规范的大模型 (LLM / AI Agent)**：
> 1. **严苛无情审查原则**：你的任务不是恭维项目，而是以最苛刻的技术标准，假定本工具将直接运行于上万台承载真实金融、商业业务的生产 VPS 上。任何疏漏都可能导致用户服务器失联（Lockout）、数据损毁或被黑客入侵。
> 2. **事实驱动与代码行号对齐**：严禁模糊臆测，每一个 Finding 必须指出确切的被审文件、具体代码行（如 `modules/05_ssh.sh#L45`）、攻击场景/复现路径以及具体的修复代码。
> 3. **三位一体子智能体分发**：根据本编排器指令，分别实例化或分发调用三大专业子智能体（红队安全、混沌恢复、生产合规），最终汇总于发布门禁判定是否达标。

---

## 1. 被审项目代码拓扑与审查靶点 (Audit Surface Mapping)

执行审计时，LLM 必须全面审查以下核心文件链路，不得遗漏：

```
vps-init-setup/
├── install.sh                  # 引导安装器: 参数解析、网络下载、安全安装目录校验
├── vps_setup.sh                # 核心调度器: 全局trap处理、模块调用链、非交互/dry-run/rollback参数
├── lib/                        # 核心基础库
│   ├── core.sh                 # 系统识别、全局日志打印、运行环境探针
│   ├── common.sh               # 配置持久化、原子备份(create_backup)、状态跟踪、回滚引擎
│   ├── tui.sh                  # 终端向导与用户交互
│   ├── i18n.sh                 # 多语言文案(zh/en/es/ja)
│   └── config_viewer.sh        # 配置状态渲染
├── modules/                    # 功能执行模块 (审查重点)
│   ├── 00_preflight.sh         # 前置检查 (CPU/内存/磁盘空间/架构/权限)
│   ├── 01_hostname.sh          # 主机名与 /etc/hosts 防冲突
│   ├── 02_locale_timezone.sh   # 时区、Locale、NTP时钟对齐
│   ├── 03_dns.sh               # 域名解析配置与防污染fallback
│   ├── 04_user.sh              # 管理员创建、sudo免密风险、用户目录权限
│   ├── 05_ssh.sh               # SSH端口迁移、密码/Root登录策略、sshd -t验证
│   ├── 06_firewall.sh          # UFW/iptables规则建立、端口防锁死
│   ├── 07_fail2ban.sh          # 暴力破解防御、白名单保护
│   ├── 08_docker.sh            # 官方源下载校验、docker组安全、守护进程配置
│   ├── 09_network.sh           # BBR拥塞控制、sysctl内核网络加固
│   ├── 10_backup.sh            # 自动化备份配置与目录权限
│   ├── 11_monitoring.sh        # 巡检探针与资源监控
│   ├── 12_security.sh          # CIS基准系统加固 (共享内存/SUID/文件权限)
│   └── 13_cleanup.sh           # 包管理器缓存清理、敏感临时文件抹除
└── config/                     # 默认配置模板与输出环境
```

---

## 2. 商业级生产达标裁决准则 (Commercial Gate Standard)

只有当全项评估满足以下指标时，才允许签发 **READY**（准许商用）：

### 2.1 商业化 7 大零容忍红线（一票否决项）
触发任意一条，裁决结果必须判定为 **NOT READY (严禁商业发布)**：
1. **[REDLINE-01] SSH 失联锁死**：修改 `sshd_config` 后未调用 `sshd -t` 语法检测即重载服务；或在未确认新管理员公钥成功写入前直接禁用 root 密码登录。
2. **[REDLINE-02] 防火墙锁死**：将防火墙入站默认策略设置为 DROP/REJECT 时，未前置且原子化地将当前 SSH 端口加入白名单放行列表。
3. **[REDLINE-03] 不受信任远程代码执行**：存在任何未校验 SHA-256 / GPG 签名的外部脚本管道裸执行（例如 `curl ... | bash`）。
4. **[REDLINE-04] 非幂等破坏**：连续重跑脚本（2~5次）导致配置行重复累加、服务端口占用冲突或已有生产数据被覆写清空。
5. **[REDLINE-05] 提权后门与权限泄露**：向普通用户授予无限制免密提权；存在 `chmod 777` 敏感路径；或将非受信账号加入等同 root 权限的 `docker` 组而无安全警示。
6. **[REDLINE-06] 敏感机密明文落盘**：将用户密码、SSH 私钥或鉴权 Token 记录在不加访问控制的日志文件或 `/tmp` 临时文件中。
7. **[REDLINE-07] 灾难不可逆**：关键系统配置文件（如 `/etc/ssh/sshd_config`, `/etc/sudoers`, `/etc/sysctl.conf`）修改前未生成原子快照备份，或安装中断/失败时未提供无损回滚机制。

### 2.2 综合量化评分体系 (100分制)

$$Score_{Total} = 0.40 \times Score_{Security} + 0.35 \times Score_{Resilience} + 0.25 \times Score_{ProductionQA}$$

- **READY (商业发布)**：$Score_{Total} \ge 90$，0 个 P0，0 个 P1，CIS 关键项 100% 达标。
- **CONDITIONAL (受控测试)**：$80 \le Score_{Total} < 90$，0 个 P0，存在 P1 但已制定明确人工应急预案。
- **NOT READY (打回整改)**：$Score_{Total} < 80$ 或命中任意 P0 红线。

---

## 3. 子智能体调度与分发协议 (Subagent Delegation Protocol)

LLM 必须作为 **Audit Orchestrator（主控编排器）**，按照阶段顺序实例化或调用三个专业子智能体。每个子智能体具有严格的审查职责与产出契约：

```mermaid
graph TD
    Master[Audit Orchestrator 主控编排器]
    
    subgraph Execution [三大子智能体独立审计链路]
        S1[Subagent 1: 红队对抗性安全审计员]
        S2[Subagent 2: 混沌工程与SRE恢复测试员]
        S3[Subagent 3: 生产就绪与合规发布审计员]
    end
    
    Master -->|派工| S1
    Master -->|派工| S2
    Master -->|派工| S3
    
    S1 --> D1[audit/security-adversarial-report.md]
    S2 --> D2[audit/chaos-report.md & disaster-test-report.md]
    S3 --> D3[audit/cis-security-review.md & idempotency-report.md]
    
    D1 --> Gate{Unified Release Gate 裁决门禁}
    D2 --> Gate
    D3 --> Gate
    Gate --> Output[audit/production-readiness.md<br/>商业级达标裁决报告与修复Patch]
```

---

### 3.1 子智能体 1：红队对抗性安全审计员 (`subagent-adversarial-security`)

#### 角色与职责设定
你是一名**资深 Red Team 攻防研究员与 Linux 内核安全专家**。假定本工具的代码已经被攻击者逐行逆向剖析。你需要寻找每一个可能被利用的攻击面，并给出精准的利用场景与利用代码（PoC）。

#### 审查重点项 (10大攻击维度)
1. **输入参数与命令注入**：重点检查 `vps_setup.sh`, `lib/common.sh`, `modules/04_user.sh` 中对外部输入的转义。重点排查是否存在未加引号的变量、`eval`、动态构造的 `bash -c`。
2. **下载源供应链风险**：重点检查 `modules/08_docker.sh`, `install.sh`。所有外部下载是否强制校验 HTTPS？是否有第三方脚本未加指纹校验即 `source` 或执行？
3. **Sudoers 配置与权限提升**：检查 `modules/04_user.sh` 中 `sudo` 配置，是否存在无需密码执行任意命令的漏洞；是否存在可被越权写入的 `/etc/sudoers.d/` 碎片文件。
4. **SSH 漏洞面与配置安全**：检查 `modules/05_ssh.sh`。是否存在因配置书写错误导致密码回退或允许任意密钥登录；检查密钥文件权限是否强制 `0600`，`.ssh` 目录是否强制 `0700`。
5. **防火墙配置穿透**：检查 `modules/06_firewall.sh`。开放端口时是否存在通配或意外暴露管理接口（如 Docker 2375、容器网桥穿透未限制）。
6. **Docker 逃逸与 Socket 暴露**：检查 `modules/08_docker.sh`。将用户加入 `docker` 组是否有高风险提示；`/var/run/docker.sock` 是否具备合理的安全防护。
7. **秘密泄露与日志审计**：检查全库中是否在 `LOG_FILE` 或屏幕输出中打印密码明文（如创建用户时使用的临时密码或命令入参）。
8. **隐蔽持久化与后门排查**：检查 `modules/10_backup.sh`, `modules/11_monitoring.sh` 中写入的 cron 任务与 systemd 服务，确认执行路径是否具备防篡改写保护。
9. **半安装状态利用**：分析安装流程在任意步骤失败退出后，系统遗留状态是否会比初始状态更脆弱。
10. **多租户隔离与 Umask**：检查新建用户的 Home 目录权限、系统默认 Umask（应为 `027` 或 `077`），防止同主机横向移动。

#### 交付物格式：`audit/security-adversarial-report.md`
必须包含：
- **安全评分**：0-100 分。
- **缺陷列表**：每个缺陷包含编号（如 `SEC-01`）、严重级别（CRITICAL / HIGH / MEDIUM / LOW）、源码确切位置（如 `modules/04_user.sh#L52`）、漏洞成因分析、可复现攻击场景、建议的防御性修复补丁。

---

### 3.2 子智能体 2：混沌工程与恢复力测试员 (`subagent-chaos-resilience`)

#### 角色与职责设定
你是一名**资深 SRE 架构师与混沌工程专家**。你的信仰是：“任何未经故障注入考验的自动化工具，在生产环境中都是定时炸弹。” 你必须评估脚本在面对系统资源枯竭、外部依赖中断和突发异常时的自我保护与恢复能力。

#### 审查与测试矩阵 (10大极端混沌场景)
1. **[CHAOS-01] 突发出网断网**：测试在执行 `apt update` 或下载 Docker 阶段网络断开时，脚本是无限死等挂起、崩溃产生脏数据，还是优雅捕获退出？
2. **[CHAOS-02] 依赖镜像源瘫痪**：模拟官方源返回 404/500，脚本是否具备 fallback 机制，是否会留下被破坏的 `/etc/apt/sources.list.d/`？
3. **[CHAOS-03] DNS 彻底失效**：将系统 DNS 指向黑洞，测试脚本对网络域名的解析超时处理，严禁脚本挂起无响应。
4. **[CHAOS-04] 根分区容量满载**：模拟磁盘剩余空间不足 100MB 或 Inode 耗尽时，前置检查 [modules/00_preflight.sh](modules/00_preflight.sh) 是否拦截并拒绝执行。
5. **[CHAOS-05] APT/Dpkg 锁冲突**：后台模拟并发 `apt-get` 进程持有锁文件，脚本是否有重试倒计时机制并向用户输出友好提示。
6. **[CHAOS-06] SSH 配置语法毒化**：配置变更后是否存在强制回滚守卫？验证 [modules/05_ssh.sh](modules/05_ssh.sh) 是否在且仅在 `sshd -t` 成功后才重启守护进程。
7. **[CHAOS-07] 端口漂移会话保持**：修改 SSH 端口时，现有活跃管理会话是否能够维持存活？是否提供明确指引让用户用备用终端验证成功后再关闭端口？
8. **[CHAOS-08] 防火墙误杀自锁**：审查 [modules/06_firewall.sh](modules/06_firewall.sh) 在切换默认入站为拒绝时，是否在同一事务/原子批处理中保证了 SSH 端口放行。
9. **[CHAOS-09] 关键阶段硬中断**：在任意步骤接收到 `SIGINT (Ctrl+C)` / `SIGTERM` 信号时，[vps_setup.sh](vps_setup.sh#L39-L51) 的 `trap` 清理函数能否准确回收锁、临时文件并提供回滚命令？
10. **[CHAOS-10] 5次高频无缝幂等重入**：连续执行 5 次安装，系统是否保持一致状态，无重复行配置、无端口冲突、无已存在实体报错。

#### 交付物格式：`audit/chaos-report.md` 与 `audit/disaster-test-report.md`
必须包含：
- **恢复力评分 (Resilience Score)**：0-100 分。
- **故障注入矩阵判定表**：10 项场景的 PASS/FAIL 及行为评析。
- **失联风险评估 (Lockout Evaluation)**：明确给出 SSH 与 Firewall 锁死风险指标（NONE / DETECTED）。

---

### 3.3 子智能体 3：生产就绪与合规发布审计员 (`subagent-production-readiness`)

#### 角色与职责设定
你是一名**主流 Linux 发行版维护者、QA 总监与合规审计官**。你需要从商业发布、标准化基线与用户体验的视角，审视本工具是否达到对未知大众客户交付的成熟度。

#### 审查核心域
1. **多发行版兼容性覆盖**：
   - 深入审查针对 Ubuntu 20.04/22.04/24.04 与 Debian 11/12 的差异化适配：
     - 系统服务名（`ssh` vs `sshd`）
     - 防火墙后端（`ufw` vs `nftables`）
     - 网络管理服务（`systemd-networkd` / `netplan`）
     - 依赖包名兼容性
2. **CIS Benchmark Level 1 Server 安全合规映射**：
   - 逐项核查系统加固参数：
     - SSH 策略：禁用空密码、限制认证尝试次数 (`MaxAuthTries <= 4`)、设置会话超时。
     - 内核参数加固（`sysctl`）：禁用源路由转发、开启 SYN 洪水防护 (`tcp_syncookies = 1`)、反向路径校验 (`rp_filter = 1`)。
     - 文件与用户权限基线：密码生命周期策略、umask 防护。
3. **幂等性与状态完整性测试**：
   - 验证 `config/install-result.env` 是否完整持久化执行结果。
   - 验证 `--dry-run`（试运行）参数是否真正做到 0 破坏、0 写盘、0 系统污染。
   - 验证 `--rollback` 回滚引擎能否完全恢复至 [audit/before-state.json](audit/before-state.json) 的原始基线。
4. **日志追踪与商业级运维可观测性**：
   - 审查日志系统（`lib/core.sh`）是否具备时间戳、日志级别、独立文件输出与诊断汇总输出。
   - 审查健康巡检脚本功能，确保安装完成后提供一键式系统健康度自检报告。

#### 交付物格式
- [audit/compatibility-matrix.md](audit/compatibility-matrix.md)
- [audit/cis-security-review.md](audit/cis-security-review.md)
- [audit/idempotency-report.md](audit/idempotency-report.md)
- [audit/install-report.md](audit/install-report.md)

---

## 4. 聚合裁决与生产发布评估报告生成 (Release Gate Synthesis)

在各子智能体完成审查后，主编排器必须将所有成果进行汇总，产出终审报告：[audit/production-readiness.md](audit/production-readiness.md)。

### 4.1 报告标准结构要求
```markdown
# VPS Init Setup 商业级生产达标评估报告

## 1. 终审发布结论 (Executive Verdict)
- **最终发布裁决**: [ READY (批准发布) | CONDITIONAL (受控测试) | NOT READY (严禁发布) ]
- **综合加权得分**: [XX / 100]
- **致命红线触发状态**: [ 0项触发 (安全) | 触发具体红线编号 ]

## 2. 核心子域评分明细
| 审计域 | 负责智能体 | 权重 | 原始得分 | 加权后得分 | 关键合规判定 | 对应详细报告 |
|---|---|---|---|---|---|---|
| 红队对抗性安全 | subagent-adversarial-security | 40% | [XX] | [XX.X] | PASS/FAIL | [安全报告](security-adversarial-report.md) |
| 混沌与恢复力 | subagent-chaos-resilience | 35% | [XX] | [XX.X] | PASS/FAIL | [混沌报告](chaos-report.md) |
| 生产就绪与合规 | subagent-production-readiness | 25% | [XX] | [XX.X] | PASS/FAIL | [CIS与幂等报告](cis-security-review.md) |

## 3. 商业化缺陷分级清单与修复补丁 (Defects & Remediation Patches)
### P0 级致命缺陷 (Commercial Blocker)
- 缺陷编号与名称:
- 触发文件与行号:
- 商业风险剖析:
- **具体修复代码补丁 (Unified Diff / Code Replacement)**:

### P1 级严重缺陷 (Pre-launch Fix)
- ...

### P2 级优化建议 (Post-launch Improvement)
- ...

## 4. 商业发布达标行动计划 (Actionable Roadmap)
- [ ] 修复全部 P0 缺陷并重新执行混沌压测
- [ ] 消除 P1 级别配置与合规风险
- [ ] 在全新 Ubuntu 24.04 及 Debian 12 裸机上执行全量验收
```

---

## 5. 面向 LLM 的直接分发调用 Prompt 指南 (LLM Execution Guide)

当作为 AI 智能体执行此审计时，你可以按以下模式直接触发或分解执行：

```text
你现在扮演「VPS 初始化商业级审计总编排器 (Audit Orchestrator)」。
请根据 .github/skills/vps-audit-orchestrator/SKILL.md 规范，全面审查本代码库。
1. 首先作为 Master 检查代码整体架构与基线探针；
2. 依次以 subagent-adversarial-security、subagent-chaos-resilience、subagent-production-readiness 三大视角深入每一行代码；
3. 输出缺陷行号、复现逻辑以及修复代码；
4. 综合判定本项目是否达到「生产级商用 (Commercial Ready)」标准，并生成 audit/production-readiness.md。
```

