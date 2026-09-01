# `sql/99_verification_suite.sql`

## Objective

A single runnable proof that every rubric item works. Prints one `PASS`/`FAIL` line per
behaviour. **This is the script to run in front of the examiner** during the live
demonstration — 20 of the 35 viva points are for exactly that.

Current result: **22 / 22 PASS**.

## How to run

```bash
psql "$PGURL" -f sql/99_verification_suite.sql
```

**Must run in autocommit** (no explicit `BEGIN`): `sp_execute_checkout` controls its own
transaction, and a `CALL` nested inside a client transaction raises `2D000`.

---

## Coverage

| Tests | Behaviour | Source under test |
|---|---|---|
| T01–T06 | all six `sp_execute_checkout` outcomes | `sql/04` |
| T07–T09 | trigger: CREDIT, DEBIT, and no-op suppression | `sql/03` |
| T10–T11 | ledger immutability: `UPDATE` and `DELETE` rejected | `sql/03` |
| T12, T12b | partial unique index blocks a 2nd active order, permits 500 `DELIVERED` | `sql/02` |
| T13–T15 | `CHECK` constraints on wallet, amount, status | `sql/01` |
| T16 | atomicity: a failed debit changes neither balance nor ledger | `sql/01` + `sql/04` |
| T17 | `REFRESH MATERIALIZED VIEW CONCURRENTLY` succeeds | `sql/05` |
| T18 | `LEFT JOIN` keeps zero-order restaurants | `sql/05` |
| T19, T19b | `ROWS` spans 10 calendar days where `RANGE` spans 7; gap fill fixes the denominator | `sql/06` |
| T20 | `DENSE_RANK` does not skip after a tie; `RANK` does | `sql/06` |

The one thing it **cannot** cover is the REPEATABLE READ serialization failure, because that
needs two concurrent sessions. See [tests_test_repeatable_read.md](tests_test_repeatable_read.md).

---

## Structure

### `verification_results`

A real table (not temp) holding `test_id, what, expected, actual`. The final `SELECT`
computes `PASS`/`FAIL` by comparing the last two columns, then prints a pass/fail/total
summary. Recording expected-vs-actual rather than a bare boolean means a failure tells you
*what* went wrong, not just *that* it did.

### Fixtures — and why they are named uniquely per run

```sql
INSERT INTO users (name, wallet_balance)
VALUES ('verification-user ' || to_char(now(), 'YYYYMMDD-HH24MISS-US'), 1000.00)
RETURNING id AS v_uid \gset
```

These users **can never be deleted afterwards**: `fk_audit_user` is `ON DELETE RESTRICT`,
and `trg_audit_block_row_change` blocks the ledger `DELETE` that would be needed first.

That is the immutability guarantee working as designed — so the suite names each run's
fixtures uniquely rather than trying to clean them up. Before this fix, a second run found
two rows named `verification-user` and the `DO` block's scalar subquery aborted with
*"more than one row returned by a subquery"*, silently skipping T07–T16.

### The `verification_fixture` handover table

```sql
CREATE TEMP TABLE verification_fixture AS
SELECT :v_uid::bigint AS uid, :v_uid2::bigint AS uid2, :v_rid::bigint AS rid;
```

**psql does not interpolate `:variables` inside a dollar-quoted string.** So the `DO` block
cannot read `:v_uid` directly — `DECLARE v_uid BIGINT := :v_uid;` fails with
`syntax error at or near ":"`. A one-row temp table is the simplest handover.

(The alternatives are `set_config()` + `current_setting()`, or building the `DO` body as a
concatenated string literal. The temp table is the most readable.)

### Three execution styles, and why each is used

| Style | Used for | Why |
|---|---|---|
| top-level `CALL … \gset` | T01–T06, T17 | `sp_execute_checkout` and the MV refresh need real transaction control, impossible inside a `DO` block |
| one `DO $verify$` block | T07–T16 | plain DML with `EXCEPTION` handlers to catch expected errors; no transaction control involved |
| plain `INSERT … SELECT` | T18–T20 | pure queries over fixtures |

---

## Notable individual tests

### T09 — the no-op suppression

```sql
UPDATE users SET wallet_balance = wallet_balance WHERE id = v_uid2;
```

The column is **mentioned**, so `AFTER UPDATE OF wallet_balance` fires — but the `WHEN`
clause suppresses the function, so no ledger row appears. This is the test that justifies
the `WHEN` clause existing at all.

### T12b — the *negative* space of the partial index

Inserts 500 `DELIVERED` orders for the same user and asserts they all succeed. T12 proves
the index **blocks**; T12b proves it does not **over**-block. A constraint that rejected
everything would pass T12 and be useless.

### T16 — atomicity, asserted rather than assumed

Snapshots balance, order count and ledger count; runs a debit that violates the `CHECK`;
asserts all three are unchanged. This is the "money shot" of the live demo.

### T18 — needs a fixture that would not otherwise exist

With 300k orders spread over 1,000 restaurants, **every** restaurant has orders, so the test
could not distinguish a correct `LEFT JOIN` from an incorrect `INNER JOIN`. The suite
therefore inserts `Ghost Kitchen (no orders)` first:

```sql
INSERT INTO restaurants (name, city, latitude, longitude)
SELECT 'Ghost Kitchen (no orders)', 'Pune', 18.5204, 73.8567
WHERE NOT EXISTS (SELECT 1 FROM restaurants WHERE name = 'Ghost Kitchen (no orders)');
```

(`ON CONFLICT DO NOTHING` would not work — there is no unique constraint on
`restaurants.name` for it to conflict on.)

### T19 / T19b — the pair that corrected our own documentation

Our first version asserted that `RANGE` would produce a 7-day average of 57.14 across a gap.
It returned 100.00. The reason: `RANGE` restricts the **boundary** but does not invent rows
for the missing days, so it averaged the 4 rows that existed. Split into two tests:

- **T19** measures the calendar span of each frame: `ROWS` = 10 days, `RANGE` = 7 days.
- **T19b** shows the gap fill is what changes the denominator: 275.00 → 157.14.

Worth mentioning in the viva unprompted — it is a genuinely subtle distinction and most
write-ups get it slightly wrong.

---

## Ordering constraint worth knowing

T02 deliberately creates an active order to prove `ACTIVE_ORDER_EXISTS`. The suite then
clears it before T03–T06:

```sql
UPDATE orders SET status = 'DELIVERED', delivered_at = now()
 WHERE user_id = :v_uid AND status IN ('PREPARING','DELIVERING');
```

Without that, T05 (`BAD_REFERENCE`) would hit the partial unique index **first** and report
`ACTIVE_ORDER_EXISTS` instead. That is not a bug — both constraints are genuinely violated —
but the test would no longer be testing what its name claims.

## Viva questions

1. Why can't this suite test the REPEATABLE READ failure?
2. Why are the fixture users named uniquely per run?
3. Why does T12b exist when T12 already passes?
4. Why does T18 need to create a restaurant first?
5. What does T09 prove about the `WHEN` clause?
6. Why do some tests use `CALL` at top level and others a `DO` block?
