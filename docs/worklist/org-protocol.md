# TFA ↔ TFA-Org 节点协议 v1

> 需求文档 §10.3 的落地。两边（TFA 的同步客户端、TFA-Org 的 `api` Blueprint）都以本文为准；改协议先改本文。
> 服务端：`~/Desktop/TFA-Org`（Flask）。客户端：TFA 的 `SuperagentRuntime` 同步循环。

## 0. 约定

- 前缀 `/api/v1`，全部 JSON；时间 ISO 8601 UTC 字符串（`2026-11-08T03:12:00Z`）。
- 节点请求头 `Authorization: Bearer <node_token>`；`X-TFA-Node: <node_id>` 可选（便于日志）。注册用邀请码，不带 token。
- 错误：`{"error": "<机器可读的 code>", "message": "<给人看的一句>"}`，HTTP 状态：400 参数错、401 token 无效或被吊销、403 不在范围允许名单内、404 不存在、409 冲突（领取失败 / 版本过期）、422 业务拒绝。
- 服务端时间为准（I-07）；客户端 `updated_at` 只用于界面排序。
- 永不上传：终端回滚、环境变量、命令全文（I-06）。审计只传命令摘要和凭据**名字**。

## 1. 对象

### Task（组织任务）

```json
{
  "id": 128, "label": "T-128",
  "title": "结算对账任务偶发超时",
  "request": "结算服务的对账任务昨晚又超时了，看一下。",
  "source": "feishu", "source_ref": "feishu:om_xxx/thread_yyy",
  "scope": {"id": 3, "name": "payment-service", "kind": "repo", "path_hint": "payment-service"},
  "owner_email": "a@x.com",
  "assignee_email": "b@x.com", "assignee_node": "node-7f3a", "claimed_at": "…",
  "due": "2026-11-14T00:00:00Z", "priority": "high",
  "deps": [120],
  "workflow": {"id": "default", "name": "默认", "stages": [{"name": "待领取", "kind": "todo"}, {"name": "进行中", "kind": "doing"}, {"name": "待评审", "kind": "review"}, {"name": "完成", "kind": "done"}]},
  "stage": "进行中", "status": "open",
  "items": [{"id": 901, "ord": 1, "text": "复现超时", "assignee": "agent:开发", "status": "done", "done_by": "开发", "done_at": "…", "started_at": "…"}],
  "result_summary": "", "note": "",
  "needs": {"kind": "answer", "question": "…", "since": "…"},
  "version": 7, "updated_at": "…"
}
```

- `status`: `open | done | cancelled | dropped`；`stage` 是工作流快照里的阶段名；`kind` 同 TFA（todo / doing / review / done）。
- `assignee` 同 TFA 的 `Assignee.raw`：`""` / `你` / `agent:<角色>`。
- `version` 每次服务端写入 +1；客户端 PATCH 时带 `base_version`，服务端按 §3 合并，不用乐观锁拒绝（勾选取并集），只有 `stage` / `status` 的后退才 409。
- `needs` = 这个任务此刻需要人的事（答问题 / 评审 / 受阻 / 失败），由节点上行，服务端只记录并展示。
- 只读附加字段：`stage_kind`（当前阶段的 kind）、`edits`（派单授权：能否改文件）、`created_at`。
- **预留**：Web 上「领取」和「派单给人」都只记 `assignee_email`、进第一个 doing、`assignee_node` 留空；该人的 TFA 收到 `task.assigned`（`reserved: true`）后用 `claim` 绑定本节点（CAS `assignee_node IS NULL AND assignee_email = 我`），同一人的第二台得 409。直接派给节点的不带 `reserved`。

### Node（节点）

```json
{"id": "node-7f3a", "person_email": "b@x.com", "roles": ["助理", "开发", "评审"], "version": "0.23.0",
 "machine": "bbc 的 MacBook Pro", "online": true, "last_seen": "…", "slots": 3, "open_tickets": 1}
```

### Policy（范围规则）

```json
{"scope_id": 3, "version": "b9bb662dd4ef", "mode": "observe",
 "rules": [{"id": "r1", "name": "CI 失败就修", "enabled": true, "instruction": "…", "role": "开发"}],
 "allowed_senders": ["a@x.com", "github:octocat"],
 "workflow": {…同上…}, "interruption_budget": 8}
```

## 2. 端点

