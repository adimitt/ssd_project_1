# `mongo/01_collections_and_indexes.js`

## Objective

Create the three collections with their `$jsonSchema` validators and build every index —
including the two the brief names explicitly:

- a **`2dsphere`** index on `DriverPings.location`
- a **TTL** index on `DriverPings.created_at` with `expireAfterSeconds: 7200`

**Rubric:** Indexing & Query Optimization (10 pts) — the TTL/geospatial portion.

## How to run

```bash
# from the repository root - the path to docs/ is resolved relative to cwd
mongosh bitestream mongo/01_collections_and_indexes.js

# wipe and rebuild instead of updating in place
mongosh bitestream --eval 'DROP_FIRST=true' -f mongo/01_collections_and_indexes.js
```

## Idempotency

Existing collections are updated **in place** with `collMod` (data preserved); indexes are
dropped and rebuilt. `DROP_FIRST=true` wipes instead.

---

## It reads the schema, it does not contain it

The script loads `docs/mongo_schema_map.json` and applies it. See
[docs_mongo_schema_map.md](docs_mongo_schema_map.md) for why.

### `loadSchemaMap()`

Tries `cwd/docs/mongo_schema_map.json`, then `cwd/../docs/…`, so the script works from the
repo root (the documented way) or from inside `mongo/`. If neither exists it throws a
message telling you exactly how to invoke it, rather than failing on `undefined`.

`mongosh` exposes Node's `fs` and `path` via `require()`, which is what makes this possible.

### `keysFromSpec(pairs)`

Rebuilds an index-key object from the schema map's ordered `[field, direction]` pairs.
Order matters: a B-tree range-scans only on its leading field.

---

## Per-collection work

### 1. Collection + validator

```javascript
if (db.getCollectionNames().includes(name)) {
    db.runCommand({ collMod: name, validator: spec.validator,
                    validationLevel: spec.validationLevel,
                    validationAction: spec.validationAction });
} else {
    db.createCollection(name, { validator: …, validationLevel: …, validationAction: … });
}
```

`create()` on an existing collection **throws**. `collMod` applies the validator in place
without touching the data — that branch is what makes re-running this script safe, and it is
also how you would roll a validator onto a live production collection.

| Setting | Value | Meaning |
|---|---|---|
| `validationLevel` | `"strict"` | validate **every** insert and update, including updates to documents that predate the validator |
| | `"moderate"` | would exempt existing non-conforming documents from update validation |
| `validationAction` | `"error"` | reject the write |
| | `"warn"` | log only — how you stage a validator rollout without breaking writers |

### 2. Indexes

Every non-`_id_` index is dropped and rebuilt from the schema map, so the map always wins.
`_id_` is implicit and cannot be dropped.

The printed line flags what each index actually is:

```
index ix_pings_geo             {"location":"2dsphere"}  [2dsphere]
index ix_pings_ttl             {"created_at":1}  [TTL 7200s]
index ux_menus_restaurant      {"restaurant_id":1}  [unique]
```

---

## The verification block — assertions, not assumptions

The brief names two indexes by hand, so the script **asserts** them rather than assuming the
loop worked. A silent failure here would not surface until the middle of the viva.

```javascript
const geo = pingIx.find((i) => i.key && i.key.location === "2dsphere");
if (!geo) throw new Error("FAIL: no 2dsphere index on DriverPings.location");

const ttl = pingIx.find((i) => i.expireAfterSeconds !== undefined);
if (!ttl) throw new Error("FAIL: no TTL index on DriverPings");
if (ttl.expireAfterSeconds !== 7200) throw new Error(`FAIL: TTL is ${…}s, brief requires 7200`);
if (Object.keys(ttl.key).length !== 1) throw new Error("FAIL: a TTL index must be single-field");
```

The last check encodes a real MongoDB rule: **a TTL index can only ever be single-field.**
Trying to add a partition key to it is a common instinct and MongoDB rejects it outright.

It then confirms each collection actually carries a validator and prints its document count.

Output on a clean run:

```
2dsphere on DriverPings.location : OK (ix_pings_geo)
TTL 7200s on DriverPings.created_at : OK (ix_pings_ttl)
Menus        validator: OK   docs: 1000
Reviews      validator: OK   docs: 200000
DriverPings  validator: OK   docs: 499800
```

---

## Interaction with the seeder

Running this **before** the seeder is fine and is what `run_all.sh` does — the seeder drops
and recreates each collection anyway (also from the schema map), loads, and **then** builds
indexes.

Index-after-load matters twice:

1. Building three B-trees per document during a 500k-document load is several times slower.
2. **The TTL index in particular is built last**, so no document can expire while the load
   is still running.

---

## TTL facts worth having ready

| Question | Answer |
|---|---|
| Can a TTL index be compound? | **No.** Single-field only. |
| What type must the field be? | A BSON `Date`. A date **string** is silently ignored — nothing expires, and there is no error. |
| How precise is expiry? | Approximate. The background reaper runs roughly every 60 seconds. |
| Capped collections? | TTL does not work on them. |
| Replica sets? | Deletion happens on the primary; secondaries receive it via the oplog. |
| Can you change it later? | Yes — `collMod` with `index: {keyPattern: …, expireAfterSeconds: N}`. |

## Viva questions

1. `2dsphere` vs `2d` — what does each actually index?
2. Why must the TTL index be single-field?
3. What happens if `created_at` is stored as a string?
4. `validationLevel` strict vs moderate; `validationAction` error vs warn.
5. Why `collMod` rather than `createCollection` on a re-run?
6. Why does this script read a JSON file instead of declaring the schema inline?
7. Why are indexes built after the bulk load?
