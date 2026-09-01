# `sql/04_stored_procedures.sql` — Workflow 1

## Objective

`sp_execute_checkout()` — a self-contained, transaction-controlling procedure that debits a
wallet and creates an order **atomically**, under **REPEATABLE READ**, and rolls back
cleanly on every failure mode.

This is the hardest file in the project and the most likely to be interrogated.

**Rubric:** Database Engine Logic (20 pts) — the stored-procedure portion.

## Position in the build order

Step 3. It must come after `sql/01` (CHECK constraints), `sql/02` (partial unique index) and
`sql/03` (the trigger), because **each of those is a failure mode this procedure is required
to catch**. It can be *created* earlier; it can only be *tested* once they all exist.

---

## Object 1 — `checkout_attempts`

An addition beyond the brief's four tables, and a deliberate one.

```sql
CREATE TABLE IF NOT EXISTS checkout_attempts (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT, restaurant_id BIGINT, amount NUMERIC(10,2),
    outcome VARCHAR(32) NOT NULL, sqlstate_code VARCHAR(5),
    order_id BIGINT, attempted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

It exists to demonstrate one transactional fact: **anything written inside a failed
transaction is destroyed by the `ROLLBACK`.** A failure log that must survive has to be
written *after* the rollback, in the next transaction. The procedure does exactly that, and
this is where it lands.

Note it carries **no foreign keys** — by design. A failure log referencing a user that the
failure prevented from existing would be self-defeating.

If asked "why is there a fifth table?", that paragraph is the answer.

---

## Object 2 — `sp_execute_checkout`

### Signature

| Parameter | Mode | Meaning |
|---|---|---|
| `p_user_id` | `IN BIGINT` | the paying customer |
| `p_restaurant_id` | `IN BIGINT` | the vendor |
| `p_amount` | `IN NUMERIC(10,2)` | order total, debited from the wallet |
| `p_order_id` | `INOUT BIGINT` | the new `orders.id` on success, `NULL` on failure |
| `p_status` | `INOUT TEXT` | machine-readable outcome |

### Outcomes

| `p_status` | Cause | SQLSTATE caught |
|---|---|---|
| `OK` | order created, wallet debited, ledger row written | — |
| `INSUFFICIENT_FUNDS` | `ck_users_wallet_non_negative` rejected the debit | 23514 |
| `ACTIVE_ORDER_EXISTS` | `idx_active_user_order` rejected a 2nd live order | 23505 |
| `BAD_REFERENCE` | `restaurant_id` does not exist | 23503 |
| `AMOUNT_INVALID` | amount is `NULL`, zero or negative | 22023 |
| `USER_NOT_FOUND` | no such user | P0002 |
| `RETRY` | concurrent update under REPEATABLE READ | 40001 |
| `ERROR:<msg>` | anything else | — |

---

## The three structural decisions

### 1. It must be a `PROCEDURE`, not a `FUNCTION`

A `FUNCTION` body executes **inside the caller's transaction** and cannot issue `COMMIT` or
`ROLLBACK`. Only a `PROCEDURE` (PostgreSQL 11+) invoked with `CALL` can control the
transaction — **and only when that `CALL` is not already nested inside a client-side
`BEGIN`.** The brief demands `COMMIT` and `ROLLBACK`, so `PROCEDURE` is forced.

```sql
-- correct: autocommit, no explicit BEGIN
CALL sp_execute_checkout(1, 1, 250.00, NULL, NULL);

-- wrong: raises 2D000 "invalid transaction termination"
BEGIN; CALL sp_execute_checkout(1, 1, 250.00, NULL, NULL); COMMIT;
```

`postgres_seeder.py` and `tests/test_repeatable_read.py` both open their connections with
`autocommit=True` for this reason.

### 2. You cannot `COMMIT` inside a block that has an `EXCEPTION` handler

**This is the single most important detail in the project.**

PL/pgSQL implements `BEGIN … EXCEPTION WHEN … END` as an internal **subtransaction**, and
transaction control is illegal while one is active. The obvious one-block implementation —
handlers and `COMMIT` in the same block — fails at *runtime* with:

```
ERROR: cannot commit while a subtransaction is active
```

So the work is split:

```
outer block   ->  owns COMMIT / ROLLBACK / SET TRANSACTION   (no handler in scope)
  inner block ->  owns the EXCEPTION handlers                (no transaction control)
outer block   ->  inner subtransaction has closed; txn control is legal again
```

Concretely:

```sql
BEGIN                                   -- outer
    COMMIT;
    SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

    BEGIN                               -- inner: subtransaction
        ... work ...
    EXCEPTION
        WHEN check_violation THEN v_failed := TRUE; ...
    END;                                -- subtransaction closes here

    IF v_failed THEN ROLLBACK; ELSE COMMIT; END IF;   -- legal again
