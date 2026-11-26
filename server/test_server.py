"""Isolated API tests: temporary SQLite only, no production data or network services."""
import asyncio
import copy
import io
import json
import secrets
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from aiohttp.test_utils import TestClient, TestServer, make_mocked_request

from server import APIError, Config, DOCUMENT_LIMIT, MAX_USERS, SERVICE_KEY, Store, canonical, create_app, loopback_and_headers, sha, uid
from backup import backup

PASSWORD = "this-is-a-test-password-2026"


def organization_document(title="Shared task", **task_fields):
    return {"schemaVersion": 2, "scope": "organization-tasks", "state": {
        "tasks": [{"id": "task-1", "title": title, "taskSpace": "work", **task_fields}], "tracks": [], "taskPages": []}}


def personal_document(title="Private task", **task_fields):
    value = organization_document(title, taskSpace="personal", **task_fields)
    value["scope"] = "personal-tasks"
    return value


class CloudTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hero-oos-cloud-test-")
        self.bootstrap_token = secrets.token_urlsafe(40)
        self.catalog_path = Path(self.temporary.name) / "versions.json"
        self.catalog_path.write_text(json.dumps({"formatVersion": 1, "versions": [{"build": 34}]}))
        self.app = create_app(Config(Path(self.temporary.name) / "state.sqlite3", sha(self.bootstrap_token), release_catalog=self.catalog_path))
        self.service = self.app[SERVICE_KEY]
        self.service.event_heartbeat_seconds = 0.08
        self.service.release_watch_seconds = 0.03
        self.stream_responses = []
        self.db = self.service.store
        self.client = TestClient(TestServer(self.app))
        await self.client.start_server()
        response, self.owner = await self.call("POST", "/v1/auth/bootstrap", body={
            "bootstrapToken": self.bootstrap_token, "organization": "Example Org", "username": "Owner", "password": PASSWORD})
        self.assertEqual(response.status, 201)
        self.token = self.owner["token"]
        self.org = self.owner["organization"]["id"]

    async def asyncTearDown(self):
        for response in self.stream_responses:
            response.close()
        await self.client.close()
        self.temporary.cleanup()

    async def call(self, method, path, token=None, body=None, headers=None):
        hdr = dict(headers or {})
        if token:
            hdr["Authorization"] = "Bearer " + token
        response = await self.client.request(method, path, json=body, headers=hdr)
        return response, await response.json()

    async def register(self, name="alice", organization="Example Org"):
        response, data = await self.call("POST", "/v1/auth/register", body={"organization": organization, "username": name, "password": PASSWORD})
        self.assertEqual(response.status, 201, data)
        self.assertNotIn("token", data)
        self.assertEqual(data["status"], "pending")
        return self.db.one("SELECT m.* FROM memberships m JOIN users u ON u.id=m.user_id WHERE u.username_key=?", (name.lower(),))

    async def login(self, name, organization="Example Org"):
        return await self.call("POST", "/v1/auth/login", body={"organization": organization, "username": name, "password": PASSWORD})

    async def approved(self, name="alice", role="member"):
        member = await self.register(name)
        response, data = await self.call("PATCH", "/v1/members/" + member["id"], self.token, {"status": "approved", "role": role})
        self.assertEqual(response.status, 200, data)
        response, login = await self.login(name)
        self.assertEqual(response.status, 200, login)
        return member, login

    async def stream(self, token=None, path="/v1/events"):
        headers = {"Authorization": "Bearer " + token} if token else {}
        response = await self.client.get(path, headers=headers)
        self.stream_responses.append(response)
        self.assertEqual(response.status, 200)
        self.assertEqual(response.content_type, "text/event-stream")
        self.assertEqual(response.headers["X-Accel-Buffering"], "no")
        return response

    async def stream_event(self, response, timeout=1):
        async def read():
            kind, data = None, []
            while True:
                line = await response.content.readline()
                if not line:
                    return None
                if line in (b"\n", b"\r\n"):
                    if kind and data:
                        return kind, json.loads("\n".join(data))
                    kind, data = None, []
                elif line.startswith(b"event: "):
                    kind = line[7:].strip().decode()
                elif line.startswith(b"data: "):
                    data.append(line[6:].strip().decode())
        return await asyncio.wait_for(read(), timeout)

    async def no_stream_event(self, response):
        with self.assertRaises(asyncio.TimeoutError):
            await self.stream_event(response, timeout=0.15)

    async def test_streams_require_auth_and_public_updates_never_include_task_revisions(self):
        response, error = await self.call("GET", "/v1/events")
        self.assertEqual(response.status, 401)
        self.assertEqual(error["error"], "unauthorized")
        self.assertEqual(len(self.service.subscribers), 0)
        stream = await self.stream(self.token)
        self.assertEqual(await self.stream_event(stream), ("state", {
            "organizationRevision": 0, "personalRevision": 0, "releaseBuild": 34}))
        public = await self.stream(path="/v1/update-events")
        self.assertEqual(await self.stream_event(public), ("release", {"releaseBuild": 34}))
        await self.call("PUT", "/v1/organization/state", self.token,
                        {"expectedRevision": 0, "mutationId": "public-must-not-see", "document": organization_document("secret title")})
        self.assertEqual((await self.stream_event(stream))[1]["organizationRevision"], 1)
        await self.no_stream_event(public)

    async def test_organization_commit_pushes_all_members_but_private_commit_only_its_owner(self):
        _, alice = await self.approved()
        owner_stream = await self.stream(self.token)
        alice_stream = await self.stream(alice["token"])
        await self.stream_event(owner_stream); await self.stream_event(alice_stream)
        response, result = await self.call("PUT", "/v1/organization/state", self.token,
            {"expectedRevision": 0, "mutationId": "org-push", "document": organization_document("updated")})
        self.assertEqual(response.status, 200)
        self.assertEqual(result["revision"], 1)
        for stream in (owner_stream, alice_stream):
            self.assertEqual((await self.stream_event(stream))[1], {
                "organizationRevision": 1, "personalRevision": 0, "releaseBuild": 34})
        await self.call("PUT", "/v1/personal/state", self.token,
            {"expectedRevision": 0, "mutationId": "private-push", "document": personal_document("owner secret")})
        self.assertEqual((await self.stream_event(owner_stream))[1]["personalRevision"], 1)
        await self.no_stream_event(alice_stream)
        await self.call("PUT", "/v1/personal/state", alice["token"],
            {"expectedRevision": 0, "mutationId": "alice-private", "document": personal_document("alice secret")})
        self.assertEqual((await self.stream_event(alice_stream))[1]["personalRevision"], 1)
        await self.no_stream_event(owner_stream)

    async def test_stream_binding_isolates_organizations_and_preserves_same_user_private_scope(self):
        self.second_org()
        _, other = await self.login("owner", "OTHER")
        first = await self.stream(self.token)
        second = await self.stream(other["token"])
        await self.stream_event(first); await self.stream_event(second)
        await self.call("PUT", "/v1/organization/state", self.token,
            {"expectedRevision": 0, "mutationId": "only-first-org", "document": organization_document("first org")})
        self.assertEqual((await self.stream_event(first))[1]["organizationRevision"], 1)
        await self.no_stream_event(second)
        await self.call("PUT", "/v1/personal/state", self.token,
            {"expectedRevision": 0, "mutationId": "own-private-across-orgs", "document": personal_document()})
        first_event, second_event = await self.stream_event(first), await self.stream_event(second)
        self.assertEqual(first_event[1]["personalRevision"], 1)
        self.assertEqual(second_event[1]["personalRevision"], 1)
        self.assertEqual(second_event[1]["organizationRevision"], 0)

    async def test_revoked_member_stream_closes_before_any_new_state_is_sent(self):
        member, alice = await self.approved()
        stream = await self.stream(alice["token"])
        await self.stream_event(stream)
        await self.call("PATCH", "/v1/members/" + member["id"], self.token, {"status": "suspended"})
        await self.call("PUT", "/v1/organization/state", self.token,
            {"expectedRevision": 0, "mutationId": "after-revoke", "document": organization_document("must not reach alice")})
        self.assertIsNone(await self.stream_event(stream))
        response, _ = await self.call("GET", "/v1/events", alice["token"])
        self.assertEqual(response.status, 401)
        self.assertFalse(any(s.user_id == alice["user"]["id"] for s in self.service.subscribers))

    async def test_logout_and_heartbeat_auth_recheck_close_existing_streams(self):
        stream = await self.stream(self.token)
        await self.stream_event(stream)
        await self.call("POST", "/v1/auth/logout", self.token)
        self.assertIsNone(await self.stream_event(stream))
        _, login = await self.login("owner")
        another = await self.stream(login["token"])
        await self.stream_event(another)
        # Simulate expiry or an out-of-band admin revocation without a wakeup.
        self.db.execute("DELETE FROM sessions WHERE token_hash=?", (sha(login["token"]),))
        self.assertIsNone(await self.stream_event(another))

    async def test_failed_and_retried_mutations_do_not_generate_false_state_events(self):
        stream = await self.stream(self.token)
        await self.stream_event(stream)
        payload = {"expectedRevision": 0, "mutationId": "one-change", "document": organization_document()}
        await self.call("PUT", "/v1/organization/state", self.token, payload)
        self.assertEqual((await self.stream_event(stream))[1]["organizationRevision"], 1)
        response, _ = await self.call("PUT", "/v1/organization/state", self.token, payload)
        self.assertEqual(response.status, 200)
        response, _ = await self.call("PUT", "/v1/organization/state", self.token, {**payload, "mutationId": "conflict"})
        self.assertEqual(response.status, 409)
        await self.no_stream_event(stream)

    async def test_release_file_changes_are_pushed_without_a_client_catalog_request(self):
        private = await self.stream(self.token)
        public = await self.stream(path="/v1/update-events")
        await self.stream_event(private); await self.stream_event(public)
        self.catalog_path.write_text(json.dumps({"formatVersion": 1, "versions": [{"build": 36}, {"build": 34}]}))
        self.assertEqual(await self.stream_event(public), ("release", {"releaseBuild": 36}))
        self.assertEqual((await self.stream_event(private))[1], {
            "organizationRevision": 0, "personalRevision": 0, "releaseBuild": 36})
        self.catalog_path.write_text("[]")
        await self.no_stream_event(public)
        self.catalog_path.write_text(json.dumps({"formatVersion": 1, "versions": [{"build": 37}]}))
        self.assertEqual(await self.stream_event(public), ("release", {"releaseBuild": 37}))

    async def test_event_connections_are_bounded_coalesce_and_cleanup_on_close(self):
        self.service.max_session_connections = 1
        stream = await self.stream(self.token)
        await self.stream_event(stream)
        response, error = await self.call("GET", "/v1/events", self.token)
        self.assertEqual(response.status, 429)
        self.assertEqual(error["error"], "rate_limited")
        subscriber = next(iter(self.service.subscribers))
        for _ in range(100):
            subscriber.wake()
        self.assertEqual(subscriber.queue.qsize(), 1)
        stream.close()
        await asyncio.sleep(0.12)
        self.assertEqual(len(self.service.subscribers), 0)
        self.assertEqual(len(self.service.event_tasks), 0)

    async def test_reconnect_initial_snapshot_catches_changes_missed_while_offline(self):
        stream = await self.stream(self.token)
        await self.stream_event(stream)
        stream.close()
        await self.call("PUT", "/v1/organization/state", self.token,
            {"expectedRevision": 0, "mutationId": "changed-offline", "document": organization_document("changed offline")})
        reconnected = await self.stream(self.token)
        self.assertEqual((await self.stream_event(reconnected))[1], {
            "organizationRevision": 1, "personalRevision": 0, "releaseBuild": 34})

    async def test_public_stream_capacity_preserves_authenticated_notification_capacity(self):
        self.service.max_public_connections = 1
        public = await self.stream(path="/v1/update-events")
        await self.stream_event(public)
        response, error = await self.call("GET", "/v1/update-events")
        self.assertEqual(response.status, 429)
        self.assertEqual(error["error"], "rate_limited")
        private = await self.stream(self.token)
        self.assertEqual((await self.stream_event(private))[0], "state")

    async def test_event_shutdown_closes_streams_before_database_cleanup(self):
        private = await self.stream(self.token)
        public = await self.stream(path="/v1/update-events")
        await self.stream_event(private); await self.stream_event(public)
        await self.service.stop_events()
        self.assertIsNone(await self.stream_event(private))
        self.assertIsNone(await self.stream_event(public))
        self.assertEqual(len(self.service.subscribers), 0)
        self.assertEqual(len(self.service.event_tasks), 0)
        self.assertTrue(self.service.release_watcher.done())
        response, _ = await self.call("GET", "/v1/events", self.token)
        self.assertEqual(response.status, 503)
        self.assertEqual(self.db.one("SELECT COUNT(*) AS n FROM users")["n"], 1)

    async def test_malformed_oversized_and_symlinked_release_hints_are_ignored(self):
        for raw in ["[]", "{bad json", json.dumps({"formatVersion": 1, "versions": [{"build": True}]}),
                    json.dumps({"formatVersion": 1, "versions": [{"build": -1}]}), " " * (256 * 1024 + 1)]:
            self.catalog_path.write_text(raw)
            self.service.refresh_release_build()
            self.assertEqual(self.service.release_build, 34)
        elsewhere = Path(self.temporary.name) / "not-the-release-directory.json"
        elsewhere.write_text(json.dumps({"formatVersion": 1, "versions": [{"build": 999}]}))
        self.catalog_path.unlink()
        self.catalog_path.symlink_to(elsewhere)
        self.service.refresh_release_build()
        self.assertEqual(self.service.release_build, 34)

    def second_org(self):
        org = uid()
        self.db.execute("INSERT INTO organizations VALUES(?,?,?,?)", (org, "OTHER", "other", int(time.time())))
        self.db.execute("INSERT INTO memberships VALUES(?,?,?,?,?)", (uid(), self.owner["user"]["id"], org, "owner", "approved"))
        return org

    def seed_pending(self, count):
        hashed = self.db.one("SELECT password_hash FROM users LIMIT 1")["password_hash"]
        for n in range(count):
            user_id = uid()
            self.db.execute("INSERT INTO users VALUES(?,?,?,?,?,?)", (user_id, f"fixture{n}", f"fixture{n}", hashed, "pending", int(time.time())))
            self.db.execute("INSERT INTO memberships VALUES(?,?,?,?,?)", (uid(), user_id, self.org, "member", "pending"))

    async def test_bootstrap_is_one_time_and_only_hashes_are_stored(self):
        response, error = await self.call("POST", "/v1/auth/bootstrap", body={
            "bootstrapToken": self.bootstrap_token, "organization": "Example Org", "username": "new-owner", "password": PASSWORD})
        self.assertEqual(response.status, 409)
        self.assertEqual(error["error"], "already_initialized")
        response, _ = await self.call("POST", "/v1/auth/bootstrap", body={"bootstrapToken": "bad"})
        self.assertEqual(response.status, 401)
        stored = self.db.one("SELECT password_hash FROM users")["password_hash"]
        self.assertTrue(stored.startswith("$argon2id$v=19$m=19456,t=2,p=1$"))
        self.assertNotEqual(stored, PASSWORD)
        tokens = [r["token_hash"] for r in self.db.all("SELECT token_hash FROM sessions")]
        self.assertIn(sha(self.token), tokens)
        self.assertNotIn(self.token, tokens)
        dump = " ".join(self.db.db.iterdump())
        self.assertNotIn(self.bootstrap_token, dump)
        self.assertNotIn(PASSWORD, dump)

    async def test_bootstrap_is_disabled_without_configured_hash(self):
        other = TestClient(TestServer(create_app(Config(Path(self.temporary.name) / "other.sqlite3"))))
        await other.start_server()
        try:
            response = await other.post("/v1/auth/bootstrap", json={"bootstrapToken": self.bootstrap_token})
            self.assertEqual(response.status, 401)
        finally:
            await other.close()

    async def test_registration_pending_approval_then_immediate_revoke(self):
        member = await self.register()
        response, error = await self.login("alice")
        self.assertEqual(response.status, 401)
        response, approved = await self.call("PATCH", "/v1/members/" + member["id"], self.token, {"status": "approved"})
        self.assertEqual(response.status, 200)
        _, login = await self.login("ALICE")
        token = login["token"]
        response, me = await self.call("GET", "/v1/me", token)
        self.assertEqual(response.status, 200)
        self.assertNotIn("token", me)
        self.assertEqual(me["user"]["username"], "alice")
        await self.call("PATCH", "/v1/members/" + member["id"], self.token, {"status": "suspended"})
        response, revoked = await self.call("GET", "/v1/me", token)
        self.assertEqual(response.status, 401)
        self.assertEqual(revoked, error)
        # Approval does not revive an old suspended session.
        await self.call("PATCH", "/v1/members/" + member["id"], self.token, {"status": "approved"})
        response, _ = await self.call("GET", "/v1/me", token)
        self.assertEqual(response.status, 401)

    async def test_username_unique_case_insensitive(self):
        await self.register("Alice")
        response, data = await self.call("POST", "/v1/auth/register", body={"organization": "example org", "username": "ALICE", "password": PASSWORD})
        self.assertEqual(response.status, 409)
        self.assertEqual(data["error"], "account_unavailable")
        self.assertEqual(self.db.one("SELECT COUNT(*) n FROM users")["n"], 2)

    async def test_member_owner_and_admin_permission_boundaries(self):
        member, alice = await self.approved()
        admin, bob = await self.approved("bob", "admin")
        owner_member = self.db.one("SELECT id FROM memberships WHERE role='owner'")["id"]
        for target, payload in [(owner_member, {"status": "suspended"}), (admin["id"], {"role": "member"}), (member["id"], {"role": "admin"})]:
            response, _ = await self.call("PATCH", "/v1/members/" + target, bob["token"], payload)
            self.assertEqual(response.status, 403)
        response, _ = await self.call("GET", "/v1/members", alice["token"])
        self.assertEqual(response.status, 403)
        response, _ = await self.call("PATCH", "/v1/members/" + member["id"], bob["token"], {"status": "suspended"})
        self.assertEqual(response.status, 200)
        # Owner can revoke an admin immediately; the session cannot continue administering.
        await self.call("PATCH", "/v1/members/" + admin["id"], self.token, {"role": "member"})
        response, _ = await self.call("GET", "/v1/members", bob["token"])
        self.assertEqual(response.status, 403)

    async def test_multi_org_join_and_cross_org_membership_isolation(self):
        other_org = self.second_org()
        member, alice = await self.approved()
        response, result = await self.call("POST", "/v1/organizations/join", alice["token"], {"organization": "other"})
        self.assertEqual(response.status, 201)
        self.assertEqual(result["status"], "pending")
        other_member = self.db.one("SELECT * FROM memberships WHERE org_id=? AND user_id=?", (other_org, member["user_id"]))
        response, _ = await self.call("PATCH", "/v1/members/" + other_member["id"], self.token, {"status": "approved"})
        self.assertEqual(response.status, 404)
        response, _ = await self.login("alice", "OTHER")
        self.assertEqual(response.status, 401)
        _, owner_other = await self.login("owner", "OTHER")
        await self.call("PATCH", "/v1/members/" + other_member["id"], owner_other["token"], {"status": "approved"})
        response, alice_other = await self.login("alice", "OTHER")
        self.assertEqual(response.status, 200)
        self.assertEqual(alice_other["organization"]["id"], other_org)
        response, memberships = await self.call("GET", "/v1/organizations", alice["token"])
        self.assertEqual({x["id"] for x in memberships["memberships"]}, {self.org, other_org})
        await self.call("PATCH", "/v1/members/" + member["id"], self.token, {"status": "suspended"})
        response, _ = await self.call("GET", "/v1/me", alice_other["token"])
        self.assertEqual(response.status, 200)

    async def test_legacy_broad_private_uploads_disabled_but_owner_recovery_preserved(self):
        self.second_org()
        _, alice = await self.approved()
        payload = {"expectedRevision": 0, "mutationId": "private-1", "document": {"tasks": [{"id": "private", "title": "private only"}]}}
        # Simulate a document saved by version 1, not a new permitted upload.
        self.db.execute("INSERT INTO personal_states VALUES(?,?,?,?)", (self.owner["user"]["id"], 1, canonical(payload["document"]), int(time.time())))
        response, result = await self.call("PUT", "/v1/personal/state", self.token, payload)
        self.assertEqual(response.status, 400)
        self.assertEqual(result["error"], "invalid_input")
        response, empty = await self.call("GET", "/v1/personal/state", alice["token"])
        self.assertEqual(empty, {"revision": 0, "document": None})
        _, shared = await self.call("GET", "/v1/shared/tasks", self.token)
        self.assertEqual(shared, {"tasks": []})
        _, owner_other = await self.login("owner", "OTHER")
        _, own = await self.call("GET", "/v1/personal/state", owner_other["token"])
        self.assertEqual(own, {"revision": 1, "document": payload["document"]})
        self.assertEqual(self.db.one("SELECT COUNT(*) n FROM mutations")["n"], 0)
        # Old arbitrary documents cannot silently fall back into storage.
        response = await self.client.put("/v1/personal/state", data="invalid-json", headers={"Authorization": "Bearer " + self.token})
        self.assertEqual(response.status, 400)
        response, _ = await self.call("PUT", "/v1/personal/state", None, payload)
        self.assertEqual(response.status, 401)

    async def test_private_task_sync_is_user_scoped_across_orgs_and_never_visible_to_admin(self):
        self.second_org()
        _, alice = await self.approved()
        body = {"expectedRevision": 0, "mutationId": "private-new", "document": personal_document("Alice private")}
        response, saved = await self.call("PUT", "/v1/personal/state", alice["token"], body)
        self.assertEqual(response.status, 200, saved)
        _, owner_copy = await self.call("GET", "/v1/personal/state", self.token)
        self.assertEqual(owner_copy, {"revision": 0, "document": None})
        _, org_copy = await self.call("GET", "/v1/organization/state", self.token)
        self.assertEqual(org_copy, {"revision": 0, "document": None})
        # Organization administrators cannot select another user's private scope.
        response, _ = await self.call("PUT", "/v1/personal/state", self.token, {**body, "userId": alice["user"]["id"]})
        self.assertEqual(response.status, 400)
        owner_body = {"expectedRevision": 0, "mutationId": "private-new", "document": personal_document("Owner private")}
        response, _ = await self.call("PUT", "/v1/personal/state", self.token, owner_body)
        self.assertEqual(response.status, 200)
        _, other_owner = await self.login("owner", "OTHER")
        _, same_user = await self.call("GET", "/v1/personal/state", other_owner["token"])
        self.assertEqual(same_user, {"revision": 1, "document": owner_body["document"]})
        response, retry = await self.call("PUT", "/v1/personal/state", other_owner["token"], owner_body)
        self.assertEqual(response.status, 200)
        self.assertEqual(retry["revision"], 1)
        _, alice_copy = await self.call("GET", "/v1/personal/state", alice["token"])
        self.assertEqual(alice_copy["document"], body["document"])

    async def test_private_cas_conflict_and_strict_scope_blocks_nonprivate_or_collage_data(self):
        path = "/v1/personal/state"
        bodies = [{"expectedRevision": 0, "mutationId": f"p-{n}", "document": personal_document(f"edit-{n}")} for n in range(2)]
        results = await asyncio.gather(*(self.call("PUT", path, self.token, body) for body in bodies))
        self.assertEqual(sorted(response.status for response, _ in results), [200, 409])
        winner = next(n for n, (response, _) in enumerate(results) if response.status == 200)
        response, retry = await self.call("PUT", path, self.token, bodies[winner])
        self.assertEqual(response.status, 200)
        self.assertEqual(retry["revision"], 1)
        response, conflict = await self.call("PUT", path, self.token, {**bodies[winner], "document": personal_document("different")})
        self.assertEqual(response.status, 409)
        self.assertEqual(conflict["error"], "mutation_conflict")
        invalid = [organization_document(), {**personal_document(), "scope": "organization-tasks"}]
        for fields in ({"taskSpace": "work"}, {"codexThreadId": "secret"}, {"localPath": "secret"}, {"futureField": "secret"}):
            value = personal_document()
            value["state"]["tasks"][0].update(fields)
            invalid.append(value)
        for key in ("collages", "assets", "captures", "memories", "receipts"):
            value = personal_document()
            value["state"][key] = []
            invalid.append(value)
        for n, value in enumerate(invalid):
            response, result = await self.call("PUT", path, self.token, {"expectedRevision": 1, "mutationId": f"unsafe-{n}", "document": value})
            self.assertEqual(response.status, 400, result)
        _, saved = await self.call("GET", path, self.token)
        self.assertEqual(saved, {"revision": 1, "document": bodies[winner]["document"]})

    async def test_task_background_roundtrip_replace_clear_and_legacy_records_in_both_scopes(self):
        multiline = "  任务背景\n第二行：说明与限制\n\n保留末尾空白  \n"
        # Each astral symbol is one code point (two UTF-16 code units), while
        # decomposed e + accent is two (one grapheme). No normalization/trimming.
        boundary = "😀" * 1000 + "e\u0301" * 500
        self.assertEqual(len(boundary), 2000)
        variants = [{}, {"background": multiline}, {"background": boundary},
                    {"background": "重新填写"}, {"background": ""},
                    {"background": None}, {}]
        for scope, make_document in (("organization", organization_document), ("personal", personal_document)):
            path = f"/v1/{scope}/state"
            for revision, fields in enumerate(variants):
                with self.subTest(scope=scope, revision=revision):
                    document = make_document(**fields)
                    body = {"expectedRevision": revision, "mutationId": f"background-{scope}-{revision}",
                            "document": document}
                    response, saved = await self.call("PUT", path, self.token, body)
                    self.assertEqual(response.status, 200, saved)
                    self.assertEqual(saved["revision"], revision + 1)
                    _, fetched = await self.call("GET", path, self.token)
                    self.assertEqual(fetched, {"revision": revision + 1, "document": document})
                    response, retry = await self.call("PUT", path, self.token, body)
                    self.assertEqual(response.status, 200, retry)
                    self.assertEqual(retry, saved)

    async def test_task_background_invalid_values_reject_whole_document_without_receipt(self):
        invalid_values = ["字" * 2001, "😀" * 2001, "e\u0301" * 1000 + "x",
                          1, 0.5, True, False, [], {}, ["text"], {"text": "background"}]
        for scope, make_document in (("organization", organization_document), ("personal", personal_document)):
            path = f"/v1/{scope}/state"
            baseline = make_document(background="原有背景\n不应改变")
            response, saved = await self.call("PUT", path, self.token,
                                              {"expectedRevision": 0, "mutationId": f"baseline-{scope}",
                                               "document": baseline})
            self.assertEqual(response.status, 200, saved)
            receipts = self.db.one("SELECT COUNT(*) n FROM mutations")["n"]
            for n, value in enumerate(invalid_values):
                with self.subTest(scope=scope, case=n):
                    document = make_document("Must not change", background="valid first task")
                    document["state"]["tasks"].append({"id": "invalid-second-task", "title": "Bad background",
                                                       "taskSpace": baseline["state"]["tasks"][0]["taskSpace"],
                                                       "background": value})
                    response, error = await self.call("PUT", path, self.token,
                                                     {"expectedRevision": 1, "mutationId": f"invalid-{scope}-{n}",
                                                      "document": document})
                    self.assertEqual(response.status, 400, error)
                    self.assertEqual(error["error"], "invalid_input")
                    self.assertIn("background", error["message"])
                    _, fetched = await self.call("GET", path, self.token)
                    self.assertEqual(fetched, {"revision": 1, "document": baseline})
                    self.assertEqual(self.db.one("SELECT COUNT(*) n FROM mutations")["n"], receipts)

    async def test_task_background_respects_organization_and_private_permissions(self):
        self.second_org()
        _, other_owner = await self.login("owner", "OTHER")
        member, alice = await self.approved()
        org_document = organization_document(background="组织共同背景")
        private_document = personal_document(background="Alice 的私人背景")
        org_body = {"expectedRevision": 0, "mutationId": "background-org", "document": org_document}
        private_body = {"expectedRevision": 0, "mutationId": "background-private", "document": private_document}
        for scope, body in (("organization", org_body), ("personal", private_body)):
            response, result = await self.call("PUT", f"/v1/{scope}/state", alice["token"], body)
            self.assertEqual(response.status, 200, result)
        _, shared = await self.call("GET", "/v1/organization/state", self.token)
        self.assertEqual(shared, {"revision": 1, "document": org_document})
        _, other_org = await self.call("GET", "/v1/organization/state", other_owner["token"])
        self.assertEqual(other_org, {"revision": 0, "document": None})
        for token in (self.token, other_owner["token"]):
            _, own_private = await self.call("GET", "/v1/personal/state", token)
            self.assertEqual(own_private, {"revision": 0, "document": None})
        _, alice_private = await self.call("GET", "/v1/personal/state", alice["token"])
        self.assertEqual(alice_private, {"revision": 1, "document": private_document})
        response, _ = await self.call("PATCH", "/v1/members/" + member["id"], self.token, {"status": "suspended"})
        self.assertEqual(response.status, 200)
        receipts = self.db.one("SELECT COUNT(*) n FROM mutations")["n"]
        for scope, document in (("organization", org_document), ("personal", private_document)):
            path = f"/v1/{scope}/state"
            response, _ = await self.call("GET", path, alice["token"])
            self.assertEqual(response.status, 401)
            rejected = copy.deepcopy(document)
            rejected["state"]["tasks"][0]["background"] = "must not overwrite"
            response, _ = await self.call("PUT", path, alice["token"],
                                          {"expectedRevision": 1, "mutationId": f"revoked-{scope}", "document": rejected})
            self.assertEqual(response.status, 401)
        self.assertEqual(self.db.one("SELECT COUNT(*) n FROM mutations")["n"], receipts)
        self.assertEqual(json.loads(self.db.one("SELECT document FROM organization_states WHERE org_id=?", (self.org,))["document"]), org_document)
        self.assertEqual(json.loads(self.db.one("SELECT document FROM personal_states WHERE user_id=?", (member["user_id"],))["document"]), private_document)

    async def test_organization_cas_and_idempotency_with_concurrent_member_writes(self):
        _, alice = await self.approved()
        tokens = [self.token, alice["token"]]
        # Identical mutation IDs are independent per actor; CAS still serializes edits.
        bodies = [{"expectedRevision": 0, "mutationId": "same-id", "document": organization_document(f"value-{n}")} for n in range(2)]
        results = await asyncio.gather(*(self.call("PUT", "/v1/organization/state", tokens[n], b) for n, b in enumerate(bodies)))
        self.assertEqual(sorted(r.status for r, _ in results), [200, 409])
        winner = next(i for i, (r, _) in enumerate(results) if r.status == 200)
        response, retry = await self.call("PUT", "/v1/organization/state", tokens[winner], bodies[winner])
        self.assertEqual(response.status, 200)
        self.assertEqual(retry["revision"], 1)
        conflicting = {**bodies[winner], "document": organization_document("different")}
        response, error = await self.call("PUT", "/v1/organization/state", tokens[winner], conflicting)
        self.assertEqual(response.status, 409)
        self.assertEqual(error["error"], "mutation_conflict")
        later = {"expectedRevision": 1, "mutationId": "same-id", "document": organization_document("newest")}
        response, _ = await self.call("PUT", "/v1/organization/state", tokens[1 - winner], later)
        self.assertEqual(response.status, 200)
        _, old_retry = await self.call("PUT", "/v1/organization/state", tokens[winner], bodies[winner])
        self.assertEqual(old_retry["revision"], 1)
        _, current = await self.call("GET", "/v1/organization/state", self.token)
        self.assertEqual(current["revision"], 2)
        _, member_copy = await self.call("GET", "/v1/organization/state", alice["token"])
        self.assertEqual(current, member_copy)

    async def test_organization_scope_is_session_bound_and_mutations_are_org_scoped(self):
        other_org = self.second_org()
        _, other = await self.login("owner", "OTHER")
        body = {"expectedRevision": 0, "mutationId": "same-id", "document": organization_document("Example Org")}
        response, _ = await self.call("PUT", "/v1/organization/state", self.token, body, headers={"X-Organization-ID": other_org})
        self.assertEqual(response.status, 200)
        _, untouched = await self.call("GET", "/v1/organization/state", other["token"])
        self.assertEqual(untouched, {"revision": 0, "document": None})
        response, _ = await self.call("PUT", "/v1/organization/state", other["token"], {**body, "document": organization_document("OTHER")})
        self.assertEqual(response.status, 200)
        _, first = await self.call("GET", "/v1/organization/state", self.token)
        _, second = await self.call("GET", "/v1/organization/state", other["token"])
        self.assertEqual(first["document"]["state"]["tasks"][0]["title"], "Example Org")
        self.assertEqual(second["document"]["state"]["tasks"][0]["title"], "OTHER")
        response, _ = await self.call("PUT", "/v1/organization/state", self.token, {**body, "orgId": other_org})
        self.assertEqual(response.status, 400)
        self.assertEqual(self.db.one("SELECT COUNT(*) n FROM organization_states")["n"], 2)

    async def test_approved_member_can_edit_and_remove_org_tasks_but_suspension_blocks_retry_and_read(self):
        member, alice = await self.approved()
        body = {"expectedRevision": 0, "mutationId": "owner", "document": organization_document()}
        await self.call("PUT", "/v1/organization/state", self.token, body)
        body = {"expectedRevision": 1, "mutationId": "member", "document": organization_document("Changed by ordinary member")}
        response, _ = await self.call("PUT", "/v1/organization/state", alice["token"], body)
        self.assertEqual(response.status, 200)
        empty = {"schemaVersion": 2, "scope": "organization-tasks", "state": {"tasks": [], "tracks": [], "taskPages": []}}
        deletion = {"expectedRevision": 2, "mutationId": "member-delete", "document": empty}
        response, _ = await self.call("PUT", "/v1/organization/state", alice["token"], deletion)
        self.assertEqual(response.status, 200)
        await self.call("PATCH", "/v1/members/" + member["id"], self.token, {"status": "suspended"})
        for method, data in (("GET", None), ("PUT", deletion)):
            response, _ = await self.call(method, "/v1/organization/state", alice["token"], data)
            self.assertEqual(response.status, 401)
        _, saved = await self.call("GET", "/v1/organization/state", self.token)
        self.assertEqual(saved, {"revision": 3, "document": empty})

    async def test_organization_validator_rejects_private_collage_codex_unknown_and_nested_payloads(self):
        invalid = []
        for key in ("collage", "assets", "captures", "memories", "receipts", "scheduleBlocks", "meta"):
            value = organization_document()
            value["state"][key] = []
            invalid.append(value)
        for fields in ({"taskSpace": "personal"}, {"taskSpace": None}, {"taskSpace": "unknown"},
                       {"codexThreadId": "local-thread"}, {"codexSummary": "private"}, {"source": "/Users/person/file"},
                       {"localPath": "/Users/person/file"}, {"collage": {}}, {"futureSecretField": "secret"},
                       {"notes": {"secret": "nested"}}, {"details": [{"path": "secret"}]},
                       {"peopleWaits": [{"id": "p1", "person": "someone", "outcome": "", "resolved": False, "path": "secret"}]},
                       {"peopleWaits": [{"id": "p1", "person": "someone", "outcome": "", "resolved": "false"}]},
                       {"dependsOn": None}, {"priority": True}, {"archived": "false"}, {"title": " "},
                       {"availableAt": "2026-10-20"}, {"availableAt": "2026-10-20T12:00:00"}):
            invalid.append(organization_document(**fields))
        for collection, entity in (("tracks", {"id": "track-1", "name": "safe", "notes": "private"}),
                                   ("taskPages", {"id": "page-" + uid(), "title": "safe", "assets": []})):
            value = organization_document()
            value["state"][collection] = [entity]
            invalid.append(value)
        invalid += [{"schemaVersion": 1, "state": {}},
                    {**organization_document(), "private": "no"},
                    {**organization_document(), "scope": "personal"},
                    {**organization_document(), "schemaVersion": True}]
        for n, value in enumerate(invalid):
            with self.subTest(case=n):
                response, result = await self.call("PUT", "/v1/organization/state", self.token,
                                                  {"expectedRevision": 0, "mutationId": f"bad-{n}", "document": value})
                self.assertEqual(response.status, 400, result)
        self.assertEqual(self.db.one("SELECT COUNT(*) n FROM organization_states")["n"], 0)
        self.assertEqual(self.db.one("SELECT COUNT(*) n FROM mutations")["n"], 0)

    async def test_organization_graph_and_collection_validation_and_valid_rich_document(self):
        page = "page-" + uid()
        valid = organization_document("Parent", taskSpace=page, trackId="track-1", details=["delivery", "invoice"],
                                      priority=5, archived=False, notes=None, availableAt="2026-10-20T12:00:00+08:00",
                                      peopleWaits=[{"id": "p1", "person": "alice", "outcome": "invoice", "resolved": False}])
        valid["state"]["tasks"].append({"id": "child", "title": "Child", "taskSpace": page, "parentId": "task-1", "dependsOn": ["task-1"]})
        valid["state"]["tracks"] = [{"id": "track-1", "name": "Track", "stages": ["delivery", "settlement"]}]
        valid["state"]["taskPages"] = [{"id": page, "title": "Organization page"}]
        invalid = []
        for field, value in (("parentId", "absent"), ("dependsOn", ["absent"]), ("dependsOn", ["child"]), ("parentId", "child"), ("taskSpace", "work")):
            candidate = copy.deepcopy(valid)
            candidate["state"]["tasks"][0][field] = value
            invalid.append(candidate)
        for collection in ("tasks", "tracks", "taskPages"):
            candidate = copy.deepcopy(valid)
            candidate["state"][collection].append(copy.deepcopy(candidate["state"][collection][0]))
            invalid.append(candidate)
        for collection, entity in (("tracks", {"id": "unused"}), ("taskPages", {"id": "page-" + uid(), "title": "unused"})):
            candidate = copy.deepcopy(valid)
            candidate["state"][collection].append(entity)
            invalid.append(candidate)
        candidate = copy.deepcopy(valid)
        candidate["state"]["taskPages"][0]["title"] = "私人任务"
        invalid.append(candidate)
        for n, candidate in enumerate(invalid):
            response, error = await self.call("PUT", "/v1/organization/state", self.token,
                                             {"expectedRevision": 0, "mutationId": f"graph-{n}", "document": candidate})
            self.assertEqual(response.status, 400, error)
        response, saved = await self.call("PUT", "/v1/organization/state", self.token,
                                         {"expectedRevision": 0, "mutationId": "valid-rich", "document": valid})
        self.assertEqual(response.status, 200, saved)
        _, fetched = await self.call("GET", "/v1/organization/state", self.token)
        self.assertEqual(fetched["document"], valid)

    async def test_legacy_shared_readonly_recovery_keeps_org_isolation_and_data(self):
        self.second_org()
        _, alice = await self.approved()
        _, bob = await self.approved("bob")
        path = "/v1/shared/tasks/task-1"
        payload = {"expectedRevision": 0, "mutationId": "create", "task": {"id": "task-1", "title": "shared"}}
        self.db.execute("INSERT INTO shared_tasks VALUES(?,?,?,?,?,0,?)", (self.org, "task-1", alice["user"]["id"], 1, canonical(payload["task"]), int(time.time())))
        for token in (self.token, alice["token"], bob["token"]):
            for method, url, body in (("PUT", path, payload), ("DELETE", path + "?expectedRevision=1", None)):
                response, error = await self.call(method, url, token, body)
                self.assertEqual(response.status, 403)
                self.assertEqual(error["error"], "organization_state_required")
        _, owner_other = await self.login("owner", "OTHER")
        _, other_tasks = await self.call("GET", "/v1/shared/tasks", owner_other["token"])
        self.assertEqual(other_tasks, {"tasks": []})
        _, local_tasks = await self.call("GET", "/v1/shared/tasks", bob["token"])
        self.assertEqual(local_tasks["tasks"][0]["ownerId"], alice["user"]["id"])
        saved = self.db.one("SELECT deleted,revision,task FROM shared_tasks")
        self.assertEqual((saved["deleted"], saved["revision"]), (0, 1))
        self.assertEqual(json.loads(saved["task"]), payload["task"])

    async def test_legacy_shared_write_rejection_precedes_parsing_and_auth_is_required(self):
        path = "/v1/shared/tasks/task-1"
        response = await self.client.put(path, data="invalid-json", headers={"Authorization": "Bearer " + self.token})
        self.assertEqual(response.status, 403)
        for method in ("PUT", "DELETE"):
            response, _ = await self.call(method, path)
            self.assertEqual(response.status, 401)
        self.assertEqual(self.db.one("SELECT COUNT(*) n FROM shared_tasks")["n"], 0)

    async def test_account_limit_includes_pending_and_concurrent_registration(self):
        self.seed_pending(MAX_USERS - 2)
        results = await asyncio.gather(*(self.call("POST", "/v1/auth/register", body={"organization": "Example Org", "username": f"last{n}", "password": PASSWORD}) for n in range(2)))
        self.assertEqual(sorted(r.status for r, _ in results), [201, 409])
        self.assertEqual(self.db.one("SELECT COUNT(*) n FROM users")["n"], MAX_USERS)
        self.assertEqual(next(data["error"] for r, data in results if r.status == 409), "user_limit")

    async def test_rejected_initial_registration_frees_slot_without_reusing_identity(self):
        rejected = await self.register("alice")
        self.seed_pending(MAX_USERS - 2)
        response, _ = await self.call("POST", "/v1/auth/register", body={"organization": "Example Org", "username": "new-user", "password": PASSWORD})
        self.assertEqual(response.status, 409)
        response, _ = await self.call("PATCH", "/v1/members/" + rejected["id"], self.token, {"status": "rejected"})
        self.assertEqual(response.status, 200)
        retained = self.db.one("SELECT id,username FROM users WHERE username_key='alice'")
        self.assertEqual(retained["id"], rejected["user_id"])
        self.assertEqual(retained["username"], "alice")
        response, unavailable = await self.call("POST", "/v1/auth/register", body={"organization": "Example Org", "username": "ALICE", "password": PASSWORD})
        self.assertEqual(response.status, 409)
        self.assertEqual(unavailable["error"], "account_unavailable")
        response, _ = await self.call("POST", "/v1/auth/register", body={"organization": "Example Org", "username": "new-user", "password": PASSWORD})
        self.assertEqual(response.status, 201)
        replacement = self.db.one("SELECT id FROM users WHERE username_key='new-user'")
        self.assertNotEqual(replacement["id"], rejected["user_id"])
        self.assertEqual(self.db.one("SELECT COUNT(*) n FROM users")["n"], MAX_USERS + 1)
        # An old rejected applicant cannot be re-approved above the live capacity.
        response, full = await self.call("PATCH", "/v1/members/" + rejected["id"], self.token, {"status": "approved"})
        self.assertEqual(response.status, 409)
        self.assertEqual(full["error"], "user_limit")
        self.assertEqual(self.db.one("SELECT status FROM memberships WHERE id=?", (rejected["id"],))["status"], "rejected")

    async def test_rejecting_one_organization_cannot_release_or_disable_an_approved_account(self):
        other_org = self.second_org()
        member, alice = await self.approved()
        await self.call("POST", "/v1/organizations/join", alice["token"], {"organization": "OTHER"})
        membership = self.db.one("SELECT id FROM memberships WHERE user_id=? AND org_id=?", (member["user_id"], other_org))
        _, other_owner = await self.login("owner", "OTHER")
        response, _ = await self.call("PATCH", "/v1/members/" + membership["id"], other_owner["token"], {"status": "approved"})
        self.assertEqual(response.status, 200)
        self.seed_pending(MAX_USERS - 2)
        await self.call("PATCH", "/v1/members/" + member["id"], self.token, {"status": "rejected"})
        self.assertEqual(self.db.one("SELECT status FROM users WHERE id=?", (member["user_id"],))["status"], "approved")
        response, _ = await self.login("alice", "OTHER")
        self.assertEqual(response.status, 200)
        response, _ = await self.login("alice", "Example Org")
        self.assertEqual(response.status, 401)
        response, full = await self.call("POST", "/v1/auth/register", body={"organization": "Example Org", "username": "overflow", "password": PASSWORD})
        self.assertEqual(response.status, 409)
        self.assertEqual(full["error"], "user_limit")

    async def test_logout_expiry_and_session_org_cannot_be_switched_by_header(self):
        other_org = self.second_org()
        _, me = await self.call("GET", "/v1/me", self.token, headers={"X-Organization-ID": other_org})
        self.assertEqual(me["organization"]["id"], self.org)
        response, _ = await self.call("POST", "/v1/auth/logout", self.token)
        self.assertEqual(response.status, 200)
        response, _ = await self.call("GET", "/v1/me", self.token)
        self.assertEqual(response.status, 401)
        _, session = await self.login("owner")
        self.db.execute("UPDATE sessions SET expires_at=? WHERE token_hash=?", (int(time.time()) - 1, sha(session["token"])))
        response, _ = await self.call("GET", "/v1/me", session["token"])
        self.assertEqual(response.status, 401)

    async def test_persistent_sessions_survive_time_and_other_device_login(self):
        self.assertIsNone(self.owner["expiresAt"])
        response, session = await self.login("owner")
        self.assertEqual(response.status, 200)
        self.assertIsNone(session["expiresAt"])
        self.assertNotEqual(session["token"], self.token)
        self.assertEqual([r["expires_at"] for r in self.db.all("SELECT expires_at FROM sessions")], [0, 0])
        with patch("server.time.time", return_value=int(time.time()) + 100 * 365 * 86400):
            for token in (self.token, session["token"]):
                actor = self.service.auth(make_mocked_request("GET", "/v1/me", headers={"Authorization": "Bearer " + token}))
                self.assertEqual(actor["user_id"], self.owner["user"]["id"])
        await self.call("POST", "/v1/auth/logout", session["token"])
        self.assertEqual((await self.call("GET", "/v1/me", session["token"]))[0].status, 401)
        self.assertEqual((await self.call("GET", "/v1/me", self.token))[0].status, 200)

    async def test_session_migration_preserves_only_active_tokens_and_is_idempotent(self):
        now = int(time.time())
        member, _ = await self.approved()
        self.db.execute("DELETE FROM sessions")
        self.db.execute("DELETE FROM metadata WHERE key='persistent_sessions_v1'")
        user_id = self.owner["user"]["id"]
        for label, expires in (("valid", now + 1000), ("expired", now - 1), ("boundary", now), ("zero", 0), ("negative", -1)):
            self.db.execute("INSERT INTO sessions VALUES(?,?,?,?)", (sha(label), user_id, self.org, expires))
        self.db.execute("INSERT INTO sessions VALUES(?,?,?,?)", (sha("suspended"), member["user_id"], self.org, now + 1000))
        self.db.execute("UPDATE memberships SET status='suspended' WHERE id=?", (member["id"],))
        untouched = {table: [tuple(r) for r in self.db.all("SELECT * FROM " + table)]
                     for table in ("users", "organizations", "memberships", "personal_states", "organization_states")}
        with patch("server.time.time", return_value=now):
            self.db.migrate_persistent_sessions()
        rows = [tuple(r) for r in self.db.all("SELECT * FROM sessions")]
        self.assertEqual(rows, [(sha("valid"), user_id, self.org, 0)])
        self.assertEqual(self.db.one("SELECT value FROM metadata WHERE key='persistent_sessions_v1'")["value"], "1")
        for table, before in untouched.items():
            self.assertEqual([tuple(r) for r in self.db.all("SELECT * FROM " + table)], before)
        # Reapproval and restarts cannot restore removed tokens. A future finite
        # token from an older server version can be migrated without reissuing it.
        self.db.execute("UPDATE memberships SET status='approved' WHERE id=?", (member["id"],))
        self.db.execute("INSERT INTO sessions VALUES(?,?,?,?)", (sha("legacy"), user_id, self.org, now + 1000))
        self.db.execute("INSERT INTO sessions VALUES(?,?,?,?)", (sha("stale"), user_id, self.org, now - 1))
        self.db.migrate_persistent_sessions()
        self.db.migrate_persistent_sessions()
        self.assertEqual({r["token_hash"] for r in self.db.all("SELECT * FROM sessions")}, {sha("valid"), sha("legacy")})
        self.assertTrue(all(r["expires_at"] == 0 for r in self.db.all("SELECT * FROM sessions")))
        self.db.execute("UPDATE metadata SET value='unknown' WHERE key='persistent_sessions_v1'")
        with self.assertRaisesRegex(RuntimeError, "Unsupported session policy"):
            self.db.migrate_persistent_sessions()
        self.assertEqual(self.db.one("SELECT COUNT(*) AS n FROM sessions")["n"], 2)

    async def test_expired_legacy_cleanup_keeps_persistent_sessions(self):
        self.db.execute("INSERT INTO sessions VALUES(?,?,?,?)", (sha("stale"), self.owner["user"]["id"], self.org, int(time.time()) - 1))
        await self.login("owner")
        self.assertIsNone(self.db.one("SELECT 1 FROM sessions WHERE token_hash=?", (sha("stale"),)))
        self.assertIsNotNone(self.db.one("SELECT 1 FROM sessions WHERE token_hash=?", (sha(self.token),)))

    async def test_password_reset_revokes_persistent_and_inflight_old_password_login(self):
        entered, resume = asyncio.Event(), asyncio.Event()
        original = self.service.verify_password

        async def delayed_verify(encoded, secret):
            valid = await original(encoded, secret)
            entered.set()
            await resume.wait()
            return valid

        with patch.object(self.service, "verify_password", delayed_verify):
            pending = asyncio.create_task(self.login("owner"))
            try:
                await asyncio.wait_for(entered.wait(), 5)
                new_hash = await self.service.hash_password(PASSWORD + "-changed")
                with self.db.transaction():
                    self.db.execute("UPDATE users SET password_hash=? WHERE id=?", (new_hash, self.owner["user"]["id"]))
                    self.db.execute("DELETE FROM sessions WHERE user_id=?", (self.owner["user"]["id"],))
            finally:
                resume.set()
            response, _ = await asyncio.wait_for(pending, 5)
        self.assertEqual(response.status, 401)
        self.assertEqual(self.db.one("SELECT COUNT(*) AS n FROM sessions")["n"], 0)
        self.assertEqual((await self.call("GET", "/v1/me", self.token))[0].status, 401)

    async def test_organization_rename_preserves_stable_id_and_session(self):
        response, renamed = await self.call("PATCH", "/v1/organization", self.token, {"name": "Example Org 新名"})
        self.assertEqual(response.status, 200)
        self.assertEqual(renamed["organization"]["id"], self.org)
        _, me = await self.call("GET", "/v1/me", self.token)
        self.assertEqual(me["organization"]["name"], "Example Org 新名")
        response, _ = await self.login("owner", "Example Org")
        self.assertEqual(response.status, 401)
        response, _ = await self.login("owner", "Example Org 新名")
        self.assertEqual(response.status, 200)

    async def test_rate_limits_and_forwarded_for_is_ignored(self):
        for n in range(10):
            response, _ = await self.call("POST", "/v1/auth/login", body={"organization": "Example Org", "username": "missing", "password": PASSWORD}, headers={"X-Forwarded-For": f"10.0.0.{n}"})
            self.assertEqual(response.status, 401)
        response, result = await self.call("POST", "/v1/auth/login", body={"organization": "Example Org", "username": "missing", "password": PASSWORD}, headers={"X-Forwarded-For": "10.0.0.99"})
        self.assertEqual(response.status, 429)
        self.assertEqual(result["error"], "rate_limited")
        self.assertIn("Retry-After", response.headers)
        # Registrar limiter is separate from authentication and is applied even to invalid attempts.
        for n in range(10):
            response, _ = await self.call("POST", "/v1/auth/register", body={})
            self.assertEqual(response.status, 400)
        response, _ = await self.call("POST", "/v1/auth/register", body={})
        self.assertEqual(response.status, 429)

    async def test_request_limits_invalid_revision_and_auth_errors(self):
        payload = {"expectedRevision": 0, "mutationId": "oversize", "document": {"x": "x" * DOCUMENT_LIMIT}}
        response = await self.client.put("/v1/organization/state", data=io.BytesIO(json.dumps(payload).encode()), headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        result = await response.json()
        self.assertEqual(response.status, 413)
        self.assertEqual(result["error"], "too_large")
        for value in [True, -1, 1.3, "0"]:
            response, _ = await self.call("PUT", "/v1/organization/state", self.token, {"expectedRevision": value, "mutationId": "bad", "document": organization_document()})
            self.assertEqual(response.status, 400)
        response, error = await self.call("POST", "/v1/auth/login", body={"organization": "Example Org", "username": "owner", "password": "wrong-but-long-password"})
        self.assertEqual(response.status, 401)
        response, unknown = await self.call("POST", "/v1/auth/login", body={"organization": "Example Org", "username": "unknown", "password": PASSWORD})
        self.assertEqual(error, unknown)
        response = await self.client.put("/v1/organization/state", headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json"}, data='{ "expectedRevision": NaN }')
        self.assertEqual(response.status, 400)

    async def test_storage_disk_and_receipt_caps_never_destroy_previous_state(self):
        path = "/v1/organization/state"
        first = {"expectedRevision": 0, "mutationId": "first", "document": organization_document("saved")}
        await self.call("PUT", path, self.token, first)
        next_body = {"expectedRevision": 1, "mutationId": "next", "document": organization_document("new")}
        with patch("server.DATABASE_LIMIT", 1):
            response, data = await self.call("PUT", path, self.token, next_body)
            self.assertEqual(response.status, 507)
            self.assertEqual(data["error"], "storage_limit")
        with patch("server.shutil.disk_usage", return_value=SimpleNamespace(free=0)):
            response, data = await self.call("PUT", path, self.token, next_body)
            self.assertEqual(response.status, 507)
        with patch("server.MAX_RECEIPTS_PER_USER", 1):
            response, data = await self.call("PUT", path, self.token, next_body)
            self.assertEqual(response.status, 507)
            self.assertEqual(data["error"], "receipt_limit")
            response, retry = await self.call("PUT", path, self.token, first)
            self.assertEqual(response.status, 200)
            self.assertEqual(retry["revision"], 1)
        _, saved = await self.call("GET", path, self.token)
        self.assertEqual(saved, {"revision": 1, "document": first["document"]})

    async def test_online_backup_is_consistent_private_and_refuses_overwrite(self):
        payload = {"expectedRevision": 0, "mutationId": "backup", "document": {"private": "preserved"}}
        self.db.execute("INSERT INTO personal_states VALUES(?,?,?,?)", (self.owner["user"]["id"], 1, canonical(payload["document"]), int(time.time())))
        org_payload = {"expectedRevision": 0, "mutationId": "backup", "document": organization_document()}
        await self.call("PUT", "/v1/organization/state", self.token, org_payload)
        target = Path(self.temporary.name) / "backups" / "snapshot.sqlite3"
        backup(self.service.config.database, target)
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        import sqlite3
        saved = sqlite3.connect(target)
        try:
            self.assertEqual(saved.execute("PRAGMA quick_check").fetchone()[0], "ok")
            row = saved.execute("SELECT document FROM personal_states").fetchone()
            self.assertEqual(json.loads(row[0]), payload["document"])
            row = saved.execute("SELECT document FROM organization_states").fetchone()
            self.assertEqual(json.loads(row[0]), org_payload["document"])
        finally:
            saved.close()
        with self.assertRaises(FileExistsError):
            backup(self.service.config.database, target)

    async def test_suspension_while_body_is_uploading_prevents_write(self):
        member, alice = await self.approved()
        original = self.service.body
        reading, resume = asyncio.Event(), asyncio.Event()

        async def paused(request):
            data = await original(request)
            if request.path == "/v1/organization/state":
                reading.set()
                await resume.wait()
            return data

        self.service.body = paused
        writer = asyncio.create_task(self.call("PUT", "/v1/organization/state", alice["token"], {"expectedRevision": 0, "mutationId": "delayed", "document": organization_document("never stored")}))
        await asyncio.wait_for(reading.wait(), timeout=3)
        response, _ = await self.call("PATCH", "/v1/members/" + member["id"], self.token, {"status": "suspended"})
        self.assertEqual(response.status, 200)
        resume.set()
        response, _ = await writer
        self.assertEqual(response.status, 401)
        self.assertIsNone(self.db.one("SELECT 1 FROM organization_states WHERE org_id=?", (self.org,)))

    async def test_private_upload_revalidates_membership_inside_transaction(self):
        member, alice = await self.approved()
        original = self.service.body

        async def revoke_after_body(request):
            data = await original(request)
            self.db.execute("UPDATE memberships SET status='suspended' WHERE id=?", (member["id"],))
            return data

        self.service.body = revoke_after_body
        response, _ = await self.call("PUT", "/v1/personal/state", alice["token"],
                                      {"expectedRevision": 0, "mutationId": "delayed-private", "document": personal_document()})
        self.assertEqual(response.status, 401)
        self.assertIsNone(self.db.one("SELECT 1 FROM personal_states WHERE user_id=?", (member["user_id"],)))

    async def test_external_peers_cannot_forge_proxy_ip_and_auth_queue_is_bounded(self):
        request = make_mocked_request("GET", "/health", headers={"X-Real-IP": "127.0.0.1"}).clone(remote="203.0.113.5")

        async def unreachable(_):
            self.fail("External connection was accepted")

        with self.assertRaises(APIError) as failure:
            await loopback_and_headers(request, unreachable)
        self.assertEqual(failure.exception.status, 403)
        self.service.hash_waiters = 8
        try:
            response, _ = await self.login("owner")
            self.assertEqual(response.status, 429)
        finally:
            self.service.hash_waiters = 0
        response = await self.client.head("/health")
        self.assertEqual(response.status, 200)

    async def test_schema_version_health_and_no_schema_downgrade(self):
        self.assertEqual(self.db.one("PRAGMA user_version")[0], 2)
        response, healthy = await self.call("GET", "/health")
        self.assertEqual(response.status, 200)
        self.assertTrue(healthy["ok"])
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        db_path = Path(self.temporary.name) / "future.sqlite3"
        import sqlite3
        connection = sqlite3.connect(db_path)
        connection.execute("PRAGMA user_version=99")
        connection.close()
        with self.assertRaisesRegex(RuntimeError, "refusing downgrade"):
            create_app(Config(db_path))

    async def test_schema_one_additive_migration_preserves_legacy_rows_and_credentials(self):
        import sqlite3
        legacy_private = {"schemaVersion": 1, "state": {"tasks": [{"id": "legacy", "title": "not auto shared"}]}}
        self.db.execute("INSERT INTO personal_states VALUES(?,?,?,?)", (self.owner["user"]["id"], 7, canonical(legacy_private), 1))
        self.db.execute("INSERT INTO shared_tasks VALUES(?,?,?,?,?,0,?)", (self.org, "legacy", self.owner["user"]["id"], 3, '{"id":"legacy","title":"saved"}', 1))
        path = Path(self.temporary.name) / "legacy.sqlite3"
        backup(self.service.config.database, path)
        connection = sqlite3.connect(path)
        connection.execute("DROP TABLE organization_states")
        connection.execute("PRAGMA user_version=1")
        connection.commit()
        expected_users = connection.execute("SELECT * FROM users").fetchall()
        expected_sessions = connection.execute("SELECT * FROM sessions").fetchall()
        expected_shared = connection.execute("SELECT * FROM shared_tasks").fetchall()
        connection.close()
        migrated = Store(Config(path))
        try:
            self.assertEqual(migrated.one("PRAGMA user_version")[0], 2)
            self.assertEqual([tuple(row) for row in migrated.all("SELECT * FROM users")], expected_users)
            self.assertEqual([tuple(row) for row in migrated.all("SELECT * FROM sessions")], expected_sessions)
            self.assertEqual([tuple(row) for row in migrated.all("SELECT * FROM shared_tasks")], expected_shared)
            self.assertEqual(json.loads(migrated.one("SELECT document FROM personal_states")["document"]), legacy_private)
            self.assertEqual(migrated.one("SELECT revision FROM personal_states")["revision"], 7)
            self.assertEqual(migrated.one("SELECT COUNT(*) n FROM organization_states")["n"], 0)
        finally:
            migrated.db.close()


if __name__ == "__main__":
    unittest.main()
