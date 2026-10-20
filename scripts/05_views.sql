-- =====================================================================
-- NovaBank Core - Étape 4 : les vues
--   1. une vue qui cache des données   -> v_customers_masked
--   2. une vue modifiable avec limite  -> v_accounts_active (CHECK OPTION)
--   3. une vue enregistrée             -> mv_account_monthly (MATERIALIZED)
--   + le relevé, réutilisé par le support et par la procédure de l'étape 7.
-- =====================================================================
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- 1. Vue qui CACHE des données.
--    Le support doit reconnaître un client sans pouvoir constituer
--    un fichier d'emails. On ne lui montre que des bouts.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW core.v_customers_masked AS
SELECT
    customer_id,
    first_name,
    left(last_name, 1) || '.'                                   AS last_name_initial,
    left(email, 1) || '***@' || split_part(email, '@', 2)       AS email_masked,
    CASE WHEN phone IS NULL THEN NULL
         ELSE '********' || right(phone, 2) END                 AS phone_masked,
    extract(year FROM birth_date)::int                          AS birth_year,
    kyc_status,
    risk_level,
    created_at
FROM core.customers;

COMMENT ON VIEW core.v_customers_masked IS
  'Clients sans donnée exportable : email et téléphone tronqués, nom réduit à une initiale.';

-- ---------------------------------------------------------------------
-- 2. Vue MODIFIABLE, avec une limite.
--    WITH CHECK OPTION : toute écriture qui ferait sortir la ligne de la
--    vue est refusée. Donc par cette vue, on ne peut pas fermer un compte
--    ni le faire passer au-dessus du plafond.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW core.v_accounts_active AS
SELECT account_id, customer_id, iban, account_type, balance, status, opened_at
FROM core.accounts
WHERE status = 'active'
  AND balance <= 5000000.00
WITH LOCAL CHECK OPTION;

COMMENT ON VIEW core.v_accounts_active IS
  'Comptes actifs sous plafond. Modifiable, mais on ne peut pas en sortir une ligne.';

-- ---------------------------------------------------------------------
-- 3. Vue ENREGISTRÉE (matérialisée).
--    Le résultat est stocké sur disque : la question "combien ce compte
--    a-t-il bougé en mars ?" ne relit plus le million de lignes.
-- ---------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS core.mv_account_monthly;
CREATE MATERIALIZED VIEW core.mv_account_monthly AS
SELECT
    account_id,
    date_trunc('month', created_at)::date                                           AS mois,
    count(*)                                                                        AS nb_ecritures,
    sum(amount) FILTER (WHERE tx_type IN ('deposit','transfer_in'))                 AS total_credits,
    sum(amount) FILTER (WHERE tx_type IN ('withdrawal','transfer_out','fee'))       AS total_debits,
    min(balance_after)                                                              AS solde_min,
    max(balance_after)                                                              AS solde_max
FROM core.transactions
GROUP BY account_id, date_trunc('month', created_at)
WITH DATA;

-- L'index unique est indispensable pour REFRESH ... CONCURRENTLY
-- (rafraîchir sans bloquer les lecteurs).
CREATE UNIQUE INDEX mv_account_monthly_pk
    ON core.mv_account_monthly (account_id, mois);

COMMENT ON MATERIALIZED VIEW core.mv_account_monthly IS
  'Totaux par compte et par mois, calculés une fois. REFRESH MATERIALIZED VIEW CONCURRENTLY pour mettre à jour.';

-- ---------------------------------------------------------------------
-- 4. Le relevé de compte (vue simple, réutilisée partout).
--    IBAN tronqué : même ici, on n'étale pas le numéro complet.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW core.v_account_statement AS
SELECT
    t.tx_id,
    t.account_id,
    '****' || right(a.iban, 4) AS iban_court,
    t.created_at,
    t.tx_type,
    t.amount,
    t.balance_after,
    t.transfer_id
FROM core.transactions t
JOIN core.accounts a ON a.account_id = t.account_id;

\echo '>>> Étape 4 terminée : 3 vues + le relevé.'
