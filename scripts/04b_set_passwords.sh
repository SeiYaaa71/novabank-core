#!/usr/bin/env bash
# =====================================================================
# Pose un mot de passe aléatoire sur chacun des 4 rôles.
# Les mots de passe sont écrits dans ~/.novabank/ (hors du dépôt Git)
# et dans un ~/.pgpass standard. Rien de secret n'entre dans Git.
# =====================================================================
set -euo pipefail
SECRETS_DIR="${HOME}/.novabank"
mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
: > "${SECRETS_DIR}/roles.env"; chmod 600 "${SECRETS_DIR}/roles.env"
PGPASS="${HOME}/.pgpass"; touch "$PGPASS"; chmod 600 "$PGPASS"

for role in novabank_analyst novabank_support novabank_app novabank_auditor; do
    pw="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
    psql -d novabank -q -c "ALTER ROLE ${role} PASSWORD '${pw}';"
    echo "${role}=${pw}" >> "${SECRETS_DIR}/roles.env"
    grep -v ":${role}:" "$PGPASS" > "${PGPASS}.tmp" 2>/dev/null || true
    mv "${PGPASS}.tmp" "$PGPASS" 2>/dev/null || true
    echo "127.0.0.1:5432:novabank:${role}:${pw}" >> "$PGPASS"
    chmod 600 "$PGPASS"
    echo "  mot de passe posé : ${role}"
done
echo "Secrets dans ${SECRETS_DIR}/roles.env (chmod 600, hors dépôt)."
