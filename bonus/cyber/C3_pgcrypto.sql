-- =====================================================================
-- BONUS C3 — Cacher une donnée
-- Le numéro de téléphone est stocké chiffré. Illisible dans la table,
-- lisible seulement avec la clé.
--
-- La clé ne doit JAMAIS être dans le dépôt. Elle est lue dans la
-- variable d'environnement NOVABANK_KEY :
--     export NOVABANK_KEY="..." ; psql -d novabank -f C3_pgcrypto.sql
-- =====================================================================
\set ON_ERROR_STOP on
\getenv cle NOVABANK_KEY
\if :{?cle}
\else
  \echo 'ERREUR : exportez NOVABANK_KEY avant de lancer ce script.'
  \quit 1
\endif

CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE core.customers ADD COLUMN IF NOT EXISTS phone_enc bytea;

\echo ''
\echo '--- 1. Avant : le téléphone est en clair dans la table ---'
SELECT customer_id, phone FROM core.customers WHERE phone IS NOT NULL ORDER BY customer_id LIMIT 3;

\echo ''
\echo '--- 2. Chiffrement, puis effacement de la version en clair ---'
UPDATE core.customers
SET phone_enc = pgp_sym_encrypt(phone, :'cle'),
    phone     = NULL
WHERE phone IS NOT NULL;

\echo ''
\echo '--- 3. Ce que voit quelqu''un qui lit la table (illisible) ---'
SELECT customer_id,
       phone                                    AS en_clair,
       left(encode(phone_enc, 'hex'), 48) || '…' AS stocke
FROM core.customers WHERE phone_enc IS NOT NULL ORDER BY customer_id LIMIT 3;

\echo ''
\echo '--- 4. Avec la bonne clé : lisible ---'
SELECT customer_id, pgp_sym_decrypt(phone_enc, :'cle') AS dechiffre
FROM core.customers WHERE phone_enc IS NOT NULL ORDER BY customer_id LIMIT 3;

\echo ''
\echo '--- 5. Avec une mauvaise clé : refusé ---'
DO $$
BEGIN
    PERFORM pgp_sym_decrypt(phone_enc, 'mauvaise-cle')
    FROM core.customers WHERE phone_enc IS NOT NULL LIMIT 1;
    RAISE NOTICE 'PROBLÈME : le déchiffrement a réussi sans la bonne clé';
EXCEPTION WHEN others THEN
    RAISE NOTICE 'Refusé, comme attendu : %', left(SQLERRM, 60);
END;
$$;

\echo ''
\echo '>>> C3 terminé. Le même texte chiffré deux fois donne deux résultats'
\echo '    différents (sel aléatoire) : on ne peut pas deviner les doublons.'
SELECT pgp_sym_encrypt('0612345678', :'cle') <> pgp_sym_encrypt('0612345678', :'cle')
       AS deux_chiffrements_differents;
