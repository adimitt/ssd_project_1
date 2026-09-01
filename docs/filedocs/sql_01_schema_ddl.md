# `sql/01_schema_ddl.sql`

## Objective

Create the entire PostgreSQL relational schema: four tables, their data types, primary and
foreign keys, and every `CHECK` constraint. This is the foundation — nothing else in the
project can run until it has succeeded.

**Rubric:** Database Engine Logic (20 pts) — the `CHECK` constraint portion.

## Position in the build order

Step 1. Runs immediately after the server is provisioned, before triggers, before indexes,
before any data.

## Idempotency

`DROP TABLE IF EXISTS … CASCADE` for all four tables, children first. Safe to re-run on a
dirty database any number of times.

> **`CASCADE` has a side effect worth knowing.** It also drops
> `mv_restaurant_performance`, because the view depends on `orders` and `restaurants`.
> That is why `postgres_seeder.py` checks `to_regclass` before trying to refresh the view —
> when the project is built in file order, the view does not exist yet at seed time and
> `sql/05` creates it `WITH DATA` a moment later.

---

## Object 1 — `users`

| Column | Type | Constraint |
|---|---|---|
| `id` | `BIGINT GENERATED ALWAYS AS IDENTITY` | PRIMARY KEY |
| `name` | `VARCHAR(120)` | `NOT NULL`, `ck_users_name_not_blank` |
| `email` | `VARCHAR(160)` | — |
| `wallet_balance` | `NUMERIC(10,2)` | `NOT NULL DEFAULT 0`, **`ck_users_wallet_non_negative`** |
| `created_at` | `TIMESTAMPTZ` | `NOT NULL DEFAULT now()` |

### Decision — `BIGINT IDENTITY` over `UUID`

The brief allows either. We chose `BIGINT`:

- **Insert locality.** A random UUIDv4 lands in a random B-tree leaf page on every insert,
  causing page splits, WAL bloat and cache misses. A monotonic BIGINT always appends to
  the rightmost leaf.
- **Width.** 8 bytes versus 16, on the PK *and* on every foreign key that references it.
  Across `orders` (300k) and `wallet_audit_logs` (150k) that is measurable.
- **The counter-argument**, which you should raise before the examiner does: UUIDs are
  generatable client-side without a round trip and are safe to expose externally. The
  modern reconciliation is **UUIDv7 / ULID**, which restores time-ordering while keeping
  global uniqueness.

### Decision — `GENERATED ALWAYS`, not `BY DEFAULT`

`ALWAYS` forbids an `INSERT` from supplying its own id without the explicit
`OVERRIDING SYSTEM VALUE` escape hatch. Consequence for the seeder: it `COPY`s only the
non-identity columns and lets PostgreSQL assign `1..N` in insertion order. Combined with
`TRUNCATE … RESTART IDENTITY`, that makes ids deterministic, which is what lets the seeder
reference user and restaurant ids without a round trip.

### Decision — `NUMERIC(10,2)` for money, never `FLOAT`

Binary floating point cannot represent `0.10` exactly. Across a ledger the error
accumulates, and a wallet that should read `0.00` reads `-0.00000000001` — which would
then violate `wallet_balance >= 0`. `NUMERIC` is exact decimal arithmetic.
`(10,2)` caps the value at `99,999,999.99`.

Note the contrast with `restaurants.latitude`: `DOUBLE PRECISION` is *correct* there,
because that is a measurement wanting precision, not a quantity wanting exactness.

### `ck_users_wallet_non_negative`

The headline `CHECK`. It is the **last** line of defence — `sp_execute_checkout` validates
the balance first — but it is what makes an overdraft physically impossible regardless of
who writes to the table. Raises **SQLSTATE 23514** (`check_violation`), which the procedure
catches and maps to `INSUFFICIENT_FUNDS`.

---

## Object 2 — `wallet_audit_logs`

The immutable ledger. **Nothing inserts into this table directly** — every row is written
by `trg_wallet_audit` (see [sql_03](sql_03_triggers_and_audit.md)).

| Column | Type | Constraint |
|---|---|---|
| `id` | `BIGINT IDENTITY` | PRIMARY KEY |
| `user_id` | `BIGINT` | `fk_audit_user → users(id) ON DELETE RESTRICT` |
| `amount_changed` | `NUMERIC(10,2)` | `ck_audit_amount_non_zero` (`<> 0`) |
| `action_type` | `VARCHAR(6)` | `ck_audit_action_type` (`IN ('DEBIT','CREDIT')`) |
| `balance_after` | `NUMERIC(10,2)` | `ck_audit_balance_after` (`>= 0`) |
| `"timestamp"` | `TIMESTAMPTZ` | `NOT NULL DEFAULT now()` |

### Decision — `ON DELETE RESTRICT`, not `CASCADE`

An audit trail you can erase by deleting the user is not an audit trail. `RESTRICT` means
you must deal with the ledger before you can remove the user — and the immutability guard
in `sql/03` means you cannot delete ledger rows either. The net effect: **a user with
wallet history can never be deleted.** `sql/99_verification_suite.sql` relies on exactly
this, which is why it names its fixture users uniquely per run rather than cleaning up.

### Decision — the multi-column `CHECK`

```sql
CONSTRAINT ck_audit_sign_matches_action CHECK (
    (action_type = 'CREDIT' AND amount_changed > 0) OR
    (action_type = 'DEBIT'  AND amount_changed < 0)
)
```