| 方法 | 路径 | 请求 | 响应 | 说明 |
|---|---|---|---|---|
| POST | `/nodes/register` | `{invite_code, node_id, person_email, roles[], version, machine}` | 201 `{token, node, workspace:{id,name}, person:{email,name}, server_time}` | 邀请码由管理员按成员生成，一次性；`node_id` 由客户端生成并持久化（UUID 前 8 位）。同一 `node_id` 重复注册 = 换 token（旧 token 吊销）。 |
| POST | `/nodes/heartbeat` | `{online, slots, open_tickets, roles[], version}` | `{ok, server_time, policy_versions:{"<scope_id>": "<version>"}}` | 每 30 s；2 分钟没心跳 = 离线，离线不自动领取（I-04）。 |
| GET | `/tasks` | query `mine=1`（派给我 / 我领的 / 预留给我）、`claimable=1`（本范围待领取）、`since=<cursor>` | `{tasks:[Task], claimable:[Task], cursor}` | `cursor` 是服务端的全局改动序号（`task.change_seq`），原样回传；`tasks` 只返回之后有变化的（首次不带 → 全量）；`claimable` 每次都是全量，客户端用它对账：本地的待领取占位行里服务端不再列出的 = 被别人领走，删掉。 |
| GET | `/tasks/{id}` | — | `{task}` | |
| POST | `/tasks/{id}/claim` | `{}` | 200 `{task}` / 409 `{error:"claimed", task}` | 服务端 CAS：`assignee_node IS NULL`，且（待领取）或（预留给我）（I-05）；预留给别人也 409；不在范围允许名单 → 403；前置未完成 → 422 `deps_open`。 |
| PATCH | `/tasks/{id}` | `{base_version, stage?, status?, items:[{id, status, done_by, done_at, started_at}], result_summary?, updated_at}` | `{task, conflicts:[{item_id, server_status, client_status}]}` | 上行阶段 / 勾选 / 结果。合并见 §3。 |
| POST | `/tasks/{id}/needs` | `{kind: "answer"|"review"|"blocked"|"failed"|"none", question?, ticket_ref?}` | `{task}` | 需要人；`none` 清除。服务端据此给范围负责人发「需要你」（Web 上琥珀 + 回到原处）。 |
| POST | `/tasks/{id}/audit` | `{entries:[{at, kind, summary, credential_names:[…]}]}` | `{ok}` | 命令摘要和凭据名，不传命令全文。不是负责节点写的记录（Web 上的留言、主管 attach 的后续消息）会让负责节点收到 `task.updated {change: audit, entries}`，节点转告主管。 |
| POST | `/nodes/interruptions` | `{date:"2026-11-08", count: 3}` | `{ok}` | 当天打扰次数（本地日）。 |
| GET | `/scopes/{id}/policy` | — | `Policy` | 带版本；客户端只在心跳里看到版本变化时拉。 |
| GET | `/events` | query `since=<cursor>`，长轮询最多 25 s | `{events:[Event], cursor}` | 推送的替代：派单、打回 / 通过、取消、规则版本变化。没有事件时 25 s 后返回空数组。 |

Event：`{"id": 55, "type": "task.assigned" | "task.updated" | "task.rejected" | "task.approved" | "task.cancelled" | "task.unassigned" | "policy.changed", "task_id": 128, "scope_id": 3, "payload": {…}, "at": "…"}`。
payload：`task.assigned` `{edits, by, reserved?}`；`task.rejected` `{text, item_id, by}`（服务端已把意见追加成新清单项，客户端不再本地加项，只回到进行中并把意见送给原工单）；`task.updated` `{change: created|claimed|reserved|assigned|transferred|released|stage|fields|items|needs|answer|audit|dropped|blocked, …}`（`answer` 带 `text`，是人在 Web 上回答的留言；`audit` 带 `entries`）；`policy.changed` `{version, mode}`。

## 3. 同步规则（需求文档 §10.3）

