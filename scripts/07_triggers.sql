-- =====================================================================
-- NovaBank Core — Étape 6 : les triggers
--   a) le solde se met à jour seul
--   b) le passé ne change plus (grand livre en écriture seule)
--   c) les fraudes sont notées
--   d) les changements sont notés (qui, quand, avant, après)
--
-- À exécuter APRÈS le chargement des données : pendant le chargement on
-- écrit le passé tel qu'il était, le trigger n'a pas à le recalculer.
-- =====================================================================
\set ON_ERROR_STOP on

-- =====================================================================
-- a) LE SOLDE SE MET À JOUR SEUL
--
-- C'est aussi la réponse au problème n°2 du sujet ("deux virements en
-- même temps ont donné un solde négatif").
-- SELECT ... FOR UPDATE verrouille la ligne du compte : la deuxième
-- transaction attend la première au lieu de lire un solde périmé.
-- =====================================================================
CREATE OR REPLACE FUNCTION core.fn_tx_apply_balance()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, core
AS $$
DECLARE
    solde_actuel numeric(18,2);
    delta        numeric(18,2);
    solde_neuf   numeric(18,2);
    statut       text;
BEGIN
    -- Verrou sur CE compte uniquement. Les autres comptes continuent de vivre.
    SELECT balance, status INTO solde_actuel, statut
    FROM core.accounts
    WHERE account_id = NEW.account_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Compte % inexistant', NEW.account_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF statut <> 'active' THEN
        RAISE EXCEPTION 'Compte % non actif (statut: %)', NEW.account_id, statut
            USING ERRCODE = 'check_violation';
    END IF;

    delta := CASE
                WHEN NEW.tx_type IN ('deposit','transfer_in')            THEN  NEW.amount
                WHEN NEW.tx_type IN ('withdrawal','transfer_out','fee')  THEN -NEW.amount
             END;

    solde_neuf := solde_actuel + delta;

    IF solde_neuf < 0 THEN
        RAISE EXCEPTION
            'Solde insuffisant sur le compte % : solde %, opération % de %',
            NEW.account_id, solde_actuel, NEW.tx_type, NEW.amount
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE core.accounts SET balance = solde_neuf WHERE account_id = NEW.account_id;

    -- L'appelant n'a pas à calculer balance_after : c'est la base qui décide.
    NEW.balance_after := solde_neuf;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tx_apply_balance
    BEFORE INSERT ON core.transactions
    FOR EACH ROW EXECUTE FUNCTION core.fn_tx_apply_balance();

-- =====================================================================
-- b) LE PASSÉ NE CHANGE PLUS
--    Le grand livre n'accepte que des ajouts. Pas de correction en
--    douce : une erreur se corrige par une écriture inverse.
-- =====================================================================
CREATE OR REPLACE FUNCTION core.fn_tx_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, core
AS $$
BEGIN
    RAISE EXCEPTION
        'core.transactions est en écriture seule : % interdit (tx_id %)',
        TG_OP, COALESCE(OLD.tx_id, NEW.tx_id)
        USING ERRCODE = 'insufficient_privilege',
              HINT = 'Pour corriger, ajoutez une écriture inverse.';
END;
$$;

CREATE TRIGGER trg_tx_no_update
    BEFORE UPDATE ON core.transactions
    FOR EACH ROW EXECUTE FUNCTION core.fn_tx_immutable();

CREATE TRIGGER trg_tx_no_delete
    BEFORE DELETE ON core.transactions
    FOR EACH ROW EXECUTE FUNCTION core.fn_tx_immutable();

-- TRUNCATE contourne les triggers de ligne : on le bloque à part.
CREATE OR REPLACE FUNCTION core.fn_no_truncate()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'TRUNCATE interdit sur %', TG_TABLE_NAME
        USING ERRCODE = 'insufficient_privilege';
END;
$$;

CREATE TRIGGER trg_tx_no_truncate
    BEFORE TRUNCATE ON core.transactions
    FOR EACH STATEMENT EXECUTE FUNCTION core.fn_no_truncate();

