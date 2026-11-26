#!/usr/bin/env python3
"""Hero OOS cloud core. One process, loopback only; TLS is terminated by nginx."""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import hmac
import ipaddress
import json
import logging
import math
import os
import re
import secrets
import shutil
import sqlite3
import stat
import time
import unicodedata
import uuid
from collections import deque
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from aiohttp import web
from argon2 import PasswordHasher, Type
from argon2.exceptions import VerificationError

DOCUMENT_LIMIT = 8 * 1024 * 1024
BODY_LIMIT = DOCUMENT_LIMIT + 65536
TASK_BACKGROUND_LIMIT = 2000
# Zero means no automatic expiry, but only after the explicit legacy migration.
PERSISTENT_SESSION_EXPIRY = 0
MAX_USERS = 100
DATABASE_LIMIT = 256 * 1024 * 1024
DISK_RESERVE = 512 * 1024 * 1024
MAX_RECEIPTS_PER_USER = 100000
# Keep rejected registration identities without letting them consume every login slot.
# Once approved, an account keeps its slot and private data even if an organization rejects it.
CAPACITY_PREDICATE = """u.status IN ('approved','suspended') OR EXISTS (
 SELECT 1 FROM memberships m WHERE m.user_id=u.id AND m.status IN ('pending','approved','suspended')
)"""
LOG = logging.getLogger("hero_oos")
CLIENT_IP_KEY = web.RequestKey("client_ip", str)
SESSION_HASH_KEY = web.RequestKey("session_hash", str)


@dataclass(frozen=True)
class Config:
    database: Path
    bootstrap_token_hash: str | None = None
    port: int = 4180
    release_catalog: Path = Path("/var/www/hero-oos-updates/versions.json")

    @classmethod
    def load(cls, path: str) -> Config:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        database = Path(data["database"])
        if not database.is_absolute():
            raise ValueError("database must be an absolute path")
        digest = data.get("bootstrapTokenHash")
        if digest is not None and not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("bootstrapTokenHash must be lowercase SHA-256 hex")
        port = data.get("port", 4180)
        if type(port) is not int or not 1024 <= port <= 65535:
            raise ValueError("port must be an integer from 1024 to 65535")
        release_catalog = Path(data.get("releaseCatalog", "/var/www/hero-oos-updates/versions.json"))
        if not release_catalog.is_absolute():
            raise ValueError("releaseCatalog must be an absolute path")
        return cls(database=database, bootstrap_token_hash=digest, port=port, release_catalog=release_catalog)


class APIError(Exception):
    def __init__(self, status: int, code: str, message: str):
        self.status, self.code, self.message = status, code, message


def bad(message: str = "请求格式不正确"):
    raise APIError(400, "invalid_input", message)


def unauthorized():
    raise APIError(401, "unauthorized", "登录信息无效、账号未获批准或会话已失效")


def uid() -> str:
    return str(uuid.uuid4())


def canonical(value) -> str:
    try:
        result = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
        result.encode("utf-8")
        return result
    except (ValueError, TypeError, RecursionError, UnicodeError):
        bad("内容不是有效 JSON")


def sha(value: str) -> str:
    try:
        return hashlib.sha256(value.encode("utf-8")).hexdigest()
    except UnicodeError:
        bad("文字编码无效")


def instant(timestamp: float) -> str:
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def text_field(data: dict, key: str, maximum=128, minimum=1, trim=True) -> str:
    value = data.get(key)
    if not isinstance(value, str):
        bad(f"{key} 必须是文字")
    value = value.strip() if trim else value
    try:
        value.encode("utf-8")
    except UnicodeError:
        bad(f"{key} 含无效文字编码")
    if not minimum <= len(value) <= maximum or any(ord(c) < 32 for c in value):
        bad(f"{key} 长度须为 {minimum}–{maximum} 字符且不能含控制字符")
    return value


def organization_name(data: dict) -> tuple[str, str]:
    name = unicodedata.normalize("NFC", text_field(data, "organization", 64))
    return name, name.casefold()


def username(data: dict) -> tuple[str, str]:
    name = text_field(data, "username", 64, 3)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.@-]{2,63}", name):
        bad("账号仅支持 3–64 位字母、数字和 _ . @ -，并以字母或数字开头")
    return name, name.casefold()


def password(data: dict) -> str:
    return text_field(data, "password", 128, 12, trim=False)


def revision(data: dict) -> int:
    value = data.get("expectedRevision")
    if type(value) is not int or value < 0 or value > 2**53 - 1:
        bad("expectedRevision 必须为非负整数")
    return value


def mutation_id(data: dict) -> str:
    value = text_field(data, "mutationId", 128)
    if not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        bad("mutationId 仅支持字母、数字、下划线和连字符")
    return value


def document(data: dict, field: str) -> str:
    value = data.get(field)
    if not isinstance(value, dict):
        bad(f"{field} 必须是 JSON 对象")
    encoded = canonical(value)
    if len(encoded.encode("utf-8")) > DOCUMENT_LIMIT:
        raise APIError(413, "too_large", "单份文档不能超过 8 MiB")
    return encoded


# This is deliberately an allowlist, not a list of fields to redact. New native
# fields stay on the device until both sides explicitly agree to sync them.
TASK_STRING_FIELDS = frozenset({
    "id", "title", "taskSpace", "status", "priorityOrigin", "stage", "due", "deadlineKind",
    "reviewDate", "project", "taskType", "requester", "managedBy", "waitingCondition", "statusNote",
    "parentId", "note", "notes", "background", "createdAt", "completedAt", "archivedAt", "availableAt", "blockedBy",
    "trackId", "ledgerID", "startDate", "mustExecuteAt", "subcategory", "nextAction", "client", "contact",
    "executor", "deliveryStatus", "invoiceStatus", "sourceChannelOwner", "currentChannelOwner", "recordType",
    "paymentStatus", "currency", "taxBasis", "settlementContact", "completionMode", "nodeKind", "outcome", "receivedDate",
})
TASK_NUMBER_FIELDS = frozenset({
    "priority", "priorityBase", "deferCount", "effortHours", "amountTaxInclusive", "boardOrder", "listOrder",
    "feeAmount", "progressPercent",
})
TASK_BOOL_FIELDS = frozenset({"archived", "externalCommitment", "ledgerEnabled"})
TASK_ARRAY_FIELDS = frozenset({"details", "dependsOn", "peopleWaits"})
TASK_FIELDS = TASK_STRING_FIELDS | TASK_NUMBER_FIELDS | TASK_BOOL_FIELDS | TASK_ARRAY_FIELDS
TRACK_STRING_FIELDS = frozenset({"id", "name", "navLabel", "archetype", "status", "createdAt"})
PAGE_STRING_FIELDS = frozenset({"id", "title", "createdAt"})
MAX_ENTITIES = 100000


