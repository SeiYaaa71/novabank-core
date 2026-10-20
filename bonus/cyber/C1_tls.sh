#!/usr/bin/env bash
# =====================================================================
# BONUS C1 - Chiffrer les connexions à la base
# L'équivalent du cadenas d'un site web : entre le client et le serveur,
# tout passe chiffré. Sans cela, un mot de passe ou un relevé circule en
# clair sur le réseau.
#
# À lancer avec sudo.
# =====================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo."; exit 1; }

PG_VERSION="$(psql --version | awk '{print $3}' | cut -d. -f1)"
PG_DIR="/etc/postgresql/${PG_VERSION}/main"
PG_CONF="${PG_DIR}/postgresql.conf"
PG_HBA="${PG_DIR}/pg_hba.conf"
CERT_DIR="/var/lib/postgresql/${PG_VERSION}/main"

echo "[1/4] Certificat auto-signé (valable 365 jours)"
# En production on utiliserait un certificat signé par une autorité ;
# auto-signé suffit ici pour démontrer le chiffrement du transport.
openssl req -new -x509 -days 365 -nodes -text \
    -out "${CERT_DIR}/server.crt" \
    -keyout "${CERT_DIR}/server.key" \
    -subj "/C=FR/O=NovaBank/CN=novabank-db" 2>/dev/null
chmod 600 "${CERT_DIR}/server.key"
chown postgres:postgres "${CERT_DIR}/server.key" "${CERT_DIR}/server.crt"
openssl x509 -in "${CERT_DIR}/server.crt" -noout -subject -dates

echo "[2/4] Activation de TLS dans postgresql.conf"
sed -i "s|^#\?ssl *=.*|ssl = on|"                                 "$PG_CONF"
sed -i "s|^#\?ssl_cert_file *=.*|ssl_cert_file = '${CERT_DIR}/server.crt'|" "$PG_CONF"
sed -i "s|^#\?ssl_key_file *=.*|ssl_key_file = '${CERT_DIR}/server.key'|" "$PG_CONF"
grep -E "^ssl" "$PG_CONF"

echo "[3/4] pg_hba.conf : TLS OBLIGATOIRE en TCP"
# hostssl au lieu de host : une connexion TCP sans chiffrement n'a plus
# aucune ligne qui l'autorise, elle est donc refusée.
sed -i "s|^host  *all|hostssl all|" "$PG_HBA"
grep -vE "^#|^$" "$PG_HBA"

echo "[4/4] Redémarrage et vérification"
systemctl restart postgresql
sleep 2

# On vérifie avec un rôle qui a un mot de passe, en lisant le ~/.pgpass de
# l'utilisateur. Trois précautions pour qu'un script ne puisse jamais rester
# bloqué :
#   -w                  : psql n'ouvre jamais d'invite de mot de passe
#   PGCONNECT_TIMEOUT   : la tentative de connexion abandonne au bout de 10 s
#   timeout 15          : filet de sécurité, on tue au pire
UTILISATEUR="${SUDO_USER:-matteo}"
export PGPASSFILE="/home/${UTILISATEUR}/.pgpass"
export PGCONNECT_TIMEOUT=10
# INDISPENSABLE : sans cela, quand psql écrit dans un terminal il envoie sa
# sortie dans un pagineur (less), qui attend une touche. Un script lancé à
# distance reste alors bloqué indéfiniment, sans message d'erreur.
export PAGER=cat
export PSQL_PAGER=cat
CHAINE="host=127.0.0.1 dbname=novabank user=novabank_analyst"

echo " a) Connexion TCP chiffrée - ce que voit le serveur :"
timeout 15 psql -P pager=off -w "${CHAINE} sslmode=require" -tAc \
 "SELECT 'TLS actif=' || ssl || '  protocole=' || version || '  chiffrement=' || cipher
   FROM pg_stat_ssl WHERE pid = pg_backend_pid();" \
  || echo "    (échec - scripts/04b_set_passwords.sh a-t-il été lancé ?)"

echo
echo " b) La même connexion en REFUSANT le chiffrement :"
SORTIE="$(timeout 15 psql -P pager=off -w "${CHAINE} sslmode=disable" -tAc "SELECT 1" 2>&1 || true)"
if printf '%s' "$SORTIE" | grep -qiE "no pg_hba.conf entry|no encryption|SSL (connection )?required"; then
    echo "    REFUSÉE - plus aucune ligne de pg_hba.conf n'autorise le TCP en clair."
    printf '     message du serveur : %s\n' "$(printf '%s' "$SORTIE" | head -1)"
else
    echo "    ATTENTION : la connexion en clair passe encore."
    printf '%s\n' "$SORTIE" | head -2
fi

echo
echo " c) La socket locale, elle, n'a pas besoin de TLS :"
echo "    (rien ne circule sur le réseau, le chiffrement n'aurait pas d'objet)"
timeout 15 psql -P pager=off -w -d novabank -tAc \
 "SELECT 'connexion locale ok, ssl=' || coalesce((SELECT ssl::text FROM pg_stat_ssl WHERE pid=pg_backend_pid()),'f');" \
  2>/dev/null || echo "    (la socket locale utilise peer : lancez cette ligne sous votre compte)"

echo
echo "OK - C1 terminé."
