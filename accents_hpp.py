#!/usr/bin/env python3
"""Donne a chaque lettre accentuee du francais sa propre touche sur l'ecran virtuel :99.
xdotool n'a alors plus besoin de reaffecter une touche a la volee pour taper un accent :
la lettre existe deja dans la table du clavier, au niveau 0 (sans Maj).

  python accents_hpp.py             applique (sans toucher aux touches deja utilisees)
  python accents_hpp.py --verifier  affiche l'etat, ne change rien
  python accents_hpp.py --si-besoin applique seulement si une lettre manque (pour le veilleur)
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clavier_hpp as C          # reutilise la connexion Termux au socket X et la lecture de la table
from Xlib import display

LETTRES = "éèêëàâçùûîïôœÉÈÊÀÇ"
KEYSYM = {"œ": 0x13BD, "Œ": 0x13BC, "’": 0xAD3}  # hors Latin-1 : keysyms X11 dedies
# Signes typographiques francais, hors des 18 lettres canoniques : guillemets, apostrophe courbe, Œ.
SYMBOLES = "«»’Œ"

def keysym(c):
    return KEYSYM.get(c, ord(c))

def manquantes(d):
    mn, rows = C.table(d)
    return [c for c in LETTRES + SYMBOLES if C.premiere_touche(rows, mn, keysym(c))[0] is None]

def appliquer(d):
    mn, rows = C.table(d)
    largeur = max(len(r) for r in rows)
    vides = [i for i, r in enumerate(rows) if mn + i >= 9 and all(k == 0 for k in r)]
    xf86 = [i for i, r in enumerate(rows) if any(r) and all(k == 0 or 0x1008FE00 <= k <= 0x1008FFFF for k in r)]
    libres = vides + xf86
    faites, impossibles = [], []
    for c in manquantes(d):
        if not libres:
            impossibles.append(c)
            continue
        s = libres.pop(0)
        rows[s] = [keysym(c), keysym(c)] + [0] * (largeur - 2)
        faites.append(c)
    d.change_keyboard_mapping(mn, rows)
    d.sync()
    return faites, impossibles

def main():
    try:
        d = display.Display(C.AFFICHAGE)
    except Exception as e:
        print(f"Ecran {C.AFFICHAGE} injoignable : {e}")
        sys.exit(0 if "--si-besoin" in sys.argv else 1)
    if "--verifier" in sys.argv:
        m = manquantes(d)
        print("Toutes les lettres accentuees ont leur touche." if not m else f"Sans touche : {''.join(m)}")
        return
    if "--si-besoin" in sys.argv and not manquantes(d):
        return
    faites, impossibles = appliquer(d)
    print(f"Touches donnees : {''.join(faites) or 'aucune'}"
          + (f" ; IMPOSSIBLE faute de touche libre : {''.join(impossibles)}" if impossibles else ""))
    sys.exit(1 if impossibles else 0)

if __name__ == "__main__":
    main()
