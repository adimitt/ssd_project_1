# `tests/test_repeatable_read.py`

## Objective

The one behaviour `sql/99_verification_suite.sql` **cannot** demonstrate, because it needs
two concurrent sessions: the **REPEATABLE READ serialization failure, SQLSTATE 40001**.

Current result: **6 / 6 PASS**.

## How to run

```bash
python3 tests/test_repeatable_read.py
```

Creates its own fixture user (named with `clock_timestamp()` so runs never collide) and the
first restaurant, so it never disturbs seeded data.

---

## Part A — REPEATABLE READ raises 40001

```
Session 1: SET TRANSACTION ISOLATION LEVEL REPEATABLE READ
Session 1: SELECT wallet_balance          <- pins the snapshot
Session 2: UPDATE … wallet_balance - 10 ; COMMIT
Session 1: UPDATE … wallet_balance - 20   <- 40001
```

Session 1 reads the row first, which is what actually **pins the snapshot** — in PostgreSQL
a REPEATABLE READ snapshot is taken at the first statement that reads data, not at `BEGIN`.
When session 1 then tries to update a row that has changed since that snapshot, PostgreSQL
cannot reconcile the two and aborts with:

```
could not serialize access due to concurrent update
```

**This is not a lost update — it is PostgreSQL refusing to allow one.** That distinction is
the point of the test.

Result: `[PASS] REPEATABLE READ raises SQLSTATE 40001 (snapshot balance 100000.00, got 40001)`

## Part B — READ COMMITTED does not raise; it blocks, then proceeds

The identical interleaving under `READ COMMITTED` succeeds, because each statement takes a
**fresh** snapshot. The write is safe — but the earlier read is now stale:

```
[PASS] READ COMMITTED completes without 40001  (read 99990.00 then 99960.00 in one transaction)
[PASS] the two reads differ -> non-repeatable read demonstrated  (99990.00 != 99960.00)
```

**Two reads of the same row, inside one transaction, returning different values.** That is
literally the non-repeatable read that REPEATABLE READ exists to prevent, shown rather than
described.

Together, A and B are the complete answer to *"what does REPEATABLE READ prevent, and what
does it cost you?"*

## Part C — the procedure reports `RETRY` under real contention

Eight threads, twelve calls each, all hammering **one** user:

```
ACTIVE_ORDER_EXISTS      2  (2%)
OK                      16  (17%)
RETRY                   78  (81%)
```

`sp_execute_checkout` catches `serialization_failure` and reports `RETRY`. **The client is
responsible for retrying** — that is the price of REPEATABLE READ, and the reason a
production caller wraps this in a retry loop with backoff.

Each worker clears the user's active-order slot between iterations:

```python
cur.execute("UPDATE orders SET status='DELIVERED', delivered_at=now() "
            "WHERE user_id=%s AND status IN ('PREPARING','DELIVERING')", (uid,))
```

Without that, `idx_active_user_order` would reject nearly every call with
`ACTIVE_ORDER_EXISTS` and **mask** the concurrency effect being measured.

The worker also catches `psycopg.Error` around the `CALL` itself and records
`RAISED_<sqlstate>`, because a serialization failure can surface on the `CALL` before the
procedure's own handler sees it.

---

## The strongest assertion in the project

```python
expected = Decimal("100000.00") + ledger_delta
record("wallet reconciles EXACTLY with the ledger (no unlogged movement)",
       balance == expected, …)
```

**Every** write to `users.wallet_balance` fires `trg_wallet_audit` — including parts A and
B, and including eight threads racing each other. So:

```
final_balance == opening_balance + SUM(wallet_audit_logs.amount_changed)
```

must hold **exactly, with no fudge factor**. If any code path could move money without the
trigger seeing it, this fails.

Measured: `balance 99720.00 == 100000.00 + ledger delta -280.00`.

### This assertion was wrong in our first version

It originally subtracted a hardcoded `60.00` to account for the balance changes made by
parts A and B. That was a misunderstanding: those updates go through the trigger too, so the
ledger already accounts for them. Removing the fudge made the test both **correct and
strictly stronger** — it now asserts total coverage rather than approximate agreement.

Worth mentioning in the viva. "We tightened the invariant when we realised the correction
was unnecessary" is a good answer.

---

## Why this is a separate file

`sql/99_verification_suite.sql` runs in one psql session. Serialization failures require two
sessions whose transactions **overlap in time**, which SQL alone cannot orchestrate. Python
gives explicit control over connection lifetimes and threads.

## Connection details that matter

| Detail | Why |
|---|---|
| session 1 opens **without** autocommit | it needs a long-lived explicit transaction |
| session 2 opens **with** autocommit | its update must commit immediately, inside session 1's snapshot |
| part C workers use autocommit | `sp_execute_checkout` controls its own transaction; a `CALL` inside a client `BEGIN` raises `2D000` |
| `Decimal(str(amount))` + `::numeric(10,2)` | psycopg infers the narrowest type; without casts no procedure signature matches |

## Viva questions

1. What is SQLSTATE 40001, and whose job is it to handle it?
2. When exactly is a REPEATABLE READ snapshot taken? *(At the first data-reading statement, not at `BEGIN`.)*
3. Show me a non-repeatable read. *(Part B.)*
4. `SELECT … FOR UPDATE` vs a serialization failure — when would you choose each?
5. Why does part C clear the active order between iterations?
6. Why can't the SQL suite test this?
7. What does the reconciliation assertion prove that the other tests do not?
