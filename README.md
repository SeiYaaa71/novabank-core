# NovaBank Core

Base de données d'une banque en ligne, sur PostgreSQL 18.
Module SQL avancé & administration PostgreSQL - Bachelor 2.

---

## Le problème qu'on résout

Le prototype de NovaBank avait trois défauts. La base livrée ici les rend
impossibles - non pas par consigne, mais parce que le serveur refuse.

| Le défaut du prototype | La réponse, et où elle est |
|---|---|
| Un employé a exporté tous les emails : il avait trop de droits. | `GRANT SELECT (colonne)` : l'analyste n'a pas le droit de lire `customers.email`. Le support ne voit qu'une vue masquée. -> `04_roles.sql`, `05_views.sql` |
| Deux virements en même temps ont donné un solde négatif. | `SELECT ... FOR UPDATE` dans le trigger de solde : le deuxième virement attend le premier. Plus la contrainte `balance >= 0`. -> `07_triggers.sql` |
| L'historique d'un compte mettait plus de 4 secondes. | Index `(account_id, created_at DESC)` : filtre et tri dans la même structure. **16,06 ms -> 0,056 ms** sur 1 000 000 d'écritures. -> `06_indexes.sql` |

---

## Démarrage

Sur une VM Ubuntu avec PostgreSQL installé et un rôle administrateur :

```bash
./run_all.sh
```

Pour partir d'une machine nue (installe PostgreSQL, ferme les accès, active le pare-feu) :

```bash
./run_all.sh --serveur
```

Le script détruit et reconstruit entièrement la base, génère le million
d'écritures, exécute les 32 tests et produit une sauvegarde.

---

## Les fichiers

| Fichier | Étape du sujet | Ce qu'il fait |
|---|---|---|
| `scripts/01_server_setup.sh` | 1 - Le serveur | Installe PostgreSQL. `listen_addresses = localhost`, `pg_hba.conf` réécrit, `ufw` : SSH ouvert, port 5432 fermé de l'extérieur. |
| `scripts/02_schema.sql` | 2 - Les tables | Schémas `core` et `audit`, les 6 tables, leurs contraintes. |
| `scripts/03_seed.sql` | 2 - Les données | 500 clients, 1 000 comptes, **1 000 000 d'écritures** via `generate_series`. |
| `scripts/04_roles.sql` | 3 - Les droits | Les 4 profils, au minimum de droits. |
| `scripts/04b_set_passwords.sh` | 3 | Tire les mots de passe au hasard, hors du dépôt. |
| `scripts/05_views.sql` | 4 - Les vues | Vue masquée, vue modifiable avec `CHECK OPTION`, vue matérialisée. |
| `scripts/06_indexes.sql` | 5 - Les index | 4 index + 1 partiel, avec `EXPLAIN ANALYZE` avant et après. |
| `scripts/07_triggers.sql` | 6 - Les triggers | Solde automatique, grand livre figé, fraude, audit. |
| `scripts/08_procedures.sql` | 7 - Les procédures | `sp_transfer`, `sp_open_account`, `fn_account_statement`. |
| `scripts/09_tests.sql` | 8 - Les tests | 32 tests : ce qui doit marcher, et ce qui doit être refusé. |
| `scripts/10_backup.sh` | 8 - La sauvegarde | `pg_dump` en deux formats + empreintes SHA-256. |
| `run_all.sh` | - | Rejoue tout, de zéro. |

### Pourquoi l'ordre d'exécution n'est pas 1-2-3-4...

`run_all.sh` exécute les droits (étape 3) en avant-dernier. Les `GRANT`
portent sur des vues (étape 4) et des procédures (étape 7) : ces objets
doivent exister avant qu'on puisse donner des droits dessus. L'ordre réel
est 2 -> 4 -> 5 -> 6 -> 7 -> **3** -> 8.

---

## Les 6 tables

Un client a plusieurs comptes. Un virement produit deux écritures.

```
customers --< accounts --< transactions >-- transfers
                  |              |
                  +--< fraud_alerts --+

audit.audit_log  <- alimenté par trigger depuis customers, accounts, fraud_alerts
```

**Choix de types qui comptent :**

- `numeric(18,2)` pour tout montant, jamais `float`. En virgule flottante,
  `0.1 + 0.2` ne fait pas exactement `0.3` : inacceptable sur de l'argent.
