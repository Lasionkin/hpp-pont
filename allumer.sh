#!/data/data/com.termux/files/usr/bin/bash
# ALLUME : un seul mot pour remettre tout le navigateur HPP en marche.
#
#   allume            allume tout et rend l'adresse du connecteur
#   allume --etat     dit seulement ou on en est, ne demarre rien
#   allume --froid    arrete tout et rallume proprement
#
# CE QUE CE SCRIPT NE FAIT PLUS, et c'est la correction du 19 septembre 2026 :
# il ne lance plus Xvfb lui-meme. La documentation de termux-browser-pilot est
# formelle, le demon demarre son propre serveur X et l'utilisateur ne doit pas
# en lancer un a la main. Deux Xvfb qui se disputent le meme numero d'ecran
# donnent exactement ce qu'on a mesure : un fond noir avec un curseur en croix,
# et un Firefox qui n'est sur aucun des deux.
#
# Ce script ne touche ni au tunnel de ChatGPT, ni au profil Firefox.
set -u
ICI="$(cd "$(dirname "$0")" && pwd)"
D="$HOME/.hpp-pont"; mkdir -p "$D"; chmod 700 "$D" 2>/dev/null
P="${HPP_PONT_PORT:-8765}"
V="${HPP_VNC_PORT:-5900}"

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
veilleur_vivant() { [ -f "$D/veilleur.pid" ] && kill -0 "$(cat "$D/veilleur.pid")" 2>/dev/null; }
tunnel_vivant()   { [ -f "$D/cf.pid" ] && kill -0 "$(cat "$D/cf.pid")" 2>/dev/null && [ -f "$D/adresse.txt" ]; }

# On ne devine JAMAIS le numero d'ecran. On demande au Xvfb qui tourne vraiment.
ecran_du_demon() {
  local ligne
  ligne="$(pgrep -a Xvfb 2>/dev/null | head -n 1)"
  [ -z "$ligne" ] && return 1
  printf '%s\n' "$ligne" | grep -o ' :[0-9]\+' | head -n 1 | tr -d ' '
}
firefox_sur_ecran() {
  local e="$1"
  command -v xdotool >/dev/null 2>&1 || return 0
  [ -n "$(DISPLAY="$e" xdotool search --class firefox 2>/dev/null | head -n 1)" ]
}

# Xvfb laisse par une ancienne version de ce script, qui empeche le demon
# de creer le sien. On ne tue que celui dont on a garde le PID, jamais un autre.
retirer_notre_xvfb() {
  [ -f "$D/xvfb.pid" ] || return 0
  local pid; pid="$(cat "$D/xvfb.pid" 2>/dev/null)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    attend "retrait de l'ecran lance a la main par l'ancienne version"
    kill "$pid" 2>/dev/null; sleep 2
  fi
  rm -f "$D/xvfb.pid"
}

manque_un_paquet() {
  local manquants=""
  for p in firefox Xvfb xdotool xclip openbox; do
    command -v "$p" >/dev/null 2>&1 || manquants="$manquants $p"
  done
  command -v x11vnc >/dev/null 2>&1 || manquants="$manquants x11vnc"
  [ -z "$manquants" ] && return 1
  rouge "paquets manquants :$manquants"
  echo "          La liste officielle de termux-browser-pilot est :"
  echo "          firefox xorg-server-xvfb xdotool xclip openbox python3"
  echo "          openbox est indispensable, sans lui le clavier ne passe pas dans Xvfb."
  echo "          Une ligne repare, puis retapez allume :"
  echo
  echo "              pkg install -y tur-repo x11-repo && pkg install -y firefox xorg-server-xvfb xdotool xclip openbox x11vnc"
  echo
  return 0
}

