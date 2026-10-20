#!/usr/bin/env bash
# =====================================================================
# NovaBank Core - Étape 8 : la sauvegarde
# Deux formats : .dump (compressé, pour restaurer) et .sql (lisible).
# Les sauvegardes vont dans out/, qui n'est pas suivi par Git.
# =====================================================================
set -euo pipefail

DB="${1:-novabank}"
RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${RACINE}/out"
HORODATAGE="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DEST"

echo "[1/4] Sauvegarde compressée (format custom, restaurable par pg_restore)"
pg_dump -d "$DB" -F c -f "${DEST}/${DB}-${HORODATAGE}.dump"

echo "[2/4] Sauvegarde lisible (SQL en clair, pour relecture et pour Git si besoin)"
pg_dump -d "$DB" -F p --schema-only -f "${DEST}/${DB}-schema-${HORODATAGE}.sql"

echo "[3/4] Empreintes SHA-256 (preuve que le fichier n'a pas bougé)"
( cd "$DEST" && sha256sum "${DB}-${HORODATAGE}.dump" "${DB}-schema-${HORODATAGE}.sql" \
    > "${DB}-${HORODATAGE}.sha256" )
cat "${DEST}/${DB}-${HORODATAGE}.sha256"

echo "[4/4] Vérification : on relit le dump sans restaurer (pg_restore --list)"
pg_restore --list "${DEST}/${DB}-${HORODATAGE}.dump" | head -15
echo " ... ($(pg_restore --list "${DEST}/${DB}-${HORODATAGE}.dump" | grep -c ';' ) entrées au total)"

ls -lh "$DEST"
echo
echo "Pour restaurer sur une base neuve :"
echo " createdb novabank_restore"
echo " pg_restore -d novabank_restore ${DEST}/${DB}-${HORODATAGE}.dump"
