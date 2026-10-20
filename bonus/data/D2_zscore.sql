-- =====================================================================
-- BONUS D2 - Les retraits bizarres
-- Le score z dit "à combien d'écarts-types de la moyenne se trouve
-- cette valeur". Au-delà de 3, la valeur est franchement inhabituelle.
--
--     z = (valeur - moyenne) / écart-type
--
-- On compare chaque retrait à la moyenne DE SON PROPRE COMPTE : un
-- retrait de 400 € est banal pour un compte qui bouge beaucoup, et
-- anormal pour un compte qui retire 20 € d'habitude.
-- =====================================================================
\set ON_ERROR_STOP on

DROP TABLE IF EXISTS core.anomalies_retraits;

CREATE TABLE core.anomalies_retraits (
    tx_id        bigint PRIMARY KEY,
    account_id   bigint        NOT NULL,
    amount       numeric(18,2) NOT NULL,
    moyenne      numeric(18,2) NOT NULL,
    ecart_type   numeric(18,2) NOT NULL,
    score_z      numeric(10,3) NOT NULL,
    created_at   timestamptz   NOT NULL,
    detecte_le   timestamptz   NOT NULL DEFAULT now()
);

COMMENT ON TABLE core.anomalies_retraits IS
  'Retraits dont le montant s''écarte de plus de 3 écarts-types de la moyenne du compte.';

WITH stats_par_compte AS (
    SELECT account_id,
           avg(amount)    AS moyenne,
           stddev_samp(amount) AS ecart_type
    FROM core.transactions
    WHERE tx_type = 'withdrawal'
    GROUP BY account_id
    HAVING stddev_samp(amount) > 0          -- sinon division par zéro
),
scores AS (
    SELECT t.tx_id, t.account_id, t.amount, t.created_at,
           s.moyenne, s.ecart_type,
           (t.amount - s.moyenne) / s.ecart_type AS z
    FROM core.transactions t
    JOIN stats_par_compte s USING (account_id)
    WHERE t.tx_type = 'withdrawal'
)
INSERT INTO core.anomalies_retraits
    (tx_id, account_id, amount, moyenne, ecart_type, score_z, created_at)
SELECT tx_id, account_id, amount,
       round(moyenne, 2), round(ecart_type, 2), round(z, 3), created_at
FROM scores
WHERE abs(z) > 3;

CREATE INDEX idx_anomalies_compte ON core.anomalies_retraits (account_id, score_z DESC);

\echo ''
\echo '--- Combien de retraits anormaux sur le million d''écritures ? ---'
SELECT
    (SELECT count(*) FROM core.transactions WHERE tx_type='withdrawal') AS retraits_total,
    count(*)                                                            AS anormaux,
    round(100.0 * count(*) /
          NULLIF((SELECT count(*) FROM core.transactions WHERE tx_type='withdrawal'),0), 4) AS pourcentage
FROM core.anomalies_retraits;

\echo ''
\echo '--- Les 10 plus atypiques ---'
SELECT tx_id, account_id, amount, moyenne, ecart_type, score_z
FROM core.anomalies_retraits
ORDER BY abs(score_z) DESC
LIMIT 10;

\echo ''
\echo '--- Les comptes qui en concentrent le plus ---'
SELECT account_id, count(*) AS nb_anomalies, round(max(abs(score_z)),2) AS pire_score
FROM core.anomalies_retraits
GROUP BY account_id
ORDER BY count(*) DESC, max(abs(score_z)) DESC
LIMIT 5;

\echo ''
\echo '>>> D2 terminé.'
