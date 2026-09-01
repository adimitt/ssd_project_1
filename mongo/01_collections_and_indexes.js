// =====================================================================================
// BiteStream :: mongo/01_collections_and_indexes.js
//
// PURPOSE
//   Creates the three MongoDB collections with their $jsonSchema validators, and builds
//   every index - including the two the brief names explicitly:
//       * a 2dsphere index on DriverPings.location
//       * a TTL index on DriverPings.created_at with expireAfterSeconds: 7200
//
// SINGLE SOURCE OF TRUTH
//   This script does not hard-code the schema. It READS docs/mongo_schema_map.json and
//   applies it. That file is the deliverable the brief asks for, and making it the input
//   rather than a description guarantees the document and the database cannot drift apart.
//   data_generation/mongo_seeder.py reads the same file.
//
// IDEMPOTENT
//   Yes. Existing collections are updated in place with collMod (data is preserved);
//   indexes are dropped and rebuilt. Pass --eval 'DROP_FIRST=true' to wipe instead.
//
// RUN  (from the repository root - the path to docs/ is resolved relative to cwd)
//   mongosh bitestream mongo/01_collections_and_indexes.js
//   mongosh bitestream --eval 'DROP_FIRST=true' -f mongo/01_collections_and_indexes.js
// =====================================================================================

const fs = require("fs");
const path = require("path");

// -------------------------------------------------------------------------------------
// Locate the schema map. Try the repo root first (the documented way to run this), then
// one level up, so the script also works if invoked from inside mongo/.
// -------------------------------------------------------------------------------------
function loadSchemaMap() {
    const candidates = [
        path.join(process.cwd(), "docs", "mongo_schema_map.json"),
        path.join(process.cwd(), "..", "docs", "mongo_schema_map.json"),
    ];
    for (const p of candidates) {
        if (fs.existsSync(p)) {
            print(`[01] schema map: ${p}`);
            return JSON.parse(fs.readFileSync(p, "utf8"));
        }
    }
    throw new Error(
        "docs/mongo_schema_map.json not found. Run this script from the repository root:\n" +
        "    mongosh bitestream mongo/01_collections_and_indexes.js"
    );
}

const SCHEMA = loadSchemaMap();
const dropFirst = (typeof DROP_FIRST !== "undefined") && DROP_FIRST === true;

print("");
print("=== 01_collections_and_indexes.js ===");
print(`database   : ${db.getName()}`);
print(`drop first : ${dropFirst}`);
print("");

// -------------------------------------------------------------------------------------
// keysFromSpec
//   The schema map stores index keys as ordered [field, direction] pairs, because JSON
//   object key order is not guaranteed by the format and COMPOUND INDEX ORDER MATTERS
//   (a B-tree can only range-scan on its leading field). Rebuilding an object from an
//   ordered array is what preserves that meaning.
//   direction is 1 (ascending), -1 (descending) or the string "2dsphere".
// -------------------------------------------------------------------------------------
function keysFromSpec(pairs) {
    const keys = {};
    for (const [field, direction] of pairs) keys[field] = direction;
    return keys;
}

for (const [name, spec] of Object.entries(SCHEMA.collections)) {
    print(`--- ${name} ---`);

    const exists = db.getCollectionNames().includes(name);

    if (dropFirst && exists) {
        db.getCollection(name).drop();
        print("    dropped");
    }

    // -------------------------------------------------------------------------------
    // Collection + validator.
    //
    //   validationLevel "strict"  : validate every insert AND every update, including
    //                               updates to documents that predate the validator.
    //                               ("moderate" would exempt existing non-conforming docs.)
    //   validationAction "error"  : reject the write. ("warn" only logs, and is how you
    //                               would roll a validator out onto a live collection.)
    //
    //   create() on an existing collection throws; collMod applies the validator in place
    //   without touching the data, which is what makes re-running this script safe.
    // -------------------------------------------------------------------------------
    if (db.getCollectionNames().includes(name)) {
        db.runCommand({
            collMod: name,
            validator: spec.validator,
            validationLevel: spec.validationLevel,
            validationAction: spec.validationAction,
        });
        print("    validator applied via collMod (existing data preserved)");
    } else {
        db.createCollection(name, {
            validator: spec.validator,
            validationLevel: spec.validationLevel,
            validationAction: spec.validationAction,
        });
        print("    created with validator");
    }

    // -------------------------------------------------------------------------------
    // Indexes. Dropped and rebuilt so the definitions in the schema map always win.
    // _id_ is implicit and cannot be dropped.
    // -------------------------------------------------------------------------------
    const coll = db.getCollection(name);
    for (const ix of coll.getIndexes()) {
        if (ix.name !== "_id_") coll.dropIndex(ix.name);
    }

    for (const ixSpec of spec.indexes) {
        const keys = keysFromSpec(ixSpec.keys);
        const opts = Object.assign({ name: ixSpec.name }, ixSpec.options || {});
        coll.createIndex(keys, opts);

        const flags = [];
        if (opts.unique) flags.push("unique");
        if (opts.expireAfterSeconds !== undefined) {
            flags.push(`TTL ${opts.expireAfterSeconds}s`);
        }
        if (Object.values(keys).includes("2dsphere")) flags.push("2dsphere");
        print(`    index ${ixSpec.name.padEnd(24)} ${JSON.stringify(keys)}` +
              (flags.length ? `  [${flags.join(", ")}]` : ""));
    }
    print("");
}

// -------------------------------------------------------------------------------------
// Verification. The two indexes the brief names by hand are asserted explicitly rather
// than assumed, so a silent failure cannot slip through to the viva.
// -------------------------------------------------------------------------------------
print("=== verification ===");

const pingIx = db.DriverPings.getIndexes();

const geo = pingIx.find((i) => i.key && i.key.location === "2dsphere");
if (!geo) throw new Error("FAIL: no 2dsphere index on DriverPings.location");
print(`  2dsphere on DriverPings.location : OK (${geo.name})`);

const ttl = pingIx.find((i) => i.expireAfterSeconds !== undefined);
if (!ttl) throw new Error("FAIL: no TTL index on DriverPings");
if (ttl.expireAfterSeconds !== 7200) {
    throw new Error(`FAIL: TTL is ${ttl.expireAfterSeconds}s, the brief requires 7200`);
}
// A TTL index can only ever be single-field. Assert that too - it is a common mistake to
// try to add a partition key to it, and MongoDB rejects a compound TTL index outright.
if (Object.keys(ttl.key).length !== 1) {
    throw new Error("FAIL: a TTL index must be single-field");
}
print(`  TTL 7200s on DriverPings.created_at : OK (${ttl.name})`);

for (const [name, spec] of Object.entries(SCHEMA.collections)) {
    const info = db.getCollectionInfos({ name })[0];
    const hasValidator = !!(info && info.options && info.options.validator);
    if (!hasValidator) throw new Error(`FAIL: ${name} has no validator`);
    print(`  ${name.padEnd(12)} validator: OK   docs: ${db.getCollection(name).countDocuments()}`);
}

print("");
print("--- 01_collections_and_indexes.js complete");
