-- =====================================================================
-- NovaBank Core — Étape 3 : les 4 profils, au minimum de droits
--
-- Rappel du problème n°1 du sujet : "un employé a exporté tous les emails,
-- il avait trop de droits". La réponse est ici, ligne par ligne :
-- l'analyste n'a tout simplement PAS le droit de lire la colonne email.
-- Ce n'est pas une consigne, c'est refusé par le serveur.
--
-- Aucun mot de passe dans ce fichier : ils sont posés par
-- scripts/04b_set_passwords.sh, qui les tire au hasard hors du dépôt.
-- =====================================================================
\set ON_ERROR_STOP on

-- Par défaut PostgreSQL est trop généreux : on ferme avant d'ouvrir.
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE novabank FROM PUBLIC;

DROP ROLE IF EXISTS novabank_analyst;
DROP ROLE IF EXISTS novabank_support;
DROP ROLE IF EXISTS novabank_app;
DROP ROLE IF EXISTS novabank_auditor;

CREATE ROLE novabank_analyst LOGIN;
CREATE ROLE novabank_support LOGIN;
CREATE ROLE novabank_app     LOGIN;
CREATE ROLE novabank_auditor LOGIN;

COMMENT ON ROLE novabank_analyst IS 'Statistiques. Aucune donnée nominative.';
COMMENT ON ROLE novabank_support IS 'Aide aux clients. Lecture seule, email masqué.';
COMMENT ON ROLE novabank_app     IS 'L''application. Passe par les procédures, pas par les tables.';
COMMENT ON ROLE novabank_auditor IS 'Contrôle. Lit le journal, rien d''autre.';

GRANT CONNECT ON DATABASE novabank TO novabank_analyst, novabank_support, novabank_app, novabank_auditor;

-- ---------------------------------------------------------------------
-- ANALYSTE : des chiffres, jamais une identité.
-- GRANT SELECT (colonnes) : le droit s'arrête au niveau de la colonne.
-- ---------------------------------------------------------------------
GRANT USAGE ON SCHEMA core TO novabank_analyst;
GRANT SELECT (customer_id, birth_date, kyc_status, risk_level, created_at)
      ON core.customers TO novabank_analyst;
GRANT SELECT (account_id, customer_id, account_type, balance, status, opened_at)
      ON core.accounts  TO novabank_analyst;      -- pas d'IBAN
GRANT SELECT ON core.transactions TO novabank_analyst;
-- Volontairement absents : customers.email, customers.phone,
-- customers.first_name, customers.last_name, accounts.iban.

-- ---------------------------------------------------------------------
-- SUPPORT : doit reconnaître un client au téléphone, pas exporter le fichier.
-- Il ne touche jamais la table customers : il passe par la vue masquée.
-- ---------------------------------------------------------------------
GRANT USAGE ON SCHEMA core TO novabank_support;
GRANT SELECT ON core.v_customers_masked TO novabank_support;
GRANT SELECT ON core.v_account_statement TO novabank_support;
GRANT SELECT ON core.fraud_alerts TO novabank_support;
GRANT UPDATE (status) ON core.fraud_alerts TO novabank_support;   -- peut clore une alerte, rien de plus

-- ---------------------------------------------------------------------
-- APPLI : n'écrit jamais en direct. Elle appelle les procédures, qui
-- sont les seules à savoir faire un virement correctement.
-- ---------------------------------------------------------------------
GRANT USAGE ON SCHEMA core TO novabank_app;
GRANT SELECT ON core.accounts, core.transactions, core.transfers TO novabank_app;
GRANT EXECUTE ON PROCEDURE core.sp_transfer(bigint, bigint, numeric, text)  TO novabank_app;
GRANT EXECUTE ON PROCEDURE core.sp_open_account(bigint, text, text)         TO novabank_app;
GRANT EXECUTE ON FUNCTION  core.fn_account_statement(bigint, date, date)    TO novabank_app;
-- Aucun INSERT/UPDATE/DELETE direct : impossible de bricoler le grand livre.

-- ---------------------------------------------------------------------
-- AUDITEUR : lit le journal et les alertes. Ne voit aucune donnée client.
-- ---------------------------------------------------------------------
GRANT USAGE ON SCHEMA audit TO novabank_auditor;
GRANT SELECT ON audit.audit_log TO novabank_auditor;
GRANT USAGE ON SCHEMA core TO novabank_auditor;
GRANT SELECT ON core.fraud_alerts TO novabank_auditor;
-- Même l'auditeur ne peut pas effacer le journal : pas de DELETE accordé.

\echo '>>> Étape 3 terminée : 4 profils créés.'
