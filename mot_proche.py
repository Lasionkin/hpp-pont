#!/usr/bin/env python3
"""Rend le mot HPP le plus proche de ce qui a ete tape, ou rien.

Sert au rattrapage des fautes de frappe et des mots mal transcrits par la dictee
vocale. N'ecrit rien, ne lit aucun fichier, ne touche pas au reseau.
"""
import sys, unicodedata

FAMILLES = {
    "allume": ("allume", "allumer", "allumage", "allumetoi", "alume", "allune",
               "alllume", "demarre", "demarrer", "reveil", "reveille", "start"),
    "saisir": ("saisir", "saisie", "saisis", "taper", "motdepasse", "password", "mdp"),
    "allume --etat": ("etat", "status", "statut"),
    "allume --froid": ("froid", "redemarre", "redemarrer", "relance", "relancer",
                       "reinitialise"),
}


def sans_accent(mot):
    mot = unicodedata.normalize("NFD", mot)
    mot = "".join(c for c in mot if not unicodedata.combining(c))
    return "".join(c for c in mot.lower() if c.isalnum())


def distance(a, b):
    if len(a) < len(b):
        a, b = b, a
    if not b:
        return len(a)
    prec = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cour = [i]
        for j, cb in enumerate(b, 1):
            cour.append(min(prec[j] + 1, cour[j - 1] + 1, prec[j - 1] + (ca != cb)))
        prec = cour
    return prec[-1]


def main():
    if len(sys.argv) < 2:
        return
    tape = sans_accent(sys.argv[1])
    # Un mot de trois lettres ou moins se confond avec trop de vraies commandes.
    # En dessous de quatre lettres, on exige le mot exact ou on ne rend rien.
    if len(tape) < 4:
        for cible, mots in FAMILLES.items():
            if tape in (sans_accent(m) for m in mots):
                print(cible)
        return
    meilleur, score = None, 99
    for cible, mots in FAMILLES.items():
        for mot in mots:
            d = distance(tape, sans_accent(mot))
            if d < score:
                meilleur, score = cible, d
    # Un mot court se trompe moins loin qu'un mot long : le seuil suit la longueur,
    # et il ne depasse jamais deux, pour ne pas avaler une vraie commande voisine.
    seuil = 1 if len(tape) <= 5 else 2
    if meilleur and score <= seuil:
        print(meilleur)


if __name__ == "__main__":
    main()
