#!/usr/bin/env python3
"""SAISIR : taper un mot de passe dans le navigateur HPP sans qu'aucune IA ne le voie.

Le texte est lu au clavier du telephone, sans echo, sans passer par l'historique,
sans fichier temporaire, et il est envoye directement au champ qui a le focus dans
Firefox sur l'ecran virtuel. Il ne transite par aucun modele, aucun journal, aucun
reseau. Claude peut demander la saisie, il ne peut pas la lire.

  python saisir.py                 tape le texte, puis Entree
  python saisir.py --sans-entree   tape le texte, sans valider
  python saisir.py --tab           tape le texte puis Tab, pour passer au champ suivant
  python saisir.py --verifier      dit seulement si l'ecran virtuel repond
"""
import getpass, os, sys, time

os.environ.setdefault("DISPLAY", os.environ.get("HPP_DISPLAY", ":99"))

from Xlib import X, XK, display
from Xlib.ext import xtest
from Xlib.support import unix_connect as _uc

_origine = _uc.get_socket


def _socket_termux(dname, protocol, host, dno):
    """Termux range le socket X dans $PREFIX/tmp, la ou python-xlib ne regarde pas."""
    for base in (os.environ.get("HPP_X11_DIR", ""),
                 os.path.join(os.environ.get("PREFIX", ""), "tmp"),
                 os.environ.get("TMPDIR", ""), "/tmp"):
        chemin = os.path.join(base, ".X11-unix", f"X{dno}") if base else ""
        if chemin and os.path.exists(chemin):
            s = _uc._get_unix_socket(chemin)
            _uc._ensure_not_inheritable(s)
            return s
    return _origine(dname, protocol, host, dno)


_uc.get_socket = _socket_termux
AFFICHAGE = os.environ.get("HPP_DISPLAY", ":99")


def code_de(d, caractere):
    """Rend le code de touche qui produit ce caractere SANS Maj.

    clavier_hpp.py a deja donne sa propre touche a chaque caractere de niveau haut,
    justement pour que Maj ne soit jamais necessaire. On s'appuie sur ce travail.
    """
    ks = XK.string_to_keysym(caractere)
    if ks == 0:
        ks = ord(caractere)
    mn = d.display.info.min_keycode
    mx = d.display.info.max_keycode
    rows = d.get_keyboard_mapping(mn, mx - mn + 1)
    for i, row in enumerate(rows):
        for niveau, k in enumerate(row):
            if k == ks:
                return mn + i, niveau
    return None, None


def frappe(d, keycode, niveau):
    maj = None
    if niveau == 1:
        maj, _ = code_de(d, "Shift_L")
        if maj:
            xtest.fake_input(d, X.KeyPress, maj)
    xtest.fake_input(d, X.KeyPress, keycode)
    xtest.fake_input(d, X.KeyRelease, keycode)
    if maj:
        xtest.fake_input(d, X.KeyRelease, maj)
    d.sync()


def touche_nommee(d, nom):
    kc, niveau = code_de(d, nom)
    if kc is None:
        return False
    frappe(d, kc, 0)
    return True


def main():
    try:
        d = display.Display(AFFICHAGE)
    except Exception as e:
        print(f"Ecran {AFFICHAGE} injoignable : {e}")
        print("Le navigateur n'est pas allume. Tapez d'abord : allume")
        sys.exit(1)

    if "--verifier" in sys.argv:
        print(f"Ecran {AFFICHAGE} joignable. Le champ qui a le focus dans Firefox recevra la saisie.")
        return

    print("Le texte ne s'affichera pas et ne sera garde nulle part.")
    print("Il part directement dans le champ qui a le focus dans Firefox.")
    texte = getpass.getpass("Texte a taper : ")
    if not texte:
        print("Rien a taper.")
        return

    inconnus = []
    for c in texte:
        kc, niveau = code_de(d, c)
        if kc is None:
            inconnus.append(c)
    if inconnus:
        print(f"ECHEC : {len(inconnus)} caractere(s) sans touche sur cet ecran.")
        print("Lancez d'abord : python ~/hpp-pont/clavier_hpp.py")
        print("Aucune touche n'a ete envoyee.")
        sys.exit(1)

    time.sleep(0.2)
    for c in texte:
        kc, niveau = code_de(d, c)
        frappe(d, kc, niveau)
        time.sleep(0.012)

    if "--tab" in sys.argv:
        touche_nommee(d, "Tab")
    elif "--sans-entree" not in sys.argv:
        touche_nommee(d, "Return")

    del texte
    print(f"Saisi : {'*' * 8}. Rien n'a ete conserve.")


if __name__ == "__main__":
    main()
