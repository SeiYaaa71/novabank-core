#!/usr/bin/env bash
# =====================================================================
# NovaBank Core — Étape 1 : installer PostgreSQL et limiter l'accès
# Idempotent : relançable sans casse.
# =====================================================================
set -euo pipefail

echo "[1/5] Installation des paquets"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq postgresql postgresql-contrib ufw

PG_VERSION="$(psql --version | awk '{print $3}' | cut -d. -f1)"
PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
echo "      PostgreSQL ${PG_VERSION} détecté"

echo "[2/5] Le serveur n'écoute que la machine elle-même"
# Aucune connexion depuis le réseau : la base n'est joignable qu'en local.
sudo sed -i "s/^#\?listen_addresses.*/listen_addresses = 'localhost'/" "$PG_CONF"
# Journalisation utile pour l'audit et le bonus C2.
sudo sed -i "s/^#\?log_connections.*/log_connections = 'all'/"        "$PG_CONF"
sudo sed -i "s/^#\?log_disconnections.*/log_disconnections = on/"     "$PG_CONF"
sudo sed -i "s/^#\?log_line_prefix.*/log_line_prefix = '%m [%p] %q%u@%d '/" "$PG_CONF"

echo "[3/5] Authentification : mot de passe chiffré obligatoire"
# En local (socket Unix) : peer, c'est le systeme qui prouve l'identite -> aucun mot de passe a stocker.
# En TCP sur 127.0.0.1 : scram-sha-256, mot de passe chiffre, pour les 4 roles applicatifs.
sudo cp "$PG_HBA" "${PG_HBA}.bak.$(date +%s)"
sudo tee "$PG_HBA" >/dev/null <<'HBA'
# TYPE  DATABASE  USER      ADDRESS         METHOD
local   all       postgres                  peer
local   all       all                       peer
host    all       all       127.0.0.1/32    scram-sha-256
host    all       all       ::1/128         scram-sha-256
# Tout le reste est refusé : aucune ligne n'autorise une adresse distante.
HBA

echo "[4/5] Pare-feu : SSH autorisé, port PostgreSQL fermé de l'extérieur"
sudo ufw allow 22/tcp            # à faire AVANT d'activer ufw, sinon on se coupe la branche
sudo ufw deny  5432/tcp
sudo ufw --force enable
sudo ufw status verbose

echo "[5/5] Redémarrage"
sudo systemctl restart postgresql
sudo systemctl is-active postgresql

echo "OK — serveur prêt et restreint au local."
