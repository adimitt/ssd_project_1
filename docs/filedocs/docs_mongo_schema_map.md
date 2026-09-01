# `docs/mongo_schema_map.json`

## Objective

The brief lists this as a deliverable — *"Document structure & validation models"*. In this
project it is **not documentation. It is the definition.**

```
docs/mongo_schema_map.json          <-- single source of truth
        |
        +--> mongo/01_collections_and_indexes.js   reads it, applies validators + indexes
        +--> data_generation/mongo_seeder.py       reads it, recreates collections + indexes
```

Editing this file **changes the database**. Nothing else defines the Mongo schema, so the
document and the database cannot drift apart — which is the failure mode that makes most
"schema map" deliverables worthless by submission day.

---

## Top-level shape

| Key | Purpose |
|---|---|
| `$comment` | an array of lines explaining the file's role (JSON has no comment syntax) |
| `database` | `"bitestream"` |
| `collections` | one entry per collection |

Each collection entry carries:

| Field | Purpose |
|---|---|
| `purpose` | one line: what the collection is for |
| `embed_or_reference` | **the modelling decision and its justification** |
| `example` | a representative document |
| `validator` | the `$jsonSchema` object, applied verbatim |
| `validationLevel` / `validationAction` | `"strict"` / `"error"` |
| `indexes` | ordered key pairs, options, and a `rationale` per index |

### Why index keys are `[[field, direction], …]` and not an object

JSON does not guarantee object key order, and **compound index order is semantically
significant** — a B-tree can only range-scan on its leading field. Storing keys as an
ordered array of pairs preserves that meaning. Both consumers rebuild an ordered structure
from it:

```javascript
function keysFromSpec(pairs) {            // mongosh
    const keys = {};
    for (const [field, direction] of pairs) keys[field] = direction;
    return keys;
}
```
```python
keys = [(field, direction) for field, direction in ix["keys"]]   # pymongo
```

`direction` is `1`, `-1`, or the string `"2dsphere"`.

---

## `Menus`

**Decision: EMBED.** A menu is always read whole, always for one restaurant, and is bounded
well under the 16 MB BSON limit. Embedding makes it a single-document read with no
`$lookup`.

**The rule applied**, and the sentence to say in the viva:

> Embed when the child is bounded, always read with the parent, and updated with it.
> Reference when it is unbounded or independently queried.

`DriverPings` is the counter-example that proves the rule is being applied rather than
recited: unbounded and write-heavy, so it gets its own collection.

Structure: `categories[] → items[] → addons[] → options[]` — four levels of nesting, which
is what makes it a genuine "flexible catalogue" rather than a flat table in disguise.

**`price` is `bsonType: "decimal"`** (Decimal128), mirroring PostgreSQL `NUMERIC`. A double
would reintroduce the exact floating-point money bug the relational side carefully avoids.
`mongo_seeder.py` writes `Decimal128("329.00")`.

**`location`** is a GeoJSON Point copied from PostgreSQL at load time. It is denormalised
here so `mongo/02_workflow3_geonear.js` can find its search origin without reaching back
across to the relational database mid-pipeline.

| Index | Rationale |
|---|---|
| `ux_menus_restaurant` `{restaurant_id:1}` unique | one live menu per restaurant; also the only access path |
| `ix_menus_item_name` `{categories.items.name:1}` | **multikey across two levels of array nesting** — "which restaurants sell X" |

---

## `Reviews`

**Decision: SEPARATE COLLECTION.** Unbounded per restaurant and queried independently of the
menu; embedding would grow the menu document without limit.

`rating` is constrained `minimum: 1, maximum: 5` by the validator — the document-store
equivalent of a `CHECK` constraint, and the answer to "MongoDB is schemaless, so how do you
enforce anything?".

| Index | Rationale |
|---|---|
| `ix_reviews_restaurant_recent` `{restaurant_id:1, created_at:-1}` | **Workflow 4's leading `$match`.** Critical: `$facet` sub-pipelines cannot use indexes, so this is the only index the faceted aggregation can ever benefit from |
| `ix_reviews_tags` `{tags:1}` | multikey, for tag-filtered searches |
| `ix_reviews_rating` `{rating:1}` | rating histogram / low-rating alerting |

Note the compound order: equality on `restaurant_id` first, then the range on `created_at`.
Reversed, the range portion would be unusable.

---

## `DriverPings`

**Decision: SEPARATE COLLECTION, and deliberately transient.** The TTL index makes it
self-pruning; telemetry is intentionally lossy.

The validator encodes the two facts most likely to be got wrong:

```json
"coordinates": {
  "bsonType": "array", "minItems": 2, "maxItems": 2, "items": {"bsonType": "double"},
  "description": "[longitude, latitude] - LONGITUDE FIRST. Reversing them is the single
                  most common bug in this assignment; the query then silently returns nothing."
}
"created_at": {
  "bsonType": "date",
  "description": "MUST be a BSON Date. A date STRING is silently ignored by the TTL monitor
                  and nothing ever expires."
}
```

| Index | Rationale |
|---|---|
| `ix_pings_geo` `{location:"2dsphere"}` | **Workflow 3.** `2dsphere` is spherical and earth-aware and understands GeoJSON; legacy `2d` is planar coordinate pairs and cannot return real distances in metres |
| `ix_pings_ttl` `{created_at:1}` `expireAfterSeconds:7200` | 2-hour TTL |
| `ix_pings_driver_recent` `{driver_id:1, created_at:-1}` | latest-ping-per-driver; the dedup in Workflow 3 |

### TTL rules encoded here

- **single-field only** — a TTL index can never be compound. `mongo/01` asserts this.
- the field must be a **BSON `Date`**; a date string is silently ignored.
- the background reaper runs roughly **every 60 seconds**, so expiry is approximate.
- TTL does not work on capped collections.
- on a replica set, deletion happens on the primary only.

---

## The cross-database contract

`restaurant_id`, `user_id` and `order_id` are **opaque copies of PostgreSQL BIGINT primary
keys**. MongoDB enforces nothing about them.

The only integrity mechanism in the project is that `mongo_seeder.py`
**reads the real ids out of PostgreSQL** before generating documents, and refuses to run if
PostgreSQL has not been seeded. Everything after that is convention.

This is the honest weakness of polyglot persistence, and the README documents it.

## Viva questions

1. Why is this file the input rather than the output?
2. Why embed `Menus` but keep `DriverPings` separate? State the rule.
3. Why are index keys stored as ordered pairs rather than a JSON object?
4. What does `validationLevel: "strict"` mean, versus `"moderate"`? *(`strict` validates every insert and update; `moderate` exempts existing non-conforming documents from update validation.)*
5. What would `validationAction: "warn"` be used for? *(Rolling a validator onto a live collection without breaking writers.)*
6. Why `Decimal128` for prices?
7. What enforces `restaurant_id` pointing at a real restaurant? *(Nothing at runtime — only the loader.)*
