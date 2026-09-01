-- =====================================================================================
-- BiteStream :: 04_stored_procedures.sql
-- WORKFLOW 1 - ATOMIC CHECKOUT
--
-- PURPOSE
--   sp_execute_checkout(): a single, self-contained, transaction-controlling procedure
--   that debits a wallet and creates an order, atomically, under REPEATABLE READ, and
--   rolls back cleanly on every failure mode.
--
-- POSITION IN THE BUILD ORDER
--   Step F - after 01 (CHECK constraints), 02 (partial unique index) and 03 (trigger),
--   because each of those is a failure mode the procedure is required to catch. Written
--   before the seeder finishes is fine; TESTED only once they all exist.
--
-- IDEMPOTENT
--   Yes. CREATE OR REPLACE, plus a guarded CREATE TABLE for the attempt log.
--
-- RUN
--   psql "$PGURL" -v ON_ERROR_STOP=1 -f sql/04_stored_procedures.sql
-- =====================================================================================

\echo '=== 04_stored_procedures.sql : Workflow 1, atomic checkout ==='

-- -------------------------------------------------------------------------------------
-- checkout_attempts - an extension beyond the brief's four tables, and a deliberate one.
--
-- It exists to demonstrate a specific transactional fact: anything written INSIDE the
-- failed transaction is destroyed by the ROLLBACK. A failure log that is to survive must
-- therefore be written AFTER the ROLLBACK, in the next transaction. The procedure does
-- exactly that, and this table is where it lands.
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS checkout_attempts (
    id            BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       BIGINT,
    restaurant_id BIGINT,
    amount        NUMERIC(10,2),
    outcome       VARCHAR(32) NOT NULL,
    sqlstate_code VARCHAR(5),
    order_id      BIGINT,
    attempted_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE checkout_attempts IS
    'Durable outcome log. Written after COMMIT/ROLLBACK so failures survive their own rollback.';


-- =====================================================================================
-- sp_execute_checkout
--
-- SIGNATURE
--   p_user_id       IN     the paying customer
--   p_restaurant_id IN     the vendor
--   p_amount        IN     order total; debited from the wallet
--   p_order_id      INOUT  the new orders.id on success, NULL on failure
--   p_status        INOUT  machine-readable outcome (see the table below)
--
-- OUTCOMES
--   OK                        order created, wallet debited, ledger row written
--   INSUFFICIENT_FUNDS        ck_users_wallet_non_negative rejected the debit  (23514)
--   ACTIVE_ORDER_EXISTS       idx_active_user_order rejected a 2nd live order  (23505)
--   BAD_REFERENCE             restaurant_id (or user_id) does not exist        (23503)
--   AMOUNT_INVALID            amount is NULL, zero or negative                 (22023)
--   USER_NOT_FOUND            no such user
--   RETRY                     concurrent update under REPEATABLE READ          (40001)
--   ERROR:<message>           anything else
--
-- ---------------------------------------------------------------------------------
-- WHY A PROCEDURE AND NOT A FUNCTION
--   A FUNCTION body executes INSIDE the caller's transaction and cannot issue COMMIT or
--   ROLLBACK. Only a PROCEDURE (PostgreSQL 11+) invoked with CALL can control the
--   transaction - and only when that CALL is not already nested inside a client-side
--   BEGIN. The brief demands COMMIT and ROLLBACK, so PROCEDURE is forced.
--
--   => Call it from autocommit (plain psql, no explicit BEGIN):
--          CALL sp_execute_checkout(1, 1, 250.00, NULL, NULL);
--      Calling it inside BEGIN ... COMMIT raises 2D000
--      "invalid transaction termination".
--
-- WHY THE STRUCTURE LOOKS LIKE THIS  (the single most important detail in the file)
--   PL/pgSQL implements  BEGIN ... EXCEPTION WHEN ... END  as an internal SUBTRANSACTION,
--   and transaction control is illegal while a subtransaction is active. Putting COMMIT
--   inside the block that also has the EXCEPTION handler fails at RUNTIME with
--       ERROR: cannot commit while a subtransaction is active
--   So the work is split:
--       outer block  -> owns COMMIT / ROLLBACK / SET TRANSACTION   (no handler in scope)
--       inner block  -> owns the EXCEPTION handlers                (no txn control)
--   Once the inner block exits, its subtransaction is closed and the outer block is free
--   to end the transaction.
--
-- WHY THE LEADING COMMIT
--   SET TRANSACTION ISOLATION LEVEL must be the first statement of its transaction, and
--   CALL has already opened one implicitly. The leading COMMIT closes that empty
--   transaction so the isolation level can be set on the fresh one.
--
-- WHY REPEATABLE READ
--   READ COMMITTED takes a new snapshot per statement, so a value re-read inside the
--   transaction can change underneath it. REPEATABLE READ pins one snapshot for the whole
--   transaction. The price is that two concurrent checkouts against the SAME user make one
--   of them fail with 40001 "could not serialize access due to concurrent update" - the
--   caller must retry. The alternative design is READ COMMITTED plus
--   SELECT ... FOR UPDATE, which blocks instead of erroring.
--
-- WHY DEBIT BEFORE INSERT
--   The CHECK constraint rejects an unaffordable order before any order row is created:
--   fail fast, and it mirrors a real payment flow. The wallet UPDATE is also what fires
--   trg_wallet_audit, so the ledger row is written as part of the same atomic unit.
--
-- NOTE ON THE BRIEF'S WORDING
--   The brief says the order INSERT "triggers the audit log". It does not: trg_wallet_audit
--   is an AFTER UPDATE trigger on users, so it is the wallet DEBIT that fires it. Recorded
--   in README.md under Assumptions.
--
-- READ-MODIFY-WRITE SAFETY
--   The debit is expressed as a single statement,
--       SET wallet_balance = wallet_balance - p_amount
--   which takes a row lock and, under REPEATABLE READ, raises 40001 rather than losing an
--   update. Never SELECT the balance and write back a value computed in the application.
-- =====================================================================================
CREATE OR REPLACE PROCEDURE sp_execute_checkout(
    IN    p_user_id       BIGINT,
    IN    p_restaurant_id BIGINT,
    IN    p_amount        NUMERIC(10,2),
    INOUT p_order_id      BIGINT DEFAULT NULL,
    INOUT p_status        TEXT   DEFAULT NULL
)
LANGUAGE plpgsql
AS $sp$
DECLARE
    v_failed  BOOLEAN := FALSE;
    v_sqlstate VARCHAR(5) := NULL;
BEGIN
    -- ---- transaction setup (outer block: no EXCEPTION handler is in scope here) ------
    COMMIT;                                            -- close the implicit txn CALL opened
    SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;   -- must be the txn's first statement

    p_order_id := NULL;

    -- ---- the unit of work (inner block: a subtransaction, so NO txn control here) ----
    BEGIN
        IF p_amount IS NULL OR p_amount <= 0 THEN
            RAISE EXCEPTION 'amount must be a positive value, got %', p_amount
                USING ERRCODE = '22023';               -- invalid_parameter_value
        END IF;

        -- Debit. ck_users_wallet_non_negative fires here on an unaffordable order.
        -- trg_wallet_audit fires here on success, writing the DEBIT ledger row.
        UPDATE users
           SET wallet_balance = wallet_balance - p_amount
         WHERE id = p_user_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'no such user: %', p_user_id
                USING ERRCODE = 'P0002';               -- no_data_found
        END IF;

        -- Create the order. idx_active_user_order fires here if the user already has a
        -- PREPARING/DELIVERING order; fk_orders_restaurant fires on a bad vendor id.
        INSERT INTO orders (user_id, restaurant_id, total_amount, status)
        VALUES (p_user_id, p_restaurant_id, p_amount, 'PREPARING')
        RETURNING id INTO p_order_id;

        p_status := 'OK';

    EXCEPTION
        WHEN check_violation THEN
            v_failed := TRUE; v_sqlstate := SQLSTATE;
            -- Distinguish the wallet floor from any other CHECK on the path.
            p_status := CASE WHEN SQLERRM LIKE '%ck_users_wallet_non_negative%'
                             THEN 'INSUFFICIENT_FUNDS' ELSE 'CHECK_FAILED' END;

        WHEN unique_violation THEN
            v_failed := TRUE; v_sqlstate := SQLSTATE; p_status := 'ACTIVE_ORDER_EXISTS';

        WHEN foreign_key_violation THEN
            v_failed := TRUE; v_sqlstate := SQLSTATE; p_status := 'BAD_REFERENCE';

        WHEN serialization_failure THEN
            v_failed := TRUE; v_sqlstate := SQLSTATE; p_status := 'RETRY';

        WHEN invalid_parameter_value THEN
            v_failed := TRUE; v_sqlstate := SQLSTATE; p_status := 'AMOUNT_INVALID';

        WHEN no_data_found THEN
            v_failed := TRUE; v_sqlstate := SQLSTATE; p_status := 'USER_NOT_FOUND';

        WHEN OTHERS THEN
            v_failed := TRUE; v_sqlstate := SQLSTATE; p_status := 'ERROR:' || SQLERRM;
    END;
    -- ---- inner subtransaction has now closed; txn control is legal again -------------

    IF v_failed THEN
        p_order_id := NULL;
        ROLLBACK;      -- discards the debit, the order AND the trigger's ledger row
    ELSE
        COMMIT;
    END IF;

    -- Written in the NEW transaction that ROLLBACK/COMMIT started, which is the only
    -- reason it survives a failed checkout. Anything logged before the ROLLBACK would
    -- have been rolled back along with the failure it was describing.
    INSERT INTO checkout_attempts (user_id, restaurant_id, amount, outcome, sqlstate_code, order_id)
    VALUES (p_user_id, p_restaurant_id, p_amount, p_status, v_sqlstate, p_order_id);
    COMMIT;
END;
$sp$;

COMMENT ON PROCEDURE sp_execute_checkout(BIGINT, BIGINT, NUMERIC, BIGINT, TEXT) IS
    'Workflow 1. REPEATABLE READ debit-and-order. Returns p_status; never leaves partial state.';


-- =====================================================================================
-- sp_advance_order_status - small companion used by the seeder and the demo.
--   PREPARING -> DELIVERING -> DELIVERED, setting delivered_at on the final hop so that
--   ck_orders_delivered_has_timestamp is satisfied. Moving an order OUT of the two active
--   states is also what frees the user's slot in idx_active_user_order.
-- =====================================================================================
CREATE OR REPLACE PROCEDURE sp_advance_order_status(IN p_order_id BIGINT)
LANGUAGE plpgsql
AS $sp$
DECLARE v_status VARCHAR(12);
BEGIN
    SELECT status INTO v_status FROM orders WHERE id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no such order: %', p_order_id USING ERRCODE = 'P0002';
    END IF;

    IF v_status = 'PREPARING' THEN
        UPDATE orders SET status = 'DELIVERING' WHERE id = p_order_id;
    ELSIF v_status = 'DELIVERING' THEN
        UPDATE orders SET status = 'DELIVERED', delivered_at = now() WHERE id = p_order_id;
    END IF;   -- DELIVERED is terminal: no-op
END;
$sp$;

\echo '--- procedures created: sp_execute_checkout, sp_advance_order_status'