- **下行**：任务字段、工作流、清单、派单、规则版本。节点对每个组织任务在本地也建一行 `task`（`origin = "<server>"`, `origin_id = "<id>"`），工单只在本地。
- **上行**：阶段、清单勾选、结果摘要、需要人、当天打扰次数、审计摘要。走 outbox（append-only，按序重放，发送成功才删，I-02）。
- **合并**（服务端 PATCH 时）：任务字段以服务端为准（标题 / 原文 / 范围 / 截止 / 优先级 / 依赖 / 工作流不接受客户端修改）；清单逐项按 `item.changed_version`（服务端这一项上次改动的版本）和 `base_version` 比：服务端在 `base_version` 之后没动过的项**听客户端的**（含 done → doing / todo：打回后重做、人取消勾选）；服务端在 `base_version` 之后置 done 的留 done（任一边的新 done 都不丢）；两边在 `base_version` 之后改成不同的非 done 状态 → 不裁决，返回 `conflicts`，客户端把它放进「需要你」（冲突项本地先标受阻，人选「本地为准 / 服务端为准」）；`stage` 只能前进（后退靠服务端的打回事件），客户端只在前进到 doing 时上行 stage，review / done 由服务端按清单完成情况自动推进；`status` 的结束态只能由服务端（通过 / 取消）或节点的 `dropped` 设置。
- **打回**：服务端把意见追加为新清单项（否则清单仍全 done，下一次上行又立刻进待评审），任务回第一个 doing。
- **节点侧**：组织任务的待评审不算本地「需要你」（通过 / 打回在 Web），节点只上行 `needs: review`；本地取消组织任务 → 上行 `status: dropped`；预留给我但还没绑节点的任务本地显示为待领取，人点「领取」才绑定；只有直接派给节点的 `task.assigned`（带 `edits`）才自动把清单项交给角色。`policy.changed` 客户端目前忽略（本机规则是本机的，`GET /scopes/{id}/policy` 暂未接）。
- **离线**：本地照常；重连后先拉（`GET /tasks?since=`）再重放 outbox；重放时 `base_version` 用本地记录的最后已知版本。
- **领取**：人领取（Web 或 TFA 的「待领取」分区）、TFA 自动领取（范围接单模式为自动 + 节点在线 + 能力匹配）、负责人派单（Web）。派单带授权：范围、能否改文件（`payload.edits`），节点据此选角色 / 建工单。

## 4. 事件源（服务端入站）

| 路径 | 校验 | 说明 |
|---|---|---|
| `POST /sources/github` | `X-Hub-Signature-256`（HMAC-SHA256，范围绑定的 secret） | issues / issue_comment / pull_request / pull_request_review_comment；`@主管`（可配置的 handle）或允许名单内的人 = explicit，否则 inferred 候选。回复 = 在同一 issue / PR 评论。 |
| `POST /sources/http/<source_key>` | `Authorization: Bearer <source token>` | 通用入口：`{sender, text, thread?, scope?, reply_url?}`；回复 POST 到 `reply_url`（有的话）。 |
| `POST /sources/feishu` | 事件订阅的 verification token / encrypt key；`url_verification` 回 challenge | `im.message.receive_v1`；`@主管` = explicit；回复用「回复消息」API（需要 app id / secret，配置项）。 |
| `POST /sources/dingtalk` | `timestamp` + `sign`（HMAC-SHA256，机器人 appSecret） | 企业内部机器人 outgoing（@机器人即 explicit）；回复 POST 到消息里的 `sessionWebhook`。 |
| 定时 | 服务端自己的调度（每分钟检查） | 范围上的定时任务 → 建组织任务（source=schedule）。 |

回复一律 ≤100 词（中文按分词），一句话：结果 + 链接 / 位置 + 需要人做的事；进展不回复。

## 5. 组织主管（headless Router）

Source → Trigger → Thread（按来源的会话 / issue / PR 分组）→ Eval（确定性 gate：发送人是否在范围允许名单、强度 explicit / inferred；模型研判：每条启用规则恰好一次、方向不明确不接）→ Decision（accept / attach / ignore / would_accept / unavailable）→ Task（+ Mandate：强度、范围、规则版本、命中的规则）。

- 一个 Thread 同时只跑一个 Eval；任何事件 15 分钟没研判完 → unavailable（服务端对 explicit 也过期：主管不在就不接，人可以再说一次）。
- accept 的任务：explicit → 进「待领取」（或范围配置了默认负责人 / 节点 → 直接派）；inferred 在 `auto` 模式 → 进待领取并标「规则接单」，`observe` → 只记 would_accept 进观察记录。
- 模型后端可配置：`ROUTER_MODEL_BACKEND = claude-cli | anthropic | fake`；`claude-cli` 用本机 `claude -p --output-format json --model <m>`（走订阅），`anthropic` 用 `ANTHROPIC_API_KEY` 调 Messages API；默认模型 `claude-sonnet-5-5`。
- 回复回到原处：由 `outbox_reply` 表异步投递（失败退避，3 次后进「问题」）。

## 6. 安全（见 TFA-Org/docs/security.md）

节点 token 只存哈希、可吊销；邀请码一次性；webhook 全部验签；Web 表单 CSRF；口令用 werkzeug 哈希；本机部署只监听 127.0.0.1，上公网必须 HTTPS。