END
```

### 3. Why the leading `COMMIT`

`SET TRANSACTION ISOLATION LEVEL` must be the **first statement of its transaction**, and
`CALL` has already opened one implicitly. The leading `COMMIT` closes that empty transaction
so the isolation level can be set on the fresh one PL/pgSQL immediately starts.

---

## The body, step by step

| Step | Statement | What can go wrong here |
|---|---|---|
| 1 | `COMMIT` | closes the implicit transaction |
| 2 | `SET TRANSACTION ISOLATION LEVEL REPEATABLE READ` | must be first in the transaction |
| 3 | `IF p_amount IS NULL OR p_amount <= 0 THEN RAISE 22023` | guards against a negative "checkout" that would *credit* the wallet |
| 4 | `UPDATE users SET wallet_balance = wallet_balance - p_amount` | `ck_users_wallet_non_negative` → 23514; concurrent update → 40001; **fires `trg_wallet_audit`** |
| 5 | `IF NOT FOUND THEN RAISE P0002` | no such user |
| 6 | `INSERT INTO orders … RETURNING id` | `idx_active_user_order` → 23505; `fk_orders_restaurant` → 23503 |
| 7 | `IF v_failed THEN ROLLBACK ELSE COMMIT` | |
| 8 | `INSERT INTO checkout_attempts …; COMMIT` | in the **new** transaction, so it survives |

### Why debit before insert

The `CHECK` rejects an unaffordable order **before any order row is created**: fail fast,
and it mirrors a real payment flow. The wallet `UPDATE` is also what fires
`trg_wallet_audit`, so the ledger row is part of the same atomic unit — and a rollback
discards the debit, the order and the ledger row together.

### Read-modify-write safety

The debit is a **single statement**:

```sql
UPDATE users SET wallet_balance = wallet_balance - p_amount WHERE id = p_user_id;
```

PostgreSQL takes a row lock and, under REPEATABLE READ, raises 40001 rather than losing an
update. **Never** `SELECT` the balance and write back a value computed in the application —
that is the textbook lost-update bug.

### Why REPEATABLE READ, and what it costs

`READ COMMITTED` takes a **new snapshot per statement**, so a value re-read inside the
transaction can change underneath it. `REPEATABLE READ` pins **one snapshot** for the whole
transaction.

The price: two concurrent checkouts against the same user make one fail with
`could not serialize access due to concurrent update` (**40001**) — the *caller* must retry.
`tests/test_repeatable_read.py` measures this: under 8 threads on one user, ~80 % of calls
return `RETRY`.

The alternative design is `READ COMMITTED` + `SELECT … FOR UPDATE`, which **blocks** instead
of erroring. Knowing both, and being able to say when you would choose each, is the strong
answer.

### The exception handler, and one subtlety

`check_violation` is caught and then **disambiguated by message**:

```sql
WHEN check_violation THEN
    p_status := CASE WHEN SQLERRM LIKE '%ck_users_wallet_non_negative%'
                     THEN 'INSUFFICIENT_FUNDS' ELSE 'CHECK_FAILED' END;
```

Several `CHECK` constraints sit on this code path (`ck_orders_amount_positive`,
`ck_orders_status`, …). Reporting them all as `INSUFFICIENT_FUNDS` would be wrong. Naming
the constraint in the message is the pragmatic way to tell them apart; a stricter design
would use `RAISE … USING CONSTRAINT` and read `GET STACKED DIAGNOSTICS`.

### Why the durable log is written after the rollback

When the inner handler catches, PostgreSQL has **already** undone the inner block's work
back to the savepoint. The outer `ROLLBACK` then ends the whole transaction. Anything
logged before that point would be rolled back along with the failure it was describing.
Writing it afterwards — in the transaction that `ROLLBACK` started — is the only way it
survives. `checkout_attempts` holds 402 rows after a full seed, including every failure.

---

## Object 3 — `sp_advance_order_status`

A small companion used by the seeder, the verification suite and the demo.
`PREPARING → DELIVERING → DELIVERED`, setting `delivered_at` on the final hop so
`ck_orders_delivered_has_timestamp` is satisfied. `DELIVERED` is terminal (no-op).

It takes `FOR UPDATE` on the row so two concurrent advances cannot both read `PREPARING`.

Moving an order out of the two active states is also what **frees the user's slot** in
`idx_active_user_order`.

---

## A real PostgreSQL restriction this file exposed

```sql
CALL sp_advance_order_status((SELECT id FROM orders LIMIT 1));
-- ERROR: cannot use subquery in CALL argument
```

`CALL` arguments cannot contain subqueries. Test harnesses must capture ids with `\gset`
(psql) or fetch them first (Python) and pass literals. This bit our first test run and is
worth knowing.

Related: psycopg infers the **narrowest** type that fits, so a small Python `int` arrives as
`smallint` and no procedure matches the signature. Hence the explicit casts:

```python
cur.execute("CALL sp_execute_checkout(%s::bigint, %s::bigint, %s::numeric(10,2), "
            "NULL::bigint, NULL::text)", (uid, rid, Decimal("15.00")))
```

---

## Test matrix (all verified, T01–T06 + the concurrency suite)

| Case | Expected | Proves |
|---|---|---|
| sufficient balance | `OK` | full path + trigger + order row |
| amount > balance | `INSUFFICIENT_FUNDS` | **balance, orders and ledger all unchanged** — atomicity |
| 2nd checkout while one is `PREPARING` | `ACTIVE_ORDER_EXISTS` | partial unique index (23505) |
| `p_amount = -50` | `AMOUNT_INVALID` | abuse guard |
| nonexistent `restaurant_id` | `BAD_REFERENCE` | FK enforcement (23503) |
| nonexistent `user_id` | `USER_NOT_FOUND` | P0002 |
| 8 threads, same user | mix of `OK` / `RETRY` | REPEATABLE READ semantics (40001) |

---

## Viva questions

1. Why must this be a `PROCEDURE` and not a `FUNCTION`?
2. Why can't you `COMMIT` inside a block with an `EXCEPTION` handler? What is the exact error?
3. Why the leading `COMMIT` before `SET TRANSACTION`?
4. What does REPEATABLE READ prevent that READ COMMITTED does not, and what does it cost?
5. What is SQLSTATE 40001, and **whose job** is it to handle it?
6. `SELECT … FOR UPDATE` versus raising a serialization failure — when would you choose each?
7. Walk through the insufficient-funds path. What is rolled back, in what order?
8. Why does `checkout_attempts` survive a rollback when the order does not?
9. Why debit before insert rather than the other way round?
10. How would you make this idempotent under client retries? *(A caller-supplied idempotency key with a unique index.)*
