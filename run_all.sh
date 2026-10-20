#!/usr/bin/env bash
# =====================================================================
# NovaBank Core — tout refaire, de zéro, en une commande.
#
#   ./run_all.sh            base + données + tests
#   ./run_all.sh --serveur  en plus : installe et durcit PostgreSQL (sudo)
#
# ORDRE D'EXÉCUTION — il ne suit pas tout à fait la numérotation du sujet,
# et c'est voulu : les GRANT de l'étape 3 citent des vues (étape 4) et des
# procédures (étape 7). Ces objets doivent exister avant qu'on donne des
# droits dessus. Les droits passent donc en avant-dernier.
# =====================================================================
set -euo pipefail

DB="${DB:-novabank}"
ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ICI"

if [[ "${1:-}" == "--serveur" ]]; then
    echo "### Étape 1 — installation et durcissement du serveur"
    ./scripts/01_server_setup.sh
fi

echo "### Base de données : ${DB} (recréée de zéro)"
dropdb --if-exists "$DB"
createdb "$DB"

lancer () {
    echo
    echo "### $2"
    psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "scripts/$1"
}

lancer 02_schema.sql      "Étape 2a — les 6 tables"
lancer 03_seed.sql        "Étape 2b — 1 000 000 d'écritures"
lancer 05_views.sql       "Étape 4  — les vues"
lancer 06_indexes.sql     "Étape 5  — les index (mesure avant / après)"
lancer 07_triggers.sql    "Étape 6  — les triggers"
lancer 08_procedures.sql  "Étape 7  — les procédures"
lancer 04_roles.sql       "Étape 3  — les droits (en avant-dernier, voir ci-dessus)"

echo
echo "### Mots de passe des 4 rôles (tirés au hasard, hors dépôt)"
./scripts/04b_set_passwords.sh

lancer 09_tests.sql       "Étape 8  — les tests"

echo
echo "### Étape 8 — sauvegarde"
./scripts/10_backup.sh "$DB"

echo
echo "===================================================="
echo " Terminé. Base ${DB} reconstruite et testée."
echo "===================================================="
