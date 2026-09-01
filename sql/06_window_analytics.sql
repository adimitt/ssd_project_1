-- =====================================================================================
-- BiteStream :: 06_window_analytics.sql
-- WORKFLOW 2 - SQL WINDOW ANALYTICS
--
-- PURPOSE
--   CTEs + window functions over the orders table:
--     Q1  the 7-day moving average of revenue per restaurant, ranked with DENSE_RANK()
--     Q2  the same series over time for the current top vendors (shows the MA evolving)
--     Q3  week-over-week momentum with LAG(), plus NTILE() bucketing
--   Q1 is the "heaviest query" whose EXPLAIN (ANALYZE) is captured in performance/.
--
-- POSITION IN THE BUILD ORDER
--   Step H - needs seeded data AND idx_orders_delivered_date_rest to produce the
--   Index Only Scan the performance section depends on.
--
-- IDEMPOTENT
--   Yes - it is read-only.
--
-- RUN
--   psql "$PGURL" -f sql/06_window_analytics.sql
-- =====================================================================================

\echo '=== 06_window_analytics.sql : Workflow 2, window analytics ==='

-- =====================================================================================
-- Q1 - HEADLINE: 7-day moving average revenue per restaurant + DENSE_RANK leaderboard
--
-- PIPELINE
--   daily     collapse ~300k order rows to one row per (restaurant, calendar day)
--   calendar  the complete grid of (restaurant x every day in the window)
--   filled    daily LEFT JOINed onto calendar, so a day with no orders becomes 0
--   windowed  the window functions themselves
--   final     take one day's slice and rank it
--
-- WHY THE GAP FILL EXISTS
--   Without it, a restaurant that sold nothing on Tuesday simply has no Tuesday row. A
--   frame of "the previous 6 ROWS" would then silently reach back 8+ calendar days, and
--   the average would be divided by the wrong denominator. Gap filling makes the series
--   dense, so ROWS and RANGE agree; the query uses RANGE regardless, belt and braces.
--
-- WHY DATE LITERALS AND NOT A params CTE
--   A non-recursive CTE referenced more than once is MATERIALIZED by PostgreSQL 12+ and
--   becomes an optimisation fence: the planner can no longer see the constant, so it
--   cannot use it as an index bound and falls back to a sequential scan. Inlining
--   CURRENT_DATE keeps the predicate visible at plan time. This single detail is the
--   difference between an Index Only Scan and a Seq Scan here.
-- =====================================================================================
\echo ''
\echo '--- Q1: top 20 restaurants by 7-day moving average revenue (latest complete day)'

