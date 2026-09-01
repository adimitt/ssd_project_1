-- =====================================================================================
-- BiteStream :: 02_indexes.sql
--
-- PURPOSE
--   Creates every index in the relational schema: the partial UNIQUE index that encodes
--   the "one active order per user" business rule, the partial COVERING index that makes
--   Workflow 2 an Index Only Scan, and the supporting secondary indexes.
--
-- POSITION IN THE BUILD ORDER
--   Logically step E - AFTER the bulk load, not before. Loading 300k rows into a table
--   that already carries five indexes is several times slower, and the partial UNIQUE
--   index will abort a COPY midway if the generated data violates it.
--   postgres_seeder.py therefore drops these indexes, COPYs, and re-runs this file.
--   Running the numbered files in order on an empty database also works: there is simply
--   nothing to index yet.
--
-- IDEMPOTENT
--   Yes. DROP INDEX IF EXISTS before each CREATE.
--
-- RUN
--   psql "$PGURL" -v ON_ERROR_STOP=1 -f sql/02_indexes.sql
-- =====================================================================================

\echo '=== 02_indexes.sql : creating indexes ==='

DROP INDEX IF EXISTS idx_active_user_order;
DROP INDEX IF EXISTS idx_orders_delivered_rest_date;
DROP INDEX IF EXISTS idx_orders_delivered_date_rest;
DROP INDEX IF EXISTS idx_orders_user_created;
DROP INDEX IF EXISTS idx_audit_user_ts;
DROP INDEX IF EXISTS idx_restaurants_active;


-- -------------------------------------------------------------------------------------
-- 1. THE BUSINESS RULE  (partial UNIQUE index - given verbatim in the brief)
--
--    "A user may not have more than one active delivery at a time."
--
--    This is a uniqueness constraint that applies only to a SUBSET of rows. A user may
--    hold 500 DELIVERED orders - those rows are simply not in the index - but a second
--    PREPARING or DELIVERING row raises unique_violation, SQLSTATE 23505.
--
--    WHY AN INDEX AND NOT A CONSTRAINT
--      ALTER TABLE ... ADD CONSTRAINT ... UNIQUE cannot take a WHERE clause. Conditional
--      uniqueness is only expressible as a partial unique INDEX.
--
--    WHEN THE PLANNER WILL USE IT FOR READS
--      Only when the query predicate is provably implied by the index predicate.
--        WHERE status = 'PREPARING'          -> usable (a literal the planner can prove)
--        WHERE status = $1                   -> generally NOT usable (parameter)
--      Enforcement of uniqueness happens regardless of the planner.
--
--    CONSEQUENCE FOR THE SEEDER
--      Generated data must contain at most one active order per user. See
--      postgres_seeder.py, _assign_active_orders().
-- -------------------------------------------------------------------------------------
CREATE UNIQUE INDEX idx_active_user_order
    ON orders (user_id)
    WHERE status IN ('PREPARING', 'DELIVERING');

COMMENT ON INDEX idx_active_user_order IS
    'Business rule: at most one PREPARING/DELIVERING order per user. Raises 23505.';


-- -------------------------------------------------------------------------------------
-- 2. THE WORKFLOW 2 / MATERIALIZED VIEW WORKHORSE  (partial COVERING index)
--
--    Key columns  : (restaurant_id, created_at)   - grouping key, then the range column
--    Payload      : INCLUDE (total_amount)        - the only other column WF2 reads
--    Predicate    : WHERE status = 'DELIVERED'    - ~98% of rows, but it lets the planner
--                                                   drop the status test entirely
--
--    INCLUDE (PostgreSQL 11+) stores total_amount in the index LEAF without making it a
--    key column: it does not affect index ordering or size-per-key comparisons, but it
--    means the whole of Workflow 2 can be answered from the index alone.
--
--    RESULT: "Index Only Scan using idx_orders_delivered_rest_date ... Heap Fetches: 0"
--
--    Heap Fetches only reaches 0 once the visibility map is set, i.e. after
--    VACUUM (ANALYZE) orders. The seeder runs that as its final step.
-- -------------------------------------------------------------------------------------
CREATE INDEX idx_orders_delivered_rest_date
    ON orders (restaurant_id, created_at)
    INCLUDE (total_amount)
    WHERE status = 'DELIVERED';

