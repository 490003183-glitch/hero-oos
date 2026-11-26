# Hero OOS cloud core

Python 3.11+ / aiohttp / Argon2id / SQLite，单进程运行，始终仅绑定 `127.0.0.1:4180`（端口可配置，绑定地址不可配置）。TLS、公开限流及安装包托管由独立 nginx 配置负责，不覆盖机器上其他服务。

## 安装、运行、验证

```sh
python3.11 -m venv .venv
.venv/bin/python -m pip install -r requirements.lock
.venv/bin/python -m unittest -v test_server
.venv/bin/python server.py --config /etc/hero-oos/config.json
```

配置示意（**不是可直接运行的密码或默认凭据**）：

```json
{
  "database": "/var/lib/hero-oos/state.sqlite3",
  "port": 4180,
  "bootstrapTokenHash": "64位小写SHA256十六进制摘要"
}
```

- 引导 token 必须由部署者通过 `secrets.token_urlsafe(32)` 或更长的密码学随机数生成。服务器配置只存 SHA-256 摘要，明文仅由本人保管、首次初始化输入；日志及数据库不写明文。
- 不配置 `bootstrapTokenHash` 时，引导接口拒绝所有请求。首次初始化完成后，即使 hash 仍在配置里，也不能创建第二个拥有者。可移除 hash 后重启服务，进一步关闭入口。
- 数据目录应归专用服务用户、权限 `0700`，配置 `0600` 或受控 `0640`。主进程 umask `0077`，数据库 `0600`。不可多个实例并行监听或使用共享网络盘数据库。
- nginx 必须覆盖 `X-Real-IP` 为真实 `$remote_addr`，不能传透外部同名头。服务只接受回环地址连接，忽略 `X-Forwarded-For`。
- 建议 nginx 请求体上限 `9m`，应用总请求上限 8 MiB + 64 KiB，单文档 UTF-8 序列化上限 8 MiB；超限 413。代理应设置连接、请求速率及超时限制。日志格式不要含 Authorization、请求 body 或 token 查询参数。
- `/health` 执行数据库探针后返回 `{ok:true,service:"hero-oos",apiVersion:1}`，无用户数据。服务禁用访问日志，错误不返回堆栈。

## 认证、组织与权限 API

除服务端事件流外，请求和响应均为 JSON。除 health、bootstrap、register、login 和公开更新通知外，必须携带 `Authorization: Bearer <opaque-token>`。有效会话不按时间自动过期；服务端仅保存令牌的 SHA-256。每次请求和事件心跳均检查账号及组织成员状态，退出或停用可撤销会话；密码重置必须同时撤销该账号所有会话。

`GET /v1/events` 是需要认证的任务变更事件流，包含当前组织和私人任务的版本；`GET /v1/update-events` 是公开的版本号提示，不包含任务或账号数据。事件流只作同步提示，客户端下载更新仍须验证签名。反向代理应关闭缓冲并配置足够的读取超时。

升级到永久会话策略时，服务端只迁移仍有效的会话，不恢复已过期或撤销的令牌。旧版服务端不认识永久会话的标记；如果回退，用户需要重新登录。回退时不要用旧数据库覆盖之后产生的业务数据。

用户名全局唯一、大小写不敏感，3–64 位 ASCII 字母数字及 `_ . @ -`，以字母数字开头。密码 12–128 字符，Argon2id 19 MiB / t=2 / p=1，同时仅进行 1 个哈希，进行中及排队认证合计最多 8 个，超过时 429。组织名 1–64 字符，NFC + casefold 唯一。最多 100 个有效账号名额，包括待审、已获准和正常停用保留的账号。首次注册且所有申请都被拒绝的账号不再占名额，但保留原行、ID 和用户名，不能被新注册者复用；批准旧拒绝申请也须在事务内再次检查容量。一个组织拒绝成员不会撤销其在其他组织的批准，也不会释放曾获准账号的私人数据保留名额。容量仍通过原有成员关系计算；数据库 schema 2 只新增组织任务文档表，不修改账号或成员表约束。

