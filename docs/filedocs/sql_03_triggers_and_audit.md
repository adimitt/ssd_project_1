# `sql/03_triggers_and_audit.sql`

## Objective

Two things:

1. **`fn_log_wallet_change()` + `trg_wallet_audit`** — automatic audit logging of every
   change to `users.wallet_balance`.
2. **`fn_block_audit_mutation()` + two guard triggers + `REVOKE`** — make
   `wallet_audit_logs` genuinely append-only, which is what the brief means by
   *"an immutable record"*.

**Rubric:** Database Engine Logic (20 pts) — the `TRIGGER` audit-logging portion.

## Position in the build order

Step 2 — immediately after the schema, **before any data is loaded**. That ordering is what
lets us claim that *every* audit row in the database was produced by the trigger rather
than inserted directly.

## Idempotency

`CREATE OR REPLACE FUNCTION` + `DROP TRIGGER IF EXISTS`. The file also ends with a
**self-test** that verifies its own behaviour and then rolls itself back.

---

## Part 1 — the audit trigger

### `fn_log_wallet_change()`

```sql
CREATE OR REPLACE FUNCTION fn_log_wallet_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $fn$
BEGIN
    INSERT INTO wallet_audit_logs (user_id, amount_changed, action_type, balance_after)
    VALUES (
        NEW.id,
        NEW.wallet_balance - OLD.wallet_balance,
        CASE WHEN NEW.wallet_balance > OLD.wallet_balance THEN 'CREDIT' ELSE 'DEBIT' END,
        NEW.wallet_balance
    );
    RETURN NULL;
END;
$fn$;
```

| Derived value | Expression | Why |
|---|---|---|
| `amount_changed` | `NEW − OLD` | signed: positive is a top-up, negative a spend |
| `action_type` | `CASE … CREDIT/DEBIT` | label follows the sign, so `ck_audit_sign_matches_action` holds **by construction** |
| `balance_after` | `NEW.wallet_balance` | the post-change balance, so the ledger is self-contained |

**`RETURN NULL`** is correct and idiomatic for an `AFTER` row trigger — the executor
discards the return value. In a `BEFORE` row trigger the identical statement would silently
**cancel the operation**, which is a classic source of "my update vanished" bugs.

**`SET search_path`** pins schema resolution so the function body cannot be redirected by a
caller-supplied `search_path`. Cheap hardening; standard practice for trigger bodies.

### `trg_wallet_audit`

```sql
CREATE TRIGGER trg_wallet_audit
    AFTER UPDATE OF wallet_balance ON users
    FOR EACH ROW
    WHEN (OLD.wallet_balance IS DISTINCT FROM NEW.wallet_balance)
    EXECUTE FUNCTION fn_log_wallet_change();
```

Every clause is deliberate, and every clause is a viva question.

#### `AFTER`, not `BEFORE`

The ledger must record changes that actually survived. A `BEFORE` trigger can be followed
by a `CHECK` violation (`ck_users_wallet_non_negative`) or by another `BEFORE` trigger
returning `NULL` — either of which would leave a log entry describing a change that never
happened.

#### `UPDATE OF wallet_balance`

Narrows the trigger to statements that **mention** that column in their `SET` list.
Critically, **"mentioned" is not "changed"**: `SET wallet_balance = wallet_balance` still
fires it.

#### `WHEN (OLD.wallet_balance IS DISTINCT FROM NEW.wallet_balance)` — mandatory

This is what converts "mentioned" into "changed". Without it, a no-op write produces a
ledger row with `amount_changed = 0`, which `ck_audit_amount_non_zero` would then reject —
turning a harmless no-op update into an error. Verified by **T09**.

Two secondary points:

- **`IS DISTINCT FROM`, not `<>`.** `NULL <> NULL` evaluates to `NULL` (falsy), so `<>`
  silently skips NULL-involving transitions. `wallet_balance` is `NOT NULL` so it cannot
  bite here — but it remains the correct habit, and saying so shows you know why.
- **`WHEN` beats an `IF` inside the function.** The executor evaluates `WHEN` *before* the
  function is called at all. Across the seeder's 150,000 trigger firings that matters.

#### `FOR EACH ROW`