- `timestamptz` et non `timestamp` : on garde le fuseau, sinon un virement
  passé à 2 h du matin au changement d'heure devient ambigu.
- `jsonb` pour `old_data` / `new_data` : le journal reste lisible même si
  on ajoute une colonne à une table plus tard.
- Clés primaires en `GENERATED ALWAYS AS IDENTITY` : la norme SQL, et
  impossible à écraser par erreur (contrairement à `serial`).

---

## Ce qui est garanti, et par quel mécanisme

| Garantie demandée | Mécanisme |
|---|---|
| Email unique et valide | `UNIQUE` + `CHECK` avec expression régulière + stockage en minuscules |
| Client majeur | `CHECK (birth_date <= CURRENT_DATE - INTERVAL '18 years')` |
| Solde jamais négatif | `CHECK (balance >= 0)` **et** le trigger qui refuse l'opération avant de l'écrire |
| IBAN unique | `UNIQUE` + `CHECK` de format |
| Montant positif, comptes différents | `CHECK` sur `transfers` |
| Grand livre jamais modifié ni supprimé | Triggers `BEFORE UPDATE`, `BEFORE DELETE`, `BEFORE TRUNCATE` qui lèvent une erreur |
| Un virement = 2 écritures ou aucune | `sp_transfer`, sans bloc `EXCEPTION` : toute erreur annule les 3 lignes |
| Alerte si retrait >= 5 000 | Trigger `AFTER INSERT` sur `transactions` |
| Alerte si 5 virements en 10 min | Trigger `AFTER INSERT` sur `transfers` |
| Tout changement noté : qui, quand, avant, après | Trigger générique `audit.fn_log_change()` avec `to_jsonb(OLD)` / `to_jsonb(NEW)` |

Le journal d'audit est lui-même en écriture seule : un trigger refuse tout
`UPDATE` et tout `DELETE` dessus. Un journal qu'on peut réécrire ne prouve rien.

---

## Les 4 profils

| Profil | Ce qu'il peut | Ce qu'il ne peut pas |
|---|---|---|
| `novabank_analyst` | Lire les écritures, les âges, les niveaux de risque | **Lire un email, un nom, un téléphone, un IBAN** |
| `novabank_support` | Lire la vue masquée, les relevés, clore une alerte | Lire la table `customers` en direct |
| `novabank_app` | Appeler `sp_transfer`, `sp_open_account`, lire | **Écrire en direct dans le grand livre** |
| `novabank_auditor` | Lire le journal et les alertes | Lire les données clients, effacer le journal |

Aucun mot de passe n'est dans ce dépôt. `04b_set_passwords.sh` les tire au
hasard et les écrit dans `~/.novabank/roles.env` (chmod 600) et `~/.pgpass`,
tous deux hors dépôt et couverts par `.gitignore`.

---

## Sécurité du serveur