def allowed_object(value, allowed, label):
    if not isinstance(value, dict) or set(value) - allowed:
        bad(f"{label} 含不支持或不允许上传的字段")


def string_array(value, label, nonempty=False):
    if not isinstance(value, list) or len(value) > MAX_ENTITIES or any(
            not isinstance(item, str) or len(item) > 16000 or (nonempty and not item.strip()) for item in value):
        bad(f"{label} 必须是文字数组")


def entity_id(entity, label):
    if not isinstance(entity.get("id"), str) or not entity["id"].strip() or len(entity["id"]) > 160:
        bad(f"{label}.id 不能为空")
    return entity["id"]


def scalar_fields(entity, strings, numbers=frozenset(), booleans=frozenset()):
    for key, value in entity.items():
        # Optional scalar nulls are an explicit clear; arrays must be arrays.
        if value is None:
            if key in strings | numbers | booleans:
                continue
            bad(f"{key} 不能是 null")
        if key in strings and not isinstance(value, str):
            bad(f"{key} 必须是文字")
        if key in strings and len(value) > (160 if key == "id" else 16000):
            bad(f"{key} 文字过长")
        if key in numbers and type(value) not in (int, float):
            bad(f"{key} 必须是数字")
        if key in numbers:
            try:
                if not math.isfinite(value):
                    bad(f"{key} 必须是有限数字")
            except OverflowError:
                bad(f"{key} 超过客户端支持的数字范围")
        if key in booleans and type(value) is not bool:
            bad(f"{key} 必须是布尔值")


