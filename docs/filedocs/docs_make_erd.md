# `docs/make_erd.py`

## Objective

Generate `docs/relational_erd.png`, the visual map of the PostgreSQL schema that the brief
lists as deliverable #1.

## How to run

```bash
python3 docs/make_erd.py     # -> docs/relational_erd.png (~190 KB)
```

Only needs `matplotlib` (pinned in `data_generation/requirements.txt`). The PNG is committed,
so a grader never has to install anything.

---

## Why a script rather than dbdiagram.io or eralchemy

| Option | Problem |
|---|---|
| **dbdiagram.io** | prettiest, but manual, needs an account, and drifts from the DDL the moment the schema changes |
| **eralchemy2** | generated from the live database so it cannot drift — but needs graphviz, and it draws *only* what the catalog knows |
| **pgAdmin ERD tool** | zero install if you already run pgAdmin, but the export is hard to check into a repo reproducibly |
| **this script** | no graphviz, no network, no account; checked in next to the schema; **and it can draw the two things the others cannot** |

That last point is the real justification. An auto-generated ERD shows tables and foreign
keys. It **cannot** show:

1. the **partial unique index** — the business rule, which lives in an index rather than a
   constraint and does not appear in any catalog view an ERD tool reads;
2. the **trigger direction** — `users ──trigger──▶ wallet_audit_logs`, which is the actual
   data flow that makes the ledger work.

Both are the point of this assignment, so both are drawn explicitly.

---

## What the diagram contains

| Element | Rendering |
|---|---|
| `users`, `restaurants`, `orders`, `wallet_audit_logs` | solid boxes — base tables |
| `mv_restaurant_performance`, `checkout_attempts` | **dashed** boxes — derived objects |
| `PK` / `UX` / `FK` / `CK` markers | colour-coded per column |
| foreign keys | solid gold arrows with `1 : N` cardinality labels |
| the trigger | **red dashed** arrow, annotated with the full trigger definition |
| the MV | **green dashed** arrow, annotated with the `ON`-not-`WHERE` join note |
| `idx_active_user_order` | a callout box below `orders`, with the full definition and both consequences |
| legend | bottom-left |

Every table row also shows its constraint inline (`NUMERIC(10,2) >= 0`,
`PREPARING|DELIVERING|DELIVERED`, `NOT NULL when DELIVERED`), so the diagram carries the
`CHECK` constraints rather than just column names.

---

## Structure of the script

| Function | Role |
|---|---|
| `TABLES` dict | data-driven layout: `xy` (top-left), `w`, and `cols` as `(kind, name, type)` |
| `draw_table()` | rounded box + tinted header + one row per column; stores `_box` for arrow anchoring |
| `arrow()` | `FancyArrowPatch` with `arc3,rad=` for curved routing |
| `tag()` | a labelled callout with a background box, so labels stay readable over crossing lines |

Layout is a **3 × 2 grid** on a 19.4 × 13.2 canvas, with the empty column between the left
and middle tables reserved for the trigger and FK annotations.

### Two layout bugs that had to be fixed

1. **The partial-index callout overlapped `orders`, and the legend overlapped
   `restaurants`.** Fixed by increasing the canvas height and reserving a dedicated band at
   the bottom (`y = 0.55 … 2.40`) for both.
2. **The trigger annotation collided with the `wallet_audit_logs → users` FK arrowhead.**
   Fixed by drawing the trigger arrow high between the two box tops and routing the FK
   *below* both boxes with `rad=-0.28`, so the two edges occupy different bands.

Worth knowing because it is the generic hazard with hand-laid diagrams: arrows and labels
are positioned in absolute coordinates and nothing warns you when they overlap. **Always
open the PNG and look at it.**

## Regenerating after a schema change

The `TABLES` dict is hand-maintained, so it does **not** auto-follow the DDL. If you alter
`sql/01_schema_ddl.sql`, update the dict and re-run. That is the one cost of this approach
versus `eralchemy2`, and it is worth stating honestly if asked.

## Viva questions

1. Why not use an ERD generator?
2. What can your diagram show that an auto-generated one cannot?
3. Why are two boxes dashed?
4. Where is the "one active order per user" rule in the diagram, and why is it not drawn as a constraint on `orders`?
5. What happens to the diagram if you add a column? *(Nothing, until you update the dict — it is not auto-generated.)*
