# TFA × Super-agent：原理研究与重构方案

> 研究对象：DeepSeek 开源原型 `deepseek-ai/dsh-superagent-prototype`（MIT，commit 8c32a9d，2026-10-31），
> 对应 DeepSeek 文章《Super-agent 设计探索》。本地克隆在 `~/Desktop/research/dsh-superagent-prototype`。
> 方法：4 个研究 agent 并行通读 9 篇设计文档、全部 prompt 与约 1.2 万行 TypeScript，本文是汇总。
> 后续：按角色派发（常驻「助理」+ 每单「开发」，主管先选角色再接单）见 [superagent-roles.md](superagent-roles.md)。
> 状态：**已实施（第 1–3 期，2026-11）**。确认结果：三期全做；主管用 Claude Code；执行终端全部放行；默认每个工单一个 git worktree；界面围绕主管 + 工单重排。实现与方案的差异见文末「实现说明」。

---

## 第一部分　原理

### 1. 唯一的原则

> **Take as little human attention as possible, and give as much value as possible.**（docs/000）

每条消息、每个通知、每个问题、每个设置、每个面板元素都要花人的注意力，给不出更多价值就删掉。由此推出：

| 对 agent | 对设计 |
|---|---|
| 只在**被明确要求**或**有成文规则允许**时行动；没人要求的工作先进入「只记录、不执行」模式 | **概念少**：业务需求要么是已有概念的属性，要么写成 prompt，不新增概念 |
| 只在人**必须行动**或**能用上结果**时说话：确认一次、干活时安静、有结果/要决定/做不成时才再说话 | **设置少**：一个默认值适合几乎所有团队，就不做开关 |
| **一次只问一个具体问题**，用结构化字段问，不埋在长报告里 | **面板只显示需要人的东西**，健康状态不占空间 |
| **按影响停，不按努力停**：局部改动做到可评审；需要设计决定就停下来问 | |
| **如实汇报**：草稿标未完成，失败报失败，绝不绕过限制来避免提问 | |

### 2. 领域模型（只有这些概念）

```
Source ──Trigger──▶ Thread ──批次──▶ Eval(准入 gate → 模型研判) ──Decision──▶ Ticket(+Mandate)
                       │                                                      │
                       └──Subscription 扇出(人的跟进直接送达，不再评估)────────┤
                                                                              ▼
                                         Executor(一个 Session + 一个目录) ◀── Assignment
                                                                              │
                                              结果经 Channel 回到原会话 ◀─────┘
```

| 概念 | 一句话 | 关键规则 |
|---|---|---|
| Source | 事件流（GitHub、飞书…） | 自带读取位置，重启不重放；进领域前丢掉自己的消息 |
| Trigger | 一条不可变事件 | 审计与幂等的单位；同一条被接受两次也只生成一个 Ticket |
| Thread | 按时间排列的 Trigger | 同一 Thread 同时只跑一个 Eval |
| Eval | 对一批 Trigger 的判断 | 两层：确定性 **gate**（谁能发起、强度 explicit/inferred）+ 模型 **研判** |
| Decision | Eval 结果 | accept / stop / ignore / unavailable |
| Mandate | accept 授予的权限 | 不可变：强度、范围、Policy 版本、命中的规则 |
| Ticket | 一个获授权的工作单元 | **只有 Eval 能创建**；自有状态，不跟随执行会话 |
| Assignment | Ticket 与一次执行的绑定 | 一个 Ticket 先后可有多个（重试、唤醒、重启） |
| Report | 执行方回报的状态 | progress / waiting / ready / blocked / failed / dropped |
| Attention | 一个等人回答的结构化问题 | 只能通过结构化字段提出 |
| Policy | 版本化的规则 + 准入表 + accept 模式 | 规则变更通知受影响的 Ticket，**不取消**正在跑的工作 |

**明确否决**的设计（节选）：从自由文本推断「在等人」；Ticket 状态跟随会话；Policy 变化时取消工作；执行方自己宣称「人让我停」；一个 Thread 最多一个 Ticket。

### 3. 授权：先规则、后模型

- **explicit**（人直接找 agent，且在允许名单上）→ 任何模式下都能接单。
- **inferred**（没人点名，但有成文规则可能适用）→ 看 accept 模式：
  - `off`：不考虑；`observe`（**默认**）：照常研判，但只记录 "would accept"，不执行；`auto`：研判通过就接单。