- `listen_addresses = 'localhost'` : la base n'écoute pas le réseau.
- `pg_hba.conf` : `peer` sur la socket locale (c'est le système qui prouve
  l'identité, donc aucun mot de passe à stocker), `scram-sha-256` en TCP.
  Aucune ligne n'autorise une adresse distante.
- `ufw` : port 22 ouvert, port 5432 explicitement fermé.

---

## Tests

`scripts/09_tests.sql` exécute **32 tests** et affiche un tableau OK/ECHEC.
Ils couvrent les contraintes, l'immuabilité du grand livre, le solde,
l'atomicité du virement, les deux règles de fraude, l'audit, les vues et
les droits de chaque rôle.

Le test le plus parlant : on lance un virement sans provision, puis on
vérifie qu'il n'a **rien** laissé derrière lui - ni ligne dans `transfers`,
ni écriture. En entier, ou pas du tout.

### Mesures d'index (dernière exécution, 1 000 000 d'écritures)

| Requête | Avant index | Après index | Plan d'exécution |
|---|---|---|---|
| 50 dernières écritures du compte 42 | 16,06 ms | **0,056 ms** | `Parallel Seq Scan` -> `Index Scan` |
| Retraits des 2 derniers jours | 25,83 ms | **6,54 ms** | `Parallel Seq Scan` -> `Bitmap Index Scan` (BRIN) |

La première requête est celle du sujet (" l'historique met plus de
4 secondes "). Elle lisait 9 865 blocs ; elle en lit maintenant 8.

---

## Les bonus - les deux parcours

```bash
./run_bonus.sh                  # tout ce qui touche la base
sudo ./run_bonus.sh --serveur   # TLS et détection d'attaque
```

**À lancer APRÈS `run_all.sh`**, jamais avant : `run_all.sh` reconstruit la
base de zéro et effacerait la colonne chiffrée, la table d'anomalies et les
fonctions de démonstration.

### Parcours Cyber

| # | Défi | Fichier | Résultat obtenu |
|---|---|---|---|
| C1 | Chiffrer les connexions | `bonus/cyber/C1_tls.sh` | **TLSv1.3**, `TLS_AES_256_GCM_SHA384`. `hostssl` dans pg_hba : une connexion TCP en clair n'a plus aucune ligne qui l'autorise, elle est refusée. |
| C2 | Repérer une attaque | `bonus/cyber/C2_detect_failed_logins.sh` | 5 échecs provoqués, puis retrouvés dans le journal avec l'heure, l'utilisateur visé et l'adresse source. |
| C3 | Cacher une donnée | `bonus/cyber/C3_pgcrypto.sql` | 501 téléphones chiffrés avec `pgp_sym_encrypt`, **0 en clair**. Illisibles sans la clé, qui n'est pas dans le dépôt. |
| C4 | Attaquer sa base | `bonus/cyber/C4_injection_sql.sql` | La fonction vulnérable laisse fuir **501 lignes** avec `' OR '1'='1`. La version corrigée (`format()` + `USING`) en renvoie **0**. |

### Parcours IA / Data

| # | Défi | Fichier | Résultat obtenu |
|---|---|---|---|
| D1 | Analyser | `bonus/data/D1_analyses.sql` | 5 requêtes : podium des avoirs par tranche d'âge (`rank`), tendance des dépôts jour après jour (`lag`), déciles de richesse (`ntile`), top des retraits, solde recalculé en somme glissante. |
| D2 | Retraits bizarres | `bonus/data/D2_zscore.sql` | Score z par rapport à la moyenne **de chaque compte**. 4 000 retraits au-delà de 3 écarts-types, rangés dans `core.anomalies_retraits`. Score maximum : 17,3. |
| D3 | Rapport automatique | `bonus/data/D3_rapport_csv.sh` | 5 fichiers CSV ouvrables dans Excel, produits par `\copy`. |
| D4 | Comptes bizarres | `bonus/data/D4_isolation_forest.py` | Isolation Forest sur 7 caractéristiques par compte. 21 comptes atypiques sur 1 002 - dont, sans qu'on le lui dise, les deux comptes de test à l'historique minuscule. |

**Pourquoi D2 et D4 ne donnent pas la même chose** : le score z regarde un
*montant* isolé, Isolation Forest regarde le *comportement* d'un compte dans
son ensemble (solde, nombre d'opérations, retrait moyen, retrait maximum...).
Un compte peut n'avoir que des montants ordinaires et se comporter
bizarrement - et inversement.

---

## Usage de l'IA

Ce projet a été réalisé avec l'assistance d'une IA, conformément aux règles
du sujet qui l'autorisent sous réserve de le déclarer. Tout a été exécuté et
vérifié sur la VM ; `NOTES.md` recense les erreurs rencontrées et corrigées.

---

## Limites connues

- Les données sont fabriquées par `generate_series`, pas issues de vrais flux.
  Les noms, emails et IBAN sont synthétiques (`@novabank.test`).
- Le solde de départ de chaque compte (1 000 000) est choisi pour que la
  génération ne puisse jamais produire un solde négatif ; ce n'est pas un
  montant réaliste.
- Pas de réplication ni de sauvegarde continue (PITR) : hors périmètre du sujet.
- Le score z (D2) signale presque tous les comptes, parce que la génération
  pose délibérément 4 gros retraits sur **chaque** compte. Sur des données
  réelles, ces anomalies seraient concentrées sur quelques comptes. Le
  recoupement avec Isolation Forest est donc à lire avec cette réserve.
- Le certificat TLS est auto-signé : il chiffre le transport mais ne prouve
  pas l'identité du serveur. En production il faudrait une autorité de
  certification et `sslmode=verify-full` côté client.
- Le **guide (document 2)** du sujet ne m'a pas été transmis ; les choix
  techniques sont les miens et peuvent différer de ceux qu'il préconise.