COMMENT ON INDEX idx_orders_delivered_rest_date IS
    'Partial covering index, restaurant-leading. Serves the MV and per-vendor drilldown.';


-- -------------------------------------------------------------------------------------
-- 2b. THE SAME COLUMNS, THE OTHER WAY ROUND  (partial COVERING index, date-leading)
--
--    Key columns  : (created_at, restaurant_id)
--    Payload      : INCLUDE (total_amount)
--    Predicate    : WHERE status = 'DELIVERED'
--
--    WHY TWO NEAR-IDENTICAL INDEXES - the obvious viva challenge, and it has a real answer.
--    A composite B-tree can only range-scan on its LEADING column. The two access patterns
--    in this schema lead with different columns:
--
--      Workflow 2  "every restaurant, but only the last 90 days"
--                  -> ranges over created_at, no restaurant predicate at all
--                  -> needs created_at FIRST, giving  Index Cond: (created_at >= ...)
--
--      MV / drilldown  "this restaurant, over its whole history"
--                  -> equality on restaurant_id, then ordering by date
--                  -> needs restaurant_id FIRST
--
--    Given only 2a, Workflow 2 can still manage an Index Only Scan, but it must walk the
--    ENTIRE index and filter created_at row by row - no Index Cond, no early termination.
--    The write cost of the second index is two extra leaf updates per insert; orders is
--    append-mostly and read-heavy, so that trade is clearly worth it.
-- -------------------------------------------------------------------------------------
CREATE INDEX idx_orders_delivered_date_rest
    ON orders (created_at, restaurant_id)
    INCLUDE (total_amount)
    WHERE status = 'DELIVERED';

COMMENT ON INDEX idx_orders_delivered_date_rest IS
    'Partial covering index, date-leading. Target for Workflow 2: Index Only Scan + Index Cond on created_at.';


-- -------------------------------------------------------------------------------------
-- 3. Per-user order history: "show me my recent orders", newest first.
--    DESC matches the query direction so no extra sort node is needed.
-- -------------------------------------------------------------------------------------
CREATE INDEX idx_orders_user_created
    ON orders (user_id, created_at DESC);


-- -------------------------------------------------------------------------------------
-- 4. Per-user ledger replay: "show me this wallet's history", newest first.
--    The quoted "timestamp" is the brief's column name.
-- -------------------------------------------------------------------------------------
CREATE INDEX idx_audit_user_ts
    ON wallet_audit_logs (user_id, "timestamp" DESC);


-- -------------------------------------------------------------------------------------
-- 5. Active-vendor scoping for the materialized view refresh.
--    A second partial index, on a boolean predicate this time.
-- -------------------------------------------------------------------------------------
CREATE INDEX idx_restaurants_active
    ON restaurants (id)
    WHERE is_active;


-- -------------------------------------------------------------------------------------
-- CONSIDERED AND DELIBERATELY NOT CREATED  (viva material)
--
--   BRIN on orders(created_at):
--     CREATE INDEX brin_orders_created ON orders USING BRIN (created_at)
--         WITH (pages_per_range = 32);
--     BRIN stores only min/max per block range, so it is roughly 1/1000th the size of the
--     equivalent B-tree and is excellent for naturally time-ordered append-only data.
--     Not created here because orders.created_at is randomised across 180 days by the
--     seeder, which destroys the physical/logical correlation BRIN depends on, and
--     because a second index on created_at would add planner noise to the Workflow 2
--     proof we are trying to demonstrate.
--
--   CREATE INDEX CONCURRENTLY:
--     The production choice - it does not take an ACCESS EXCLUSIVE lock, so writes keep
--     working while the index builds. Not used here because it cannot run inside a
--     transaction block, and because this file is executed against an offline database
--     during setup where the lock costs nothing.
--
--   GIN on a tsvector of restaurants.name:
--     Only worth it once free-text vendor search exists. It does not.
-- -------------------------------------------------------------------------------------

\echo '--- indexes created: 6 (4 partial, 2 covering, 1 unique-partial)'
