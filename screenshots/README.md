# Captures d'écran du terminal

Prises sur la console de la VM Ubuntu, base `novabank` sur PostgreSQL 18.6.

| Capture | Étape | Ce qu'elle montre |
|---|---|---|
| `01-volumes.png` | 2 | PostgreSQL 18.6 sur aarch64, et **1 000 016 écritures** dans le grand livre. |
| `02-tests.png` | 8 | Les 32 tests par famille : Audit, Droits, Fraude, Grand livre, Solde, Tables, Virement, Vues. **0 échec partout.** |
| `03-droits-refuses.png` | 3 | Un analyste tente de lire les emails : `ERROR: permission denied for table customers`. C'est la réponse au problème n°1 du sujet. |
| `04-grand-livre-fige.png` | 6 | `DELETE` et `UPDATE` sur une écriture, tous deux refusés par le trigger, avec le conseil de passer par une écriture inverse. |
| `05-taille-index.png` | 5 | La taille de chaque index. Le BRIN est minuscule comparé au B-tree : c'est tout l'intérêt sur une table qui ne fait que grandir. |
| `06-bonus-C1-tls.png` | Bonus C1 | Connexion chiffrée en **TLSv1.3 / TLS_AES_256_GCM_SHA384**, puis la même connexion sans chiffrement, refusée faute de ligne dans `pg_hba.conf`. |
| `07-bonus-C4-injection.png` | Bonus C4 | L'injection SQL `' OR '1'='1` : **501 lignes volées** sur la fonction vulnérable, **0 ligne** sur la version corrigée. |
| `08-bonus-C3-chiffrement.png` | Bonus C3 | Les téléphones dans la table : colonne en clair vide, colonne chiffrée illisible (`c30d0407...`). |

Les sorties complètes correspondantes sont dans `docs/` :
`benchmark-index.txt` (EXPLAIN avant/après), `resultats-tests.txt` (les 32 tests),
`sortie-bonus.txt` (l'exécution des 8 bonus).
