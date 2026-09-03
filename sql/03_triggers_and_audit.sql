-- =====================================================================================
-- BiteStream :: 03_triggers_and_audit.sql
--
-- PURPOSE
--   1. fn_log_wallet_change() + trg_wallet_audit
--        Automatic, tamper-proof audit logging of every wallet balance change.
--   2. fn_block_audit_mutation() + two guard triggers + REVOKE
--        Makes wallet_audit_logs genuinely append-only, which is what the brief means
--        by "an immutable record".
--
-- POSITION IN THE BUILD ORDER
--   Step C - immediately after the schema, BEFORE any data is loaded, so that every
--   audit row in the database was produced by the trigger rather than inserted directly.
--
-- IDEMPOTENT
--   Yes. CREATE OR REPLACE FUNCTION + DROP TRIGGER IF EXISTS.
--
-- RUN
--   psql "$PGURL" -v ON_ERROR_STOP=1 -f sql/03_triggers_and_audit.sql
-- =====================================================================================

\echo '=== 03_triggers_and_audit.sql : audit trigger + immutability guards ==='

-- =====================================================================================
-- PART 1 - THE AUDIT TRIGGER
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- fn_log_wallet_change()
--
--   Fires once per row whose users.wallet_balance actually changed, and writes the
--   corresponding ledger entry.
--
--   Derived values:
--     amount_changed = NEW - OLD    signed; positive is a top-up, negative a spend
--     action_type    = CREDIT when the balance rose, DEBIT when it fell
--     balance_after  = NEW.wallet_balance, i.e. the post-change balance
--
--   These satisfy ck_audit_sign_matches_action by construction: a rise always produces
--   (CREDIT, positive) and a fall always (DEBIT, negative). The WHEN clause on the
--   trigger guarantees the delta is never zero, satisfying ck_audit_amount_non_zero.
--
--   RETURN NULL is correct and idiomatic for an AFTER row trigger - the return value is
--   discarded by the executor. In a BEFORE row trigger the same statement would silently
--   CANCEL the operation, which is a classic source of bugs.
--
--   SET search_path pins schema resolution so the function cannot be hijacked by a
--   caller-supplied search_path. Cheap hardening; standard practice for trigger bodies.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_log_wallet_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $fn$
BEGIN
    INSERT INTO wallet_audit_logs (user_id, amount_changed, action_type, balance_after)
    VALUES (
        NEW.id,
        NEW.wallet_balance - OLD.wallet_balance,
        CASE WHEN NEW.wallet_balance > OLD.wallet_balance THEN 'CREDIT' ELSE 'DEBIT' END,
        NEW.wallet_balance
    );

    RETURN NULL;   -- AFTER trigger: value ignored
END;
$fn$;

COMMENT ON FUNCTION fn_log_wallet_change() IS
    'Writes one wallet_audit_logs row per changed users.wallet_balance. Fired by trg_wallet_audit.';


-- -------------------------------------------------------------------------------------
-- trg_wallet_audit
--
--   AFTER, not BEFORE
--     The ledger must only record changes that actually survived. A BEFORE trigger can be
--     followed by a CHECK violation (ck_users_wallet_non_negative) or by another BEFORE
--     trigger returning NULL, either of which would leave a log entry describing a change
--     that never happened.
--
--   UPDATE OF wallet_balance
--     Narrows the trigger to statements that MENTION that column in their SET list.
--     Critically, it still fires when the column is set to its existing value
--     (SET wallet_balance = wallet_balance) - "mentioned" is not "changed".
--
--   WHEN (OLD.wallet_balance IS DISTINCT FROM NEW.wallet_balance)
--     This is what turns "mentioned" into "changed", and it is therefore mandatory, not
--     decorative. Evaluated by the executor BEFORE the function is called, so it is
--     cheaper than an equivalent IF inside the function body - at 150k rows that matters.
--     IS DISTINCT FROM rather than <> because NULL <> NULL evaluates to NULL (falsy) and
--     would silently skip NULL-involving transitions. wallet_balance is NOT NULL so it
--     cannot bite here; it remains the correct habit.
--
--   FOR EACH ROW
--     Row-level is required: the function needs OLD and NEW per user. A statement-level
--     trigger has neither.
--
--   NO RECURSION RISK
--     The function writes to a different table. Were it to write back to users, a
--     pg_trigger_depth() guard would be needed to stop infinite recursion.
--
--   FIRING SURFACE
--     COPY     - fires row-level INSERT triggers, but this is an UPDATE trigger, so
--                COPYing into users produces ZERO audit rows. This is precisely why
--                postgres_seeder.py generates the ledger with set-based UPDATE
--                statements instead.
--     TRUNCATE - does NOT fire row-level triggers at all, only statement-level ones.
-- -------------------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_wallet_audit ON users;

CREATE TRIGGER trg_wallet_audit
    AFTER UPDATE OF wallet_balance ON users
    FOR EACH ROW
    WHEN (OLD.wallet_balance IS DISTINCT FROM NEW.wallet_balance)
    EXECUTE FUNCTION fn_log_wallet_change();


