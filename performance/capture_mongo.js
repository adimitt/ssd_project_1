// =====================================================================================
// BiteStream :: performance/capture_mongo.js
//
// Produces performance/mongo_execution_stats.json - the raw explain("executionStats")
// evidence for Workflows 3 and 4, each paired with a COLLSCAN control so the index's
// contribution is measurable rather than merely asserted.
//
// RUN  (from the repository root)
//   mongosh bitestream --quiet performance/capture_mongo.js > performance/mongo_execution_stats.json
//   (or simply: bash performance/capture_mongo.sh)
// =====================================================================================

// ---- explain-shape helpers (see mongo/02_workflow3_geonear.js for why) ---------------
function execStatsOf(doc) {
    if (doc.executionStats) return doc.executionStats;
    if (doc.stages && doc.stages.length) {
        const f = doc.stages[0];
        for (const k of ["$cursor", "$geoNearCursor"]) {
            if (f[k] && f[k].executionStats) return f[k].executionStats;
        }
    }
    return null;
}
function stageNames(node, acc) {
    acc = acc || [];
    if (!node || typeof node !== "object") return acc;
    if (node.stage) acc.push(node.stage);
    for (const c of [node.inputStage].concat(node.inputStages || [])) {
        if (c) stageNames(c, acc);
    }
    return acc;
}
function summarise(explainDoc) {
    const e = execStatsOf(explainDoc);
    if (!e) return { error: "no executionStats in this explain shape" };
    const stages = stageNames(e.executionStages);
    const counted = {};
    for (const s of stages) counted[s] = (counted[s] || 0) + 1;
    return {
        nReturned: e.nReturned,
        executionTimeMillis: e.executionTimeMillis,
        totalKeysExamined: e.totalKeysExamined,
        totalDocsExamined: e.totalDocsExamined,
        stages: counted,
        usedIndex: !stages.includes("COLLSCAN"),
    };
}
function timeIt(fn) {
    const t0 = Date.now();
    const n = fn();
    return { wallClockMs: Date.now() - t0, resultCount: n };
}

// =====================================================================================
const origin = db.Menus.findOne({ restaurant_id: 1 }, { location: 1, name: 1 });
const REVIEW_RID = 7;
const since = new Date(Date.now() - 540 * 24 * 3600 * 1000);

const out = {
    captured_at: new Date().toISOString(),
    server_version: db.version(),
    database: db.getName(),
    collection_sizes: {},
    indexes: {},
    workflow3: {},
    workflow4: {},
};

for (const c of ["Menus", "Reviews", "DriverPings"]) {
    out.collection_sizes[c] = db.getCollection(c).countDocuments();
    out.indexes[c] = db.getCollection(c).getIndexes().map((i) => ({
        name: i.name,
        key: i.key,
        expireAfterSeconds: i.expireAfterSeconds,
        unique: i.unique || false,
    }));
}

// =====================================================================================
// WORKFLOW 3 - $geoNear, 5 km, active drivers only
// =====================================================================================
const wf3Pipeline = [
    { $geoNear: {
        near: origin.location, distanceField: "distance_m", maxDistance: 5000,
        spherical: true, key: "location", query: { status: "ACTIVE" },
    }},
    { $sort: { driver_id: 1, distance_m: 1 } },
    { $group: { _id: "$driver_id", distance_m: { $first: "$distance_m" } } },
    { $sort: { distance_m: 1 } },
    // ONE, matching the shipped default in mongo/02_workflow3_geonear.js - the brief asks
    // for "the closest active driver". The $limit barely affects the measurement either
    // way: the per-driver $group upstream must drain the entire 5 km radius before any
    // limit can apply, which is why docsExamined stays ~44k regardless.
    { $limit: 1 },
];

out.workflow3.description =
    "The closest ACTIVE driver within 5km of restaurant 1, deduplicated to one row per driver (brief: 'locate the closest active driver'). Pass DRIVERS=n to the workflow script for the n nearest instead.";
out.workflow3.origin = origin.location;
out.workflow3.pipeline = wf3Pipeline;
out.workflow3.summary = summarise(db.DriverPings.explain("executionStats").aggregate(wf3Pipeline));
out.workflow3.timing = timeIt(() => db.DriverPings.aggregate(wf3Pipeline).toArray().length);
out.workflow3.full_explain = db.DriverPings.explain("executionStats").aggregate(wf3Pipeline);