- 研判必须对**每条启用的规则**逐条给出判断，方向不明确（`requires_design_decision`）一律不接。
- Policy 版本 = 规则 + 模式 + 准入表的哈希；每个 Mandate 记下它依据的版本。

### 4. 两种会话、严格分工

| | Router（主 Session） | Worker（执行会话） |
|---|---|---|
| 职责 | 读、路由、建/停 Ticket、回复人 | 在自己的目录里把一个 Ticket 做完 |
| 工具 | 14 个（`orchestrator_route` 一次 1–20 个决定、`orchestrator_reply`…），**没有写文件/编辑** | 6 个（`ack` 确认一次、`report` 结构化回报、`handback` 退回越界请求…）+ 编码工具 |
| 禁止 | 不看代码、不自己解决 blocker、不加需求、不 sleep 轮询、不 merge | 不直接找人、不发第二条消息、不谎报成功、不删目录 |
| 对人说话 | `orchestrator_reply` 有网关：result 要求 ready；attention 必须原样复制 worker 的问题 | 只能 `ack` 一次 |

回复风格：默认**一句话**（结果 + 链接 + 必要动作），硬上限 100 词；用源会话的语言；"IM is a delivery notification, not a work report."

### 5. 执行引擎

- **Pass 主循环**：每 2 秒 + 有新事件时立即，单飞（同时只跑一个，并发请求合并成一次）。每轮：派发副作用 → 处理超时 → 唤醒 → 启动 Eval。
- **副作用队列（effect 表）**：`(kind,key)` 主键，和状态变更在**同一个事务**里入队，提交后才执行；失败指数退避（2s→60s、5s→300s），连续 3 次失败才报警；"稍后"（槽位满/会话忙）不计失败。
  - kinds：`assessment`（送研判）、`launch`（起执行会话）、`delivery`（把输入送给 worker）、`relay`（worker 回报送给 Router，有序）、`reply`（回复人）。
- **WorkerSlots**：默认 3 个并发执行；人的跟进额外 +1 槽，唤醒优先于新建。
- **一个 Ticket 一个会话 + 一个目录**（可由 prepare 命令建 git worktree）；重试/唤醒沿用同一会话和目录。
- **状态 / 计算 / 环境分离**：唯一的 SQLite 是事实来源，只有 Engine 写领域数据；LLM 会话可丢弃可重建；目录「存在即已准备」。
- **重启恢复**：完全依赖持久化状态，把已投递未读取的输入放回队首，新建 Assignment 并附恢复说明。

### 6. 面板

Overview 只列**需要人**的 Ticket（按 answer → review → blocked → failed 排序），每行给出跳转、重试、停止；问题列表（setup 缺失、源报错、Eval 超时…）；健康状态不占位置。**没有「批准」按钮**：人的回答一律回到原会话里写。

---

## 第二部分　TFA 现状对照

TFA 天然具备 Super-agent 的「执行层」，缺的是「授权层」和「路由层」。

| Super-agent | TFA 现有 | 差距 |
|---|---|---|
| Executor：一个会话 + 一个目录 / Ticket | tmux 会话 = 隔离终端，跑 Claude Code / Codex / axis-claude | ✅ 已有，而且 tmux 会话在 App 崩溃后仍存活（比原型更强） |
| delivery（steer 进会话） | `ConnectionSession.sendLine`（打字 + 250ms 后回车） | 终端只能「打字」，没有结构化 inbox，需要自己做送达确认 |
| Worker 状态（agent/status idle、error） | `isWorking`、OSC 133、BEL/OSC 9 注意力检测 | ⚠ 只能看屏幕，不是结构化事件 |
| `orchestrator_report` 结构化回报 | 无（v0.20 删除了 `tfa-task` 看板） | ❌ 需要新的回报通道 |
| Router + 工具 | 无（人自己当 Router） | ❌ |
| Eval / Policy / Mandate / Decision | 无 | ❌ |
| Pass 循环 | `startScheduler` 1.5s 心跳 | 可扩展 |
| effect 队列 + 退避 | 无（v0.20 删掉的 DispatchCenter 有「空闲才发、排队、送达核验」） | 可复用 git 历史中的 DispatchCenter |
| 面板 Overview | 「待处理」按钮 + AttentionCenter | 可升级为「需要你」视图 |
| 状态存储 | `~/.tfa/sessions.db`（SQLite WAL） | 新建 `~/.tfa/superagent.db` |

