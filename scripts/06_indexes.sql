-- =====================================================================
-- NovaBank Core - Étape 5 : les index, et la preuve qu'ils servent
--
-- Problème n°3 du sujet : "l'historique d'un compte met plus de
-- 4 secondes". On mesure AVANT, on indexe, on mesure APRÈS.
-- =====================================================================
\set ON_ERROR_STOP on

-- On repart de zéro pour que la mesure "avant" soit honnête.
DROP INDEX IF EXISTS core.idx_tx_account_created;
DROP INDEX IF EXISTS core.idx_tx_created_brin;
DROP INDEX IF EXISTS core.idx_accounts_customer;
DROP INDEX IF EXISTS core.idx_transfers_from_created;
DROP INDEX IF EXISTS core.idx_fraud_open;

\echo ''
\echo '============================================================'
\echo ' AVANT INDEX - historique des 50 dernières écritures du compte 42'
\echo '============================================================'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT tx_id, created_at, tx_type, amount, balance_after
FROM core.transactions
WHERE account_id = 42
ORDER BY created_at DESC
LIMIT 50;

-- Fenêtre volontairement étroite : les données générées couvrent environ
-- 24 jours (1 000 écritures x 35 min). Demander "les 30 derniers jours"
-- ramènerait TOUTE la table, et aucun index ne battrait jamais un parcours
-- complet dans ce cas. Sur 2 jours (~8 % des lignes), le BRIN a un intérêt.
\echo ''
\echo '--- AVANT INDEX - total des retraits des 2 derniers jours ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*), sum(amount)
FROM core.transactions
WHERE created_at >= now() - INTERVAL '2 days'
  AND tx_type = 'withdrawal';

-- ---------------------------------------------------------------------
-- Les 4 index
-- ---------------------------------------------------------------------

-- 1. LE plus important : l'historique d'un compte, du plus récent au plus
--    ancien. Les deux colonnes dans cet ordre permettent de filtrer ET de
--    trier avec le même index : plus aucun tri à faire.
CREATE INDEX idx_tx_account_created
    ON core.transactions (account_id, created_at DESC);

-- 2. Les écritures arrivent dans l'ordre du temps et ne bougent jamais.
--    C'est le cas d'école du BRIN : il retient juste le min/max par bloc,
--    donc il pèse quelques kilo-octets là où un B-tree ferait des dizaines
--    de méga-octets.
CREATE INDEX idx_tx_created_brin
    ON core.transactions USING brin (created_at) WITH (pages_per_range = 32);

-- 3. "Les comptes de ce client" : clé étrangère non indexée = parcours complet.
CREATE INDEX idx_accounts_customer
    ON core.accounts (customer_id);

-- 4. Sert la règle anti-fraude "5 virements en 10 minutes" (étape 6),
--    qui interroge les virements d'un compte sur une fenêtre de temps.
CREATE INDEX idx_transfers_from_created
    ON core.transfers (from_account_id, created_at DESC);

-- Bonus : index PARTIEL. Seules les alertes ouvertes sont indexées,
-- c'est-à-dire une poignée de lignes au lieu de toute la table.
CREATE INDEX idx_fraud_open
    ON core.fraud_alerts (account_id, created_at DESC)
    WHERE status = 'open';

ANALYZE core.transactions;
ANALYZE core.accounts;
ANALYZE core.transfers;

\echo ''
\echo '============================================================'
\echo ' APRÈS INDEX - exactement la même requête'
\echo '============================================================'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT tx_id, created_at, tx_type, amount, balance_after
FROM core.transactions
WHERE account_id = 42
ORDER BY created_at DESC
LIMIT 50;

\echo ''
\echo '--- APRÈS INDEX - total des retraits des 2 derniers jours ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*), sum(amount)
FROM core.transactions
WHERE created_at >= now() - INTERVAL '2 days'
  AND tx_type = 'withdrawal';

\echo ''
\echo '--- Taille des index (le BRIN est minuscule, c''est voulu) ---'
SELECT indexrelname AS index,
       pg_size_pretty(pg_relation_size(indexrelid)) AS taille
FROM pg_stat_user_indexes
WHERE schemaname = 'core'
ORDER BY pg_relation_size(indexrelid) DESC;

\echo '>>> Étape 5 terminée.'
