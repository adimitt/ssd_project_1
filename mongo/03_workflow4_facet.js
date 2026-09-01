// =====================================================================================
// BiteStream :: mongo/03_workflow4_facet.js
// WORKFLOW 4 - MULTI-FACETED REVIEW ANALYTICS
//
// PURPOSE
//   One pass over the Reviews collection producing, via $facet:
//     1. the rating distribution, 1-5 stars
//     2. the most frequent tag strings, via $unwind
//     3. the overall average rating
//   plus, because they cost nothing once the stream is already open, a sentiment split
//   and a monthly trend.
//
// RUN  (from the repository root)
//   mongosh bitestream mongo/03_workflow4_facet.js
//   mongosh bitestream --eval 'RESTAURANT_ID=42' -f mongo/03_workflow4_facet.js
//   mongosh bitestream --eval 'SCOPE="all"'      -f mongo/03_workflow4_facet.js
//   mongosh bitestream --eval 'EXPLAIN=true'     -f mongo/03_workflow4_facet.js
//
// DEPENDS ON
//   mongo/01_collections_and_indexes.js  (ix_reviews_restaurant_recent)
//   data_generation/mongo_seeder.py
// =====================================================================================

const RID = (typeof RESTAURANT_ID !== "undefined") ? RESTAURANT_ID : 7;
const SCOPE_ALL = (typeof SCOPE !== "undefined") && SCOPE === "all";
const WANT_EXPLAIN = (typeof EXPLAIN !== "undefined") && EXPLAIN === true;

// See mongo/02_workflow3_geonear.js for why this probing is necessary.
function execStatsOf(explainDoc) {
    if (explainDoc.executionStats) return explainDoc.executionStats;
    if (explainDoc.stages && explainDoc.stages.length) {
        const first = explainDoc.stages[0];
        for (const key of ["$cursor", "$geoNearCursor"]) {
            if (first[key] && first[key].executionStats) return first[key].executionStats;
        }
    }
    return null;
}
function stageNames(node, acc) {
    acc = acc || [];
    if (!node || typeof node !== "object") return acc;
    if (node.stage) acc.push(node.stage);
    for (const child of [node.inputStage].concat(node.inputStages || [])) {
        if (child) stageNames(child, acc);
    }
    return acc;
}

print("");
print("=== Workflow 4 : multi-faceted review analytics ===");

// =====================================================================================
// THE LEADING $match - THE MOST IMPORTANT LINE IN THIS FILE
//
//   $facet SUB-PIPELINES CANNOT USE INDEXES. Only the stage IMMEDIATELY PRECEDING $facet
//   can. So this $match is not a stylistic nicety: it is the only opportunity the entire
//   aggregation has to touch an index. Remove it, or move it inside a facet, and the
//   query degrades to a full COLLSCAN of every review in the collection.
//
//   The predicate is shaped to match ix_reviews_restaurant_recent {restaurant_id:1,
//   created_at:-1}: equality on the leading field, then a range on the second. Reversing
//   that order would leave the index unusable for the range portion.
// =====================================================================================
const since = new Date(Date.now() - 540 * 24 * 3600 * 1000);

const match = SCOPE_ALL
    ? { created_at: { $gte: since } }                       // every vendor: broad, less selective
    : { restaurant_id: RID, created_at: { $gte: since } };  // one vendor: index-backed

const menu = db.Menus.findOne({ restaurant_id: RID }, { name: 1, city: 1 });
print(`scope   : ${SCOPE_ALL ? "ALL restaurants" : `restaurant ${RID}` +
      (menu ? ` - ${menu.name} (${menu.city})` : "")}`);
print(`window  : reviews created since ${since.toISOString().slice(0, 10)}`);
print("");

