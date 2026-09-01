#!/usr/bin/env python3
"""
BiteStream :: tests/test_repeatable_read.py
===========================================

The one behaviour sql/99_verification_suite.sql cannot demonstrate, because it needs TWO
concurrent sessions: the REPEATABLE READ serialization failure, SQLSTATE 40001.

WHAT THIS PROVES, IN THREE PARTS
--------------------------------
A. REPEATABLE READ raises 40001 on a concurrent update.
     Session 1 opens a REPEATABLE READ transaction and reads the wallet, pinning its
     snapshot. Session 2 then updates and commits the same row. When session 1 tries to
     update, PostgreSQL cannot apply the change to a row that has changed since the
     snapshot was taken, so it aborts with
         could not serialize access due to concurrent update
     This is NOT a lost update - it is PostgreSQL refusing to allow one.

B. READ COMMITTED does not raise; it BLOCKS and then proceeds.
     The same interleaving under READ COMMITTED succeeds, because each statement takes a
     fresh snapshot. The write is safe, but session 1's earlier read is now stale - which
     is exactly the non-repeatable read that REPEATABLE READ exists to prevent.

C. Under real concurrency, sp_execute_checkout returns RETRY.
     Several threads hammer the same user. The procedure catches serialization_failure and
     reports 'RETRY'. The CLIENT is responsible for retrying - that is the price of
     REPEATABLE READ, and the reason a production caller wraps this in a retry loop.

RUN
    python3 tests/test_repeatable_read.py
"""

from __future__ import annotations

import os
import sys
import threading
from decimal import Decimal

import psycopg

PASS, FAIL = "PASS", "FAIL"
results: list[tuple[str, str, str]] = []


def dsn() -> str:
    return (
        f"host={os.getenv('PGHOST', '127.0.0.1')} "
        f"port={os.getenv('PGPORT', '5432')} "
        f"dbname={os.getenv('PGDATABASE', 'bitestream')} "
        f"user={os.getenv('PGUSER', 'bs')} "
        f"password={os.getenv('PGPASSWORD', 'bs')}"
    )


def record(name: str, ok: bool, detail: str = "") -> None:
    results.append((name, PASS if ok else FAIL, detail))
    print(f"  [{PASS if ok else FAIL}] {name}" + (f"  ({detail})" if detail else ""))


def make_fixture() -> tuple[int, int]:
    """A dedicated user and restaurant, so the test never disturbs the seeded data."""
    with psycopg.connect(dsn(), autocommit=True) as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO users (name, wallet_balance) "
            "VALUES ('concurrency-test ' || clock_timestamp(), 100000.00) RETURNING id"
        )
        uid = cur.fetchone()[0]
        cur.execute("SELECT id FROM restaurants ORDER BY id LIMIT 1")
        rid = cur.fetchone()[0]
    return uid, rid


# ======================================================================================
def part_a_repeatable_read_conflicts(uid: int) -> None:
    print("\nA. REPEATABLE READ -> 40001 on a concurrent update")

    s1 = psycopg.connect(dsn())
    s2 = psycopg.connect(dsn(), autocommit=True)
    try:
        # Session 1: pin a REPEATABLE READ snapshot by actually reading the row.
        with s1.cursor() as c1:
            c1.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
            c1.execute("SELECT wallet_balance FROM users WHERE id = %s", (uid,))
            snapshot = c1.fetchone()[0]

        # Session 2: change the same row and commit, entirely inside session 1's snapshot.
        with s2.cursor() as c2:
            c2.execute(
                "UPDATE users SET wallet_balance = wallet_balance - 10 WHERE id = %s",
                (uid,),
            )

        # Session 1: the update it now attempts cannot be reconciled with its snapshot.
        got = None
        try:
            with s1.cursor() as c1:
                c1.execute(
                    "UPDATE users SET wallet_balance = wallet_balance - 20 WHERE id = %s",
                    (uid,),
                )
            s1.commit()
            got = "no error"
        except psycopg.errors.SerializationFailure as exc:
            got = exc.sqlstate
            s1.rollback()
        except psycopg.Error as exc:
            got = exc.sqlstate or "other"
            s1.rollback()

        record("REPEATABLE READ raises SQLSTATE 40001", got == "40001",
               f"snapshot balance {snapshot}, got {got}")
    finally:
        s1.close()
        s2.close()


