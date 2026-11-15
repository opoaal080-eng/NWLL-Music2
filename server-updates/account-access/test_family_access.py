"""Family limits, token lifecycle, owner isolation, and concurrent mutations."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest

from access_database import AccessDatabase, AccessError
from family_access import FamilyService, INVITE_TTL_SECONDS


class FamilyServiceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "access.sqlite3"
        self.database = AccessDatabase(self.path)
        self.now = 1_800_000_000.0
        self.service = FamilyService(self.database, clock=lambda: self.now)
        self.active = {"owner", "other-owner", "third-owner"}

    def owner_check(self, owner_id):
        return owner_id in self.active

    def invite(self, owner="owner"):
        return self.service.create_invite(owner, allow_owner=self.owner_check)

    def join(self, account, invitation):
        return self.service.accept(account, invitation["token"], allow_owner=self.owner_check)

    def assert_code(self, code, call, status=None):
        with self.assertRaises(AccessError) as caught:
            call()
        self.assertEqual(caught.exception.code, code)
        if status is not None:
            self.assertEqual(caught.exception.status_code, status)

    def test_owner_and_two_members_have_separate_memberships(self):
        first = self.invite()
        second = self.invite()
        alice = self.join("alice", first)
        bob = self.join("bob", second)
        state = self.service.family_for("owner")
        self.assertEqual(state["member_count"], 3)
        self.assertEqual(state["capacity"], 3)
        self.assertEqual([x["account_id"] for x in state["members"]], ["owner", "alice", "bob"])
        self.assertEqual(alice["role"], "member")
        self.assertEqual(bob["owner_id"], "owner")
        self.assertEqual(self.service.owner_for("alice"), "owner")
        self.assertEqual(self.service.owner_for("owner"), "owner")
        self.assertIsNone(self.service.owner_for("stranger"))
        self.assertIsNone(self.service.family_for("stranger"))
        self.assert_code("family_full", self.invite, 409)

    def test_pending_invites_reserve_slots(self):
        first = self.invite()
        second = self.invite()
        self.assert_code("family_full", self.invite, 409)
        state = self.service.family_for("owner")
        self.assertEqual(len(state["pending_invites"]), 2)
        self.assertEqual(state["available_invites"], 0)
        self.join("alice", first)
        self.assertEqual(self.service.family_for("owner")["available_invites"], 0)
        self.service.revoke_invite("owner", second["invite_id"])
        replacement = self.invite()
        self.join("bob", replacement)
        self.assertEqual(self.service.family_for("owner")["member_count"], 3)

    def test_only_hash_is_stored_and_token_is_single_use(self):
        invitation = self.invite()
        token = invitation["token"]
        self.assertEqual(len(token), 43)
        self.assertEqual(invitation["expires_at"], self.now + INVITE_TTL_SECONDS)
        with self.database.read() as db:
            row = dict(db.execute("SELECT * FROM family_invites").fetchone())
        self.assertEqual(row["token_hash"], hashlib.sha256(token.encode("ascii")).hexdigest())
        self.assertNotIn(token, repr(row))
        self.join("alice", invitation)
        retry = self.join("alice", invitation)
        self.assertTrue(retry["already_member"])
        self.assert_code("invite_used", lambda: self.join("bob", invitation), 409)
        self.assertEqual(self.service.family_for("owner")["member_count"], 2)

    def test_pending_metadata_is_visible_only_to_owner(self):
        first = self.invite()
        second = self.invite()
        self.join("alice", first)
        state = self.service.family_for("alice")
        self.assertNotIn("pending_invites", state)
        self.assertNotIn("available_invites", state)
        self.assertNotIn(second["token"], repr(self.service.family_for("owner")))
        self.assertNotIn("token_hash", repr(self.service.family_for("owner")))

    def test_expiry_frees_slots_without_removing_family(self):
        first = self.invite()
        self.invite()
        self.now += INVITE_TTL_SECONDS
        preview = self.service.preview(first["token"])
        self.assertFalse(preview["available"])
        self.assertEqual(preview["reason"], "invite_expired")
        self.assert_code("invite_expired", lambda: self.join("alice", first), 410)
        self.assertEqual(self.service.family_for("owner")["available_invites"], 2)
        self.invite()
        self.invite()
        self.assertEqual(self.service.family_for("owner")["member_count"], 1)

    def test_revocation_and_retry(self):
        invitation = self.invite()
        self.service.revoke_invite("owner", invitation["invite_id"])
        self.service.revoke_invite("owner", invitation["invite_id"])
        self.assertFalse(self.service.preview(invitation["token"])["available"])
        self.assert_code("invite_revoked", lambda: self.join("alice", invitation), 410)
        self.assertEqual(self.service.family_for("owner")["available_invites"], 2)

    def test_invite_rate_limit_counts_revoked_and_accepted_invites(self):
        first = self.invite()
        self.join("alice", first)
        for _ in range(29):
            invitation = self.invite()
            self.service.revoke_invite("owner", invitation["invite_id"])
        self.assert_code("invite_rate_limit", self.invite, 429)
        with self.database.read() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM family_invites").fetchone()[0], 30)
        self.now += 24 * 60 * 60
        invitation = self.invite()
        self.assertTrue(self.service.preview(invitation["token"])["available"])

    def test_used_invite_cannot_be_revoked_instead_of_removing_member(self):
        invitation = self.invite()
        self.join("alice", invitation)
        self.assert_code("invite_used", lambda: self.service.revoke_invite("owner", invitation["invite_id"]), 409)
        self.assertEqual(self.service.owner_for("alice"), "owner")

    def test_expired_owner_cannot_issue_or_accept_invites(self):
        invitation = self.invite()
        self.active.remove("owner")
        self.assert_code("family_owner_premium_required", self.invite, 403)
        self.assert_code("family_owner_premium_required", lambda: self.join("alice", invitation), 403)
        self.assertTrue(self.service.preview(invitation["token"])["available"])
        self.assertEqual(self.service.family_for("owner")["member_count"], 1)
        self.active.add("owner")
        self.join("alice", invitation)
        self.active.remove("owner")
        self.assertEqual(self.service.owner_for("alice"), "owner")
        self.assertEqual(self.service.family_for("alice")["member_count"], 2)

    def test_check_failure_rolls_back_mutation(self):
        def unavailable(_owner):
            raise AccessError(503, "premium_check_unavailable", "test")
        self.assert_code("premium_check_unavailable",
                         lambda: self.service.create_invite("owner", allow_owner=unavailable), 503)
        self.assertIsNone(self.service.family_for("owner"))
        invitation = self.invite()
        self.assert_code("premium_check_unavailable",
                         lambda: self.service.accept("alice", invitation["token"], allow_owner=unavailable), 503)
        self.assertIsNone(self.service.family_for("alice"))

    def test_falsey_or_awaitable_callbacks_do_not_grant_access(self):
        self.assert_code("premium_check_unavailable",
                         lambda: self.service.create_invite("owner"), 503)
        self.assert_code("premium_check_unavailable",
                         lambda: self.service.create_invite("owner", allow_owner=lambda _: None), 503)
        async def asynchronous(_owner):
            return True
        self.assert_code("premium_check_unavailable",
                         lambda: self.service.create_invite("owner", allow_owner=asynchronous), 503)
        self.assertIsNone(self.service.family_for("owner"))

    def test_premium_check_runs_under_write_lock(self):
        def checked(owner):
            self.assertEqual(owner, "owner")
            with sqlite3.connect(self.path, timeout=0) as outsider:
                with self.assertRaises(sqlite3.OperationalError):
                    outsider.execute("BEGIN IMMEDIATE")
            return True
        invitation = self.service.create_invite("owner", allow_owner=checked)
        self.service.accept("alice", invitation["token"], allow_owner=checked)

    def test_member_cannot_create_nested_family_even_with_personal_premium(self):
        invitation = self.invite()
        self.join("alice", invitation)
        self.active.add("alice")
        self.assert_code("account_in_family", lambda: self.invite("alice"), 409)
        self.assertEqual(self.service.owner_for("alice"), "owner")

    def test_self_invite_and_accounts_already_in_families(self):
        invitation = self.invite()
        self.assert_code("cannot_join_own_family", lambda: self.join("owner", invitation), 400)
        other = self.invite("other-owner")
        self.assert_code("account_in_family", lambda: self.join("other-owner", invitation), 409)
        self.join("alice", invitation)
        self.assert_code("account_in_family", lambda: self.join("alice", other), 409)

    def test_owner_operations_are_scoped_to_own_family(self):
        first = self.invite()
        self.join("alice", first)
        foreign = self.invite("other-owner")
        self.join("bob", foreign)
        pending = self.invite("other-owner")
        self.assert_code("invite_not_found", lambda: self.service.revoke_invite("owner", pending["invite_id"]), 404)
        self.assert_code("family_member_not_found", lambda: self.service.remove_member("owner", "bob"), 404)
        self.assert_code("family_owner_required", lambda: self.service.remove_member("alice", "owner"), 403)
        self.assert_code("family_owner_required", lambda: self.service.revoke_invite("alice", pending["invite_id"]), 403)
        self.assert_code("family_owner_required", lambda: self.service.dissolve("alice"), 403)
        self.assertEqual(self.service.owner_for("bob"), "other-owner")

    def test_removal_frees_slot_and_old_link_cannot_rejoin(self):
        invitation = self.invite()
        self.join("alice", invitation)
        self.service.remove_member("owner", "alice")
        self.assertIsNone(self.service.owner_for("alice"))
        self.assert_code("invite_used", lambda: self.join("alice", invitation), 409)
        fresh = self.invite()
        self.join("alice", fresh)
        self.assertEqual(self.service.owner_for("alice"), "owner")
        self.assert_code("cannot_remove_owner", lambda: self.service.remove_member("owner", "owner"), 400)

    def test_leave_and_dissolve(self):
        invitation = self.invite()
        self.join("alice", invitation)
        self.service.leave("alice")
        self.assertIsNone(self.service.owner_for("alice"))
        self.assert_code("invite_used", lambda: self.join("alice", invitation), 409)
        self.assert_code("owner_must_dissolve", lambda: self.service.leave("owner"), 409)
        next_invitation = self.invite()
        self.join("bob", next_invitation)
        self.service.dissolve("owner")
        self.assertIsNone(self.service.owner_for("owner"))
        self.assertIsNone(self.service.owner_for("bob"))
        self.assert_code("invite_not_found", lambda: self.service.preview(next_invitation["token"]), 404)
        with self.database.read() as db:
            for table in ["family_groups", "family_members", "family_invites"]:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM " + table).fetchone()[0], 0)

    def test_invalid_tokens_are_uniform_not_found(self):
        for token in ["", "short", "!" * 43, "a" * 43, None, 123]:
            with self.subTest(token=token):
                self.assert_code("invite_not_found", lambda: self.service.preview(token), 404)
                self.assert_code("invite_not_found", lambda: self.service.accept("alice", token), 404)

    def _parallel(self, items, function):
        barrier = threading.Barrier(len(items))
        def work(item):
            barrier.wait(timeout=10)
            try:
                return ("ok", function(item))
            except AccessError as error:
                return ("error", error.code)
        with ThreadPoolExecutor(max_workers=len(items)) as executor:
            return list(executor.map(work, items))

    def test_concurrent_invite_creation_never_reserves_more_than_two_slots(self):
        results = self._parallel(range(8), lambda _: self.invite())
        self.assertEqual(sum(kind == "ok" for kind, _ in results), 2)
        self.assertEqual([value for kind, value in results if kind == "error"], ["family_full"] * 6)
        state = self.service.family_for("owner")
        self.assertEqual(state["member_count"] + len(state["pending_invites"]), 3)

    def test_concurrent_claims_of_one_invite_have_one_winner(self):
        invitation = self.invite()
        results = self._parallel(["user-" + str(i) for i in range(8)], lambda account: self.join(account, invitation))
        self.assertEqual(sum(kind == "ok" for kind, _ in results), 1)
        self.assertEqual(self.service.family_for("owner")["member_count"], 2)
        self.assertTrue(all(value == "invite_used" for kind, value in results if kind == "error"))

    def test_concurrent_claims_of_two_invites_fit_exactly_two_members(self):
        invitations = [self.invite(), self.invite()]
        results = self._parallel(list(enumerate(invitations)), lambda pair: self.join("user-" + str(pair[0]), pair[1]))
        self.assertTrue(all(kind == "ok" for kind, _ in results))
        self.assertEqual(self.service.family_for("owner")["member_count"], 3)

    def test_concurrent_same_account_cannot_join_two_families(self):
        invitations = [self.invite(), self.invite("other-owner")]
        results = self._parallel(invitations, lambda invitation: self.join("alice", invitation))
        self.assertEqual(sum(kind == "ok" for kind, _ in results), 1)
        self.assertEqual([value for kind, value in results if kind == "error"], ["account_in_family"])
        with self.database.read() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM family_members WHERE account_id='alice'").fetchone()[0], 1)

    def test_separate_service_instances_enforce_the_same_limits(self):
        second = FamilyService(AccessDatabase(self.path), clock=lambda: self.now)
        invitations = [self.invite(), second.create_invite("owner", allow_owner=self.owner_check)]
        self.assert_code("family_full", lambda: second.create_invite("owner", allow_owner=self.owner_check), 409)
        second.accept("alice", invitations[0]["token"], allow_owner=self.owner_check)
        self.join("bob", invitations[1])
        self.assertEqual(second.family_for("owner")["member_count"], 3)


if __name__ == "__main__":
    unittest.main()
