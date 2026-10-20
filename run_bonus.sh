#!/usr/bin/env bash
# =====================================================================
# NovaBank Core - les bonus, dans l'ordre.
#
#   ./run_bonus.sh             les bonus qui touchent seulement la base
#   sudo ./run_bonus.sh --serveur   en plus : TLS et détection d'attaque
#
# À lancer APRÈS ./run_all.sh : celui-ci reconstruit la base de zéro et
# effacerait donc tout ce que les bonus ajoutent (colonne chiffrée,
# table d'anomalies, fonctions de démonstration).
# =====================================================================
set -euo pipefail

DB="${DB:-novabank}"
ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ICI"
export PAGER=cat PSQL_PAGER=cat

# La clé de chiffrement n'est jamais dans le dépôt. On la crée au premier
# passage et on la relit ensuite, pour pouvoir redéchiffrer plus tard.
SECRETS="${HOME}/.novabank"
mkdir -p "$SECRETS"; chmod 700 "$SECRETS"
if [[ ! -s "${SECRETS}/pgcrypto.key" ]]; then
    openssl rand -base64 32 > "${SECRETS}/pgcrypto.key"
    chmod 600 "${SECRETS}/pgcrypto.key"
    echo "Clé de chiffrement créée dans ${SECRETS}/pgcrypto.key"
fi
export NOVABANK_KEY="$(cat "${SECRETS}/pgcrypto.key")"

lancer () {
    echo
    echo "=============================================================="
    echo " $2"
    echo "=============================================================="
    psql -P pager=off -d "$DB" -v ON_ERROR_STOP=1 -q -f "$1"
}

if [[ "${1:-}" == "--serveur" ]]; then
    [[ $EUID -eq 0 ]] || { echo "--serveur demande sudo."; exit 1; }
    echo "### C1 - chiffrer les connexions (TLS)"
    ./bonus/cyber/C1_tls.sh
    echo
    echo "### C2 - repérer une attaque dans les journaux"
    sudo -u "${SUDO_USER:-matteo}" ./bonus/cyber/C2_detect_failed_logins.sh
    exit 0
fi

lancer bonus/cyber/C3_pgcrypto.sql    "C3 - cacher un numéro de téléphone (pgcrypto)"
lancer bonus/cyber/C4_injection_sql.sql "C4 - injection SQL, puis correction"
lancer bonus/data/D1_analyses.sql      "D1 - cinq analyses (rank, lag, ntile)"
lancer bonus/data/D2_zscore.sql        "D2 - retraits anormaux (score z)"

echo
echo "=============================================================="
echo " D3 - rapport automatique en CSV"
echo "=============================================================="
./bonus/data/D3_rapport_csv.sh

echo
echo "=============================================================="
echo " D4 - comptes atypiques (Isolation Forest)"
echo "=============================================================="
if python3 -c "import pandas, sklearn" 2>/dev/null; then
    python3 -I bonus/data/D4_isolation_forest.py
else
    echo "pandas / scikit-learn absents. Pour les installer :"
    echo " sudo apt-get install -y python3-pandas python3-sklearn"
fi

echo
echo "=============================================================="
echo " Bonus terminés."
echo " TLS et détection d'attaque : sudo ./run_bonus.sh --serveur"
echo "=============================================================="