**遗留问题（现在就有）**：`~/.claude/skills/tfa-task/` 和 `~/.tfa/bin/tfa-task` 是 v0.20 前装的，App 已不再读 `board.db`，但你的每个 Claude Code 会话仍会加载这个失效的 skill。重构时替换掉。

---

## 第三部分　重构方案

### 设计原则（照搬原型）
1. **TFA 只加 Super-agent 的必要概念**：请求(Trigger)、工单(Ticket)、派工(Assignment)、回报(Report)、待你决定(Attention)、决定(Decision)。Policy/规则/研判放到第 2 期。
2. **单一写入者**：所有领域数据只由 App 内的 `SuperagentEngine`（纯 Swift、无 I/O、可单测）写入；Router、Worker、CLI 都只「提交命令」或「读视图」。
3. **结构化回报，不猜屏幕**：worker 必须用 `tfa report` 回报状态和问题；屏幕信号（空闲、BEL）只作兜底（如原型的 workerIdle：空闲且未回报 → 记 waiting 并附最后输出）。
4. **安静**：progress 只进记录不通知；只有 ready / 需要你决定 / 做不成 才进「待处理」和系统通知。
5. **模型无关**：Router 和 Worker 都通过同一个 `tfa` 命令行工具和 App 交互，所以 Claude Code、Codex、axis-claude 都能当 Router 或 Worker。

### 目标架构

```
┌──────────────────────────── TFA.app ────────────────────────────┐
│  SuperagentEngine（纯逻辑，单一写入者）                              │
│    Ticket/Assignment/Report/Attention/Decision 状态机             │
│  Pass 循环（复用心跳，单飞）  ──▶  Effect 队列（SQLite，退避重试）     │
│     launch：建执行终端（一个 Ticket 一个 tmux 会话 + 一个目录）        │
│     delivery：空闲时打字送入，屏幕标记核验送达（复用 DispatchCenter）   │
│     relay：把 worker 回报打进「主管」终端（有序）                      │
│     notify：进入「需要你」时发系统通知                                 │
│  WorkerSlots（默认 3，人的跟进 +1）                                   │
│  ~/.tfa/superagent.db（WAL；命令表 + 领域表 + effect 表）            │
└───────────────▲──────────────────────────────────▲──────────────┘
                │ 提交命令 / 读视图（SQLite）         │
        ┌───────┴────────┐                  ┌──────┴─────────┐
        │ 「主管」终端      │                  │ 执行终端 ×N      │
        │ Claude Code      │                  │ Claude Code /   │
        │ --system-prompt  │                  │ Codex / axis    │
        │ 只允许 tfa 路由命令│                  │ + tfa worker 命令│
        └──────────────────┘                  └────────────────┘
```

- **`tfa` 命令行**（随 TFA.app 分发，Swift，仅依赖 Foundation，和 axis-claude 一样）
  - Router 子命令：`tfa read <资源>`、`tfa route accept|attach|stop|ignore …`（一次 1–20 个决定）、`tfa note`、`tfa status-request`、`tfa retry`、`tfa reply answer|result|attention`（带网关校验）。
  - Worker 子命令：`tfa ack <ticket> "<具体对象+预期结果>"`、`tfa report <ticket> --state ready|blocked|failed|dropped|progress --summary … [--ask "一个问题"]`、`tfa handback`、`tfa read ticket/<id>`。
- **「主管」**：侧栏顶部固定一个「主管」终端。默认用 Claude Code 启动：`--system-prompt-file`（改写自原型的 shared/orchestrator/dispatch/replies prompt）+ `--allowedTools "Bash(tfa:*)"` + 禁用 Edit/Write，让它**物理上碰不到代码**。你在这个终端里用自然语言提需求，它负责拆分、派工、汇总，只在需要你时说话。
- **执行终端**：主管 accept 后，App 新建一个终端（标题 = 工单标题，自动归入「工单」分组，目录可选 git worktree），启动所选 agent，打入一行派工指令（原文 ≤1500 字，更长的用 `tfa read` 读取）。
- **人的入口**：
  - 「待处理」升级为「需要你」：只列 answer / review / blocked / failed 的工单，行内「前往终端 / 重试 / 停止」。
  - 回答问题：直接在执行终端里打字（等同原型的「订阅扇出」——人的跟进直达 worker），或在主管终端里说。
  - 工具面板「主管」：只显示需要你的工单 + 问题列表 + 设置（并发数、执行 agent、目录策略）。
