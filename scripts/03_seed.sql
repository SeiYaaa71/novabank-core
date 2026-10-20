-- =====================================================================
-- NovaBank Core — Étape 2b : fabriquer les données (1 000 000 d'écritures)
-- 500 clients -> 1 000 comptes -> 1 000 écritures par compte.
-- Exécuté AVANT les triggers (étape 6) : ici on écrit le passé tel quel,
-- les triggers n'ont pas à le recalculer.
-- =====================================================================
\set ON_ERROR_STOP on
\timing on

TRUNCATE core.fraud_alerts, core.transactions, core.transfers, core.accounts, core.customers RESTART IDENTITY CASCADE;

-- ---------------------------------------------------------------------
-- 500 clients. Tous majeurs : la date la plus récente possible reste
-- très au-dessus de la limite des 18 ans.
-- ---------------------------------------------------------------------
INSERT INTO core.customers (first_name, last_name, email, phone, birth_date, kyc_status, risk_level)
SELECT
    'Prenom' || i,
    'Nom'    || i,
    'client' || i || '@novabank.test',
    '+336' || lpad(((random() * 99999999)::bigint)::text, 8, '0'),
    DATE '1960-01-01' + ((random() * 16000)::int),          -- entre 1960 et ~2003
    (ARRAY['pending','verified','verified','verified','rejected'])[1 + (random() * 4)::int],
    1 + (random() * 4)::int
FROM generate_series(1, 500) AS i;

-- ---------------------------------------------------------------------
-- 1 000 comptes : 2 par client (le sujet précise "un client a plusieurs comptes").
-- IBAN synthétique, unique par construction grâce au numéro de ligne.
-- ---------------------------------------------------------------------
INSERT INTO core.accounts (customer_id, iban, account_type, balance, status)
SELECT
    c.customer_id,
    'FR76' || lpad((c.customer_id * 10 + k)::text, 19, '0'),
    CASE k WHEN 1 THEN 'courant' ELSE 'epargne' END,
    1000000.00,                                              -- solde de départ
    'active'
FROM core.customers c
CROSS JOIN generate_series(1, 2) AS k;

-- ---------------------------------------------------------------------
-- 1 000 000 d'écritures : 1 000 par compte.
--
-- Pourquoi on ne descend jamais sous zéro :
--   solde de départ          = 1 000 000,00
--   pire cas = 1 000 retraits plafonnés à 500,00 = 500 000,00
--   -> le solde reste positif quoi qu'il arrive, la contrainte tient.
--
-- balance_after est calculé par une somme glissante (SUM OVER) : chaque
-- ligne porte le solde du compte juste après elle, comme un vrai relevé.
-- ---------------------------------------------------------------------
WITH brut AS (
    SELECT
        a.account_id,
        g.n,
        (random() < 0.55)                               AS est_depot,
        round((random() * 890 + 10)::numeric, 2)        AS montant_brut,
        now() - ((1000 - g.n) * INTERVAL '35 minutes')
              + (((random() * 1800)::int) * INTERVAL '1 second')  AS created_at
    FROM core.accounts a
    CROSS JOIN generate_series(1, 1000) AS g(n)
),
typee AS (
    SELECT
        account_id, n, created_at,
        CASE WHEN est_depot THEN 'deposit' ELSE 'withdrawal' END AS tx_type,
        CASE WHEN est_depot THEN montant_brut
             ELSE least(montant_brut, 500.00) END                AS amount
    FROM brut
),
signee AS (
    SELECT *,
           CASE WHEN tx_type = 'deposit' THEN amount ELSE -amount END AS delta
    FROM typee
),
calculee AS (
    SELECT
        account_id,
        tx_type,
        amount,
        1000000.00 + SUM(delta) OVER (PARTITION BY account_id ORDER BY n ROWS UNBOUNDED PRECEDING) AS balance_after,
        created_at
    FROM signee
)
INSERT INTO core.transactions (account_id, tx_type, amount, balance_after, created_at)
SELECT account_id, tx_type, amount, balance_after, created_at
FROM calculee
-- ORDER BY date : le grand livre est ecrit dans l'ordre du temps, comme
-- dans la vraie vie. Sans cela la table serait rangee compte par compte,
-- et l'index BRIN de l'etape 5 ne servirait a rien (il suppose que les
-- valeurs proches sont stockees ensemble).
ORDER BY created_at;

-- Le solde du compte = le solde de sa dernière écriture. Les deux doivent coller.
UPDATE core.accounts a
SET balance = d.dernier_solde
FROM (
    SELECT DISTINCT ON (account_id) account_id, balance_after AS dernier_solde
    FROM core.transactions
    ORDER BY account_id, tx_id DESC
) d
WHERE a.account_id = d.account_id;

ANALYZE core.customers;
ANALYZE core.accounts;
ANALYZE core.transactions;

\timing off
\echo ''
\echo '>>> Volumes obtenus :'
SELECT 'clients'   AS objet, count(*) FROM core.customers
UNION ALL SELECT 'comptes',    count(*) FROM core.accounts
UNION ALL SELECT 'écritures',  count(*) FROM core.transactions;

\echo '>>> Contrôle de cohérence (doit être vide) :'
SELECT a.account_id, a.balance, d.dernier_solde
FROM core.accounts a
JOIN (SELECT DISTINCT ON (account_id) account_id, balance_after AS dernier_solde
      FROM core.transactions ORDER BY account_id, tx_id DESC) d USING (account_id)
WHERE a.balance <> d.dernier_solde;
