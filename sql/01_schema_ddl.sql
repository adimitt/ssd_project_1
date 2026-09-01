-- =====================================================================================
-- BiteStream :: 01_schema_ddl.sql
-- CS6.302 Software System Development - Assignment 1 - Project 1
--
-- PURPOSE
--   Creates the entire PostgreSQL relational schema: 4 tables, their data types,
--   primary keys, foreign keys and every CHECK constraint.
--
-- POSITION IN THE BUILD ORDER
--   Step B - runs first, immediately after the server is provisioned.
--   Nothing else in sql/ can run until this file has succeeded.
--
-- IDEMPOTENT
--   Yes. Drops all four tables (CASCADE) before recreating them, so the file can be
--   re-run any number of times on a dirty database.
--
-- RUN
--   psql "$PGURL" -v ON_ERROR_STOP=1 -f sql/01_schema_ddl.sql
-- =====================================================================================

\echo '=== 01_schema_ddl.sql : building relational schema ==='

-- -------------------------------------------------------------------------------------
-- 0. Clean slate.
--    Order does not matter because of CASCADE, but we drop children first anyway so the
--    intent stays readable.
-- -------------------------------------------------------------------------------------
DROP TABLE IF EXISTS orders             CASCADE;
DROP TABLE IF EXISTS wallet_audit_logs  CASCADE;
DROP TABLE IF EXISTS restaurants        CASCADE;
DROP TABLE IF EXISTS users              CASCADE;


-- -------------------------------------------------------------------------------------
-- 1. users
--
--    DESIGN NOTE (primary key): BIGINT GENERATED ALWAYS AS IDENTITY, not UUID.
--    The brief allows either. A random UUIDv4 primary key destroys B-tree insert
--    locality - every insert lands in a random leaf page, causing page splits, WAL
--    bloat and cache misses - and widens every foreign key from 8 bytes to 16. At the
--    300k-order scale this schema is seeded to, that is measurable. UUIDv7 / ULID would
--    restore time-ordering if a globally unique, externally safe key were required.
--
--    DESIGN NOTE (money): NUMERIC(10,2), never FLOAT / DOUBLE PRECISION. Binary floating
--    point cannot represent 0.10 exactly and the error compounds across a ledger.
--    NUMERIC(10,2) is exact decimal arithmetic, capped at 99,999,999.99.
--
--    GENERATED ALWAYS (not BY DEFAULT) means an INSERT cannot supply its own id without
--    the explicit OVERRIDING SYSTEM VALUE escape hatch. The seeder therefore COPYs only
--    the non-identity columns and lets Postgres assign 1..N in insertion order.
-- -------------------------------------------------------------------------------------
CREATE TABLE users (
    id              BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            VARCHAR(120)  NOT NULL,
    email           VARCHAR(160),
    wallet_balance  NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),

    -- The rubric's headline CHECK constraint. This is the LAST line of defence:
    -- sp_execute_checkout also validates the balance, but this constraint is what makes
    -- a negative wallet physically impossible no matter who writes to the table.
    CONSTRAINT ck_users_wallet_non_negative CHECK (wallet_balance >= 0.00),
    CONSTRAINT ck_users_name_not_blank      CHECK (length(btrim(name)) > 0)
);

COMMENT ON TABLE  users                IS 'BiteStream customers and their prepaid wallet balance.';
COMMENT ON COLUMN users.wallet_balance IS 'Exact decimal balance. CHECK >= 0 makes overdraft impossible at the storage layer.';


-- -------------------------------------------------------------------------------------
-- 2. wallet_audit_logs  -- the immutable ledger
--
--    Every row here is written by trg_wallet_audit (see 03_triggers_and_audit.sql).
--    Nothing inserts into this table directly, and 03 additionally revokes UPDATE/DELETE
--    and installs a guard trigger so rows cannot be altered after the fact.
--
--    DESIGN NOTE (FK action): ON DELETE RESTRICT, not CASCADE. An audit trail you can
--    erase by deleting the user is not an audit trail.
--
--    DESIGN NOTE (column name): "timestamp" is spelled by the brief. It is a
--    non-reserved keyword in PostgreSQL, so it is legal as a column name, but it is also
--    a type name - quoting it everywhere ("timestamp") removes all parser ambiguity.
-- -------------------------------------------------------------------------------------
CREATE TABLE wallet_audit_logs (
    id              BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         BIGINT        NOT NULL,
    amount_changed  NUMERIC(10,2) NOT NULL,
    action_type     VARCHAR(6)    NOT NULL,
    balance_after   NUMERIC(10,2) NOT NULL,
    "timestamp"     TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT fk_audit_user
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT,

    -- A no-op wallet write must never produce a ledger row. The trigger's WHEN clause
    -- prevents it; this constraint proves it.
    CONSTRAINT ck_audit_amount_non_zero  CHECK (amount_changed <> 0),

    CONSTRAINT ck_audit_action_type      CHECK (action_type IN ('DEBIT','CREDIT')),

    -- The balance recorded in the ledger is subject to the same floor as the live column.
    CONSTRAINT ck_audit_balance_after    CHECK (balance_after >= 0.00),

    -- Multi-column CHECK: makes the DEBIT/CREDIT label impossible to falsify. A CREDIT
    -- row must carry a positive delta, a DEBIT row a negative one. Without this, a
    -- caller could log a DEBIT of +500.
    CONSTRAINT ck_audit_sign_matches_action CHECK (
        (action_type = 'CREDIT' AND amount_changed > 0) OR
        (action_type = 'DEBIT'  AND amount_changed < 0)
    )
);