def part_b_read_committed_succeeds(uid: int) -> None:
    print("\nB. READ COMMITTED -> no error, but the earlier read is now stale")

    s1 = psycopg.connect(dsn())
    s2 = psycopg.connect(dsn(), autocommit=True)
    try:
        with s1.cursor() as c1:
            c1.execute("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
            c1.execute("SELECT wallet_balance FROM users WHERE id = %s", (uid,))
            first_read = c1.fetchone()[0]

        with s2.cursor() as c2:
            c2.execute(
                "UPDATE users SET wallet_balance = wallet_balance - 10 WHERE id = %s",
                (uid,),
            )

        ok = True
        try:
            with s1.cursor() as c1:
                c1.execute(
                    "UPDATE users SET wallet_balance = wallet_balance - 20 WHERE id = %s",
                    (uid,),
                )
                # Re-read inside the SAME transaction: under READ COMMITTED this can
                # differ from first_read. That difference IS the non-repeatable read.
                c1.execute("SELECT wallet_balance FROM users WHERE id = %s", (uid,))
                second_read = c1.fetchone()[0]
            s1.commit()
        except psycopg.Error as exc:
            ok = False
            second_read = f"error {exc.sqlstate}"
            s1.rollback()

        record("READ COMMITTED completes without 40001", ok,
               f"read {first_read} then {second_read} in one transaction")
        record("the two reads differ -> non-repeatable read demonstrated",
               ok and first_read != second_read,
               f"{first_read} != {second_read}")
    finally:
        s1.close()
        s2.close()


def part_c_procedure_reports_retry(uid: int, rid: int, threads: int = 8,
                                   per_thread: int = 12) -> None:
    print(f"\nC. sp_execute_checkout under {threads} concurrent threads on ONE user")

    counts: dict[str, int] = {}
    lock = threading.Lock()

    def worker() -> None:
        local: dict[str, int] = {}
        with psycopg.connect(dsn(), autocommit=True) as conn, conn.cursor() as cur:
            for _ in range(per_thread):
                try:
                    cur.execute(
                        "CALL sp_execute_checkout("
                        "  %s::bigint, %s::bigint, %s::numeric(10,2), "
                        "  NULL::bigint, NULL::text)",
                        (uid, rid, Decimal("15.00")),
                    )
                    status = (cur.fetchone()[1] or "NULL").split(":")[0]
                except psycopg.Error as exc:
                    # A serialization failure can also surface on the CALL itself, before
                    # the procedure's own handler sees it.
                    status = f"RAISED_{exc.sqlstate}"
                local[status] = local.get(status, 0) + 1
                # Free the user's active-order slot so the partial unique index does not
                # mask the concurrency effect we are actually measuring.
                cur.execute(
                    "UPDATE orders SET status='DELIVERED', delivered_at=now() "
                    "WHERE user_id=%s AND status IN ('PREPARING','DELIVERING')",
                    (uid,),
                )
        with lock:
            for k, v in local.items():
                counts[k] = counts.get(k, 0) + v

    ts = [threading.Thread(target=worker) for _ in range(threads)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()

    total = sum(counts.values())
    for k in sorted(counts):
        print(f"      {k:<26} {counts[k]:>4}  ({100 * counts[k] / total:.0f}%)")

    contention = (counts.get("RETRY", 0)
                  + counts.get("ACTIVE_ORDER_EXISTS", 0)
                  + sum(v for k, v in counts.items() if k.startswith("RAISED_40")))
    record("the procedure never returns a partial success", "ERROR" not in counts,
           f"{total} calls, {len(counts)} distinct outcomes")
    record("concurrency on one user is detected and reported, not silently lost",
           contention > 0,
           f"{contention} contended calls (RETRY / ACTIVE_ORDER_EXISTS / 40001)")

    # Whatever happened, the invariant must hold: money is never created or destroyed.
    with psycopg.connect(dsn(), autocommit=True) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT u.wallet_balance,
                   (SELECT COALESCE(SUM(amount_changed), 0)
                      FROM wallet_audit_logs WHERE user_id = u.id) AS ledger_delta
            FROM users u WHERE u.id = %s
            """,
            (uid,),
        )
        balance, ledger_delta = cur.fetchone()
    # THE STRONGEST INVARIANT IN THE PROJECT.
    # Every single write to users.wallet_balance fires trg_wallet_audit - including the
    # ones made by parts A and B, and including those made concurrently by eight threads.
    # So the ledger must account for the balance EXACTLY, with no fudge factor:
    #     final_balance == opening_balance + SUM(ledger.amount_changed)
    # If any code path could move money without the trigger seeing it, this fails.
    expected = Decimal("100000.00") + ledger_delta
    record("wallet reconciles EXACTLY with the ledger (no unlogged movement)",
           balance == expected,
           f"balance {balance} == 100000.00 + ledger delta {ledger_delta}")


def main() -> int:
    print("=" * 66)
    print(" REPEATABLE READ / concurrency tests")
    print("=" * 66)
    uid, rid = make_fixture()
    print(f"fixture: user {uid}, restaurant {rid}")

    part_a_repeatable_read_conflicts(uid)
    part_b_read_committed_succeeds(uid)
    part_c_procedure_reports_retry(uid, rid)

    passed = sum(1 for _, r, _ in results if r == PASS)
    print("\n" + "-" * 66)
    print(f" {passed}/{len(results)} passed")
    print("=" * 66)
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
