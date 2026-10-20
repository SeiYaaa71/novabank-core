#!/usr/bin/env bash
# =====================================================================
# BONUS C2 — Repérer une attaque
# On se trompe volontairement 5 fois de mot de passe, puis on retrouve
# les 5 échecs dans les journaux du serveur.
#
# Prérequis :
#   - log_connections activé (fait par scripts/01_server_setup.sh)
#   - votre compte doit pouvoir LIRE les journaux. Sur Ubuntu ils
#     appartiennent à postgres:adm en 640, donc :
#         sudo usermod -aG adm "$USER"     (puis rouvrir une session)
#     C'est préférable à un sudo dans le script : un outil de lecture de
#     journaux n'a aucune raison de tourner en root.
# =====================================================================
set -euo pipefail

PG_VERSION="$(psql --version | awk '{print $3}' | cut -d. -f1)"
LOG="/var/log/postgresql/postgresql-${PG_VERSION}-main.log"
CIBLE="novabank_analyst"
DEBUT="$(date '+%Y-%m-%d %H:%M:%S')"

if [[ ! -r "$LOG" ]]; then
    echo "Journal illisible : $LOG"
    echo "Ajoutez votre compte au groupe adm :  sudo usermod -aG adm \"$USER\""
    echo "puis rouvrez une session."
    exit 1
fi

echo "=== 1. Cinq tentatives avec un mauvais mot de passe ==="
for i in 1 2 3 4 5; do
    PGPASSWORD="mauvais-mot-de-passe-$i" \
    psql "host=127.0.0.1 dbname=novabank user=${CIBLE} sslmode=prefer" \
         -c "SELECT 1" >/dev/null 2>&1 \
      && echo "  tentative $i : acceptée (anormal !)" \
      || echo "  tentative $i : refusée"
done

echo
echo "=== 2. On retrouve ces échecs dans le journal ==="
echo "    Fichier : ${LOG}"
echo

grep -a "password authentication failed" "$LOG" \
  | awk -v debut="$DEBUT" '$0 >= debut' \
  | tail -10

NB=$(grep -ac "password authentication failed" "$LOG" || true)
echo
echo "    À noter : ici 5 tentatives donnent 5 lignes. Ce n'était pas le cas"
echo "    avant d'activer TLS (bonus C1) : avec sslmode=prefer, psql essayait"
echo "    d'abord en chiffré, se faisait refuser, puis retentait en clair —"
echo "    soit DEUX échecs journalisés par appel. Depuis que hostssl impose"
echo "    TLS, la poignée de main réussit et il n'y a plus qu'une tentative."
echo "    Un seuil d'alerte calibré sur l'ancien comportement se déclencherait"
echo "    deux fois trop tard."
echo
echo "    Le compteur ci-dessous est CUMULÉ sur toutes les exécutions"
echo "    précédentes : le journal n'est pas remis à zéro entre deux essais."
echo
echo "=== 3. Bilan ==="
echo "    Échecs d'authentification au total dans le journal : ${NB}"

echo
echo "=== 4. Comptage par utilisateur visé et par adresse source ==="
grep -a "password authentication failed" "$LOG" \
  | grep -oE 'user "[^"]+"' | sort | uniq -c | sort -rn
echo
echo "    Et par adresse source (le %h du log_line_prefix) :"
grep -a "password authentication failed" "$LOG" \
  | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | sort | uniq -c | sort -rn | head -5

echo
echo "=== 5. Ce qu'on en ferait en vrai ==="
cat <<'TXT'
    Cinq échecs d'affilée sur le même compte, c'est la signature d'une
    attaque par essais successifs. En production on brancherait fail2ban
    sur ce fichier pour bannir l'adresse source, et on ferait remonter une
    alerte. Le simple fait de journaliser ne protège pas : il faut que
    quelque chose lise le journal.
TXT
