#!/usr/bin/env python3
"""
BONUS D4 - Trouver les comptes les plus différents des autres.

Le sujet renvoie à "un script fourni dans le guide". Ce guide ne m'ayant
pas été transmis, voici ma propre version.

Isolation Forest, en une phrase : l'algorithme découpe les données au
hasard, encore et encore. Un point banal, noyé dans la masse, demande
beaucoup de découpes avant de se retrouver seul. Un point atypique est
isolé en quelques coupes. Le score, c'est ce nombre de coupes.

Différence avec le score z du bonus D2 :
  - D2 regarde UNE colonne à la fois (le montant d'un retrait).
  - Ici on regarde le compte DANS SON ENSEMBLE : son solde, son nombre
    d'opérations, son retrait moyen, son retrait maximum... Un compte peut
    être anormal par la COMBINAISON de ses valeurs, alors qu'aucune prise
    séparément ne sort du lot.

Usage :
    ./bonus/data/D3_rapport_csv.sh            # produit le CSV d'entrée
    python3 bonus/data/D4_isolation_forest.py
"""

import glob
import os
import sys

try:
    import pandas as pd
    from sklearn.ensemble import IsolationForest
    from sklearn.preprocessing import StandardScaler
except ImportError as e:
    sys.exit(f"Dépendance manquante ({e.name}).\n"
             f"Sur Ubuntu : sudo apt-get install -y python3-pandas python3-sklearn")

RACINE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DOSSIER = os.path.join(RACINE, "out", "rapports")

# --- 1. Lire le dernier export -----------------------------------------
fichiers = sorted(glob.glob(os.path.join(DOSSIER, "comptes-pour-analyse-*.csv")))
if not fichiers:
    sys.exit(f"Aucun export trouvé dans {DOSSIER}.\n"
             f"Lancez d'abord : ./bonus/data/D3_rapport_csv.sh")

entree = fichiers[-1]
df = pd.read_csv(entree)
print(f"Lu : {os.path.basename(entree)} - {len(df)} comptes\n")

# --- 2. Choisir les colonnes qui décrivent le comportement -------------
COLONNES = ["balance", "nb_ecritures", "retrait_moyen", "retrait_max",
           "retrait_ecart_type", "nb_retraits", "nb_depots"]

manquantes = [c for c in COLONNES if c not in df.columns]
if manquantes:
    sys.exit(f"Colonnes absentes du CSV : {manquantes}")

X = df[COLONNES].fillna(0)

# Mise à l'échelle : sans cela, 'balance' (de l'ordre du million) écraserait
# 'nb_retraits' (de l'ordre de la centaine). Chaque colonne est ramenée à
# une moyenne de 0 et un écart-type de 1, pour qu'elles pèsent pareil.
X_norm = StandardScaler().fit_transform(X)

# --- 3. Entraîner le modèle --------------------------------------------
# contamination=0.02 : on annonce qu'environ 2 % des comptes sont atypiques.
# random_state fixé pour que deux exécutions donnent le même résultat.
modele = IsolationForest(
    n_estimators=200,
    contamination=0.02,
    random_state=42,
    n_jobs=-1,
)
df["anomalie"] = modele.fit_predict(X_norm)          # -1 = atypique, 1 = banal
df["score"] = modele.score_samples(X_norm)           # plus bas = plus atypique

atypiques = df[df["anomalie"] == -1].sort_values("score")

# --- 4. Résultats -------------------------------------------------------
print(f"Comptes jugés atypiques : {len(atypiques)} sur {len(df)} "
      f"({100 * len(atypiques) / len(df):.1f} %)\n")

print("Les 10 plus différents des autres :")
affichage = atypiques.head(10)[
    ["account_id", "score", "balance", "nb_retraits", "retrait_moyen", "retrait_max"]
].copy()
affichage["score"] = affichage["score"].round(4)
for c in ("balance", "retrait_moyen", "retrait_max"):
    affichage[c] = affichage[c].round(2)
print(affichage.to_string(index=False))

print("\nPour comparaison, un compte parfaitement banal :")
banal = df[df["anomalie"] == 1].sort_values("score", ascending=False).head(1)
print(banal[["account_id", "score", "balance", "nb_retraits",
            "retrait_moyen", "retrait_max"]].round(2).to_string(index=False))

# --- 5. Écrire le résultat ---------------------------------------------
sortie = os.path.join(DOSSIER, "comptes-atypiques.csv")
atypiques[["account_id", "score"] + COLONNES].to_csv(sortie, index=False)
print(f"\nÉcrit : {sortie}")

# --- 6. Recoupement avec le score z (bonus D2) -------------------------
zfichiers = sorted(glob.glob(os.path.join(DOSSIER, "retraits-anormaux-*.csv")))
if zfichiers:
    dz = pd.read_csv(zfichiers[-1])
    comptes_z = set(dz["account_id"].unique())
    comptes_if = set(atypiques["account_id"])
    communs = comptes_z & comptes_if
    print(f"\nRecoupement avec le score z (D2) :")
    print(f" comptes signalés par le score z        : {len(comptes_z)}")
    print(f" comptes signalés par Isolation Forest  : {len(comptes_if)}")
    print(f" signalés par les deux méthodes         : {len(communs)}")
    print("\n  Les deux méthodes ne voient pas la même chose, et c'est normal :")
    print(" le score z repère un MONTANT hors norme, Isolation Forest repère")
    print(" un COMPORTEMENT de compte hors norme. Un compte peut n'avoir que")
    print(" des montants ordinaires tout en se comportant bizarrement.")