-- =====================================================================================
-- PART 2 - IMMUTABILITY
--
--   Two independent layers, because neither alone is sufficient:
--
--     Layer 1 (privileges) stops ordinary roles, but the table OWNER and any superuser
--             bypass it entirely.
--     Layer 2 (triggers)   stops everyone who is not explicitly disabling the trigger,
--             including the owner. Disabling a trigger requires ownership and is a
--             deliberate, auditable act - which is exactly the property we want.
--
--   Layer 2 is split in two because row-level triggers never see TRUNCATE.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- Layer 1: privileges
-- -------------------------------------------------------------------------------------
REVOKE UPDATE, DELETE, TRUNCATE ON wallet_audit_logs FROM PUBLIC;

-- -------------------------------------------------------------------------------------
-- Layer 2: guard triggers
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_block_audit_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $fn$
BEGIN
    RAISE EXCEPTION
        'wallet_audit_logs is append-only: % is not permitted on this table', TG_OP
        USING ERRCODE = '42501',          -- insufficient_privilege
              HINT    = 'Correct a wallet by posting a compensating balance change; the trigger will log it.';
END;
$fn$;

COMMENT ON FUNCTION fn_block_audit_mutation() IS
    'Guard body shared by the row-level and statement-level immutability triggers.';

-- Row-level guard: catches UPDATE and DELETE, including by the table owner.
DROP TRIGGER IF EXISTS trg_audit_block_row_change ON wallet_audit_logs;
CREATE TRIGGER trg_audit_block_row_change
    BEFORE UPDATE OR DELETE ON wallet_audit_logs
    FOR EACH ROW
    EXECUTE FUNCTION fn_block_audit_mutation();

-- Statement-level guard: TRUNCATE never reaches a row-level trigger, so it needs its own.
-- postgres_seeder.py must ALTER TABLE ... DISABLE TRIGGER USER to reset the database,
-- which is the intended behaviour: wiping the ledger cannot happen by accident.
DROP TRIGGER IF EXISTS trg_audit_block_truncate ON wallet_audit_logs;
CREATE TRIGGER trg_audit_block_truncate
    BEFORE TRUNCATE ON wallet_audit_logs
    FOR EACH STATEMENT
    EXECUTE FUNCTION fn_block_audit_mutation();


-- =====================================================================================
-- SELF-TEST (safe to run: every change it makes is rolled back)
--   Demonstrates, in order:
--     1. a CREDIT is logged with the correct sign and balance_after
--     2. a DEBIT is logged
--     3. a no-op write produces NO ledger row  (the WHEN clause)
--     4. UPDATE on the ledger is rejected      (the row guard)
--   The six sp_execute_checkout outcomes are exercised by hand; see README section 7.
-- =====================================================================================
DO $selftest$
DECLARE
    v_user   BIGINT;
    v_rows   INT;
    v_before INT;
BEGIN
    INSERT INTO users (name, wallet_balance) VALUES ('trigger-selftest', 100.00)
        RETURNING id INTO v_user;

    UPDATE users SET wallet_balance = wallet_balance + 250.00 WHERE id = v_user;  -- CREDIT
    UPDATE users SET wallet_balance = wallet_balance -  40.50 WHERE id = v_user;  -- DEBIT

    SELECT count(*) INTO v_rows FROM wallet_audit_logs WHERE user_id = v_user;
    ASSERT v_rows = 2, format('expected 2 ledger rows, found %s', v_rows);

    PERFORM 1 FROM wallet_audit_logs
      WHERE user_id = v_user AND action_type = 'CREDIT'
        AND amount_changed = 250.00 AND balance_after = 350.00;
    ASSERT FOUND, 'CREDIT row missing or wrong';

    PERFORM 1 FROM wallet_audit_logs
      WHERE user_id = v_user AND action_type = 'DEBIT'
        AND amount_changed = -40.50 AND balance_after = 309.50;
    ASSERT FOUND, 'DEBIT row missing or wrong';

    -- 3. no-op write: column is mentioned, value unchanged -> WHEN clause suppresses it
    SELECT count(*) INTO v_before FROM wallet_audit_logs WHERE user_id = v_user;
    UPDATE users SET wallet_balance = wallet_balance WHERE id = v_user;
    SELECT count(*) INTO v_rows   FROM wallet_audit_logs WHERE user_id = v_user;
    ASSERT v_rows = v_before, 'no-op wallet write incorrectly produced a ledger row';

    -- 4. the ledger rejects mutation even for the table owner
    BEGIN
        UPDATE wallet_audit_logs SET amount_changed = 0 WHERE user_id = v_user;
        RAISE EXCEPTION 'immutability guard did NOT fire';
    EXCEPTION
        WHEN insufficient_privilege THEN NULL;   -- expected
    END;

    RAISE NOTICE 'self-test passed: audit trigger, WHEN suppression and immutability all verified';
    RAISE EXCEPTION 'rollback-selftest';         -- undo everything this block did
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM <> 'rollback-selftest' THEN RAISE; END IF;
END;
$selftest$;

\echo '--- trigger trg_wallet_audit + 2 immutability guards installed and self-tested'
