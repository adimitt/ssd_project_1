-- =====================================================================================
-- BiteStream :: 05_materialized_views.sql
--
-- PURPOSE
--   mv_restaurant_performance: a physical snapshot joining restaurants to their lifetime
--   completed-order count and revenue, plus the REFRESH CONCURRENTLY wrapper the brief
--   asks for.
--
-- POSITION IN THE BUILD ORDER
--   Step G - after the seeder, so the view has something to summarise. Creating it on an
--   empty database also works; it is simply empty.
--
-- IDEMPOTENT
--   Yes. DROP MATERIALIZED VIEW IF EXISTS ... CASCADE.
--
-- RUN
--   psql "$PGURL" -v ON_ERROR_STOP=1 -f sql/05_materialized_views.sql
-- =====================================================================================

\echo '=== 05_materialized_views.sql : restaurant performance MV ==='

DROP MATERIALIZED VIEW IF EXISTS mv_restaurant_performance CASCADE;

-- -------------------------------------------------------------------------------------
-- mv_restaurant_performance
--
-- WHY LEFT JOIN, NOT INNER JOIN
--   A restaurant with zero delivered orders must still appear, with 0 revenue. An INNER
--   JOIN silently drops it, which quietly corrupts any ranking or "worst performers"
--   report built on top of this view.
--
-- WHY THE STATUS TEST IS IN THE  ON  CLAUSE AND NOT  WHERE
--   In a LEFT JOIN, a WHERE predicate on the right-hand table is evaluated AFTER the join
--   has manufactured NULL rows - and  NULL = 'DELIVERED'  is NULL, i.e. false - so the
--   zero-order restaurants are filtered straight back out. Putting the predicate in ON
--   restricts which rows are eligible to join while preserving the outer side. This is a
--   standard exam question; the LEFT JOIN above is only correct because of it.
--
-- WHY COALESCE
--   SUM() and AVG() over zero rows return NULL, not 0. Callers ordering by total_revenue
--   would then sort NULLs first (DESC) unless every query remembered NULLS LAST. Fixing
--   it once, here, is better than fixing it in every consumer.
-- -------------------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_restaurant_performance AS
SELECT
    r.id                                             AS restaurant_id,
    r.name,
    r.city,
    r.is_active,
    COUNT(o.id)                                      AS completed_orders,
    COALESCE(SUM(o.total_amount), 0)::NUMERIC(14,2)  AS total_revenue,
    COALESCE(AVG(o.total_amount), 0)::NUMERIC(10,2)  AS avg_order_value,
    MAX(o.created_at)                                AS last_order_at
FROM restaurants r
LEFT JOIN orders o
       ON o.restaurant_id = r.id
      AND o.status = 'DELIVERED'          -- in ON, deliberately: see note above
GROUP BY r.id, r.name, r.city, r.is_active
WITH DATA;                                -- populated immediately; required for CONCURRENTLY

COMMENT ON MATERIALIZED VIEW mv_restaurant_performance IS
    'Snapshot of lifetime delivered-order count and revenue per restaurant. Refresh via sp_refresh_restaurant_performance().';


-- -------------------------------------------------------------------------------------
-- THE UNIQUE INDEX IS MANDATORY, NOT OPTIONAL
--
--   REFRESH MATERIALIZED VIEW CONCURRENTLY works by building the new contents into a
--   temporary table and then applying the DIFFERENCE to the existing view. To diff two
--   sets it needs a key that identifies a row in both. Without one:
--       ERROR: cannot refresh materialized view "..." concurrently
--       HINT:  Create a unique index with no WHERE clause on one or more columns.
--
--   Note "with no WHERE clause": a PARTIAL unique index does not satisfy this requirement.
-- -------------------------------------------------------------------------------------
CREATE UNIQUE INDEX ux_mv_rest_perf ON mv_restaurant_performance (restaurant_id);

-- Supporting index for the usual access pattern: the revenue leaderboard.
CREATE INDEX idx_mv_rest_perf_revenue ON mv_restaurant_performance (total_revenue DESC);


-- -------------------------------------------------------------------------------------
-- sp_refresh_restaurant_performance()
--
--   PLAIN REFRESH vs CONCURRENTLY
--     REFRESH MATERIALIZED VIEW              takes ACCESS EXCLUSIVE on the view. Every
--                                            reader blocks for the entire rebuild.
--     REFRESH MATERIALIZED VIEW CONCURRENTLY takes only EXCLUSIVE. Readers keep working
--                                            throughout. It is SLOWER in total work
--                                            (build + diff + apply) and it requires the
--                                            unique index above.
--     For a dashboard that must stay queryable, CONCURRENTLY is the right trade.
--
--   TWO PRECONDITIONS, both satisfied above:
--     1. a non-partial UNIQUE index exists on the view          -> ux_mv_rest_perf
--     2. the view has already been populated at least once      -> WITH DATA
--     A view created WITH NO DATA is "unscannable" and a concurrent refresh on it fails.
--
--   WHY A PROCEDURE RATHER THAN A FUNCTION
--     A FUNCTION always runs inside the caller's transaction. A PROCEDURE called with CALL
--     from autocommit gives the refresh its own transaction, which keeps the lock window
--     as short as possible and avoids any transaction-context surprises across versions.
--
--   PRODUCTION SCHEDULING
--     pg_cron every 15 minutes. Revenue dashboards tolerate 15-minute staleness, and that
--     bounds the lock churn. Refreshing from a statement trigger on orders would rebuild
--     the entire view on every single order - the wrong answer, and a likely viva probe.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_refresh_restaurant_performance()
LANGUAGE plpgsql
AS $sp$
DECLARE
    v_started  TIMESTAMPTZ := clock_timestamp();
    v_rows     BIGINT;
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_restaurant_performance;

    SELECT count(*) INTO v_rows FROM mv_restaurant_performance;
    RAISE NOTICE 'mv_restaurant_performance refreshed CONCURRENTLY: % rows in %',
                 v_rows, (clock_timestamp() - v_started);
END;
$sp$;

COMMENT ON PROCEDURE sp_refresh_restaurant_performance() IS
    'REFRESH MATERIALIZED VIEW CONCURRENTLY wrapper. Call from autocommit: CALL sp_refresh_restaurant_performance();';

\echo '--- mv_restaurant_performance + ux_mv_rest_perf + refresh procedure created'
