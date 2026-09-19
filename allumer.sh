#!/data/data/com.termux/files/usr/bin/bash
# ALLUME : un seul mot pour remettre tout le navigateur HPP en marche.
#
#   allume            allume tout et rend l'adresse du connecteur
#   allume --etat     dit seulement ou on en est, ne demarre rien
#   allume --froid    arrete tout et rallume proprement
#
# Ce script ne touche JAMAIS au tunnel de ChatGPT, ni au profil Firefox,
# ni a aucun fichier deja existant. Il n'appelle que les scripts du dossier.
set -u
ICI="$(cd "$(dirname "$0")" && pwd)"
D="$HOME/.hpp-pont"; mkdir -p "$D"; chmod 700 "$D" 2>/dev/null
P="${HPP_PONT_PORT:-8765}"
V="${HPP_VNC_PORT:-5900}"
E="${HPP_ECRAN:-:99}"
N="${E#:}"

vert()  { printf '  OK      %s\n' "$*"; }
rouge() { printf '  ECHEC   %s\n' "$*"; }
attend(){ printf '  ...     %s\n' "$*"; }
detail(){ sed 's/^/          /'; }

pont_repond() { curl -fsS --max-time 6 "http://127.0.0.1:$P/sante" >/dev/null 2>&1; }
vnc_repond() {
  python -c 'import socket,sys
try:
    socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2).close()
except (OSError, ValueError):
    sys.exit(1)' "$V" >/dev/null 2>&1
}
ecran_present() {
  [ -S "/tmp/.X11-unix/X$N" ] || [ -S "${PREFIX:-/data/data/com.termux/files/usr}/tmp/.X11-unix/X$N" ] \
    || pgrep -f "Xvfb.*:$N" >/dev/null
}
veilleur_vivant() { [ -f "$D/veilleur.pid" ] && kill -0 "$(cat "$D/veilleur.pid")" 2>/dev/null; }

etat() {
  echo "ETAT DU NAVIGATEUR HPP"
  veilleur_vivant && vert "veilleur en marche"            || rouge "veilleur arrete"
  pont_repond     && vert "pont repond sur 127.0.0.1:$P"  || rouge "pont muet sur 127.0.0.1:$P"
  vnc_repond      && vert "ecran visible sur 127.0.0.1:$V" || rouge "ecran noir sur 127.0.0.1:$V"
  if [ -f "$D/tunnel-fixe.conf" ]; then
    vert "adresse FIXE : $(sed -n 's/^ADRESSE=//p' "$D/tunnel-fixe.conf" | head -n 1)/mcp"
    echo "          Elle ne change jamais. Rien a recoller dans Claude."
  elif [ -f "$D/adresse.txt" ]; then
    echo "  ADRESSE du connecteur, A RECOLLER DANS CLAUDE si elle a change :"
    echo; echo "      $(cat "$D/adresse.txt")"; echo
    echo "  Pour ne plus jamais la recoller :"
    echo "      bash ~/hpp-pont/tunnel_fixe.sh hpp.royalkelo.com"
  else
    rouge "aucune adresse de connecteur trouvee"
  fi
}

# Repare l'ecran et, surtout, MONTRE pourquoi quand ca rate.
# Un script qui cache la cause d'un echec fait perdre un tour a celui qui le lit.
reparer_ecran() {
  if ! command -v x11vnc >/dev/null 2>&1; then
    rouge "x11vnc n'est pas installe sur ce telephone."
    echo "          C'est la cause, et elle se repare en une ligne :"
    echo
    echo "              pkg install -y x11vnc"
    echo
    echo "          Puis retapez : allume"
    return 1
  fi
  if ! ecran_present; then
    attend "l'ecran virtuel $E n'existe pas, relance du pilote"
    bash "$ICI/relancer.sh" 2>&1 | detail
    for i in $(seq 1 25); do ecran_present && break; sleep 1; done
  fi
  if ! ecran_present; then
    rouge "l'ecran virtuel $E n'existe toujours pas apres relance"
    echo "          Dernieres lignes du journal du veilleur :"
    tail -n 12 "$D/veilleur.log" 2>/dev/null | detail
    return 1
  fi
  attend "reparation de l'affichage"
  bash "$ICI/ecran.sh" 2>&1 | detail
  for i in $(seq 1 15); do vnc_repond && break; sleep 1; done
  vnc_repond && return 0
  rouge "l'ecran ne repond toujours pas sur $V"
  echo "          Journal de x11vnc, les 15 dernieres lignes, c'est la que la cause est ecrite :"
  tail -n 15 "$D/x11vnc.log" 2>/dev/null | detail
  echo "          Copiez ces lignes a Claude, il n'a pas acces a ce fichier autrement."
  return 1
}

if [ "${1:-}" = "--etat" ]; then etat; exit 0; fi

if [ "${1:-}" = "--froid" ]; then
  echo "Arret complet avant rallumage."
  kill "$(cat "$D/veilleur.pid" 2>/dev/null)" 2>/dev/null; rm -f "$D/veilleur.pid"
  bash "$ICI/arreter.sh" >/dev/null 2>&1
  sleep 2
fi

echo "Allumage du navigateur HPP."
command -v termux-wake-lock >/dev/null && termux-wake-lock

if veilleur_vivant; then
  vert "veilleur deja en marche"
else
  attend "demarrage du veilleur"
  nohup bash "$ICI/veilleur.sh" >/dev/null 2>&1 &
  sleep 3
  veilleur_vivant && vert "veilleur demarre" || rouge "le veilleur n'a pas demarre"
fi

attend "attente du pont, jusqu'a 90 secondes"
for i in $(seq 1 90); do pont_repond && break; sleep 1; done
if pont_repond; then
  vert "pont vivant apres $i secondes"
else
  rouge "le pont ne repond toujours pas apres 90 secondes"
  echo "          Dernieres lignes du journal du veilleur :"
  tail -n 12 "$D/veilleur.log" 2>/dev/null | detail
fi

if vnc_repond; then vert "ecran deja visible"; else reparer_ecran && vert "ecran visible"; fi

echo
etat
