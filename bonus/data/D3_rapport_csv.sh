#!/usr/bin/env bash
# =====================================================================
# BONUS D3 - Rapport automatique en CSV
# Produit des fichiers ouvrables dans Excel ou LibreOffice.
#
# On utilise \copy (commande psql côté client) et non COPY (commande SQL
# côté serveur) : \copy écrit avec les droits de l'utilisateur qui lance
# le script, sans exiger d'être superutilisateur.
# =====================================================================
set -euo pipefail

DB="${DB:-novabank}"
RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEST="${RACINE}/out/rapports"
JOUR="$(date +%Y%m%d)"
mkdir -p "$DEST"

csv () {   # csv <nom_du_fichier> <requête>
    local nom="$1"; shift
    psql -d "$DB" -v ON_ERROR_STOP=1 \
         -c "\copy ($1) TO '${DEST}/${nom}-${JOUR}.csv' WITH (FORMAT csv, HEADER true)"
    printf '  %-28s %6s lignes\n' "${nom}-${JOUR}.csv" "$(( $(wc -l < "${DEST}/${nom}-${JOUR}.csv") - 1 ))"
}

echo "Rapports NovaBank - $(date '+%d/%m/%Y %H:%M')"
echo

csv "soldes-par-compte" "
    SELECT a.account_id, a.account_type, a.status, a.balance,
           c.customer_id, c.kyc_status, c.risk_level
    FROM core.accounts a JOIN core.customers c USING (customer_id)
    ORDER BY a.balance DESC"

csv "retraits-anormaux" "
    SELECT tx_id, account_id, amount, moyenne, ecart_type, score_z, created_at
    FROM core.anomalies_retraits
    ORDER BY abs(score_z) DESC"

csv "alertes-fraude" "
    SELECT f.alert_id, f.account_id, f.tx_id, f.rule_code, f.status, f.created_at,
           t.amount
    FROM core.fraud_alerts f LEFT JOIN core.transactions t USING (tx_id)
    ORDER BY f.created_at DESC"

csv "activite-mensuelle" "
    SELECT account_id, mois, nb_ecritures, total_credits, total_debits,
           solde_min, solde_max
    FROM core.mv_account_monthly
    ORDER BY mois DESC, account_id"

csv "comptes-pour-analyse" "
    SELECT a.account_id,
           a.balance,
           count(t.tx_id)                                                  AS nb_ecritures,
           coalesce(avg(t.amount)         FILTER (WHERE t.tx_type='withdrawal'), 0) AS retrait_moyen,
           coalesce(max(t.amount)         FILTER (WHERE t.tx_type='withdrawal'), 0) AS retrait_max,
           coalesce(stddev_samp(t.amount) FILTER (WHERE t.tx_type='withdrawal'), 0) AS retrait_ecart_type,
           count(*) FILTER (WHERE t.tx_type='withdrawal')                  AS nb_retraits,
           count(*) FILTER (WHERE t.tx_type='deposit')                     AS nb_depots
    FROM core.accounts a LEFT JOIN core.transactions t USING (account_id)
    GROUP BY a.account_id, a.balance
    ORDER BY a.account_id"

echo
echo "Écrits dans ${DEST}"
ls -lh "$DEST" | tail -n +2 | awk '{printf " %s  %s\n", $5, $9}'
echo
echo "Aperçu de soldes-par-compte :"
head -4 "${DEST}/soldes-par-compte-${JOUR}.csv"