// =====================================================================================
// THE PIPELINE
//
// WHY $facet AT ALL
//   It runs every sub-pipeline over the SAME input stream in a SINGLE PASS. The
//   alternative is five separate aggregations, each re-reading the same documents. That
//   single-pass property is the entire reason the stage exists, and it is the answer to
//   "why not just run three queries?".
//
// THE 16 MB CEILING
//   $facet emits ONE document containing every sub-result, so the combined output is
//   bounded by the BSON document size limit. Any sub-pipeline that can fan out must be
//   capped - hence the $limit inside topTags, which would otherwise emit one entry per
//   distinct tag in the corpus.
//
// WHAT $facet FORBIDS
//   $out, $merge, $geoNear, $changeStream, and nested $facet.
// =====================================================================================
const pipeline = [
    { $match: match },

    {
        $facet: {
            // ---- 1. RATING DISTRIBUTION, 1-5 stars -----------------------------------
            ratingDistribution: [
                { $group: { _id: "$rating", count: { $sum: 1 } } },
                { $sort: { _id: 1 } },
                { $project: { _id: 0, rating: "$_id", count: 1 } },
            ],

            // ---- 2. MOST FREQUENT TAGS, via $unwind ----------------------------------
            // $unwind is a MULTIPLYING stage: a review carrying 4 tags becomes 4
            // documents. preserveNullAndEmptyArrays is deliberately left OFF here,
            // because a review with no tags contributes nothing to a tag ranking; it
            // would be required if the count had to include untagged reviews.
            topTags: [
                { $unwind: "$tags" },
                { $group: { _id: "$tags", count: { $sum: 1 } } },
                { $sort: { count: -1, _id: 1 } },   // _id breaks ties deterministically
                { $limit: 10 },                     // bound the fan-out: see the 16 MB note
                { $project: { _id: 0, tag: "$_id", count: 1 } },
            ],

            // ---- 3. OVERALL AVERAGE --------------------------------------------------
            overall: [
                {
                    $group: {
                        _id: null,
                        avgRating: { $avg: "$rating" },
                        totalReviews: { $sum: 1 },
                        stdDev: { $stdDevPop: "$rating" },
                        minRating: { $min: "$rating" },
                        maxRating: { $max: "$rating" },
                    },
                },
            ],

            // ---- 4. sentiment split (free, the stream is already open) ---------------
            sentimentSplit: [
                { $group: { _id: "$sentiment", count: { $sum: 1 } } },
                { $sort: { count: -1 } },
                { $project: { _id: 0, sentiment: "$_id", count: 1 } },
            ],

            // ---- 5. monthly trend ----------------------------------------------------
            monthlyTrend: [
                {
                    $group: {
                        _id: { $dateToString: { format: "%Y-%m", date: "$created_at" } },
                        avgRating: { $avg: "$rating" },
                        count: { $sum: 1 },
                    },
                },
                { $sort: { _id: -1 } },
                { $limit: 6 },
                { $project: { _id: 0, month: "$_id", avgRating: { $round: ["$avgRating", 2] }, count: 1 } },
            ],
        },
    },

    // $facet's output is nested one level deep and every scalar arrives wrapped in a
    // single-element array, because each sub-pipeline is itself an array of documents.
    // $arrayElemAt unwraps them; $ifNull covers the empty-result case, where the "overall"
    // sub-pipeline legitimately produces NO documents at all rather than a zero.
    {
        $project: {
            ratingDistribution: 1,
            topTags: 1,
            sentimentSplit: 1,
            monthlyTrend: 1,
            totalReviews: { $ifNull: [{ $arrayElemAt: ["$overall.totalReviews", 0] }, 0] },
            avgRating: { $round: [{ $ifNull: [{ $arrayElemAt: ["$overall.avgRating", 0] }, 0] }, 3] },
            stdDev: { $round: [{ $ifNull: [{ $arrayElemAt: ["$overall.stdDev", 0] }, 0] }, 3] },
            minRating: { $arrayElemAt: ["$overall.minRating", 0] },
            maxRating: { $arrayElemAt: ["$overall.maxRating", 0] },
        },
    },
];

// allowDiskUse lets a $group whose working set exceeds the 100 MB in-memory limit spill to
// disk instead of failing. Harmless when it is not needed.
const options = { allowDiskUse: true };

// =====================================================================================
if (WANT_EXPLAIN) {
    print(JSON.stringify(
        db.Reviews.explain("executionStats").aggregate(pipeline, options), null, 2));
} else {
    const t0 = Date.now();
    const out = db.Reviews.aggregate(pipeline, options).toArray()[0];
    const ms = Date.now() - t0;

    if (!out || out.totalReviews === 0) {
        print("No reviews matched. Run data_generation/mongo_seeder.py first.");
    } else {
        print(`--- ${out.totalReviews.toLocaleString()} reviews aggregated in ${ms} ms`);
        print("");

        print(`  OVERALL   average ${out.avgRating}   sd ${out.stdDev}   ` +
              `range ${out.minRating}-${out.maxRating}`);
        print("");

        print("  RATING DISTRIBUTION");
        const maxCount = Math.max(...out.ratingDistribution.map((r) => r.count));
        for (const r of out.ratingDistribution) {
            const pct = (100 * r.count / out.totalReviews).toFixed(1);
            const bar = "#".repeat(Math.max(1, Math.round(34 * r.count / maxCount)));
            print(`    ${r.rating} star  ${String(r.count).padStart(7)}  ` +
                  `${String(pct).padStart(5)}%  ${bar}`);
        }
        print("");

        print("  TOP 10 TAGS  (via $unwind)");
        for (const t of out.topTags) {
            print(`    ${t.tag.padEnd(20)} ${String(t.count).padStart(7)}`);
        }
        print("");

        print("  SENTIMENT");
        for (const s of out.sentimentSplit) {
            print(`    ${s.sentiment.padEnd(20)} ${String(s.count).padStart(7)}`);
        }
        print("");

        print("  MONTHLY TREND  (last 6 months with reviews)");
        for (const m of out.monthlyTrend) {
            print(`    ${m.month}   avg ${m.avgRating}   n=${m.count}`);
        }
    }

    // ---------------------------------------------------------------------------------
    // Index proof.
    // ---------------------------------------------------------------------------------
    const exec = execStatsOf(db.Reviews.explain("executionStats").aggregate(pipeline, options));
    print("");
    if (exec) {
        const stages = stageNames(exec.executionStages);
        const total = db.Reviews.estimatedDocumentCount();
        print(`  collection size    : ${total.toLocaleString()} reviews`);
        print(`  documents examined : ${exec.totalDocsExamined.toLocaleString()}`);
        print(`  keys examined      : ${exec.totalKeysExamined.toLocaleString()}`);
        print(`  execution time     : ${exec.executionTimeMillis} ms`);
        print(`  plan stages        : ${stages.join(" <- ")}`);

        if (stages.includes("COLLSCAN")) {
            if (SCOPE_ALL) {
                print("  verdict            : COLLSCAN - EXPECTED for SCOPE=\"all\". The " +
                      "predicate covers most of");
                print("                       the collection, so a full scan genuinely IS " +
                      "the cheaper plan.");
            } else {
                throw new Error("FAIL: COLLSCAN on a single-restaurant query - the index is not being used");
            }
        } else if (stages.includes("IXSCAN")) {
            print("  verdict            : IXSCAN on ix_reviews_restaurant_recent, no COLLSCAN -> index confirmed");
        }
    }
}

print("");
print("--- Workflow 4 complete");