// ---- control -------------------------------------------------------------------------
// $geoNear cannot be run WITHOUT a 2dsphere index at all - MongoDB rejects the pipeline
// outright rather than falling back to a scan. So the honest control is the equivalent
// brute-force bounding-box query, forced onto a collection scan with hint({$natural:1}).
const bboxLng = origin.location.coordinates[0];
const bboxLat = origin.location.coordinates[1];
// The control must do the SAME LOGICAL WORK as Workflow 3, otherwise the comparison is
// meaningless: an early $limit lets a collection scan stop after a handful of documents.
// Workflow 3 has to consume every ping inside the radius before it can dedupe by driver,
// so the control gets the same $sort/$group/$sort/$limit tail.
const wf3Control = [
    { $match: {
        status: "ACTIVE",
        "location.coordinates.0": { $gte: bboxLng - 0.05, $lte: bboxLng + 0.05 },
        "location.coordinates.1": { $gte: bboxLat - 0.045, $lte: bboxLat + 0.045 },
    }},
    { $sort: { driver_id: 1 } },
    { $group: { _id: "$driver_id", n: { $sum: 1 } } },
    { $sort: { n: -1 } },
    { $limit: 5 },
];
out.workflow3.control_note =
    "$geoNear REQUIRES a 2dsphere index - without one MongoDB errors with 'unable to find " +
    "index for $geoNear query' rather than degrading to a scan. The control below is the " +
    "equivalent brute-force bounding box, pinned to a collection scan with hint({$natural:1}).";
out.workflow3.control_summary =
    summarise(db.DriverPings.explain("executionStats").aggregate(wf3Control,
        { hint: { $natural: 1 }, allowDiskUse: true }));
out.workflow3.control_timing =
    timeIt(() => db.DriverPings.aggregate(wf3Control,
        { hint: { $natural: 1 }, allowDiskUse: true }).toArray().length);

// Prove the claim about $geoNear needing the index, and record the actual error text.
try {
    db.Menus.aggregate([{ $geoNear: {
        near: origin.location, distanceField: "d", spherical: true } }]).toArray();
    out.workflow3.geonear_without_index = "UNEXPECTED: no error";
} catch (e) {
    out.workflow3.geonear_without_index = e.message;
}

// =====================================================================================
// WORKFLOW 4 - $facet
// =====================================================================================
const wf4Pipeline = [
    { $match: { restaurant_id: REVIEW_RID, created_at: { $gte: since } } },
    { $facet: {
        ratingDistribution: [
            { $group: { _id: "$rating", count: { $sum: 1 } } }, { $sort: { _id: 1 } },
        ],
        topTags: [
            { $unwind: "$tags" },
            { $group: { _id: "$tags", count: { $sum: 1 } } },
            { $sort: { count: -1, _id: 1 } },
            { $limit: 10 },
        ],
        overall: [
            { $group: { _id: null, avgRating: { $avg: "$rating" },
                        totalReviews: { $sum: 1 }, stdDev: { $stdDevPop: "$rating" } } },
        ],
    }},
];

out.workflow4.description =
    "Faceted review analytics for one restaurant: rating histogram, top tags via $unwind, overall average.";
out.workflow4.pipeline = wf4Pipeline;
out.workflow4.summary = summarise(db.Reviews.explain("executionStats").aggregate(wf4Pipeline, { allowDiskUse: true }));
out.workflow4.timing = timeIt(() => db.Reviews.aggregate(wf4Pipeline, { allowDiskUse: true }).toArray().length);
out.workflow4.full_explain = db.Reviews.explain("executionStats").aggregate(wf4Pipeline, { allowDiskUse: true });

// ---- control: identical pipeline, forced onto a collection scan ----------------------
out.workflow4.control_note =
    "The identical pipeline pinned to a collection scan with hint({$natural:1}), showing " +
    "what the leading $match buys. Note that $facet's SUB-pipelines never use an index in " +
    "either case - only the stage before $facet can.";
out.workflow4.control_summary =
    summarise(db.Reviews.explain("executionStats").aggregate(wf4Pipeline,
        { allowDiskUse: true, hint: { $natural: 1 } }));
out.workflow4.control_timing =
    timeIt(() => db.Reviews.aggregate(wf4Pipeline, { allowDiskUse: true, hint: { $natural: 1 } }).toArray().length);

// ---- and the specific failure mode: $match moved INSIDE the facet --------------------
// This is the mistake the design notes warn about. Recorded here with real numbers.
const wf4Wrong = [
    { $facet: {
        ratingDistribution: [
            { $match: { restaurant_id: REVIEW_RID, created_at: { $gte: since } } },
            { $group: { _id: "$rating", count: { $sum: 1 } } }, { $sort: { _id: 1 } },
        ],
    }},
];
out.workflow4.antipattern_note =
    "The SAME work with the $match moved INSIDE the facet. A $facet sub-pipeline cannot " +
    "use an index, so this degrades to scanning every review in the collection.";
out.workflow4.antipattern_summary =
    summarise(db.Reviews.explain("executionStats").aggregate(wf4Wrong, { allowDiskUse: true }));
out.workflow4.antipattern_timing =
    timeIt(() => db.Reviews.aggregate(wf4Wrong, { allowDiskUse: true }).toArray().length);

print(JSON.stringify(out, null, 2));