WITH daily AS (
    -- One row per restaurant per day. The WHERE clause is what the partial covering
    -- index idx_orders_delivered_date_rest is built to serve.
    SELECT
        o.restaurant_id,
        o.created_at::date        AS d,
        SUM(o.total_amount)       AS revenue,
        COUNT(*)                  AS order_count
    FROM orders o
    WHERE o.status = 'DELIVERED'
      AND o.created_at >= CURRENT_DATE - INTERVAL '90 days'
      AND o.created_at <  CURRENT_DATE + INTERVAL '1 day'
    GROUP BY o.restaurant_id, o.created_at::date
),
calendar AS (
    -- Cartesian product of "restaurants that traded in the window" x "every day".
    SELECT dr.restaurant_id, gs::date AS d
    FROM (SELECT DISTINCT restaurant_id FROM daily) dr
    CROSS JOIN LATERAL generate_series(
        CURRENT_DATE - INTERVAL '90 days',
        CURRENT_DATE,
        INTERVAL '1 day'
    ) AS gs
),
filled AS (
    SELECT
        c.restaurant_id,
        c.d,
        COALESCE(dl.revenue, 0)     AS revenue,
        COALESCE(dl.order_count, 0) AS order_count
    FROM calendar c
    LEFT JOIN daily dl
           ON dl.restaurant_id = c.restaurant_id
          AND dl.d             = c.d
),
windowed AS (
    SELECT
        f.restaurant_id,
        f.d,
        f.revenue,
        f.order_count,

        -- THE 7-DAY MOVING AVERAGE.
        -- RANGE ... INTERVAL '6 days' PRECEDING is CALENDAR-based: it means "every row
        -- whose d lies within 6 days before this one", which is the definition of a
        -- 7-day window. ROWS BETWEEN 6 PRECEDING would instead mean "the previous six
        -- rows", which is only equivalent when the series has no gaps.
        -- (The third form, GROUPS, counts distinct peer groups rather than rows.)
        AVG(f.revenue)      OVER w7 AS ma7_revenue,
        SUM(f.order_count)  OVER w7 AS orders_last_7d,

        -- Cumulative revenue since the start of the window: an unbounded frame.
        SUM(f.revenue) OVER (PARTITION BY f.restaurant_id ORDER BY f.d
                             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                    AS running_total,

        -- Same weekday, one week earlier. Because the series is gap-filled, an offset of
        -- exactly 7 rows is exactly 7 days.
        LAG(f.revenue, 7)  OVER (PARTITION BY f.restaurant_id ORDER BY f.d)
                                    AS revenue_same_day_last_week
    FROM filled f
    -- A named window, declared once and referenced twice above. Beyond readability, it
    -- lets the planner satisfy both aggregates from a single WindowAgg node.
    WINDOW w7 AS (
        PARTITION BY f.restaurant_id
        ORDER BY f.d
        RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW
    )
)
SELECT
    w.d                              AS business_date,
    w.restaurant_id,
    r.name                           AS restaurant,
    r.city,
    w.revenue                        AS revenue_today,
    ROUND(w.ma7_revenue, 2)          AS ma7_revenue,
    w.orders_last_7d,

    -- DENSE_RANK, as the brief specifies.
    --   DENSE_RANK -> 1,2,2,3   ranks are consecutive; ties share a rank, nothing skipped
    --   RANK       -> 1,2,2,4   ties share a rank and the next rank is skipped
    --   ROW_NUMBER -> 1,2,3,4   ties broken arbitrarily and non-deterministically
    -- A leaderboard should not jump from 2nd to 4th because two venues tied, so
    -- DENSE_RANK is the correct choice here.
    DENSE_RANK()   OVER (PARTITION BY w.d ORDER BY w.ma7_revenue DESC) AS rank_by_ma7,
    RANK()         OVER (PARTITION BY w.d ORDER BY w.ma7_revenue DESC) AS rank_gapped,
    ROUND((PERCENT_RANK() OVER (PARTITION BY w.d ORDER BY w.ma7_revenue))::numeric, 4)
                                                                      AS pct_rank
FROM windowed w
JOIN restaurants r ON r.id = w.restaurant_id
-- The latest COMPLETE day: today is still accumulating orders, so ranking it is misleading.
WHERE w.d = CURRENT_DATE - 1
ORDER BY rank_by_ma7, w.restaurant_id
LIMIT 20;


-- =====================================================================================
-- Q2 - the moving average as a time series, for the current top 5 vendors.
--      Demonstrates that ma7_revenue really is a smoothed trailing mean rather than a
--      single scalar, and gives the viva something to point at.
-- =====================================================================================
\echo ''
\echo '--- Q2: last 14 days of the 7-day moving average, top 5 vendors'

WITH daily AS (
    SELECT o.restaurant_id, o.created_at::date AS d, SUM(o.total_amount) AS revenue
    FROM orders o
    WHERE o.status = 'DELIVERED'
      AND o.created_at >= CURRENT_DATE - INTERVAL '90 days'
      AND o.created_at <  CURRENT_DATE + INTERVAL '1 day'
    GROUP BY 1, 2
),
top5 AS (
    SELECT restaurant_id
    FROM daily
    GROUP BY restaurant_id
    ORDER BY SUM(revenue) DESC
    LIMIT 5
),
calendar AS (
    SELECT t.restaurant_id, gs::date AS d
    FROM top5 t
    CROSS JOIN LATERAL generate_series(CURRENT_DATE - INTERVAL '90 days',
                                       CURRENT_DATE, INTERVAL '1 day') gs
),
filled AS (
    SELECT c.restaurant_id, c.d, COALESCE(dl.revenue, 0) AS revenue
    FROM calendar c
    LEFT JOIN daily dl ON dl.restaurant_id = c.restaurant_id AND dl.d = c.d
)
SELECT
    f.d AS business_date,
    r.name AS restaurant,
    f.revenue AS revenue_today,
    ROUND(AVG(f.revenue) OVER (PARTITION BY f.restaurant_id ORDER BY f.d
                               RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW), 2)
        AS ma7_revenue
FROM filled f
JOIN restaurants r ON r.id = f.restaurant_id
WHERE f.d > CURRENT_DATE - 15
ORDER BY r.name, f.d;


-- =====================================================================================
-- Q3 - week-over-week momentum.
--      Uses LAG over a weekly grain plus NTILE to bucket vendors into quartiles.
--      Note the extra CTE: a window function cannot be referenced in the WHERE of the
--      SELECT that computes it, because window functions are evaluated AFTER WHERE and
--      GROUP BY but BEFORE ORDER BY and LIMIT. Filtering on one always needs a wrapper.
-- =====================================================================================
\echo ''
\echo '--- Q3: week-over-week revenue momentum, best and worst movers'

WITH weekly AS (
    SELECT
        o.restaurant_id,
        date_trunc('week', o.created_at)::date AS week_start,
        SUM(o.total_amount)                    AS revenue
    FROM orders o
    WHERE o.status = 'DELIVERED'
      AND o.created_at >= CURRENT_DATE - INTERVAL '90 days'
    GROUP BY 1, 2
),
momentum AS (
    SELECT
        w.restaurant_id,
        w.week_start,
        w.revenue,
        LAG(w.revenue) OVER (PARTITION BY w.restaurant_id ORDER BY w.week_start)
            AS prev_week_revenue,
        NTILE(4) OVER (PARTITION BY w.week_start ORDER BY w.revenue DESC)
            AS revenue_quartile
    FROM weekly w
),
scored AS (
    SELECT
        m.*,
        CASE WHEN m.prev_week_revenue IS NULL OR m.prev_week_revenue = 0 THEN NULL
             ELSE ROUND(100.0 * (m.revenue - m.prev_week_revenue) / m.prev_week_revenue, 1)
        END AS wow_pct_change
    FROM momentum m
)
SELECT s.week_start, r.name AS restaurant, s.revenue,
       s.prev_week_revenue, s.wow_pct_change, s.revenue_quartile
FROM scored s
JOIN restaurants r ON r.id = s.restaurant_id
WHERE s.week_start = (SELECT MAX(week_start) FROM weekly) - 7   -- last complete week
  AND s.wow_pct_change IS NOT NULL
ORDER BY s.wow_pct_change DESC NULLS LAST
LIMIT 10;

\echo ''
\echo '--- 06_window_analytics.sql complete (3 queries)'