| 请求 | body / 结果 |
| --- | --- |
| `POST /v1/auth/bootstrap` | `{bootstrapToken,organization:"Example Team",username,password}`；仅初始化一次，创建 owner，返回登录结构，201 |
| `POST /v1/auth/register` | `{organization,username,password}`；只能申请已存在组织；201 `{ok:true,status:"pending"}`，**不发 token** |
| `POST /v1/auth/login` | `{organization,username,password}`；账号与成员关系均须 approved；返回下方登录结构 |
| `POST /v1/auth/logout` | 吊销当前 token，`{ok:true}` |
| `GET /v1/me` | 登录结构去掉 token/expiresAt |
| `GET /v1/organizations` | `{memberships:[{id,name,role,status}]}`，`id` 为稳定组织 ID |
| `POST /v1/organizations/join` | `{organization}`；当前登录用户申请加入其他已有组织，pending，不提升角色；拒绝/停用成员须联系目标组织管理员恢复 |
| `GET /v1/members` | 当前组织 owner/admin 可见 `{members:[{id,userId,username,role,status}]}`，此处 id 为成员关系 ID |
| `PATCH /v1/members/{id}` | `{status:"approved/rejected/suspended",role:"admin/member"}`，字段可单独提供；只修改当前组织。不能改 owner 或自身权限。只有 owner 可任命/降级 admin，admin 仅管理普通成员 |
| `PATCH /v1/organization` | `{name}`；当前组织 owner 才能改名；稳定组织 ID 与会话均不变 |

登录结构：

```json
{
  "token": "仅本次响应提供的随机凭据",
  "expiresAt": null,
  "user": {"id": "uuid", "username": "account"},
  "organization": {"id": "稳定组织uuid", "name": "Example Team", "role": "owner"},
  "memberships": [{"id": "稳定组织uuid", "name": "Example Team", "role": "owner", "status": "approved"}]
}
```

初始组织名称由部署者在首次引导时指定，没有开放任意用户创建组织/自升管理员的入口。切组织须重新登录该组织（用户名密码相同）。测试中的其他组织是隔离 SQLite fixture，不创建任何线上测试组织。

## 组织任务、私人任务与本机拼图（2026-10-13 新口径）

只有任务管理信息云同步。非私人任务属于当前组织，所有已批准成员可以共同查看、修改及删除；私人任务也上云，但只属于本人，不对其他成员或组织管理员开放。私人任务以 **user ID** 隔离，不以组织 ID 隔离，同一账号切换已批准组织仍访问同一份私人任务。这里的“本人可见”是服务 API 权限隔离，不是端到端加密，服务器维护者仍能访问服务器数据库。

拼图画布、文字、图片资产以及任何本机路径不在同步文档中；没有拼图或图片上传接口。Codex 线程、回复摘要、设备布局、收集箱、记忆、决策、回执及未知字段也不允许经任务接口上传。客户端仍可在本机保留这些信息。

| 请求 | 作用域与结果 |
| --- | --- |
| `GET /v1/organization/state` | 当前会话组织；初始 `{revision:0,document:null}`，已有 `{revision:N,document:object}` |
| `PUT /v1/organization/state` | body `{expectedRevision:N,mutationId:"uuid",document:object}`；全部 approved 成员可写，成功 `{ok:true,revision:N+1}` |
| `GET /v1/personal/state` | 仅当前 user ID；响应格式同上；保留旧 schema 文档供本人恢复，不自动分享或改写 |
| `PUT /v1/personal/state` | 严格 schema 2 私人任务文档；body/成功响应同上；不再接受旧 schema 1 或任意 JSON |
| `GET /v1/shared/tasks` | 旧版本显式共享副本的只读恢复入口，保留当前会话组织的原记录，不自动迁入新组织文档 |
| `PUT /v1/shared/tasks/{id}` / `DELETE /v1/shared/tasks/{id}` | 已停用；认证通过后固定 403 `organization_state_required`，不修改旧记录 |

组织文档格式固定为：

```json
{
  "schemaVersion": 2,
  "scope": "organization-tasks",
  "state": {
    "tasks": [{"id":"task-1","title":"组织任务","taskSpace":"work"}],
    "tracks": [],
    "taskPages": []
  }
}
```

私人文档格式完全相同，但 `scope` 必须是 `personal-tasks`，每个任务 `taskSpace` 必须是 `personal`，`taskPages` 只能是空数组。组织只允许 `work` 或 `page-UUID`；显式拒绝私人任务、缺失或未知分区，不猜测归属。

服务执行递归字段白名单，不只是客户端过滤。顶层只允许 `schemaVersion/scope/state`，state 必须恰有三个集合 `tasks/tracks/taskPages`。任务字段为 `server.py` 中 `TASK_STRING_FIELDS/TASK_NUMBER_FIELDS/TASK_BOOL_FIELDS/TASK_ARRAY_FIELDS`；它们与原生 `OrganizationStateSchema` 固定对齐，包括任务标题、进度、阻断、父子/依赖、台账结算等业务字段。可空标量用 `null` 清除，数组不可为 `null`。`details/dependsOn` 仅文字数组，`peopleWaits` 每项只能含 `id/person/outcome/resolved`；禁止嵌套任意 JSON。Tracks 仅 `id/name/navLabel/archetype/status/createdAt/stages`，任务页仅 `id/title/createdAt`；只上传任务实际引用的定义。引用必须存在，父子需同页，关系不能循环，ID 不可重复。未知字段直接 400，不静默存储或丢弃。

