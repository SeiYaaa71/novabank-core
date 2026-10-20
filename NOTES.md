# Notes de travail — ce qui a raté, et pourquoi

Le README déclare que ce projet a été fait avec l'aide d'une IA. Pour que
cette déclaration veuille dire quelque chose, voici les erreurs réellement
rencontrées et la façon dont elles ont été corrigées. Elles font partie du
travail.

## 1. La VM n'avait pas de clavier

**Symptôme :** taper dans la fenêtre VirtualBox n'affichait rien.

**Cause :** la VM était déclarée avec un clavier **PS/2**, un bus qui
n'existe pas sur la plateforme ARM `armv8virtual` (Mac Apple Silicon).
`/proc/bus/input/devices` ne listait aucun clavier.

**Correction :** `VBoxManage modifyvm <vm> --usb-xhci on --keyboard usb --mouse usbtablet`.

**Ce que ça apprend :** une plateforme matérielle émulée n'a pas les mêmes
bus qu'un PC. Le réflexe « ça doit marcher par défaut » est faux sur ARM.

## 2. L'utilisateur `postgres` ne pouvait pas lire les scripts

**Symptôme :** `psql: error: ... Permission denied` sur un fichier du dépôt.

**Cause :** `sudo -u postgres psql -f ~/novabank-core/...` — le compte
`postgres` n'a pas accès au dossier personnel d'un autre utilisateur.

**Correction :** création d'un rôle PostgreSQL au nom de l'utilisateur Unix,
avec authentification `peer`. On exécute `psql` sous son propre compte :
aucun `sudo`, et aucun mot de passe à stocker nulle part.

## 3. Les GRANT arrivaient trop tôt

**Symptôme :** `04_roles.sql` échouait : les vues et procédures citées dans
les `GRANT` n'existaient pas encore.

**Cause :** suivre la numérotation du sujet (droits en étape 3) alors que
les objets visés sont créés aux étapes 4 et 7.

**Correction :** `run_all.sh` exécute les droits en avant-dernier. La
numérotation des fichiers suit le sujet, l'ordre d'exécution suit les
dépendances. C'est expliqué dans le README.

## 4. Une requête de démonstration qui ne démontrait rien

**Symptôme :** après création des index, la requête « retraits du dernier
mois » restait en `Seq Scan`, sans aucun gain.

**Cause :** les données générées couvrent environ 24 jours. Demander
« les 30 derniers jours » sélectionne donc **toute** la table. Dans ce cas
un parcours complet est le bon plan, et aucun index ne peut faire mieux —
PostgreSQL avait raison, c'est la requête qui était mal choisie.

**Correction :** fenêtre ramenée à 2 jours (~8 % des lignes).

**Ce que ça apprend :** un index ne « rend pas rapide ». Il sert à éviter de
lire ce dont on n'a pas besoin. Si on a besoin de tout, il ne sert à rien.

## 5. L'index BRIN était inutile

**Symptôme :** même avec une fenêtre étroite, le BRIN sur `created_at`
n'était pas utilisé.

**Cause :** le script de génération insérait les écritures **compte par
compte** (`accounts CROSS JOIN generate_series`). La table était donc rangée
par compte, et les dates éparpillées partout. Or un BRIN ne retient que le
minimum et le maximum par groupe de blocs : sans regroupement physique des
valeurs proches, il ne peut rien éliminer.

**Correction :** ajout de `ORDER BY created_at` sur l'insertion. Un vrai
grand livre s'écrit de toute façon dans l'ordre du temps.

**Résultat :** le plan passe de `Parallel Seq Scan` (25,83 ms) à
`Bitmap Index Scan` sur le BRIN (6,54 ms).

## 6. Erreurs de syntaxe bêtes, mais réelles

- `AS table` dans un `SELECT` : `table` est un mot réservé SQL.
- Virgule manquante entre deux CTE après une réécriture du script.
- `--rtc-useutc` au lieu de `--rtc-use-utc` dans `VBoxManage` : la commande
  entière a été ignorée, et la VM est restée à 1 Go de RAM et 1 cœur sans
  que rien ne le signale.

Ces trois-là ont été trouvées en exécutant, pas en relisant.

## 7. Un script bloqué par son pagineur

**Symptôme :** le script TLS restait bloqué indéfiniment, sans message, sur
une commande `psql` qui fonctionnait pourtant en une fraction de seconde
quand on la lançait à la main.

**Cause :** le script était lancé par SSH avec un pseudo-terminal (`ssh -tt`,
nécessaire pour `sudo`). Quand `psql` écrit vers un terminal, il envoie sa
sortie dans un pagineur (`less`) — qui attend une touche que personne ne
tapera jamais. Le test manuel passait justement parce qu'il n'avait pas de
terminal.

**Correction :** `export PAGER=cat`, `psql -P pager=off`, et un `timeout 15`
en filet de sécurité.

**Ce que ça apprend :** un programme ne se comporte pas pareil selon qu'il
écrit vers un terminal ou vers un tuyau. Tout script automatisé doit couper
les comportements interactifs, sans quoi il se bloque au pire moment.

## 8. `sudo` et l'entrée standard

Deux fois le même piège :

- `sudo -S chpasswd <<< 'user:motdepasse'` : le `<<<` remplace l'entrée
  standard de **sudo**, qui lit donc `user:motdepasse` comme mot de passe.
  Solution : `printf 'motdepasse\nuser:nouveau\n' | sudo -S chpasswd` —
  sudo consomme la première ligne, `chpasswd` lit le reste.
- `sudo -u autre ...` imbriqué dans un script déjà lancé par `sudo -S` :
  l'entrée standard est déjà consommée, le sudo interne attend pour rien.
  Solution : supprimer le sudo imbriqué (ici en pointant `PGPASSFILE`).

## 9. Un mot de passe sans entropie

Le premier mot de passe de la VM valait quatre fois le même mot. Le
générateur appelait `awk 'BEGIN{srand()}'` quatre fois de suite ; `srand()`
sans argument s'initialise sur l'heure **en secondes**, donc les quatre
appels dans la même seconde tiraient le même mot.

Un générateur qui a l'air aléatoire ne l'est pas forcément. Corrigé avec le
module `secrets` de Python, et surtout **vérifié** : on contrôle que les
quatre mots diffèrent au lieu de le supposer.

## 10. Les bonus effacés par la reconstruction

`run_all.sh` détruit et recrée la base. Les bonus (colonne chiffrée, table
d'anomalies, fonctions de démonstration) disparaissaient donc à chaque
reconstruction, sans que rien ne le signale — on ne s'en apercevait qu'en
cherchant une colonne devenue absente.

D'où `run_bonus.sh`, séparé, avec l'ordre écrit noir sur blanc : `run_all.sh`
d'abord, `run_bonus.sh` ensuite.
