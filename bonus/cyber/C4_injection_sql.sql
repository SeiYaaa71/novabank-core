-- =====================================================================
-- BONUS C4 — Attaquer sa propre base, puis la réparer
-- On écrit volontairement une fonction vulnérable, on l'exploite,
-- puis on la corrige avec format() et USING.
-- =====================================================================
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- LA VERSION VULNÉRABLE
-- Le défaut : la saisie de l'utilisateur est COLLÉE dans le texte de la
-- requête. Tout ce que l'utilisateur tape devient du code SQL.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_chercher_client_vulnerable(p_nom text)
RETURNS TABLE (customer_id bigint, last_name text, email text)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT customer_id, last_name, email FROM core.customers WHERE last_name = ''' || p_nom || '''';
END;
$$;

-- ---------------------------------------------------------------------
-- LA VERSION CORRIGÉE
--   %I : identifiant (nom de table/colonne), échappé par PostgreSQL
--   $1 + USING : la valeur ne traverse JAMAIS le texte de la requête.
--                Elle est transmise à part, comme un paramètre.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_chercher_client_sur(p_nom text)
RETURNS TABLE (customer_id bigint, last_name text, email text)
LANGUAGE plpgsql
SET search_path = pg_catalog, core
AS $$
BEGIN
    RETURN QUERY EXECUTE
        format('SELECT customer_id, last_name, email FROM %I.%I WHERE last_name = $1', 'core', 'customers')
        USING p_nom;
END;
$$;

\echo ''
\echo '=== 1. Usage normal : on cherche un nom précis ==='
SELECT count(*) AS lignes_rendues FROM core.fn_chercher_client_vulnerable('Nom1');

\echo ''
\echo '=== 2. L''ATTAQUE sur la version vulnérable ==='
\echo '    Saisie piégée :  Nom1'' OR ''1''=''1'
\echo '    La requête devient : ... WHERE last_name = ''Nom1'' OR ''1''=''1'''
\echo '    -> la condition est toujours vraie, tout le fichier client sort.'
SELECT count(*) AS lignes_rendues FROM core.fn_chercher_client_vulnerable('Nom1'' OR ''1''=''1');

\echo ''
\echo '    Les 3 premières lignes volées :'
SELECT customer_id, last_name, email
FROM core.fn_chercher_client_vulnerable('Nom1'' OR ''1''=''1')
ORDER BY customer_id LIMIT 3;

\echo ''
\echo '=== 3. La MÊME attaque sur la version corrigée ==='
\echo '    La saisie est traitée comme un simple texte : aucun client ne'
\echo '    s''appelle littéralement "Nom1'' OR ''1''=''1", donc 0 ligne.'
SELECT count(*) AS lignes_rendues FROM core.fn_chercher_client_sur('Nom1'' OR ''1''=''1');

\echo ''
\echo '    Et l''usage normal fonctionne toujours :'
SELECT count(*) AS lignes_rendues FROM core.fn_chercher_client_sur('Nom1');

\echo ''
\echo '>>> C4 terminé.'
\echo '    À retenir : échapper les quotes à la main ne suffit pas. La seule'
\echo '    méthode sûre est de ne jamais mettre la valeur dans le texte de'
\echo '    la requête — USING la transmet à part.'