单文档仍限 8 MiB，每集合/数组最多 100,000 项，实体 ID 最多 160 字符，标题最多 400 字符，普通文本最多 16,000 字符，任务页标题 1–60 字符。更改此契约必须同时更新服务端、客户端和测试；不得重新启用旧版全 state 上传作为回退。

CAS 和幂等规则：

- 事务内比较 `expectedRevision`，不匹配返回 409 `revision_conflict`，客户端必须重新 GET，禁止静默强制覆盖。
- mutationId 作用域为本人 + `personal-v2`，或本人 + 当前组织。私人新命名空间防止错误复用旧版全 state 回执；组织作用域防止同用户跨组织串用回执。相同 mutationId + 同一 expectedRevision/内容安全返回原成功 revision；相同 ID 不同内容返回 409 `mutation_conflict`。所有成员写同一个组织文档 revision，不能绕过他人的编辑。
- 读取/写入均实时校验会话、账号与该组织成员 approved；请求上传结束后，在写入事务内再次校验。上传途中被停用的账号也不能提交，幂等重试不能绕过停用。组织不能由 body、请求头或查询参数指定。
- 重试可能返回旧成功 revision（重试之前已有另一设备继续更新），所以客户端必要时再 GET，不把旧成功 revision 当成“当前最新”。服务不存 mutation 的文档副本，只存 hash 和小响应；不自动丢弃幂等记录。

容量保护：数据库有效页的全服共享配额为 **256 MiB**，不是每个账号保证 8 MiB x 100；每次新文档写入同时要求磁盘至少剩余 512 MiB。超过时返回 507 `storage_limit`，本机必须继续保留未同步内容。幂等回执仅存 hash/小响应，每账号上限 100,000 条；达到上限返回 507 `receipt_limit`，不静默淘汰，已存在的相同请求仍可重试。WAL 约每 2 MiB 自动 checkpoint，checkpoint 后 journal 保留上限 16 MiB（活跃事务期间临时可超过）。备份不计入库配额，部署层需按磁盘空间保留备份。拼图图片资产在本阶段**仅保留本机**，没有上传、跨端图片同步接口。

## 错误与限流

错误统一 `{ok:false,error:"code",message:"中文"}`，HTTP 400/401/403/404/409/413/429/500/507。

- 401 `unauthorized`：账号不存在、密码错误、待审批、停用、过期统一文案。
- 403 `forbidden`：没有该操作权限。
- 409 `revision_conflict` / `mutation_conflict` / `user_limit` 等。
- 登录：每 IP 60/分钟、每账号 10/分钟；注册每 IP 10/小时；bootstrap 每 IP 5/5分钟；申请加入每账号 10/小时。429 含 Retry-After。内存限流键有容量上限，进程重启会重置；nginx 同时负责公网限流。

## 备份与恢复

不要直接拷贝正在运行的 SQLite 主文件（未包含 WAL 事务）。使用：

```sh
.venv/bin/python backup.py /var/lib/hero-oos/state.sqlite3 /var/backups/hero-oos/cloud-2026-10-13.sqlite3
```

备份通过 SQLite online backup API 得到一致性快照，执行 quick_check，文件 `0600`，目标已存在时拒绝覆盖。备份包含所有私人数据、密码 hash 和会话 hash，必须仅管理员可访问，不得放在 nginx 下载目录。自动备份计划、保留数量与异地存储由部署层负责。

恢复需先停止服务、保留旧数据库及 WAL/SHM；对备份 `quick_check` 验证后再替换，并恢复专用用户权限。数据库当前 schema 为 2；schema 1 启动时仅在一个事务内新建 `organization_states` 并提升版本，保留账号、凭据、旧私人文档、旧共享副本及所有回执，不自动转成组织共享。部署前先做 online backup。高版本 schema 拒绝启动而不降级；旧服务二进制会拒绝打开 schema 2，不得为了回退软件而降级/丢弃数据库。

## 测试

`test_server.py` 全部使用 TemporaryDirectory / 临时数据库、aiohttp 隔离端口与自生成测试凭据，不读取/修改正式业务数据。覆盖账号待审/批准/撤权、owner/admin 边界、跨组织与同用户私人文档隔离、普通成员共同编辑/删除、并发/CAS/幂等、上传时撤权、私人/组织分区互斥、拼图/Codex/未知与嵌套字段拒绝、依赖循环/失效引用、旧接口停用与旧数据保留、100 账号上限、密码和会话 hash、过期注销、容量与限流、schema 1→2 无损添加和高版本拒绝降级等。