etat() {
  local e; e="$(ecran_du_demon || true)"
  echo "ETAT DU NAVIGATEUR HPP"
  veilleur_vivant && vert "veilleur en marche"            || rouge "veilleur arrete"
  pont_repond     && vert "pont repond sur 127.0.0.1:$P"  || rouge "pont muet sur 127.0.0.1:$P"
  if [ -n "$e" ]; then
    vert "ecran du demon : $e"
    firefox_sur_ecran "$e" && vert "Firefox est bien sur $e" || rouge "Firefox n'est pas sur $e"
  else
    rouge "aucun ecran virtuel ne tourne"
  fi
  vnc_repond && vert "affichage diffuse sur 127.0.0.1:$V" || rouge "affichage eteint sur 127.0.0.1:$V"
  if [ -f "$D/tunnel-fixe.conf" ]; then
    vert "adresse FIXE : $(sed -n 's/^ADRESSE=//p' "$D/tunnel-fixe.conf" | head -n 1)/mcp"
    echo "          Elle ne change jamais. Rien a recoller dans Claude."
  elif [ -f "$D/adresse.txt" ]; then
    echo "  ADRESSE du connecteur : $(cat "$D/adresse.txt")"
  else
    rouge "aucune adresse de connecteur trouvee"
  fi
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

manque_un_paquet && exit 1
retirer_notre_xvfb

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
  rouge "le pont ne repond pas apres 90 secondes"
  tail -n 12 "$D/veilleur.log" 2>/dev/null | detail
fi

# LE POINT QUI MANQUAIT, mesure du 19 septembre 2026 : le demon ne demarre le
# navigateur qu'a la PREMIERE COMMANDE recue. Tant que personne ne lui demande
# rien, il n'y a ni Firefox ni ecran, et c'est normal. Il faut donc le reveiller.
ECRAN="$(ecran_du_demon || true)"
if [ -z "$ECRAN" ]; then
  if command -v tbp >/dev/null 2>&1; then
    attend "reveil du navigateur, le demon ne le demarre qu'a la premiere commande"
    timeout 60 tbp start 2>&1 | detail
  else
    attend "reveil du navigateur"
  fi
  for i in $(seq 1 45); do ECRAN="$(ecran_du_demon || true)"; [ -n "$ECRAN" ] && break; sleep 1; done
fi
if [ -z "$ECRAN" ]; then
  rouge "aucun ecran virtuel, le navigateur n'a pas ete reveille"
  echo "          Ce n'est pas une panne : le demon ne demarre Firefox qu'a la"
  echo "          premiere commande recue. Demandez n'importe quoi a Claude, par"
  echo "          exemple d'ouvrir une page, puis retapez : allume"
  echo "          Le veilleur allumera l'affichage tout seul dans les 30 secondes"
  echo "          qui suivent la naissance de l'ecran."
  if command -v tbp >/dev/null 2>&1; then
    echo "          Dernieres lignes du serveur MCP :"
    tail -n 20 "$D/enfant.stderr.log" 2>/dev/null | detail
  fi
  echo
  etat
  exit 1
fi
vert "ecran du demon : $ECRAN"

if firefox_sur_ecran "$ECRAN"; then
  vert "Firefox est bien sur $ECRAN"
else
  rouge "l'ecran $ECRAN existe mais Firefox n'est pas dessus"
  echo "          Dernieres lignes du serveur MCP :"
  tail -n 20 "$D/enfant.stderr.log" 2>/dev/null | detail
fi

if vnc_repond; then
  vert "affichage deja diffuse sur 127.0.0.1:$V"
else
  attend "diffusion de l'affichage depuis $ECRAN"
  HPP_ECRAN="$ECRAN" HPP_DISPLAY="$ECRAN" bash "$ICI/ecran.sh" 2>&1 | detail
  for i in $(seq 1 15); do vnc_repond && break; sleep 1; done
  vnc_repond && vert "affichage diffuse sur 127.0.0.1:$V" || {
    rouge "rien n'ecoute sur $V"
    tail -n 15 "$D/x11vnc.log" 2>/dev/null | detail
  }
fi

echo
etat
