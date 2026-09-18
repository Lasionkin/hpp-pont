#!/usr/bin/env python3
"""Corrige la perte de Maj dans RealVNC (x11vnc sans XKB) sur l'ecran virtuel :99.

Chaque caractere qui demande Maj (@ ! : A...) recoit sa propre touche, sans Maj.
x11vnc n'a alors plus besoin d'appuyer sur Maj pour le produire.

  python clavier_hpp.py             applique la correction (sauvegarde d'abord la table d'origine)
  python clavier_hpp.py --verifier  affiche l'etat, ne change rien
  python clavier_hpp.py --restaurer remet la table d'origine
  python clavier_hpp.py --si-besoin applique seulement si l'ecran virtuel a perdu la correction (pour le veilleur)
"""
import json, os, sys
from Xlib import XK, display
from Xlib.support import unix_connect as _uc

_get_socket_origine = _uc.get_socket


def _get_socket_termux(dname, protocol, host, dno):
    """Termux range le socket X dans $PREFIX/tmp, que python-xlib ne cherche pas."""
    for base in (os.environ.get("HPP_X11_DIR", ""), os.path.join(os.environ.get("PREFIX", ""), "tmp"),
                 os.environ.get("TMPDIR", ""), "/tmp"):
        chemin = os.path.join(base, ".X11-unix", f"X{dno}") if base else ""
        if chemin and os.path.exists(chemin):
            s = _uc._get_unix_socket(chemin)
            _uc._ensure_not_inheritable(s)
            return s
    return _get_socket_origine(dname, protocol, host, dno)


_uc.get_socket = _get_socket_termux

AFFICHAGE = os.environ.get("HPP_DISPLAY", ":99")
SAUVEGARDE = os.path.expanduser(os.environ.get("HPP_CLAVIER_SAUVEGARDE", "~/.hpp-pont/clavier-origine.json"))
TEST = "@!:#AZ?\"&"


def table(d):
    mn = d.display.info.min_keycode
    mx = d.display.info.max_keycode
    return mn, [list(row) for row in d.get_keyboard_mapping(mn, mx - mn + 1)]


def premiere_touche(rows, mn, ks):
    for i, row in enumerate(rows):
        if ks in row:
            return mn + i, row.index(ks)
    return None, None


def etat(d):
    mn, rows = table(d)
    res = []
    for c in TEST:
        kc, niveau = premiere_touche(rows, mn, ord(c))
        res.append(f"{c}: touche {kc}, niveau {niveau} ({'sans Maj' if niveau == 0 else 'avec Maj' if niveau == 1 else '?'})")
    return res


def appliquer(d):
    mn, rows = table(d)
    largeur = max(len(r) for r in rows)
    if not os.path.exists(SAUVEGARDE):
        os.makedirs(os.path.dirname(SAUVEGARDE), exist_ok=True)
        with open(SAUVEGARDE, "w") as f:
            json.dump({"min": mn, "rows": rows}, f)
    # Touches libres : vides, puis touches multimedia XF86 (inutiles sur cet ecran virtuel)
    vides = [i for i, r in enumerate(rows) if mn + i >= 9 and all(k == 0 for k in r)]
    xf86 = [i for i, r in enumerate(rows) if any(r) and all(k == 0 or 0x1008FE00 <= k <= 0x1008FFFF for k in r)]
    libres = vides + xf86
    a_deplacer = []
    for i, r in enumerate(rows):
        kc = mn + i
        if not (10 <= kc <= 61) or len(r) < 2:
            continue
        bas, haut = r[0], r[1]
        if haut and haut != bas and 0x20 <= haut <= 0x7e:
            a_deplacer.append((i, haut))
    deja = {k for r in rows for k in r[:1]}
    faits = 0
    for i, haut in a_deplacer:
        bas = rows[i][0]
        if haut in deja:
            rows[i] = [bas if k == haut else k for k in rows[i]]
            continue
        if not libres:
            break
        s = libres.pop(0)
        rows[s] = [haut, haut] + [0] * (largeur - 2)
        rows[i] = [bas if k == haut else k for k in rows[i]]
        deja.add(haut)
        faits += 1
    d.change_keyboard_mapping(mn, rows)
    d.sync()
    return faits, len(libres)


def restaurer(d):
    with open(SAUVEGARDE) as f:
        sv = json.load(f)
    d.change_keyboard_mapping(sv["min"], sv["rows"])
    d.sync()


def deja_corrige(d):
    mn, rows = table(d)
    return premiere_touche(rows, mn, ord("@"))[1] == 0


def main():
    try:
        d = display.Display(AFFICHAGE)
    except Exception as e:  # ecran virtuel pas encore demarre
        print(f"Ecran {AFFICHAGE} injoignable : {e}")
        sys.exit(0 if "--si-besoin" in sys.argv else 1)
    if "--si-besoin" in sys.argv:
        if deja_corrige(d):
            return
        faits, reste = appliquer(d)
        print(f"Correction reappliquee : {faits} caracteres.")
        return
    if "--restaurer" in sys.argv:
        restaurer(d)
        print("Table d'origine remise.")
    elif "--verifier" not in sys.argv:
        faits, reste = appliquer(d)
        print(f"Correction appliquee : {faits} caracteres ont maintenant leur propre touche ({reste} touches libres restantes).")
    print("\n".join(etat(d)))


if __name__ == "__main__":
    main()