A single-column `CHECK` can only say "`action_type` is one of two strings". This one ties
the **label** to the **sign**, making a mislabelled `DEBIT of +500` impossible. The trigger
satisfies it by construction: a rise always produces `(CREDIT, positive)`.

This is the constraint to point at when asked "what can a `CHECK` do that a type cannot?".

### Decision — quoting `"timestamp"`

The brief names the column `timestamp`. In PostgreSQL that is a *non-reserved* keyword
(legal as a column name) but it is also a type name, so bare use can confuse readers and
some tooling. Quoting it everywhere removes all ambiguity at zero cost.

---

## Object 3 — `restaurants`

| Column | Type | Constraint |
|---|---|---|
| `id` | `BIGINT IDENTITY` | PRIMARY KEY |
| `name` | `VARCHAR(160)` | `NOT NULL` |
| `city` | `VARCHAR(80)` | `NOT NULL` |
| `latitude` | `DOUBLE PRECISION` | `ck_rest_latitude` (`BETWEEN -90 AND 90`) |
| `longitude` | `DOUBLE PRECISION` | `ck_rest_longitude` (`BETWEEN -180 AND 180`) |
| `is_active` | `BOOLEAN` | `NOT NULL DEFAULT true` |

### Why the range checks earn their keep

They are nearly free, and they stop the seeder writing a coordinate that MongoDB's
`2dsphere` index would later reject **at index-build time** — a failure that surfaces
hundreds of thousands of documents later and is miserable to diagnose. `mongo_seeder.py`
clamps its generated coordinates for the same reason.

### Why not PostGIS

Geospatial querying lives in MongoDB (`DriverPings` + `$geoNear`). These columns exist only
to supply the **origin point** for that query, which `mongo_seeder.py` copies into the
`Menus` documents at load time. Adding PostGIS would duplicate a capability the design has
already placed on the other engine.

---

## Object 4 — `orders`

| Column | Type | Constraint |
|---|---|---|
| `id` | `BIGINT IDENTITY` | PRIMARY KEY |
| `user_id` | `BIGINT` | `fk_orders_user → users(id)` |
| `restaurant_id` | `BIGINT` | `fk_orders_restaurant → restaurants(id)` |
| `total_amount` | `NUMERIC(10,2)` | `ck_orders_amount_positive` (`> 0`) |
| `status` | `VARCHAR(12)` | `ck_orders_status` (three values) |
| `created_at` | `TIMESTAMPTZ` | `NOT NULL DEFAULT now()` |
| `delivered_at` | `TIMESTAMPTZ` | `ck_orders_delivered_has_timestamp`, `ck_orders_delivered_after_created` |

### Decision — `VARCHAR + CHECK` for `status`

Three candidates, and you should be able to argue all three:

| Approach | For | Against |
|---|---|---|
| **`CHECK`** (chosen) | trivial to read; the brief specifies `VARCHAR` | `ALTER` re-validates the whole table |
| `ENUM` | compact, type-safe, ordered | `ALTER TYPE … ADD VALUE` historically could not run in a transaction |
| lookup table | most flexible, supports metadata | adds a join to every query |

For a **closed three-value set on a `VARCHAR` column**, `CHECK` is the intended answer.

### Decision — state/timestamp coherence

`CHECK (status <> 'DELIVERED' OR delivered_at IS NOT NULL)` means a row cannot claim to be
delivered without recording when. The partner constraint
`CHECK (delivered_at IS NULL OR delivered_at >= created_at)` forbids time travel.

Both shape the seeder: `build_orders()` must set `delivered_at` on every `DELIVERED` row
and clear it on the rows it flips to active.

### What is deliberately **not** here

The "one active order per user" rule. It is conditional — it applies only to two of the
three statuses — and a table constraint cannot express that. It is a **partial unique
index**, created in [sql_02](sql_02_indexes.md).

---

## Failure modes this file prevents

| Attempted write | Rejected by | SQLSTATE |
|---|---|---|
| wallet driven below zero | `ck_users_wallet_non_negative` | 23514 |
| free or negative-value order | `ck_orders_amount_positive` | 23514 |
| `status = 'CANCELLED'` | `ck_orders_status` | 23514 |
| `DELIVERED` with no `delivered_at` | `ck_orders_delivered_has_timestamp` | 23514 |
| ledger row labelled `DEBIT` with a positive delta | `ck_audit_sign_matches_action` | 23514 |
| deleting a user who has wallet history | `fk_audit_user … RESTRICT` | 23503 |
| order referencing a nonexistent restaurant | `fk_orders_restaurant` | 23503 |

Verified by T13, T14, T15 and T05 in `sql/99_verification_suite.sql`.

## Viva questions

1. Why `NUMERIC` and not `FLOAT` for money — and why is `FLOAT` right for latitude?
2. `CHECK` vs `ENUM` vs lookup table for `status`. Defend your choice.
3. What does `TIMESTAMPTZ` physically store? *(A UTC instant. `TIMESTAMP` stores a wall-clock reading with no zone, so two machines can disagree about ordering.)*
4. Why `ON DELETE RESTRICT` on the audit FK? What is the consequence for deleting users?
5. UUID vs BIGINT: make the index-locality argument, then argue the other side.
6. What can a multi-column `CHECK` express that per-column constraints cannot?
7. Why is the "one active order" rule not in this file?
8. `GENERATED ALWAYS` vs `BY DEFAULT` — how does that affect the seeder?
