#!/data/data/com.termux/files/usr/bin/bash
# Reinstallation complete du pont HPP sur un telephone neuf, en une seule commande.
#
#   curl -fsSL https://raw.githubusercontent.com/Lasionkin/hpp-pont/main/reinstaller.sh | bash
#
# Ce script fait tout ce qui peut l'etre sans le compte d'Enock. Il s'arrete proprement
# et dit quoi faire pour les etapes qui exigent son compte ou son code.
# Il ne supprime rien : profil Firefox, cle du pont et tunnel existants sont conserves.
set -u
DEPOT="https://raw.githubusercontent.com/Lasionkin/hpp-pont/main"
DEST="$HOME/hpp-pont"
FICHIERS="hpp_pont.py demarrer.sh relancer.sh arreter.sh etat.sh bloques.txt clavier_hpp.py ecran.sh royal.sh veilleur.sh installer_auto.sh tunnel_fixe.sh reinstaller.sh"
echec=0

titre() { echo; echo "=== $* ==="; }
ok()    { echo "  OK   $*"; }
rate()  { echo "  RATE $*"; echec=1; }

titre "1. Environnement"
if [ -z "${PREFIX:-}" ] || [ ! -d "$PREFIX" ]; then
  echo "Ce script doit tourner dans Termux. Arret."; exit 1
fi
ok "Termux detecte ($(uname -m))"

titre "2. Paquets"
pkg update -y >/dev/null 2>&1
for p in python curl git procps x11vnc xdotool cloudflared termux-api; do
  if command -v "${p%%-*}" >/dev/null 2>&1 || pkg list-installed 2>/dev/null | grep -q "^$p/"; then
    ok "$p deja present"
  else
    if pkg install -y "$p" >/dev/null 2>&1; then ok "$p installe"; else rate "$p non installe"; fi
  fi
done
python -m pip install --quiet --upgrade python-xlib >/dev/null 2>&1 \
  && ok "python-xlib present" || rate "python-xlib non installe (correction clavier indisponible)"

titre "3. Pilote du navigateur"
if command -v tbp-mcp >/dev/null 2>&1; then
  ok "tbp-mcp present : $(command -v tbp-mcp)"
else
  rate "tbp-mcp absent. Reinstalle-le comme sur l'ancien telephone, puis relance ce script."
  echo "       Le pont ne sert a rien sans lui : c'est lui qui pilote Firefox."
fi

titre "4. Fichiers du pont"
mkdir -p "$DEST" && cd "$DEST" || { echo "Impossible de creer $DEST"; exit 1; }
for f in $FICHIERS; do
  if curl -fsSL -o "$f.neuf" "$DEPOT/$f"; then
    mv "$f.neuf" "$f"; ok "$f"
  else
    rm -f "$f.neuf"; rate "$f non telecharge"
  fi
done
chmod +x ./*.sh 2>/dev/null

titre "5. Demarrage automatique, veilleur et commande royal"
# Un veilleur deja en marche tournerait sur l'ancien code : on l'arrete d'abord.
if [ -f "$HOME/.hpp-pont/veilleur.pid" ]; then
  kill "$(cat "$HOME/.hpp-pont/veilleur.pid")" 2>/dev/null
  rm -f "$HOME/.hpp-pont/veilleur.pid"
  sleep 1
fi
bash "$DEST/installer_auto.sh"

titre "6. Ce qui reste, et qui exige ton compte"
cat <<'FIN'
  1. Autoriser Cloudflare une seule fois :
       cloudflared tunnel login
  2. Remettre l'adresse fixe du connecteur :
       bash ~/hpp-pont/tunnel_fixe.sh hpp.royalkelo.com
  3. Choisir le code d'acces du pont (il ne s'affiche jamais a l'ecran) :
       python ~/hpp-pont/hpp_pont.py --set-pin
  4. Dans Android, Options de developpement, activer
     "Desactiver les restrictions de processus enfant", sinon Android tue Termux.
  5. Dans claude.ai, le connecteur Navigateur HPP garde la meme adresse :
       https://hpp.royalkelo.com/mcp
  6. Claude Code vit dans une Debian proot, a reinstaller a part. Ensuite : royal
FIN

titre "Resultat"
if [ "$echec" -eq 0 ]; then
  echo "Tout ce qui est automatisable est en place."
else
  echo "Des etapes ont echoue, voir les lignes RATE ci-dessus."
fi
exit "$echec"
