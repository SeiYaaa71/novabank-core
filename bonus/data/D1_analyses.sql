-- =====================================================================
-- BONUS D1 - Cinq analyses
-- Fonctions de fenêtrage : rank, dense_rank, lag, ntile, sum cumulée.
-- Une fonction de fenêtrage calcule une valeur par ligne EN REGARDANT
-- les lignes voisines, sans regrouper ni perdre le détail.
-- =====================================================================
\set ON_ERROR_STOP on

\echo ''
\echo '=== 1. Qui a le plus d''argent, par tranche d''âge ? ==='
WITH par_client AS (
    SELECT
        c.customer_id,
        date_part('year', age(c.birth_date))::int AS age,
        CASE
            WHEN date_part('year', age(c.birth_date)) < 30 THEN '18-29 ans'
            WHEN date_part('year', age(c.birth_date)) < 45 THEN '30-44 ans'
            WHEN date_part('year', age(c.birth_date)) < 60 THEN '45-59 ans'
            ELSE '60 ans et plus'
        END AS tranche,
        sum(a.balance) AS avoirs
    FROM core.customers c
    JOIN core.accounts a USING (customer_id)
    GROUP BY c.customer_id, c.birth_date
)
SELECT tranche, customer_id, age, round(avoirs, 2) AS avoirs,
       rang
FROM (
    SELECT *, rank() OVER (PARTITION BY tranche ORDER BY avoirs DESC) AS rang
    FROM par_client
) t
WHERE rang <= 3                       -- le podium de chaque tranche
ORDER BY tranche, rang;

\echo ''
\echo '=== 2. Les dépôts montent-ils ? (comparaison avec la veille) ==='
WITH par_jour AS (
    SELECT date_trunc('day', created_at)::date AS jour,
           sum(amount) AS total_depots
    FROM core.transactions
    WHERE tx_type = 'deposit'
    GROUP BY 1
)
SELECT
    jour,
    round(total_depots, 2) AS depots,
    round(lag(total_depots) OVER (ORDER BY jour), 2) AS veille,
    round(total_depots - lag(total_depots) OVER (ORDER BY jour), 2) AS variation,
    CASE
        WHEN lag(total_depots) OVER (ORDER BY jour) IS NULL THEN '-'
        WHEN total_depots > lag(total_depots) OVER (ORDER BY jour) THEN 'hausse'
        WHEN total_depots < lag(total_depots) OVER (ORDER BY jour) THEN 'baisse'
        ELSE 'stable'
    END AS tendance
FROM par_jour
ORDER BY jour DESC
LIMIT 10;

\echo ''
\echo '=== 3. Répartition des comptes en 10 tranches de richesse (ntile) ==='
WITH deciles AS (
    SELECT account_id, balance,
           ntile(10) OVER (ORDER BY balance) AS decile
    FROM core.accounts
)
SELECT decile,
       count(*)              AS nb_comptes,
       round(min(balance),2) AS solde_min,
       round(max(balance),2) AS solde_max,
       round(sum(balance),2) AS avoirs_du_decile
FROM deciles
GROUP BY decile
ORDER BY decile;

\echo ''
\echo '=== 4. Top 5 des comptes qui retirent le plus ==='
SELECT
    rank() OVER (ORDER BY sum(amount) DESC) AS rang,
    account_id,
    count(*)              AS nb_retraits,
    round(sum(amount), 2) AS total_retire,
    round(avg(amount), 2) AS retrait_moyen
FROM core.transactions
WHERE tx_type = 'withdrawal'
GROUP BY account_id
ORDER BY sum(amount) DESC
LIMIT 5;

\echo ''
\echo '=== 5. Un relevé avec le solde cumulé recalculé (somme glissante) ==='
-- Vérifie que balance_after stocké colle bien au cumul recalculé.
SELECT
    tx_id, created_at::date AS jour, tx_type, amount,
    balance_after AS solde_stocke,
    round(sum(CASE WHEN tx_type IN ('deposit','transfer_in') THEN amount ELSE -amount END)
          OVER (ORDER BY tx_id ROWS UNBOUNDED PRECEDING) + 1000000.00, 2) AS solde_recalcule
FROM core.transactions
WHERE account_id = 42
ORDER BY tx_id
LIMIT 8;

\echo ''
\echo '>>> D1 terminé.'