COMMENT ON TABLE  wallet_audit_logs               IS 'Append-only ledger. Written exclusively by trg_wallet_audit; UPDATE/DELETE blocked in 03.';
COMMENT ON COLUMN wallet_audit_logs.amount_changed IS 'NEW.wallet_balance - OLD.wallet_balance. Signed: positive = CREDIT, negative = DEBIT.';
COMMENT ON COLUMN wallet_audit_logs.balance_after  IS 'NEW.wallet_balance, i.e. the balance once the change had been applied.';


-- -------------------------------------------------------------------------------------
-- 3. restaurants
--
--    DESIGN NOTE (coordinates): DOUBLE PRECISION is correct here, unlike money. We want
--    geographic precision, not exact decimal arithmetic. The range CHECKs are cheap and
--    they stop the seeder from ever writing a coordinate that MongoDB's 2dsphere index
--    would later reject at index-build time.
--
--    Geospatial querying itself lives in MongoDB (DriverPings); this table only supplies
--    the origin point for the Workflow 3 $geoNear query. PostGIS would duplicate that
--    capability and is deliberately out of scope.
-- -------------------------------------------------------------------------------------
CREATE TABLE restaurants (
    id         BIGINT           GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       VARCHAR(160)     NOT NULL,
    city       VARCHAR(80)      NOT NULL,
    latitude   DOUBLE PRECISION NOT NULL,
    longitude  DOUBLE PRECISION NOT NULL,
    is_active  BOOLEAN          NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ      NOT NULL DEFAULT now(),

    CONSTRAINT ck_rest_latitude  CHECK (latitude  BETWEEN  -90 AND  90),
    CONSTRAINT ck_rest_longitude CHECK (longitude BETWEEN -180 AND 180)
);

COMMENT ON TABLE restaurants IS 'Vendor list. latitude/longitude are the origin for the MongoDB $geoNear driver search.';


-- -------------------------------------------------------------------------------------
-- 4. orders
--
--    DESIGN NOTE (status): VARCHAR + CHECK, as the brief specifies. The three candidates
--    were:
--      * CHECK  - trivial to ALTER, but altering re-validates the whole table.
--      * ENUM   - compact and type-safe, but ALTER TYPE ... ADD VALUE historically could
--                 not run inside a transaction block.
--      * lookup table - most flexible, but adds a join to every query.
--    For a closed three-value set on a VARCHAR column, CHECK is the right answer.
--
--    DESIGN NOTE (state coherence): ck_orders_delivered_has_timestamp ties the status
--    machine to the clock - a row cannot claim DELIVERED without recording when.
--
--    The "one active order per user" rule is NOT here. It cannot be expressed as a table
--    constraint because it is conditional; it is a partial UNIQUE INDEX, created in
--    02_indexes.sql.
-- -------------------------------------------------------------------------------------
CREATE TABLE orders (
    id            BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       BIGINT        NOT NULL,
    restaurant_id BIGINT        NOT NULL,
    total_amount  NUMERIC(10,2) NOT NULL,
    status        VARCHAR(12)   NOT NULL,
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    delivered_at  TIMESTAMPTZ,

    CONSTRAINT fk_orders_user       FOREIGN KEY (user_id)       REFERENCES users(id),
    CONSTRAINT fk_orders_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurants(id),

    CONSTRAINT ck_orders_amount_positive CHECK (total_amount > 0),
    CONSTRAINT ck_orders_status          CHECK (status IN ('PREPARING','DELIVERING','DELIVERED')),
    CONSTRAINT ck_orders_delivered_has_timestamp
        CHECK (status <> 'DELIVERED' OR delivered_at IS NOT NULL),
    CONSTRAINT ck_orders_delivered_after_created
        CHECK (delivered_at IS NULL OR delivered_at >= created_at)
);

COMMENT ON TABLE  orders        IS 'Order state machine: PREPARING -> DELIVERING -> DELIVERED.';
COMMENT ON COLUMN orders.status IS 'PREPARING and DELIVERING are the two ACTIVE states policed by idx_active_user_order.';

\echo '--- schema created: users, wallet_audit_logs, restaurants, orders'
