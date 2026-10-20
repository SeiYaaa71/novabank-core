-- =====================================================================
-- NovaBank Core — Étape 8 : les tests
-- On prouve deux choses : ce qui doit marcher marche, et ce qui doit
-- être refusé est refusé. Chaque test affiche OK ou ECHEC.
-- À exécuter en DERNIER (après les droits).
-- =====================================================================
\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS tests CASCADE;
CREATE SCHEMA tests;

CREATE TABLE tests.resultats (
    n        int GENERATED ALWAYS AS IDENTITY,
    famille  text,
    intitule text,
    verdict  text,
    detail   text
);

CREATE TABLE tests.fixtures (cle text PRIMARY KEY, val bigint);

-- --- petit harnais -------------------------------------------------
CREATE OR REPLACE FUNCTION tests.doit_echouer(p_fam text, p_intitule text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
    EXECUTE p_sql;
    INSERT INTO tests.resultats(famille, intitule, verdict, detail)
    VALUES (p_fam, p_intitule, 'ECHEC', 'accepté alors que cela devait être refusé');
EXCEPTION WHEN others THEN
    INSERT INTO tests.resultats(famille, intitule, verdict, detail)
    VALUES (p_fam, p_intitule, 'OK', 'refusé : ' || left(SQLERRM, 70));
END;
$fn$;

CREATE OR REPLACE FUNCTION tests.doit_reussir(p_fam text, p_intitule text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
    EXECUTE p_sql;
    INSERT INTO tests.resultats(famille, intitule, verdict, detail)
    VALUES (p_fam, p_intitule, 'OK', 'accepté');
EXCEPTION WHEN others THEN
    INSERT INTO tests.resultats(famille, intitule, verdict, detail)
    VALUES (p_fam, p_intitule, 'ECHEC', left(SQLERRM, 70));
END;
$fn$;

CREATE OR REPLACE FUNCTION tests.verifier(p_fam text, p_intitule text, p_cond boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
    INSERT INTO tests.resultats(famille, intitule, verdict, detail)
    VALUES (p_fam, p_intitule, CASE WHEN p_cond THEN 'OK' ELSE 'ECHEC' END, p_detail);
END;
$fn$;

-- --- jeu d'essai ----------------------------------------------------
DO $fx$
DECLARE c bigint; a1 bigint; a2 bigint;
BEGIN
    INSERT INTO core.customers (first_name, last_name, email, phone, birth_date, kyc_status)
    VALUES ('Test','Virement','test.virement@novabank.test','+33600000000', DATE '1990-05-05','verified')
    RETURNING customer_id INTO c;

    CALL core.sp_open_account(c, 'courant');
    CALL core.sp_open_account(c, 'epargne');

    SELECT min(account_id), max(account_id) INTO a1, a2
    FROM core.accounts WHERE customer_id = c;

    INSERT INTO core.transactions (account_id, tx_type, amount, balance_after)
    VALUES (a1, 'deposit', 20000, 0);
    INSERT INTO core.transactions (account_id, tx_type, amount, balance_after)
    VALUES (a2, 'deposit', 500, 0);

    INSERT INTO tests.fixtures VALUES ('client', c), ('compte_a', a1), ('compte_b', a2);
END;
$fx$;

-- =====================================================================
-- LES TESTS
-- =====================================================================
DO $t$
DECLARE
    a1 bigint := (SELECT val FROM tests.fixtures WHERE cle = 'compte_a');
    a2 bigint := (SELECT val FROM tests.fixtures WHERE cle = 'compte_b');
    cl bigint := (SELECT val FROM tests.fixtures WHERE cle = 'client');
    v_tx        bigint;
    v_avant     numeric;
    v_apres     numeric;
    v_nb_t      bigint;
    v_nb_x      bigint;
    v_somme_av  numeric;
    v_somme_ap  numeric;
BEGIN
-- --- 1. Les protections des tables (étape 2) ------------------------
PERFORM tests.doit_echouer('Tables', 'Email sans arobase refusé',
  $q$INSERT INTO core.customers (first_name,last_name,email,birth_date)
     VALUES ('A','B','pasunemail', DATE '1990-01-01')$q$);

PERFORM tests.doit_echouer('Tables', 'Email en double refusé',
  $q$INSERT INTO core.customers (first_name,last_name,email,birth_date)
     VALUES ('A','B','test.virement@novabank.test', DATE '1990-01-01')$q$);

PERFORM tests.doit_echouer('Tables', 'Client mineur refusé',
  format($q$INSERT INTO core.customers (first_name,last_name,email,birth_date)
            VALUES ('Jeune','Mineur','mineur@novabank.test', %L)$q$,
         (CURRENT_DATE - INTERVAL '10 years')::date));

PERFORM tests.doit_echouer('Tables', 'IBAN en double refusé',
  format($q$INSERT INTO core.accounts (customer_id, iban)
            VALUES (%s, (SELECT iban FROM core.accounts WHERE account_id=%s))$q$, cl, a1));

PERFORM tests.doit_echouer('Tables', 'Virement de montant négatif refusé',
  format($q$INSERT INTO core.transfers (from_account_id,to_account_id,amount)
            VALUES (%s,%s,-50)$q$, a1, a2));

PERFORM tests.doit_echouer('Tables', 'Virement vers le même compte refusé',
  format($q$INSERT INTO core.transfers (from_account_id,to_account_id,amount)
            VALUES (%s,%s,10)$q$, a1, a1));

-- --- 2. Le grand livre ne change plus (étape 6) ---------------------
SELECT tx_id INTO v_tx FROM core.transactions WHERE account_id = a1 ORDER BY tx_id DESC LIMIT 1;

PERFORM tests.doit_echouer('Grand livre', 'UPDATE d''une écriture refusé',
  format($q$UPDATE core.transactions SET amount = 1 WHERE tx_id = %s$q$, v_tx));

PERFORM tests.doit_echouer('Grand livre', 'DELETE d''une écriture refusé',
  format($q$DELETE FROM core.transactions WHERE tx_id = %s$q$, v_tx));

PERFORM tests.doit_echouer('Grand livre', 'TRUNCATE du grand livre refusé',
  $q$TRUNCATE core.transactions$q$);

-- --- 3. Le solde (étape 6) ------------------------------------------
SELECT balance INTO v_avant FROM core.accounts WHERE account_id = a2;

PERFORM tests.doit_echouer('Solde', 'Retrait supérieur au solde refusé',
  format($q$INSERT INTO core.transactions (account_id,tx_type,amount,balance_after)
            VALUES (%s,'withdrawal', %s, 0)$q$, a2, v_avant + 1));

PERFORM tests.doit_reussir('Solde', 'Un dépôt met le solde à jour tout seul',
  format($q$INSERT INTO core.transactions (account_id,tx_type,amount,balance_after)
            VALUES (%s,'deposit', 250.00, 0)$q$, a2));

SELECT balance INTO v_apres FROM core.accounts WHERE account_id = a2;
PERFORM tests.verifier('Solde', 'Le solde a augmenté d''exactement 250,00',
  v_apres = v_avant + 250.00, format('avant %s, après %s', v_avant, v_apres));

-- --- 4. Le virement (étape 7) ---------------------------------------
SELECT count(*) INTO v_nb_t FROM core.transfers;
SELECT count(*) INTO v_nb_x FROM core.transactions;
SELECT sum(balance) INTO v_somme_av FROM core.accounts WHERE account_id IN (a1, a2);

PERFORM tests.doit_reussir('Virement', 'Virement valide accepté',
  format($q$CALL core.sp_transfer(%s, %s, 1000.00, 'test ok')$q$, a1, a2));

PERFORM tests.verifier('Virement', 'Le virement a produit exactement 2 écritures',
  (SELECT count(*) FROM core.transactions) = v_nb_x + 2,
  format('%s écritures ajoutées', (SELECT count(*) FROM core.transactions) - v_nb_x));

SELECT sum(balance) INTO v_somme_ap FROM core.accounts WHERE account_id IN (a1, a2);
PERFORM tests.verifier('Virement', 'L''argent n''est ni créé ni détruit',
  v_somme_av = v_somme_ap, format('avant %s, après %s', v_somme_av, v_somme_ap));

-- Atomicité : un virement impossible ne doit RIEN laisser derrière lui.
SELECT count(*) INTO v_nb_t FROM core.transfers;
SELECT count(*) INTO v_nb_x FROM core.transactions;

PERFORM tests.doit_echouer('Virement', 'Virement sans provision refusé',
  format($q$CALL core.sp_transfer(%s, %s, 99999999.00, 'trop gros')$q$, a2, a1));

PERFORM tests.verifier('Virement', 'Le virement refusé n''a laissé AUCUNE trace',
  (SELECT count(*) FROM core.transfers) = v_nb_t
  AND (SELECT count(*) FROM core.transactions) = v_nb_x,
  'en entier, ou pas du tout');

-- --- 5. La fraude (étape 6) -----------------------------------------
PERFORM tests.doit_reussir('Fraude', 'Gros retrait accepté (compte approvisionné)',
  format($q$INSERT INTO core.transactions (account_id,tx_type,amount,balance_after)
            VALUES (%s,'withdrawal', 5000.00, 0)$q$, a1));

PERFORM tests.verifier('Fraude', 'Retrait de 5 000 : alerte BIG_WITHDRAWAL créée',
  EXISTS (SELECT 1 FROM core.fraud_alerts
          WHERE account_id = a1 AND rule_code = 'BIG_WITHDRAWAL'));

-- 5 virements coup sur coup depuis le même compte
FOR i IN 1..5 LOOP
    CALL core.sp_transfer(a1, a2, 1.00, 'rafale ' || i);
END LOOP;

PERFORM tests.verifier('Fraude', '5 virements en 10 minutes : alerte RAPID_TRANSFERS créée',
  EXISTS (SELECT 1 FROM core.fraud_alerts
          WHERE account_id = a1 AND rule_code = 'RAPID_TRANSFERS'));

-- --- 6. Le journal d'audit (étape 6) --------------------------------
UPDATE core.customers SET risk_level = 5 WHERE customer_id = cl;

PERFORM tests.verifier('Audit', 'Le changement est noté avec avant ET après',
  EXISTS (SELECT 1 FROM audit.audit_log
          WHERE table_name = 'core.customers' AND operation = 'UPDATE'
            AND (old_data->>'risk_level') IS DISTINCT FROM (new_data->>'risk_level')
            AND (new_data->>'customer_id')::bigint = cl));

PERFORM tests.verifier('Audit', 'Le journal retient qui a fait le changement',
  EXISTS (SELECT 1 FROM audit.audit_log WHERE db_user = session_user));

PERFORM tests.doit_echouer('Audit', 'Modifier le journal est refusé',
  $q$UPDATE audit.audit_log SET db_user = 'quelquun_dautre' WHERE log_id =
     (SELECT min(log_id) FROM audit.audit_log)$q$);

PERFORM tests.doit_echouer('Audit', 'Effacer le journal est refusé',
  $q$DELETE FROM audit.audit_log WHERE log_id = (SELECT min(log_id) FROM audit.audit_log)$q$);

-- --- 7. Les vues (étape 4) ------------------------------------------
PERFORM tests.verifier('Vues', 'La vue masquée ne laisse pas fuir l''email complet',
  NOT EXISTS (SELECT 1 FROM core.v_customers_masked
              WHERE email_masked = 'test.virement@novabank.test')
  AND EXISTS (SELECT 1 FROM core.v_customers_masked
              WHERE customer_id = cl AND email_masked LIKE 't***@%'));

PERFORM tests.doit_echouer('Vues', 'CHECK OPTION : fermer un compte via la vue est refusé',
  format($q$UPDATE core.v_accounts_active SET status='closed' WHERE account_id=%s$q$, a1));

PERFORM tests.verifier('Vues', 'La vue matérialisée contient des totaux',
  (SELECT count(*) FROM core.mv_account_monthly) > 0);

END;
$t$;

-- --- 8. Les droits (étape 3) ----------------------------------------
-- Testés à part : il faut changer de rôle, donc sortir du bloc précédent.
DO $r$
DECLARE refuse boolean := false; lecture_ok boolean := false;
BEGIN
    SET LOCAL ROLE novabank_analyst;
    BEGIN
        PERFORM email FROM core.customers LIMIT 1;
    EXCEPTION WHEN insufficient_privilege THEN refuse := true;
    END;
    BEGIN
        PERFORM count(*) FROM core.transactions;
        lecture_ok := true;
    EXCEPTION WHEN others THEN lecture_ok := false;
    END;
    RESET ROLE;
    PERFORM tests.verifier('Droits', 'Analyste : lire les emails est REFUSÉ', refuse,
      'c''est la réponse au problème n°1 du sujet');
    PERFORM tests.verifier('Droits', 'Analyste : lire les écritures reste autorisé', lecture_ok);
END;
$r$;

DO $r2$
DECLARE vue_ok boolean := false; table_refusee boolean := false;
BEGIN
    SET LOCAL ROLE novabank_support;
    BEGIN
        PERFORM count(*) FROM core.v_customers_masked;
        vue_ok := true;
    EXCEPTION WHEN others THEN vue_ok := false;
    END;
    BEGIN
        PERFORM email FROM core.customers LIMIT 1;
    EXCEPTION WHEN insufficient_privilege THEN table_refusee := true;
    END;
    RESET ROLE;
    PERFORM tests.verifier('Droits', 'Support : la vue masquée est lisible', vue_ok);
    PERFORM tests.verifier('Droits', 'Support : la table clients reste interdite', table_refusee);
END;
$r2$;

DO $r3$
DECLARE ecriture_refusee boolean := false; proc_ok boolean := false;
BEGIN
    SET LOCAL ROLE novabank_app;
    BEGIN
        INSERT INTO core.transactions (account_id, tx_type, amount, balance_after)
        VALUES ((SELECT val FROM tests.fixtures WHERE cle='compte_a'), 'deposit', 1, 0);
    EXCEPTION WHEN insufficient_privilege THEN ecriture_refusee := true;
             WHEN others THEN ecriture_refusee := false;
    END;
    RESET ROLE;
    PERFORM tests.verifier('Droits', 'Appli : écrire en direct dans le grand livre est REFUSÉ',
      ecriture_refusee, 'elle doit passer par sp_transfer');
END;
$r3$;

-- =====================================================================
-- LE BILAN
-- =====================================================================
\echo ''
\echo '================= RÉSULTATS DES TESTS ================='
SELECT n, famille, intitule, verdict, detail FROM tests.resultats ORDER BY n;

\echo ''
SELECT
    count(*)                                  AS total,
    count(*) FILTER (WHERE verdict = 'OK')    AS reussis,
    count(*) FILTER (WHERE verdict = 'ECHEC') AS echoues
FROM tests.resultats;

\echo ''
\echo '--- Alertes de fraude levées pendant les tests ---'
SELECT alert_id, account_id, rule_code, status, created_at FROM core.fraud_alerts ORDER BY alert_id;

\echo ''
\echo '--- Dernières lignes du journal d''audit ---'
SELECT log_id, table_name, operation, db_user, changed_at FROM audit.audit_log ORDER BY log_id DESC LIMIT 5;
