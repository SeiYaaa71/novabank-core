-- =====================================================================
-- NovaBank Core — Étape 2a : la base et les 6 tables
-- Les colonnes sont imposées par le sujet ; les types et les
-- protections (CHECK, UNIQUE, clés étrangères) sont nos choix.
-- =====================================================================
\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS core  CASCADE;
DROP SCHEMA IF EXISTS audit CASCADE;

CREATE SCHEMA core;
CREATE SCHEMA audit;

COMMENT ON SCHEMA core  IS 'Données métier de NovaBank';
COMMENT ON SCHEMA audit IS 'Journal des modifications sensibles';

-- ---------------------------------------------------------------------
-- 1. core.customers — les clients
--    Garanties demandées : email unique et valide, client majeur.
-- ---------------------------------------------------------------------
CREATE TABLE core.customers (
    customer_id bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name  text        NOT NULL,
    last_name   text        NOT NULL,
    email       text        NOT NULL,
    phone       text,
    birth_date  date        NOT NULL,
    kyc_status  text        NOT NULL DEFAULT 'pending',
    risk_level  smallint    NOT NULL DEFAULT 1,
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT customers_email_unique    UNIQUE (email),
    -- Un email doit ressembler à un email : du texte, @, un domaine, un point, une extension.
    CONSTRAINT customers_email_valide    CHECK (email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    -- Stocké en minuscules : sinon "A@x.fr" et "a@x.fr" passeraient tous les deux l'unicité.
    CONSTRAINT customers_email_minuscule CHECK (email = lower(email)),
    -- Majorité : au moins 18 ans révolus au moment de l'écriture.
    CONSTRAINT customers_majeur          CHECK (birth_date <= (CURRENT_DATE - INTERVAL '18 years')),
    CONSTRAINT customers_naissance_reelle CHECK (birth_date > DATE '1900-01-01'),
    CONSTRAINT customers_kyc_valide      CHECK (kyc_status IN ('pending','verified','rejected')),
    CONSTRAINT customers_risque_valide   CHECK (risk_level BETWEEN 1 AND 5),
    CONSTRAINT customers_prenom_rempli   CHECK (btrim(first_name) <> ''),
    CONSTRAINT customers_nom_rempli      CHECK (btrim(last_name)  <> '')
);

-- ---------------------------------------------------------------------
-- 2. core.accounts — les comptes
--    Garanties demandées : solde jamais négatif, IBAN unique.
--    Un client a plusieurs comptes : la clé étrangère va vers customers.
-- ---------------------------------------------------------------------
CREATE TABLE core.accounts (
    account_id   bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  bigint        NOT NULL REFERENCES core.customers(customer_id) ON DELETE RESTRICT,
    iban         text          NOT NULL,
    account_type text          NOT NULL DEFAULT 'courant',
    -- numeric et pas float : en banque, 0.1 + 0.2 doit faire exactement 0.3.
    balance      numeric(18,2) NOT NULL DEFAULT 0,
    status       text          NOT NULL DEFAULT 'active',
    opened_at    timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT accounts_iban_unique    UNIQUE (iban),
    -- LA protection centrale du sujet : aucun solde négatif, quoi qu'il arrive.
    CONSTRAINT accounts_solde_positif  CHECK (balance >= 0),
    CONSTRAINT accounts_iban_format    CHECK (iban ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$'),
    CONSTRAINT accounts_type_valide    CHECK (account_type IN ('courant','epargne','joint')),
    CONSTRAINT accounts_statut_valide  CHECK (status IN ('active','frozen','closed'))
);

-- ---------------------------------------------------------------------
-- 3. core.transfers — les virements (l'intention)
--    Garanties demandées : montant positif, comptes différents.
-- ---------------------------------------------------------------------
CREATE TABLE core.transfers (
    transfer_id     bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_account_id bigint        NOT NULL REFERENCES core.accounts(account_id) ON DELETE RESTRICT,
    to_account_id   bigint        NOT NULL REFERENCES core.accounts(account_id) ON DELETE RESTRICT,
    amount          numeric(18,2) NOT NULL,
    label           text,
    created_at      timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT transfers_montant_positif    CHECK (amount > 0),
    CONSTRAINT transfers_comptes_differents CHECK (from_account_id <> to_account_id)
);

-- ---------------------------------------------------------------------
-- 4. core.transactions — les écritures (le grand livre)
--    Garanties demandées : jamais modifiée ni supprimée (étape 6),
--    un virement = 2 écritures ou aucune (étape 7).
-- ---------------------------------------------------------------------
CREATE TABLE core.transactions (
    tx_id         bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id    bigint        NOT NULL REFERENCES core.accounts(account_id) ON DELETE RESTRICT,
    tx_type       text          NOT NULL,
    amount        numeric(18,2) NOT NULL,
    balance_after numeric(18,2) NOT NULL,
    transfer_id   bigint        REFERENCES core.transfers(transfer_id) ON DELETE RESTRICT,
    created_at    timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT transactions_type_valide     CHECK (tx_type IN ('deposit','withdrawal','transfer_in','transfer_out','fee')),
    CONSTRAINT transactions_montant_positif CHECK (amount > 0),
    CONSTRAINT transactions_solde_positif   CHECK (balance_after >= 0),
    -- Une écriture de virement cite forcément son virement ; un dépôt n'en cite jamais.
    CONSTRAINT transactions_virement_lie    CHECK (
        (tx_type IN ('transfer_in','transfer_out') AND transfer_id IS NOT NULL)
     OR (tx_type NOT IN ('transfer_in','transfer_out') AND transfer_id IS NULL)
    )
);

-- ---------------------------------------------------------------------
-- 5. core.fraud_alerts — les alertes
--    Remplie automatiquement par un trigger (étape 6).
-- ---------------------------------------------------------------------
CREATE TABLE core.fraud_alerts (
    alert_id   bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id bigint      NOT NULL REFERENCES core.accounts(account_id) ON DELETE RESTRICT,
    tx_id      bigint      REFERENCES core.transactions(tx_id) ON DELETE RESTRICT,
    rule_code  text        NOT NULL,
    status     text        NOT NULL DEFAULT 'open',
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fraud_regle_valide  CHECK (rule_code IN ('BIG_WITHDRAWAL','RAPID_TRANSFERS')),
    CONSTRAINT fraud_statut_valide CHECK (status IN ('open','reviewing','closed','false_positive'))
);

-- ---------------------------------------------------------------------
-- 6. audit.audit_log — le journal
--    Qui, quand, avant, après. Rempli par trigger (étape 6).
-- ---------------------------------------------------------------------
CREATE TABLE audit.audit_log (
    log_id     bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name text        NOT NULL,
    operation  text        NOT NULL,
    old_data   jsonb,
    new_data   jsonb,
    db_user    text        NOT NULL DEFAULT session_user,
    changed_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT audit_operation_valide CHECK (operation IN ('INSERT','UPDATE','DELETE'))
);

\echo '>>> Étape 2a terminée : 6 tables créées.'