Required: the function needs `OLD` and `NEW` per user. A statement-level trigger has
neither. **This is also the property the seeder exploits** — a row trigger fires once per
*affected row*, so one `UPDATE users SET wallet_balance = wallet_balance + 500` produces
50,000 audit rows in a single statement.

#### Firing surface — the two questions that catch people out

| Operation | Does `trg_wallet_audit` fire? |
|---|---|
| `UPDATE` touching `wallet_balance` | **yes** |
| `UPDATE` not touching `wallet_balance` | no (`UPDATE OF` filter) |
| `UPDATE` setting it to the same value | no (`WHEN` clause) |
| `COPY` into `users` | **no** — COPY fires row-level *INSERT* triggers; this is an UPDATE trigger |
| `TRUNCATE` | **no** — TRUNCATE fires only *statement*-level triggers |

The `COPY` row is the reason `postgres_seeder.py` cannot bulk-load the ledger.

#### Recursion

The function writes to a *different* table, so there is no loop. If it wrote back to
`users`, a `pg_trigger_depth()` guard would be required.

---

## Part 2 — immutability

Two independent layers, because **neither alone is sufficient**.

### Layer 1 — privileges

```sql
REVOKE UPDATE, DELETE, TRUNCATE ON wallet_audit_logs FROM PUBLIC;
```

Stops ordinary roles. **The table owner and any superuser bypass it entirely** — which is
precisely why layer 2 exists.

### Layer 2a — the row guard

```sql
CREATE TRIGGER trg_audit_block_row_change
    BEFORE UPDATE OR DELETE ON wallet_audit_logs
    FOR EACH ROW
    EXECUTE FUNCTION fn_block_audit_mutation();
```

`fn_block_audit_mutation()` raises with `ERRCODE = '42501'` (`insufficient_privilege`) and a
`HINT` pointing the caller at the correct remedy: post a **compensating** balance change and
let the trigger log it. This catches everyone who is not deliberately disabling the trigger,
**including the owner**. Verified by T10 and T11.

### Layer 2b — the `TRUNCATE` guard

```sql
CREATE TRIGGER trg_audit_block_truncate
    BEFORE TRUNCATE ON wallet_audit_logs
    FOR EACH STATEMENT
    EXECUTE FUNCTION fn_block_audit_mutation();
```

A separate trigger is required because **row-level triggers never see `TRUNCATE`**. Knowing
this unprompted is one of the strongest signals you can give in the viva.

### The consequence the seeder has to deal with

`postgres_seeder.py` must reset the database, and `TRUNCATE` is now blocked. It handles this
explicitly:

```python
cur.execute("ALTER TABLE wallet_audit_logs DISABLE TRIGGER USER")
cur.execute(f"TRUNCATE {targets} RESTART IDENTITY CASCADE")
cur.execute("ALTER TABLE wallet_audit_logs ENABLE TRIGGER USER")
```

That is not a workaround — it is the design working. Wiping the ledger requires table
ownership and a deliberate, visible, auditable act. It cannot happen by accident.

---

## Part 3 — the self-test

The file ends with a `DO` block that verifies four behaviours and then rolls everything
back by raising a sentinel exception it catches itself:

1. a `CREDIT` is logged with the correct sign and `balance_after`
2. a `DEBIT` is logged
3. a **no-op write produces no ledger row** (the `WHEN` clause)
4. `UPDATE` on the ledger is rejected (the row guard)

It prints `self-test passed: audit trigger, WHEN suppression and immutability all verified`
and leaves no trace. Full six-outcome coverage lives in `sql/99_verification_suite.sql`.

---

## Viva questions

1. Why `AFTER` rather than `BEFORE`? Give a concrete scenario where `BEFORE` logs a lie.
2. `UPDATE OF wallet_balance` fires even when the value does not change. Why, and how do you stop it?
3. Why `IS DISTINCT FROM` instead of `<>`?
4. `WHEN` clause vs an `IF` inside the function — which is cheaper, and why?
5. What does `RETURN NULL` mean in an `AFTER` trigger? In a `BEFORE` trigger?
6. Does the trigger fire on `COPY`? On `TRUNCATE`? How did that change your seeder?
7. Name two mechanisms for making a table immutable, and what each one misses.
8. Your seeder disables the guard trigger. Doesn't that defeat the point? *(No — it requires ownership and is explicit. The guard prevents accident, not authorised administration.)*
9. How would you make the trigger safe if it wrote back to `users`?
