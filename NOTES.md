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
