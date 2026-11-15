"""Transactional three-person families; billing remains with the host server.

The family owner must have direct, paid Premium; the invited account may be
Free. The host passes its synchronous ``allow_owner(account_id) -> bool`` check into both
operations so the check runs inside the same serialized write transaction.
Family membership never manufactures or extends a paid subscription.
"""
from __future__ import annotations

import hashlib
import inspect
import re
import secrets
import time
import uuid
from typing import Callable

from access_database import AccessDatabase, AccessError


INVITE_TTL_SECONDS = 7 * 24 * 60 * 60
INVITE_CREATION_LIMIT = 30
INVITE_CREATION_WINDOW_SECONDS = 24 * 60 * 60
GUEST_LIMIT = 2
FAMILY_LIMIT = 1 + GUEST_LIMIT
_TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9_-]{43}$")
OwnerCheck = Callable[[str], bool]


class FamilyService:
    def __init__(self, database: AccessDatabase, clock=time.time):
        self.database = database
        self.clock = clock
        with self.database.transaction() as db:
            schema = """
                CREATE TABLE IF NOT EXISTS family_groups (
                    id TEXT PRIMARY KEY,
                    owner_id TEXT NOT NULL UNIQUE,
                    created_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS family_members (
                    account_id TEXT PRIMARY KEY,
                    family_id TEXT NOT NULL REFERENCES family_groups(id) ON DELETE CASCADE,
                    joined_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS family_members_group
                    ON family_members(family_id);
                CREATE TABLE IF NOT EXISTS family_invites (
                    id TEXT PRIMARY KEY,
                    family_id TEXT NOT NULL REFERENCES family_groups(id) ON DELETE CASCADE,
                    token_hash TEXT NOT NULL UNIQUE,
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('pending','accepted','revoked')),
                    accepted_by TEXT,
                    accepted_at REAL
                );
                CREATE INDEX IF NOT EXISTS family_invites_group_status
                    ON family_invites(family_id, status, expires_at);
                CREATE INDEX IF NOT EXISTS family_invites_group_created
                    ON family_invites(family_id, created_at);
            """
            for statement in schema.split(";"):
                if statement.strip():
                    db.execute(statement)

    @staticmethod
    def _token_hash(token: str) -> str:
        if not isinstance(token, str) or not _TOKEN_PATTERN.fullmatch(token):
            raise AccessError(404, "invite_not_found", "Приглашение не найдено.")
        return hashlib.sha256(token.encode("ascii")).hexdigest()

    @staticmethod
    def _require_owner_access(owner_id: str, allow_owner: OwnerCheck | None) -> None:
        if allow_owner is None:
            raise AccessError(503, "premium_check_unavailable", "Не настроена проверка подписки владельца.")
        result = allow_owner(owner_id)
        if inspect.isawaitable(result):
            # A coroutine must never be treated as a truthy entitlement.
            if inspect.iscoroutine(result):
                result.close()
            raise AccessError(503, "premium_check_unavailable", "Нужна синхронная проверка подписки владельца.")
        if result is False:
            raise AccessError(403, "family_owner_premium_required", "Нужна действующая личная подписка владельца.")
        if result is not True:
            raise AccessError(503, "premium_check_unavailable", "Не удалось подтвердить подписку владельца.")

    @staticmethod
    def _membership(db, account_id: str):
        return db.execute(
            """SELECT g.* FROM family_members AS m
               JOIN family_groups AS g ON g.id=m.family_id WHERE m.account_id=?""",
            (account_id,),
        ).fetchone()

    @staticmethod
    def _owned_family(db, owner_id: str):
        family = db.execute("SELECT * FROM family_groups WHERE owner_id=?", (owner_id,)).fetchone()
        if family is None:
            membership = FamilyService._membership(db, owner_id)
            if membership is not None:
                raise AccessError(403, "family_owner_required", "Управлять семьёй может только её владелец.")
            raise AccessError(404, "family_not_found", "Семья не найдена.")
        return family

    def _pending(self, db, family_id: str):
        return db.execute(
            """SELECT id,created_at,expires_at FROM family_invites
               WHERE family_id=? AND status='pending' AND expires_at>?
               ORDER BY created_at,id""",
            (family_id, self.clock()),
        ).fetchall()

    @staticmethod
    def _members(db, family_id: str, owner_id: str):
        rows = db.execute(
            """SELECT account_id,joined_at FROM family_members
               WHERE family_id=? ORDER BY joined_at,account_id""",
            (family_id,),
        ).fetchall()
        return sorted(
            [{"account_id": row["account_id"], "joined_at": row["joined_at"],
              "role": "owner" if row["account_id"] == owner_id else "member"} for row in rows],
            key=lambda row: (row["role"] != "owner", row["joined_at"], row["account_id"]),
        )

    def _state(self, db, family, viewer_id: str) -> dict:
        members = self._members(db, family["id"], family["owner_id"])
        result = {
            "id": family["id"],
            "owner_id": family["owner_id"],
            "created_at": family["created_at"],
            "members": members,
            "member_count": len(members),
            "capacity": FAMILY_LIMIT,
            "guest_limit": GUEST_LIMIT,
            "role": "owner" if viewer_id == family["owner_id"] else "member",
        }
        if viewer_id == family["owner_id"]:
            pending = self._pending(db, family["id"])
            result["pending_invites"] = [dict(row) for row in pending]
            result["available_invites"] = max(0, FAMILY_LIMIT - len(members) - len(pending))
        return result

    def owner_for(self, account_id: str) -> str | None:
        with self.database.read() as db:
            family = self._membership(db, account_id)
            return family["owner_id"] if family is not None else None

    def family_for(self, account_id: str) -> dict | None:
        with self.database.read() as db:
            # A SAVEPOINT gives all display queries the same snapshot and also
            # nests safely if the host read helper already started a transaction.
            db.execute("SAVEPOINT family_snapshot")
            try:
                family = self._membership(db, account_id)
                return self._state(db, family, account_id) if family is not None else None
            finally:
                db.execute("RELEASE family_snapshot")

    def create_invite(self, owner_id: str, *, allow_owner: OwnerCheck | None = None) -> dict:
        now = self.clock()
        token = secrets.token_urlsafe(32)
        invite_id = uuid.uuid4().hex
        expires_at = now + INVITE_TTL_SECONDS
        with self.database.transaction() as db:
            self._require_owner_access(owner_id, allow_owner)
            family = self._membership(db, owner_id)
            if family is not None and family["owner_id"] != owner_id:
                raise AccessError(409, "account_in_family", "Участник семьи не может создавать другую семью.")
            if family is None:
                family_id = uuid.uuid4().hex
                db.execute("INSERT INTO family_groups(id,owner_id,created_at) VALUES(?,?,?)",
                           (family_id, owner_id, now))
                db.execute("INSERT INTO family_members(account_id,family_id,joined_at) VALUES(?,?,?)",
                           (owner_id, family_id, now))
                family = db.execute("SELECT * FROM family_groups WHERE id=?", (family_id,)).fetchone()
            recent_count = db.execute(
                "SELECT COUNT(*) FROM family_invites WHERE family_id=? AND created_at>?",
                (family["id"], now - INVITE_CREATION_WINDOW_SECONDS),
            ).fetchone()[0]
            if recent_count >= INVITE_CREATION_LIMIT:
                raise AccessError(429, "invite_rate_limit", "Можно создать не больше 30 приглашений за 24 часа.")
            guest_count = db.execute(
                "SELECT COUNT(*) FROM family_members WHERE family_id=? AND account_id<>?",
                (family["id"], owner_id),
            ).fetchone()[0]
            if guest_count + len(self._pending(db, family["id"])) >= GUEST_LIMIT:
                raise AccessError(409, "family_full", "Все места заняты участниками или действующими приглашениями.")
            db.execute(
                """INSERT INTO family_invites(id,family_id,token_hash,created_at,expires_at,status)
                   VALUES(?,?,?,?,?,'pending')""",
                (invite_id, family["id"], hashlib.sha256(token.encode("ascii")).hexdigest(), now, expires_at),
            )
            return {"token": token, "invite_id": invite_id, "expires_at": expires_at,
                    "family_id": family["id"]}

    def preview(self, token: str) -> dict:
        digest = self._token_hash(token)
        with self.database.read() as db:
            row = db.execute(
                """SELECT i.*,g.owner_id FROM family_invites AS i
                   JOIN family_groups AS g ON g.id=i.family_id WHERE i.token_hash=?""",
                (digest,),
            ).fetchone()
            if row is None:
                raise AccessError(404, "invite_not_found", "Приглашение не найдено.")
            reason = None
            if row["status"] == "accepted":
                reason = "invite_used"
            elif row["status"] == "revoked":
                reason = "invite_revoked"
            elif row["expires_at"] <= self.clock():
                reason = "invite_expired"
            return {"owner_id": row["owner_id"], "expires_at": row["expires_at"],
                    "available": reason is None, "reason": reason}

    def accept(self, account_id: str, token: str, *, allow_owner: OwnerCheck | None = None) -> dict:
        digest = self._token_hash(token)
        with self.database.transaction() as db:
            invitation = db.execute(
                """SELECT i.*,g.owner_id FROM family_invites AS i
                   JOIN family_groups AS g ON g.id=i.family_id WHERE i.token_hash=?""",
                (digest,),
            ).fetchone()
            if invitation is None:
                raise AccessError(404, "invite_not_found", "Приглашение не найдено.")
            membership = self._membership(db, account_id)
            if invitation["status"] == "accepted":
                if (invitation["accepted_by"] == account_id and membership is not None and
                        membership["id"] == invitation["family_id"]):
                    result = self._state(db, membership, account_id)
                    result["already_member"] = True
                    return result
                raise AccessError(409, "invite_used", "Приглашение уже использовано.")
            if invitation["status"] == "revoked":
                raise AccessError(410, "invite_revoked", "Приглашение отозвано.")
            if invitation["expires_at"] <= self.clock():
                raise AccessError(410, "invite_expired", "Срок приглашения истёк.")
            if account_id == invitation["owner_id"]:
                raise AccessError(400, "cannot_join_own_family", "Владелец уже входит в свою семью.")
            if membership is not None:
                raise AccessError(409, "account_in_family", "Аккаунт уже состоит в семье.")
            self._require_owner_access(invitation["owner_id"], allow_owner)
            guest_count = db.execute(
                "SELECT COUNT(*) FROM family_members WHERE family_id=? AND account_id<>?",
                (invitation["family_id"], invitation["owner_id"]),
            ).fetchone()[0]
            if guest_count >= GUEST_LIMIT:
                raise AccessError(409, "family_full", "В семье уже три участника, включая владельца.")
            now = self.clock()
            db.execute("INSERT INTO family_members(account_id,family_id,joined_at) VALUES(?,?,?)",
                       (account_id, invitation["family_id"], now))
            db.execute("""UPDATE family_invites SET status='accepted',accepted_by=?,accepted_at=?
                          WHERE id=? AND status='pending'""",
                       (account_id, now, invitation["id"]))
            result = self._state(db, {"id": invitation["family_id"],
                                      "owner_id": invitation["owner_id"],
                                      "created_at": db.execute("SELECT created_at FROM family_groups WHERE id=?",
                                                               (invitation["family_id"],)).fetchone()[0]}, account_id)
            result["already_member"] = False
            return result

    def revoke_invite(self, owner_id: str, invite_id: str) -> dict:
        with self.database.transaction() as db:
            family = self._owned_family(db, owner_id)
            invitation = db.execute("SELECT status FROM family_invites WHERE id=? AND family_id=?",
                                    (invite_id, family["id"])).fetchone()
            if invitation is None:
                raise AccessError(404, "invite_not_found", "Приглашение не найдено.")
            if invitation["status"] == "accepted":
                raise AccessError(409, "invite_used", "Приглашение уже использовано; удалите участника семьи.")
            db.execute("UPDATE family_invites SET status='revoked' WHERE id=? AND family_id=?",
                       (invite_id, family["id"]))
            return {"ok": True}

    def remove_member(self, owner_id: str, member_id: str) -> dict:
        with self.database.transaction() as db:
            family = self._owned_family(db, owner_id)
            if member_id == owner_id:
                raise AccessError(400, "cannot_remove_owner", "Для выхода владельца нужно распустить семью.")
            cursor = db.execute("DELETE FROM family_members WHERE account_id=? AND family_id=?",
                                (member_id, family["id"]))
            if not cursor.rowcount:
                raise AccessError(404, "family_member_not_found", "Участник не найден в вашей семье.")
            return {"ok": True}

    def leave(self, account_id: str) -> dict:
        with self.database.transaction() as db:
            family = self._membership(db, account_id)
            if family is None:
                raise AccessError(404, "family_not_found", "Семья не найдена.")
            if family["owner_id"] == account_id:
                raise AccessError(409, "owner_must_dissolve", "Владелец должен распустить семью перед выходом.")
            db.execute("DELETE FROM family_members WHERE account_id=? AND family_id=?",
                       (account_id, family["id"]))
            return {"ok": True}

    def dissolve(self, owner_id: str) -> dict:
        with self.database.transaction() as db:
            family = self._owned_family(db, owner_id)
            # Explicit order also works with a host connection that has no FK pragma.
            db.execute("DELETE FROM family_invites WHERE family_id=?", (family["id"],))
            db.execute("DELETE FROM family_members WHERE family_id=?", (family["id"],))
            db.execute("DELETE FROM family_groups WHERE id=? AND owner_id=?", (family["id"], owner_id))
            return {"ok": True}
