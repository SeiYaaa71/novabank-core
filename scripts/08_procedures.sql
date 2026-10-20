-- =====================================================================
-- NovaBank Core — Étape 7 : les procédures
--   sp_transfer         : le virement sûr
--   sp_open_account     : l'ouverture d'un compte
--   fn_account_statement: le relevé
-- =====================================================================
\set ON_ERROR_STOP on

-- Sert à fabriquer des IBAN uniques sans tirage au hasard ni collision.
CREATE SEQUENCE IF NOT EXISTS core.seq_iban START 1000000;

-- =====================================================================
-- LE VIREMENT SÛR
--
-- "Un virement se fait en entier ou pas du tout" (problème n°2 du sujet).
-- Trois lignes sont écrites : 1 virement + 2 écritures. Si la troisième
-- échoue, les deux premières disparaissent aussi.
-- =====================================================================
CREATE OR REPLACE PROCEDURE core.sp_transfer(
    p_from_account_id bigint,
    p_to_account_id   bigint,
    p_amount          numeric,
    p_label           text DEFAULT NULL
)
LANGUAGE plpgsql
SET search_path = pg_catalog, core
AS $$
DECLARE
    v_transfer_id bigint;
    v_premier     bigint;
    v_second      bigint;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Montant invalide : %', p_amount
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_from_account_id = p_to_account_id THEN
        RAISE EXCEPTION 'Un virement ne peut pas partir et arriver sur le compte %',
            p_from_account_id USING ERRCODE = 'check_violation';
    END IF;

    -- Toujours verrouiller dans l'ordre croissant des identifiants.
    -- Sinon deux virements croisés (A->B et B->A lancés en même temps)
    -- s'attendraient l'un l'autre : c'est un interblocage.
    v_premier := least(p_from_account_id, p_to_account_id);
    v_second  := greatest(p_from_account_id, p_to_account_id);
    PERFORM 1 FROM core.accounts WHERE account_id = v_premier FOR UPDATE;
    PERFORM 1 FROM core.accounts WHERE account_id = v_second  FOR UPDATE;

    INSERT INTO core.transfers (from_account_id, to_account_id, amount, label)
    VALUES (p_from_account_id, p_to_account_id, p_amount, p_label)
    RETURNING transfer_id INTO v_transfer_id;

    -- balance_after vaut 0 ici : le trigger de l'étape 6 le remplace par le
    -- vrai solde. Aucune application n'a à calculer un solde elle-même.
    INSERT INTO core.transactions (account_id, tx_type, amount, balance_after, transfer_id)
    VALUES (p_from_account_id, 'transfer_out', p_amount, 0, v_transfer_id);

    INSERT INTO core.transactions (account_id, tx_type, amount, balance_after, transfer_id)
    VALUES (p_to_account_id, 'transfer_in', p_amount, 0, v_transfer_id);

    -- Pas de bloc EXCEPTION, et c'est volontaire : si le solde est
    -- insuffisant, le trigger lève une erreur qui remonte et annule les
    -- trois lignes d'un coup. Attraper l'erreur ici laisserait un
    -- virement orphelin dans la table transfers.
END;
$$;

COMMENT ON PROCEDURE core.sp_transfer(bigint, bigint, numeric, text) IS
  'Virement atomique : 1 ligne transfers + 2 lignes transactions, ou rien.';

-- =====================================================================
-- L'OUVERTURE D'UN COMPTE
-- =====================================================================
CREATE OR REPLACE PROCEDURE core.sp_open_account(
    p_customer_id   bigint,
    p_account_type  text DEFAULT 'courant',
    p_iban          text DEFAULT NULL
)
LANGUAGE plpgsql
SET search_path = pg_catalog, core
AS $$
DECLARE
    v_kyc  text;
    v_iban text;
BEGIN
    SELECT kyc_status INTO v_kyc
    FROM core.customers WHERE customer_id = p_customer_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Client % inexistant', p_customer_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- Règle métier : pas de compte pour un dossier refusé.
    IF v_kyc = 'rejected' THEN
        RAISE EXCEPTION 'Dossier KYC refusé pour le client % : ouverture impossible',
            p_customer_id USING ERRCODE = 'check_violation';
    END IF;

    v_iban := COALESCE(
        p_iban,
        'FR76' || lpad(nextval('core.seq_iban')::text, 19, '0')
    );

    INSERT INTO core.accounts (customer_id, iban, account_type, balance, status)
    VALUES (p_customer_id, v_iban, p_account_type, 0, 'active');
END;
$$;

COMMENT ON PROCEDURE core.sp_open_account(bigint, text, text) IS
  'Ouvre un compte à solde nul. IBAN fourni, ou généré par séquence.';

-- =====================================================================
-- LE RELEVÉ
-- Fonction (et non procédure) : elle renvoie des lignes.
-- STABLE : elle ne modifie rien, le planificateur peut l'optimiser.
-- Le tri colle exactement à l'index idx_tx_account_created de l'étape 5.
-- =====================================================================
CREATE OR REPLACE FUNCTION core.fn_account_statement(
    p_account_id bigint,
    p_from       date DEFAULT NULL,
    p_to         date DEFAULT NULL
)
RETURNS TABLE (
    tx_id       bigint,
    moment      timestamptz,
    type        text,
    montant     numeric,
    solde_apres numeric,
    virement    bigint
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, core
AS $$
    SELECT t.tx_id, t.created_at, t.tx_type, t.amount, t.balance_after, t.transfer_id
    FROM core.transactions t
    WHERE t.account_id = p_account_id
      AND (p_from IS NULL OR t.created_at >= p_from::timestamptz)
      AND (p_to   IS NULL OR t.created_at <  (p_to + 1)::timestamptz)
    ORDER BY t.created_at DESC, t.tx_id DESC;
$$;

COMMENT ON FUNCTION core.fn_account_statement(bigint, date, date) IS
  'Relevé d''un compte, du plus récent au plus ancien, période optionnelle.';

\echo '>>> Étape 7 terminée : 2 procédures + 1 fonction.'
