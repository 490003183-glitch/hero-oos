# Hero OOS operations

## Wrapper

From the installed skill directory:

```bash
./scripts/hero-oos meta
./scripts/hero-oos state
./scripts/hero-oos attention
./scripts/hero-oos worker-list
./scripts/hero-oos changes --consumer codex-global
./scripts/hero-oos changes-ack --consumer codex-global --version <n>
./scripts/hero-oos op --expected-version <n> --file <ops.json> --mutation-id <unique-id>
```

Read changes first; acknowledge only after reading affected entities. If `resyncRequired` is true, reload state and Current Truth before acknowledging.

## Status model

- `active`: explicitly in progress.
- `ready`: executable now.
- `review`: requires a close/review decision.
- `waiting`: blocked by a named external condition; pair with `waitingCondition` and, when known, `reviewDate`.
- `paused`: intentionally not being executed now; keep the task, but exclude it from Today, Current Truth, attention, and execution ranking until its status changes.
- `backlog`: not scheduled for execution.
- `blocked`: dependency is incomplete or abnormal.
- `information`: awareness only; exclude from execution ranking.
- `completed` / `cancelled`: closed history.

When asked what to do next, rank explicit current choice, hard deadlines within 24 hours, active work, ready work within seven days, due reviews, then other executable work. Keep waiting, backlog, blocked, and information items after executable work and explain why. Exclude paused items unless the user explicitly asks to inspect or resume them.

## Common payloads

Create a task (no track is required; use an existing track ID only after reading the workspace):

```json
[{"type":"task.create","task":{"title":"任务名称","status":"ready","priority":5,"priorityBase":5,"priorityOrigin":"system-default","project":"项目名","due":null,"reviewDate":null,"waitingCondition":null}}]
```

Update, defer, or complete:

```json
[{"type":"task.update","id":"TASK-ID","changes":{"status":"waiting","waitingCondition":"等待甲方回复","reviewDate":"2026-08-28","statusNote":"已发出确认"}}]
```

```json
[{"type":"task.update","id":"TASK-ID","changes":{"reviewDate":"2026-09-01","deferCount":2,"priority":7}}]
```

```json
[{"type":"task.complete","id":"TASK-ID"}]
```

Schedule one execution:

```json
[{"type":"schedule.create","block":{"title":"处理任务","taskId":"TASK-ID","start":"2026-08-26T10:00:00+08:00","end":"2026-08-26T11:00:00+08:00"}}]
```

Quick Capture commits immediately and creates a Worker review item:

```json
[{"type":"capture.add","text":"未经整理的真实情况"}]
```

Undo with the receipt returned by the original mutation:

```json
[{"type":"receipt.undo","receiptId":"receipt-id"}]
```

## Migration provenance

Legacy V2 IDs are preserved as canonical task IDs. Imported tasks retain `sourceSystem`, `sourceId`, `sourceStatus`, the full `sourceRecord`, project fields, priority lineage, waiting/review semantics, parent links, and dependency links. Do not write status changes back to the old ledger after cutover.