-- =====================================================================
-- c) LES FRAUDES SONT NOTÉES
--    Règle 1 : retrait de 5 000 ou plus.
--    Règle 2 : 5 virements en 10 minutes depuis le même compte.
-- =====================================================================
CREATE OR REPLACE FUNCTION core.fn_detect_big_withdrawal()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, core
AS $$
BEGIN
    IF NEW.tx_type IN ('withdrawal','transfer_out') AND NEW.amount >= 5000 THEN
        INSERT INTO core.fraud_alerts (account_id, tx_id, rule_code)
        VALUES (NEW.account_id, NEW.tx_id, 'BIG_WITHDRAWAL');
    END IF;
    RETURN NULL;              -- AFTER trigger : la valeur de retour est ignorée
END;
$$;

CREATE TRIGGER trg_detect_big_withdrawal
    AFTER INSERT ON core.transactions
    FOR EACH ROW EXECUTE FUNCTION core.fn_detect_big_withdrawal();

CREATE OR REPLACE FUNCTION core.fn_detect_rapid_transfers()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, core
AS $$
DECLARE
    nb int;
BEGIN
    SELECT count(*) INTO nb
    FROM core.transfers
    WHERE from_account_id = NEW.from_account_id
      AND created_at >= NEW.created_at - INTERVAL '10 minutes'
      AND created_at <= NEW.created_at;

    IF nb >= 5 THEN
        -- Une seule alerte par rafale : on ne spamme pas l'équipe fraude.
        INSERT INTO core.fraud_alerts (account_id, rule_code)
        SELECT NEW.from_account_id, 'RAPID_TRANSFERS'
        WHERE NOT EXISTS (
            SELECT 1 FROM core.fraud_alerts
            WHERE account_id = NEW.from_account_id
              AND rule_code  = 'RAPID_TRANSFERS'
              AND status     = 'open'
              AND created_at >= NEW.created_at - INTERVAL '10 minutes'
        );
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_detect_rapid_transfers
    AFTER INSERT ON core.transfers
    FOR EACH ROW EXECUTE FUNCTION core.fn_detect_rapid_transfers();

-- =====================================================================
-- d) LES CHANGEMENTS SONT NOTÉS — qui, quand, avant, après
--    Une seule fonction générique, branchée sur plusieurs tables.
--    to_jsonb(ligne) transforme la ligne entière en JSON : le journal
--    reste valable même si on ajoute une colonne plus tard.
-- =====================================================================
CREATE OR REPLACE FUNCTION audit.fn_log_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER                      -- écrit dans audit même si l'appelant n'y a pas droit
SET search_path = pg_catalog, audit, core
AS $$
BEGIN
    INSERT INTO audit.audit_log (table_name, operation, old_data, new_data, db_user)
    VALUES (
        TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
        TG_OP,
        CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
        CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END,
        session_user
    );
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_audit_customers
    AFTER INSERT OR UPDATE OR DELETE ON core.customers
    FOR EACH ROW EXECUTE FUNCTION audit.fn_log_change();

CREATE TRIGGER trg_audit_accounts
    AFTER INSERT OR UPDATE OR DELETE ON core.accounts
    FOR EACH ROW EXECUTE FUNCTION audit.fn_log_change();

CREATE TRIGGER trg_audit_fraud_alerts
    AFTER INSERT OR UPDATE OR DELETE ON core.fraud_alerts
    FOR EACH ROW EXECUTE FUNCTION audit.fn_log_change();

-- Le journal lui-même ne se réécrit pas : sinon il ne prouve rien.
CREATE OR REPLACE FUNCTION audit.fn_log_immutable()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit.audit_log est en écriture seule : % interdit', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END;
$$;

CREATE TRIGGER trg_audit_no_update
    BEFORE UPDATE OR DELETE ON audit.audit_log
    FOR EACH ROW EXECUTE FUNCTION audit.fn_log_immutable();

\echo '>>> Étape 6 terminée : solde auto, passé figé, fraude et audit branchés.'