def validate_task(task, personal=False):
    allowed_object(task, TASK_FIELDS, "task")
    scalar_fields(task, TASK_STRING_FIELDS, TASK_NUMBER_FIELDS, TASK_BOOL_FIELDS)
    # UTF-8 JSON validation rejects unpaired surrogates before this point. Python
    # len therefore counts Unicode code points, matching Swift unicodeScalars.count.
    # Preserve multiline text verbatim; null/empty are explicit clears.
    if task.get("background") is not None and len(task["background"]) > TASK_BACKGROUND_LIMIT:
        bad(f"background 不能超过 {TASK_BACKGROUND_LIMIT} 个 Unicode 字符")
    entity_id(task, "task")
    if not isinstance(task.get("title"), str) or not task["title"].strip() or len(task["title"]) > 400:
        bad("task.title 需要 1–400 字符")
    space = task.get("taskSpace")
    if personal:
        if space != "personal":
            bad("私人同步文档只能包含 taskSpace=personal 的任务")
    elif space != "work" and not (isinstance(space, str) and re.fullmatch(
            r"page-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", space)):
        bad("只允许同步非私人任务；taskSpace 必须是 work 或有效任务页")
    for key in ("details", "dependsOn"):
        if key in task:
            string_array(task[key], key, nonempty=key == "dependsOn")
    if "peopleWaits" in task:
        waits = task["peopleWaits"]
        if not isinstance(waits, list) or len(waits) > MAX_ENTITIES:
            bad("peopleWaits 必须是列表")
        ids = set()
        for wait in waits:
            allowed_object(wait, {"id", "person", "outcome", "resolved"}, "peopleWaits")
            wait_id = entity_id(wait, "peopleWaits")
            if wait_id in ids or not isinstance(wait.get("person"), str) or not wait["person"].strip() or \
                    not isinstance(wait.get("outcome"), str) or type(wait.get("resolved")) is not bool:
                bad("等人条件需要独立 ID、等谁、等待结果文字和解决状态")
            if len(wait["person"]) > 16000 or len(wait["outcome"]) > 16000:
                bad("等人条件文字过长")
            ids.add(wait_id)
    for key in ("priority", "priorityBase"):
        if task.get(key) is not None and not 1 <= task[key] <= 10:
            bad(f"{key} 必须在 1–10 之间")
    for key in ("deferCount", "effortHours", "amountTaxInclusive"):
        if task.get(key) is not None and task[key] < 0:
            bad(f"{key} 不能为负数")
    if task.get("availableAt"):
        try:
            if "T" not in task["availableAt"]:
                raise ValueError()
            parsed = datetime.fromisoformat(task["availableAt"].replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                raise ValueError()
        except ValueError:
            bad("availableAt 必须是含时区的有效日期时间")


def scoped_document(data, personal=False):
    # Size/finite-JSON validation happens before traversing attacker input.
    encoded = document(data, "document")
    value = data["document"]
    allowed_object(value, {"schemaVersion", "scope", "state"}, "document")
    scope = "personal-tasks" if personal else "organization-tasks"
    if type(value.get("schemaVersion")) is not int or value["schemaVersion"] != 2 or value.get("scope") != scope:
        bad(f"仅接受 schemaVersion=2 的 {scope} 文档")
    state = value.get("state")
    allowed_object(state, {"tasks", "tracks", "taskPages"}, "state")
    indexed = {}
    for collection in ("tasks", "tracks", "taskPages"):
        entries = state.get(collection)
        if not isinstance(entries, list) or len(entries) > MAX_ENTITIES:
            bad(f"{collection} 必须是列表且不超过 {MAX_ENTITIES} 项")
        items = {}
        for entry in entries:
            if collection == "tasks":
                validate_task(entry, personal=personal)
            elif collection == "tracks":
                allowed_object(entry, TRACK_STRING_FIELDS | {"stages"}, "track")
                scalar_fields(entry, TRACK_STRING_FIELDS)
                if isinstance(entry.get("name"), str) and len(entry["name"]) > 400:
                    bad("Track 名称不能超过 400 字符")
                if "stages" in entry:
                    string_array(entry["stages"], "stages")
            else:
                allowed_object(entry, PAGE_STRING_FIELDS, "taskPage")
                scalar_fields(entry, PAGE_STRING_FIELDS)
                if not isinstance(entry.get("title"), str) or not 1 <= len(entry["title"].strip()) <= 60:
                    bad("任务页名称需要 1–60 字符")
            key = entity_id(entry, collection)
            if key in items:
                bad(f"{collection} 中有重复 ID")
            if collection == "taskPages" and not re.fullmatch(
                    r"page-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", key):
                bad("任务页 ID 无效")
            items[key] = entry
        indexed[collection] = items
    tasks = indexed["tasks"]
    referenced_tracks = {task["trackId"] for task in tasks.values() if task.get("trackId")}
    referenced_pages = {task["taskSpace"] for task in tasks.values() if task["taskSpace"].startswith("page-")}
    if set(indexed["tracks"]) != referenced_tracks or set(indexed["taskPages"]) != referenced_pages:
        bad("组织文档只能包含任务引用的 Track 和任务页")
    page_names = {name.casefold() for name in ("今日", "日程", "板块", "任务", "私人任务", "工作室台账", "任务关系图", "专注画布", "拼图", "归档与恢复")}
    for page in indexed["taskPages"].values():
        name = page["title"].strip().casefold()
        if name in page_names:
            bad("任务页名称重复或与内置页面同名")
        page_names.add(name)
    for task in tasks.values():
        space = task["taskSpace"]
        if space not in ("work", "personal") and space not in indexed["taskPages"]:
            bad("任务所属页面不存在")
        if task.get("trackId") and task["trackId"] not in indexed["tracks"]:
            bad("任务所属 Track 不存在")
        parent = task.get("parentId")
        if parent and (parent not in tasks or tasks[parent]["taskSpace"] != space):
            bad("父任务不存在或不在同一任务页")
        if any(target not in tasks for target in task.get("dependsOn", [])):
            bad("前置任务不存在于组织任务文档")
    # Iterative traversal prevents recursion-limit attacks on legitimate long chains.
    for relationship in ("parentId", "dependsOn"):
        done = set()
        for start in tasks:
            if start in done:
                continue
            active, stack = set(), [(start, False)]
            while stack:
                current, exiting = stack.pop()
                if exiting:
                    active.discard(current)
                    done.add(current)
                    continue
                if current in active:
                    bad("任务关系存在循环")
                if current in done:
                    continue
                active.add(current)
                stack.append((current, True))
                links = [tasks[current].get(relationship)] if relationship == "parentId" else tasks[current].get(relationship, [])
                stack.extend((target, False) for target in links if target)
    return encoded


class RateLimiter:
    """Bounded per-process limiter. nginx also limits the public ingress."""
    def __init__(self):
        self.buckets: dict[str, tuple[deque, int]] = {}

    def check(self, key: str, count: int, seconds: int):
        now = time.monotonic()
        if len(self.buckets) >= 20000:
            self.buckets = {k: v for k, v in self.buckets.items() if v[0] and now - v[0][-1] < v[1]}
            if len(self.buckets) >= 20000:
                raise APIError(429, "rate_limited", "请求过于频繁，请稍后重试")
        queue, _ = self.buckets.setdefault(key, (deque(), seconds))
        while queue and now - queue[0] >= seconds:
            queue.popleft()
        if len(queue) >= count:
            raise APIError(429, "rate_limited", "请求过于频繁，请稍后重试")
        queue.append(now)


SCHEMA = """
BEGIN IMMEDIATE;
CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE users (
 id TEXT PRIMARY KEY, username TEXT NOT NULL, username_key TEXT NOT NULL UNIQUE,
 password_hash TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('pending','approved','suspended')),
 created_at INTEGER NOT NULL
);
CREATE TABLE organizations (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, name_key TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL
);
CREATE TABLE memberships (
 id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), org_id TEXT NOT NULL REFERENCES organizations(id),
 role TEXT NOT NULL CHECK(role IN ('owner','admin','member')),
 status TEXT NOT NULL CHECK(status IN ('pending','approved','rejected','suspended')),
 UNIQUE(user_id,org_id)
);
CREATE UNIQUE INDEX one_owner ON memberships(org_id) WHERE role='owner';
CREATE TABLE sessions (
 token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), org_id TEXT NOT NULL REFERENCES organizations(id),
 expires_at INTEGER NOT NULL
);
CREATE INDEX sessions_expiry ON sessions(expires_at);
CREATE TABLE personal_states (
 user_id TEXT PRIMARY KEY REFERENCES users(id), revision INTEGER NOT NULL, document TEXT NOT NULL, updated_at INTEGER NOT NULL
);
CREATE TABLE organization_states (
 org_id TEXT PRIMARY KEY REFERENCES organizations(id), revision INTEGER NOT NULL, document TEXT NOT NULL, updated_at INTEGER NOT NULL
);
CREATE TABLE shared_tasks (
 org_id TEXT NOT NULL REFERENCES organizations(id), id TEXT NOT NULL, owner_id TEXT NOT NULL REFERENCES users(id),
 revision INTEGER NOT NULL, task TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL,
 PRIMARY KEY(org_id,id)
);
CREATE TABLE mutations (
 actor_id TEXT NOT NULL REFERENCES users(id), scope TEXT NOT NULL, mutation_id TEXT NOT NULL,
 payload_hash TEXT NOT NULL, response TEXT NOT NULL, created_at INTEGER NOT NULL,
 PRIMARY KEY(actor_id,scope,mutation_id)
);
PRAGMA user_version=2;
COMMIT;
"""


class Store:
    def __init__(self, config: Config):
        config.database.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(config.database, isolation_level=None)
        os.chmod(config.database, 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA busy_timeout=5000")
        self.db.execute("PRAGMA wal_autocheckpoint=512")
        self.db.execute("PRAGMA journal_size_limit=16777216")
        self.db.execute(f"PRAGMA max_page_count={DATABASE_LIMIT // self.db.execute('PRAGMA page_size').fetchone()[0]}")
        version = self.db.execute("PRAGMA user_version").fetchone()[0]
        if version == 0:
            self.db.executescript(SCHEMA)
        elif version == 1:
            # Additive migration only: legacy private/shared data is preserved for
            # owner-controlled recovery, never promoted into an organization.
            self.db.executescript("""BEGIN IMMEDIATE;
              CREATE TABLE organization_states (
                org_id TEXT PRIMARY KEY REFERENCES organizations(id), revision INTEGER NOT NULL,
                document TEXT NOT NULL, updated_at INTEGER NOT NULL
              );
              PRAGMA user_version=2;
              COMMIT;""")
        elif version != 2:
            self.db.close()
            raise RuntimeError(f"Unsupported database schema {version}; refusing downgrade")

    @contextmanager
    def transaction(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
            self.db.execute("COMMIT")
        except BaseException:
            # SQLITE_FULL may already have rolled the transaction back internally.
            if self.db.in_transaction:
                self.db.execute("ROLLBACK")
            raise

    def one(self, sql, args=()):
        return self.db.execute(sql, args).fetchone()

    def all(self, sql, args=()):
        return self.db.execute(sql, args).fetchall()

    def execute(self, sql, args=()):
        return self.db.execute(sql, args)

    def migrate_persistent_sessions(self):
        """Retain only currently authorized sessions; never resurrect expired tokens."""
        with self.transaction():
            marker = self.one("SELECT value FROM metadata WHERE key='persistent_sessions_v1'")
            if marker is not None and marker["value"] != "1":
                raise RuntimeError("Unsupported session policy; refusing migration")
            now = int(time.time())
            if marker is None:
                # Before this marker, even a legacy zero meant already expired.
                self.execute("DELETE FROM sessions WHERE expires_at<=?", (now,))
            else:
                self.execute("DELETE FROM sessions WHERE expires_at<>0 AND expires_at<=?", (now,))
            self.execute("""DELETE FROM sessions WHERE NOT EXISTS (
              SELECT 1 FROM users u JOIN memberships m ON m.user_id=u.id
              WHERE u.id=sessions.user_id AND m.org_id=sessions.org_id
                AND u.status='approved' AND m.status='approved')""")
            self.execute("UPDATE sessions SET expires_at=0 WHERE expires_at>?", (now,))
            self.execute("INSERT OR IGNORE INTO metadata VALUES('persistent_sessions_v1','1')")


@web.middleware
async def errors(request, handler):
    try:
        response = await handler(request)
    except APIError as exc:
        headers = {"Retry-After": "60"} if exc.status == 429 else None
        response = web.json_response({"ok": False, "error": exc.code, "message": exc.message}, status=exc.status, headers=headers)
    except web.HTTPRequestEntityTooLarge:
        response = web.json_response({"ok": False, "error": "too_large", "message": "请求内容过大"}, status=413)
    except web.HTTPException as exc:
        response = web.json_response({"ok": False, "error": "not_found" if exc.status == 404 else "http_error", "message": "请求路径或方法不支持"}, status=exc.status)
    except sqlite3.OperationalError as exc:
        if getattr(exc, "sqlite_errorcode", None) == sqlite3.SQLITE_FULL:
            response = web.json_response({"ok": False, "error": "storage_limit", "message": "服务器存储空间不足，写入已回滚"}, status=507)
        else:
            LOG.exception("Database operation failed (request body omitted)")
            response = web.json_response({"ok": False, "error": "internal_error", "message": "数据库暂时不可用，请稍后重试"}, status=500)
    except Exception:
        LOG.exception("Request failed (request body and credentials omitted)")
        response = web.json_response({"ok": False, "error": "internal_error", "message": "服务暂时不可用，请稍后重试"}, status=500)
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response


@web.middleware
async def loopback_and_headers(request, handler):
    try:
        remote = ipaddress.ip_address(request.remote or "")
    except ValueError:
        raise APIError(403, "forbidden", "只允许本地反向代理访问")
    if not remote.is_loopback:
        raise APIError(403, "forbidden", "只允许本地反向代理访问")
    # Never trust X-Forwarded-For. nginx must overwrite X-Real-IP with $remote_addr.
    actual_ip = request.headers.get("X-Real-IP", str(remote))
    try:
        request[CLIENT_IP_KEY] = str(ipaddress.ip_address(actual_ip))
    except ValueError:
        bad("来源地址无效")
    return await handler(request)


@dataclass(eq=False)
class EventSubscriber:
    """Only a wakeup is queued; revisions are read at the authorized send time."""
    request: web.Request
    user_id: str | None
    org_id: str | None
    session_hash: str | None
    queue: asyncio.Queue

    def wake(self):
        if self.queue.empty():
            self.queue.put_nowait(True)


class Service:
    def __init__(self, config: Config):
        self.config = config
        self.store = Store(config)
        self.store.migrate_persistent_sessions()
        self.limiter = RateLimiter()
        self.hasher = PasswordHasher(time_cost=2, memory_cost=19456, parallelism=1, type=Type.ID)
        self.hash_slots = asyncio.Semaphore(1)
        self.hash_waiters = 0
        self.dummy_hash = self.hasher.hash(secrets.token_urlsafe(32))
        self.subscribers: set[EventSubscriber] = set()
        self.event_tasks: set[asyncio.Task] = set()
        self.events_closing = False
        self.release_build = 0
        self.release_fingerprint = None
        self.release_watcher: asyncio.Task | None = None
        self.event_heartbeat_seconds = 20
        self.release_watch_seconds = 2
        self.max_event_connections = 512
        self.max_session_connections = 4
        self.max_user_connections = 8
        self.max_public_connections = 256

    def notify_state(self, actor, personal=False):
        for subscriber in self.subscribers:
            if subscriber.user_id is not None and (
                subscriber.user_id == actor["user_id"] if personal else subscriber.org_id == actor["org_id"]
            ):
                subscriber.wake()

    def notify_auth_change(self):
        # Wake authorized streams so revocation is observed promptly, rather
        # than waiting for the next heartbeat. Unchanged streams send no event.
        for subscriber in self.subscribers:
            if subscriber.user_id is not None:
                subscriber.wake()

    def refresh_release_build(self):
        """A local catalog notification is a hint, never update signature trust."""
        path = self.config.release_catalog
        try:
            if path.is_symlink():
                return
            metadata = path.stat()
            fingerprint = (metadata.st_ino, metadata.st_mtime_ns, metadata.st_size)
            if (not stat.S_ISREG(metadata.st_mode) or fingerprint == self.release_fingerprint or
                    metadata.st_size > 256 * 1024):
                return
            with path.open("rb") as handle:
                raw = handle.read(256 * 1024 + 1)
            if len(raw) > 256 * 1024:
                return
            catalog = json.loads(raw)
            if not isinstance(catalog, dict):
                return
            entries = catalog.get("versions")
            if catalog.get("formatVersion") != 1 or not isinstance(entries, list) or len(entries) > 10:
                return
            builds = [entry.get("build") for entry in entries if isinstance(entry, dict)]
            if len(builds) != len(entries) or any(type(build) is not int or not 0 < build <= 2**53 - 1 for build in builds):
                return
            build = max(builds, default=0)
            self.release_fingerprint = fingerprint
        except (OSError, ValueError, RecursionError, UnicodeError):
            return
        if self.release_build != build:
            self.release_build = build
            for subscriber in self.subscribers:
                subscriber.wake()

    async def start_events(self):
        self.refresh_release_build()

        async def watch():
            while not self.events_closing:
                await asyncio.sleep(self.release_watch_seconds)
                self.refresh_release_build()

        self.release_watcher = asyncio.create_task(watch())

    async def stop_events(self):
        self.events_closing = True
        if self.release_watcher is not None:
            self.release_watcher.cancel()
            await asyncio.gather(self.release_watcher, return_exceptions=True)
        for subscriber in self.subscribers:
            subscriber.wake()
        if self.event_tasks:
            _, remaining = await asyncio.wait(self.event_tasks.copy(), timeout=5)
            for task in remaining:
                task.cancel()
            if remaining:
                await asyncio.gather(*remaining, return_exceptions=True)

    def event_payload(self, subscriber):
        if subscriber.user_id is None:
            return {"releaseBuild": self.release_build}
        actor = self.auth(subscriber.request)
        if actor["user_id"] != subscriber.user_id or actor["org_id"] != subscriber.org_id:
            unauthorized()
        organization = self.store.one("SELECT revision FROM organization_states WHERE org_id=?", (actor["org_id"],))
        personal = self.store.one("SELECT revision FROM personal_states WHERE user_id=?", (actor["user_id"],))
        return {"organizationRevision": organization["revision"] if organization else 0,
                "personalRevision": personal["revision"] if personal else 0, "releaseBuild": self.release_build}

    async def state_events(self, request):
        return await self.stream_events(request, authenticated=True)

    async def update_events(self, request):
        return await self.stream_events(request, authenticated=False)

    async def stream_events(self, request, authenticated):
        actor = self.auth(request) if authenticated else None
        session_hash = request.get(SESSION_HASH_KEY) if authenticated else None
        if self.events_closing:
            raise APIError(503, "unavailable", "服务正在重启，请稍后重新连接")
        public = [s for s in self.subscribers if s.user_id is None]
        if (len(self.subscribers) >= self.max_event_connections or
            (authenticated and (sum(s.session_hash == session_hash for s in self.subscribers) >= self.max_session_connections or
                                sum(s.user_id == actor["user_id"] for s in self.subscribers) >= self.max_user_connections)) or
            (not authenticated and (len(public) >= self.max_public_connections or
             sum(s.request[CLIENT_IP_KEY] == request[CLIENT_IP_KEY] for s in public) >= 128))):
            raise APIError(429, "rate_limited", "通知连接过多，请稍后重新连接")
        if not authenticated:
            self.limiter.check("update-events:" + request[CLIENT_IP_KEY], 240, 60)
        subscriber = EventSubscriber(request, actor["user_id"] if actor else None,
                                     actor["org_id"] if actor else None, session_hash, asyncio.Queue(maxsize=1))
        # Register before preparing the response so a concurrent commit cannot
        # land between the initial snapshot and notification registration.
        self.subscribers.add(subscriber)
        task = asyncio.current_task()
        self.event_tasks.add(task)
        response = web.StreamResponse(headers={"Content-Type": "text/event-stream; charset=utf-8",
            "Cache-Control": "no-store", "X-Accel-Buffering": "no", "X-Content-Type-Options": "nosniff"})
        try:
            await response.prepare(request)
            last = None
            subscriber.wake()
            while not self.events_closing:
                heartbeat = False
                try:
                    await asyncio.wait_for(subscriber.queue.get(), timeout=self.event_heartbeat_seconds)
                except asyncio.TimeoutError:
                    heartbeat = True
                if self.events_closing or request.transport is None or request.transport.is_closing():
                    break
                # Re-authenticate before every state event and heartbeat, even
                # without changes. Logout/suspension cannot keep a live stream.
                payload = self.event_payload(subscriber)
                if payload != last:
                    kind = "state" if authenticated else "release"
                    data = f"event: {kind}\ndata: {canonical(payload)}\n\n".encode()
                    await asyncio.wait_for(response.write(data), timeout=10)
                    last = payload
                elif heartbeat:
                    await asyncio.wait_for(response.write(b": keepalive\n\n"), timeout=10)
        except (APIError, ConnectionError, asyncio.TimeoutError):
            pass  # Headers are already sent; EOF makes the client reconnect/authenticate.
        finally:
            self.subscribers.discard(subscriber)
            self.event_tasks.discard(task)
        try:
            await response.write_eof()
        except (ConnectionError, RuntimeError):
            pass
        return response

    async def body(self, request):
        if request.content_type != "application/json":
            bad("Content-Type 必须是 application/json")
        try:
            data = json.loads(await request.text(), parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        except (json.JSONDecodeError, ValueError, RecursionError, UnicodeDecodeError):
            bad("请求不是有效 JSON")
        if not isinstance(data, dict):
            bad("请求必须是 JSON 对象")
        return data

    async def hash_password(self, value):
        return await self.hash_operation(self.hasher.hash, value)

    async def hash_operation(self, function, *args):
        # Bound both memory-heavy Argon2 work and queued requests on a 1-core / 1 GiB host.
        if self.hash_waiters >= 8:
            raise APIError(429, "rate_limited", "认证请求较多，请稍后重试")
        self.hash_waiters += 1
        try:
            async with self.hash_slots:
                work = asyncio.create_task(asyncio.to_thread(function, *args))
                try:
                    return await asyncio.shield(work)
                except asyncio.CancelledError:
                    # A disconnected client must not release the memory slot while its hash still runs.
                    try:
                        await work
                    except Exception:
                        pass
                    raise
        finally:
            self.hash_waiters -= 1

    async def verify_password(self, encoded, value):
        try:
            return await self.hash_operation(self.hasher.verify, encoded, value)
        except VerificationError:
            return False

    def memberships(self, user_id):
        rows = self.store.all("""SELECT o.id,o.name,m.role,m.status FROM memberships m JOIN organizations o ON o.id=m.org_id
          WHERE m.user_id=? ORDER BY o.name_key""", (user_id,))
        return [dict(row) for row in rows]

    def profile(self, user_id, org_id):
        row = self.store.one("""SELECT u.id,u.username,o.id AS org_id,o.name,m.role FROM users u
          JOIN memberships m ON m.user_id=u.id JOIN organizations o ON o.id=m.org_id WHERE u.id=? AND o.id=?""", (user_id, org_id))
        return {"user": {"id": row["id"], "username": row["username"]},
                "organization": {"id": row["org_id"], "name": row["name"], "role": row["role"]},
                "memberships": self.memberships(user_id)}

    def issue_session(self, user_id, org_id):
        token = secrets.token_urlsafe(32)
        self.store.execute("DELETE FROM sessions WHERE expires_at<>0 AND expires_at<=?", (int(time.time()),))
        self.store.execute("INSERT INTO sessions(token_hash,user_id,org_id,expires_at) VALUES(?,?,?,?)", (sha(token), user_id, org_id, PERSISTENT_SESSION_EXPIRY))
        return {"token": token, "expiresAt": None, **self.profile(user_id, org_id)}

    def auth(self, request):
        header = request.headers.get("Authorization", "")
        if not header.startswith("Bearer ") or not 32 <= len(header[7:]) <= 128:
            unauthorized()
        digest = sha(header[7:])
        row = self.store.one("""SELECT s.user_id,s.org_id,s.expires_at,m.role FROM sessions s
          JOIN users u ON u.id=s.user_id JOIN memberships m ON m.user_id=s.user_id AND m.org_id=s.org_id
          WHERE s.token_hash=? AND (s.expires_at=0 OR s.expires_at>?)
            AND u.status='approved' AND m.status='approved'""", (digest, int(time.time())))
        if row is None:
            unauthorized()
        request[SESSION_HASH_KEY] = digest
        return row

    def admin(self, request, owner=False):
        actor = self.auth(request)
        if actor["role"] not in (("owner",) if owner else ("owner", "admin")):
            raise APIError(403, "forbidden", "需要组织管理权限")
        return actor

    def user_capacity(self):
        if self.store.one("SELECT COUNT(*) AS n FROM users u WHERE " + CAPACITY_PREDICATE)["n"] >= MAX_USERS:
            raise APIError(409, "user_limit", "服务器最多支持 100 个账号，请联系管理员")

    def occupies_capacity(self, user_id):
        return self.store.one("SELECT 1 FROM users u WHERE u.id=? AND (" + CAPACITY_PREDICATE + ")", (user_id,)) is not None

    async def health(self, request):
        self.store.one("SELECT 1")
        return web.json_response({"ok": True, "service": "hero-oos", "apiVersion": 1})

    async def bootstrap(self, request):
        self.limiter.check("bootstrap:" + request[CLIENT_IP_KEY], 5, 300)
        data = await self.body(request)
        raw_token = data.get("bootstrapToken")
        digest = self.config.bootstrap_token_hash
        if not digest or not isinstance(raw_token, str) or not 32 <= len(raw_token) <= 512 or not hmac.compare_digest(sha(raw_token), digest):
            unauthorized()
        name, key = organization_name(data)
        account, account_key = username(data)
        hashed = await self.hash_password(password(data))
        with self.store.transaction():
            if self.store.one("SELECT 1 FROM metadata WHERE key='bootstrapped'") or self.store.one("SELECT 1 FROM users LIMIT 1"):
                raise APIError(409, "already_initialized", "服务器已完成初始化")
            user_id, org_id = uid(), uid()
            now = int(time.time())
            self.store.execute("INSERT INTO users VALUES(?,?,?,?,?,?)", (user_id, account, account_key, hashed, "approved", now))
            self.store.execute("INSERT INTO organizations VALUES(?,?,?,?)", (org_id, name, key, now))
            self.store.execute("INSERT INTO memberships VALUES(?,?,?,?,?)", (uid(), user_id, org_id, "owner", "approved"))
            self.store.execute("INSERT INTO metadata VALUES('bootstrapped','1')")
            result = self.issue_session(user_id, org_id)
        return web.json_response(result, status=201)

    async def register(self, request):
        self.limiter.check("register:" + request[CLIENT_IP_KEY], 10, 3600)
        data = await self.body(request)
        _, org_key = organization_name(data)
        account, account_key = username(data)
        secret = password(data)
        org = self.store.one("SELECT id FROM organizations WHERE name_key=?", (org_key,))
        if org is None:
            raise APIError(404, "organization_not_found", "组织不存在，请核对组织名称")
        hashed = await self.hash_password(secret)
        with self.store.transaction():
            if self.store.one("SELECT 1 FROM users WHERE username_key=?", (account_key,)):
                raise APIError(409, "account_unavailable", "账号不可用；已有账号请先登录再申请加入组织")
            self.user_capacity()
            user_id = uid()
            self.store.execute("INSERT INTO users VALUES(?,?,?,?,?,?)", (user_id, account, account_key, hashed, "pending", int(time.time())))
            self.store.execute("INSERT INTO memberships VALUES(?,?,?,?,?)", (uid(), user_id, org["id"], "member", "pending"))
        return web.json_response({"ok": True, "status": "pending"}, status=201)

    async def login(self, request):
        self.limiter.check("login-ip:" + request[CLIENT_IP_KEY], 60, 60)
        data = await self.body(request)
        # Return the same authentication error for unknown, invalid, pending and revoked accounts.
        try:
            _, account_key = username(data)
            _, org_key = organization_name(data)
            secret = password(data)
        except APIError:
            unauthorized()
        self.limiter.check("login-account:" + account_key, 10, 60)
        user = self.store.one("SELECT * FROM users WHERE username_key=?", (account_key,))
        valid = await self.verify_password(user["password_hash"] if user else self.dummy_hash, secret)
        if not valid or user is None:
            unauthorized()
        with self.store.transaction():
            membership = self.store.one("""SELECT m.org_id FROM memberships m JOIN organizations o ON o.id=m.org_id
              JOIN users u ON u.id=m.user_id WHERE m.user_id=? AND o.name_key=? AND m.status='approved' AND u.status='approved'
                AND u.password_hash=?""", (user["id"], org_key, user["password_hash"]))
            if membership is None:
                unauthorized()
            result = self.issue_session(user["id"], membership["org_id"])
        return web.json_response(result)

    async def logout(self, request):
        self.auth(request)
        self.store.execute("DELETE FROM sessions WHERE token_hash=?", (request[SESSION_HASH_KEY],))
        self.notify_auth_change()
        return web.json_response({"ok": True})

    async def me(self, request):
        actor = self.auth(request)
        return web.json_response(self.profile(actor["user_id"], actor["org_id"]))

    async def organizations(self, request):
        actor = self.auth(request)
        return web.json_response({"memberships": self.memberships(actor["user_id"])})

    async def join(self, request):
        actor = self.auth(request)
        self.limiter.check("join:" + actor["user_id"], 10, 3600)
        data = await self.body(request)
        _, key = organization_name(data)
        with self.store.transaction():
            actor = self.auth(request)
            org = self.store.one("SELECT id FROM organizations WHERE name_key=?", (key,))
            if org is None:
                raise APIError(404, "organization_not_found", "组织不存在")
            previous = self.store.one("SELECT status FROM memberships WHERE user_id=? AND org_id=?", (actor["user_id"], org["id"]))
            if previous is not None:
                if previous["status"] in ("pending", "approved"):
                    return web.json_response({"ok": True, "status": previous["status"]})
                raise APIError(403, "forbidden", "申请曾被拒绝或成员被停用，请联系该组织管理员")
            self.store.execute("INSERT INTO memberships VALUES(?,?,?,?,?)", (uid(), actor["user_id"], org["id"], "member", "pending"))
        return web.json_response({"ok": True, "status": "pending"}, status=201)

    async def members(self, request):
        actor = self.admin(request)
        rows = self.store.all("""SELECT m.id,m.user_id AS userId,u.username,m.role,m.status FROM memberships m
          JOIN users u ON u.id=m.user_id WHERE m.org_id=? ORDER BY u.username_key""", (actor["org_id"],))
        return web.json_response({"members": [dict(row) for row in rows]})

    async def change_member(self, request):
        actor = self.admin(request)
        data = await self.body(request)
        if not data or set(data) - {"role", "status"}:
            bad("仅可修改成员的角色和审批状态")
        if "status" in data and data["status"] not in ("approved", "rejected", "suspended"):
            bad("成员状态无效")
        if "role" in data and data["role"] not in ("admin", "member"):
            bad("成员角色无效")
        with self.store.transaction():
            actor = self.admin(request)
            target = self.store.one("SELECT * FROM memberships WHERE id=? AND org_id=?", (request.match_info["id"], actor["org_id"]))
            if target is None:
                raise APIError(404, "not_found", "成员不存在")
            if target["role"] == "owner" or target["user_id"] == actor["user_id"]:
                raise APIError(403, "forbidden", "不能修改组织拥有者或自己的权限")
            role, status = data.get("role", target["role"]), data.get("status", target["status"])
            # Admins manage ordinary members; only the owner may appoint/demote an admin.
            if actor["role"] != "owner" and (target["role"] == "admin" or role == "admin"):
                raise APIError(403, "forbidden", "仅组织拥有者可调整管理员")
            if status in ("approved", "suspended") and not self.occupies_capacity(target["user_id"]):
                self.user_capacity()
            self.store.execute("UPDATE memberships SET role=?,status=? WHERE id=?", (role, status, target["id"]))
            if status == "approved":
                self.store.execute("UPDATE users SET status='approved' WHERE id=? AND status='pending'", (target["user_id"],))
            else:
                self.store.execute("DELETE FROM sessions WHERE user_id=? AND org_id=?", (target["user_id"], actor["org_id"]))
        self.notify_auth_change()
        return web.json_response({"ok": True})

    async def rename_organization(self, request):
        actor = self.admin(request, owner=True)
        data = await self.body(request)
        name, key = organization_name({"organization": data.get("name")})
        with self.store.transaction():
            actor = self.admin(request, owner=True)
            if self.store.one("SELECT 1 FROM organizations WHERE name_key=? AND id<>?", (key, actor["org_id"])):
                raise APIError(409, "organization_unavailable", "组织名称已被使用")
            self.store.execute("UPDATE organizations SET name=?,name_key=? WHERE id=?", (name, key, actor["org_id"]))
        return web.json_response({"ok": True, "organization": {"id": actor["org_id"], "name": name, "role": actor["role"]}})

    def previous_mutation(self, actor, scope, mutation, payload):
        prior = self.store.one("SELECT payload_hash,response FROM mutations WHERE actor_id=? AND scope=? AND mutation_id=?", (actor, scope, mutation))
        if prior is not None:
            if not hmac.compare_digest(prior["payload_hash"], sha(payload)):
                raise APIError(409, "mutation_conflict", "同一 mutationId 不能用于不同内容")
            return json.loads(prior["response"])
        return None

    def record_mutation(self, actor, scope, mutation, payload, result):
        self.store.execute("INSERT INTO mutations VALUES(?,?,?,?,?,?)", (actor, scope, mutation, sha(payload), canonical(result), int(time.time())))

    def check_storage(self, actor, additional_bytes):
        # The 256 MiB cap is shared by the whole service, not guaranteed per account.
        pages = self.store.one("PRAGMA page_count")[0] - self.store.one("PRAGMA freelist_count")[0]
        page_size = self.store.one("PRAGMA page_size")[0]
        if pages * page_size + max(0, additional_bytes) + 8192 > DATABASE_LIMIT:
            raise APIError(507, "storage_limit", "服务器共享存储配额已满，请联系管理员；本机数据仍应保留")
        # Reserve room for WAL, auth/admin writes, and orderly backup/maintenance.
        if shutil.disk_usage(self.config.database.parent).free < DISK_RESERVE + max(0, additional_bytes):
            raise APIError(507, "storage_limit", "服务器剩余磁盘空间不足，已停止写入以保护数据")
        count = self.store.one("SELECT COUNT(*) AS n FROM mutations WHERE actor_id=?", (actor,))["n"]
        if count >= MAX_RECEIPTS_PER_USER:
            raise APIError(507, "receipt_limit", "同步记录已达安全上限，请联系管理员归档；已有请求仍可安全重试")

    async def get_personal(self, request):
        # User scoped, including across approved organization memberships.
        # Legacy broad documents remain readable solely for owner recovery.
        actor = self.auth(request)
        row = self.store.one("SELECT revision,document FROM personal_states WHERE user_id=?", (actor["user_id"],))
        return web.json_response({"revision": row["revision"], "document": json.loads(row["document"])} if row else {"revision": 0, "document": None})

    async def put_personal(self, request):
        return await self.put_task_state(request, personal=True)

    async def get_organization(self, request):
        actor = self.auth(request)
        row = self.store.one("SELECT revision,document FROM organization_states WHERE org_id=?", (actor["org_id"],))
        return web.json_response({"revision": row["revision"], "document": json.loads(row["document"])} if row else {"revision": 0, "document": None})

    async def put_organization(self, request):
        return await self.put_task_state(request, personal=False)

    async def put_task_state(self, request, personal):
        self.auth(request)
        data = await self.body(request)
        allowed_object(data, {"expectedRevision", "mutationId", "document"}, "request")
        expected, mutation, encoded = revision(data), mutation_id(data), scoped_document(data, personal=personal)
        payload = canonical({"expectedRevision": expected, "document": json.loads(encoded)})
        table, key = ("personal_states", "user_id") if personal else ("organization_states", "org_id")
        with self.store.transaction():
            actor = self.auth(request)
            scope = "personal-v2" if personal else "organization:" + actor["org_id"]
            prior = self.previous_mutation(actor["user_id"], scope, mutation, payload)
            if prior is not None:
                return web.json_response(prior)
            row = self.store.one(f"SELECT revision,length(CAST(document AS BLOB)) AS bytes FROM {table} WHERE {key}=?", (actor[key],))
            current = row["revision"] if row else 0
            if current != expected:
                raise APIError(409, "revision_conflict", "云端已有更新，请先拉取最新版本后合并")
            self.check_storage(actor["user_id"], len(encoded.encode("utf-8")) - (row["bytes"] if row else 0))
            next_revision = current + 1
            self.store.execute(f"""INSERT INTO {table} VALUES(?,?,?,?) ON CONFLICT({key})
              DO UPDATE SET revision=excluded.revision,document=excluded.document,updated_at=excluded.updated_at""", (actor[key], next_revision, encoded, int(time.time())))
            result = {"ok": True, "revision": next_revision}
            self.record_mutation(actor["user_id"], scope, mutation, payload, result)
        self.notify_state(actor, personal=personal)
        return web.json_response(result)

    async def get_shared(self, request):
        actor = self.auth(request)
        rows = self.store.all("SELECT id,revision,owner_id,task FROM shared_tasks WHERE org_id=? AND deleted=0 ORDER BY id", (actor["org_id"],))
        return web.json_response({"tasks": [{"id": r["id"], "revision": r["revision"], "ownerId": r["owner_id"], "task": json.loads(r["task"])} for r in rows]})

    async def put_shared(self, request):
        self.auth(request)
        raise APIError(403, "organization_state_required", "旧版共享副本接口已停用；请更新客户端，使用组织任务同步")

    async def delete_shared(self, request):
        self.auth(request)
        raise APIError(403, "organization_state_required", "旧版共享副本接口已停用；历史副本保留供恢复，不再接受写入或删除")


SERVICE_KEY = web.AppKey("service", Service)


def create_app(config: Config) -> web.Application:
    service = Service(config)
    app = web.Application(client_max_size=BODY_LIMIT, middlewares=[errors, loopback_and_headers])
    app[SERVICE_KEY] = service
    app.add_routes([
        web.get("/health", service.health),
        web.get("/v1/events", service.state_events, allow_head=False),
        web.get("/v1/update-events", service.update_events, allow_head=False),
        web.post("/v1/auth/bootstrap", service.bootstrap),
        web.post("/v1/auth/register", service.register),
        web.post("/v1/auth/login", service.login),
        web.post("/v1/auth/logout", service.logout),
        web.get("/v1/me", service.me),
        web.get("/v1/organizations", service.organizations),
        web.post("/v1/organizations/join", service.join),
        web.get("/v1/members", service.members),
        web.patch("/v1/members/{id}", service.change_member),
        web.patch("/v1/organization", service.rename_organization),
        web.get("/v1/personal/state", service.get_personal),
        web.put("/v1/personal/state", service.put_personal),
        web.get("/v1/organization/state", service.get_organization),
        web.put("/v1/organization/state", service.put_organization),
        web.get("/v1/shared/tasks", service.get_shared),
        web.put("/v1/shared/tasks/{id}", service.put_shared),
        web.delete("/v1/shared/tasks/{id}", service.delete_shared),
    ])

    async def close(_):
        service.store.db.close()

    async def start_events(_):
        await service.start_events()

    async def stop_events(_):
        await service.stop_events()

    app.on_startup.append(start_events)
    app.on_shutdown.append(stop_events)
    app.on_cleanup.append(close)
    return app


def main():
    parser = argparse.ArgumentParser(description="Hero OOS API (loopback only)")
    parser.add_argument("--config", required=True, help="Absolute path to private JSON config")
    args = parser.parse_args()
    os.umask(0o077)
    config = Config.load(args.config)
    logging.basicConfig(level=logging.WARNING)
    web.run_app(create_app(config), host="127.0.0.1", port=config.port, access_log=None,
                print=lambda _: LOG.warning("Hero OOS API started on loopback port %s", config.port))


if __name__ == "__main__":
    main()