- **侧栏**：工单终端显示工单阶段（工作中 / 等你回答 / 待评审 / 受阻 / 失败）。

### 分期

| 期 | 内容 | 完成标准 |
|---|---|---|
| **1. 主管 + 执行（只接明确请求）** | Engine + 状态机 + superagent.db；Pass + Effect 队列；WorkerSlots；launch/delivery/relay；`tfa` 命令行（router + worker）；「主管」终端与 prompt；「需要你」视图；替换旧 tfa-task skill；与 tmux 存活会话对账的重启恢复 | 单测覆盖状态机与 effect 退避；在私有 tmux socket 上用假 agent 脚本跑通「提需求 → 派工 → 回报 ready → 进待处理 → 结单」；真实 Claude Code 端到端演示一次 |
| **2. 规则与主动接单** | Policy（自然语言规则 + off/observe/auto，默认 observe）+ 研判；终端事件源（某个终端的 agent 完成/报错）；定时任务源；决定日志与 Policy 历史 | observe 模式下 "would accept" 记录可在面板查看；切 auto 后按规则自动接单 |
| **3. 验收** | 接入 LobeHub Acceptance（Apache-2.0）：ready 前跑验收，「待评审」行内打开 `report.html` | 一个 Web 改动的工单产出带截图的验收报告 |

### 风险与对策

| 风险 | 对策 |
|---|---|
| 向 Claude Code 等 TUI「打字」送达不可靠（粘贴识别、忙时吞键） | 沿用已验证的 `sendLine`（文本后 250ms 回车）+ 只在空闲时发 + 屏幕标记核验；失败走退避重试并在面板显示 |
| 执行终端里的 agent 卡在权限提示 | 由你选：执行终端用 `--permission-mode acceptEdits` / `bypassPermissions`，或保留提示（卡住时 BEL 进「需要你」） |
| 主管用 Claude Code 会消耗额度 | 可改用 axis-claude（本地模型，免费，较弱）；`tfa` 命令对两者通用 |
| 状态与 tmux 不一致（会话被手动关掉） | 每轮 Pass 对账；Ticket 有自己的状态，不跟随会话（原型的设计） |
| 改动面大 | 新代码集中在新模块（`Superagent*.swift` + `Sources/TFACLI`），现有终端功能不改；每期独立提交、可回滚 |

### 需要你确认
1. 是否按此方案启动第 1 期？
2. 「主管」默认用 Claude Code（强、耗额度）还是 axis-claude（本地、免费）？
3. 执行终端默认用哪个 agent，以及权限模式（保留提示 / 自动接受编辑 / 全部放行）？
4. 每个工单是否默认建 git worktree（隔离改动，适合同仓库并行）？

---

## 实现说明（与方案的差异）

| 方案 | 实现 | 原因 |
|---|---|---|
| CLI 往命令表插命令、等 App 执行 | CLI 直接调用同一份 `SuperagentEngine`，在 `BEGIN IMMEDIATE` 事务里写 `superagent.db`，提交后发 Darwin 通知让 App 立刻跑一轮 Pass | 领域逻辑仍只有一份（单一写入者是「同一个引擎」而不是「同一个进程」）；App 没开时主管/执行者也能读写，少一个往返和超时 |
| relay 用 IM 回复人 | 主管自己在终端里对人说话，所以没有 `reply` 网关；relay 把回报打进主管终端 | TFA 的人就坐在终端前 |
| ready 即结单 | ready 进「待评审」，人点「通过」才结单（有工单分支就先合并进主仓库当前分支，合并不了不结单），「打回」把意见送回执行终端 | 本地评审是 TFA 的交付环节 |
| 只靠结构化回报 | 屏幕信号只做兜底：停下 `idleSeconds`（默认 90 秒）没回报先催一次，仍不回报记「停下未回报」；agent 退出、会话丢失各自处理 | 终端无法强制结构化，兜底避免工单悄悄卡死 |

代码位置：`Sources/SuperagentCore`（模型、存储、引擎、规则、prompt）、`Sources/TFACLI`（`tfa`）、`Sources/Mux/Superagent*.swift`（tmux 驱动、Pass 循环、界面）、`Sources/Mux/AppModel+Superagent.swift`（侧栏/通知接入）。

