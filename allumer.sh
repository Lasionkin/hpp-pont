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
tunnel_vivant()   { [ -f "$D/cf.pid" ] && kill -0 "$(cat "$D/cf.pid")" 2>/dev/null && [ -f "$D/adresse.txt" ]; }
# Un ecran qui existe ne prouve pas que Firefox est dessus. Un fond noir avec un
# curseur en forme de croix, c'est la racine de X toute nue : l'ecran est la, le
# navigateur est ailleurs. Seule une fenetre reellement presente tranche.
firefox_sur_ecran() {
  command -v xdotool >/dev/null 2>&1 || return 0
  [ -n "$(DISPLAY="$E" xdotool search --class firefox 2>/dev/null | head -n 1)" ]
}

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
#
# LE MAILLON QUI MANQUAIT, trouve le 19 septembre 2026 : personne ne lancait Xvfb.
# ecran.sh renvoyait vers relancer.sh, et relancer.sh ne relance que le pont.
# Firefox demarrait donc sans ecran, pilotable mais invisible, et la saisie au
# clavier etait impossible faute d'ecran ou taper.
demarrer_xvfb() {
  if ! command -v Xvfb >/dev/null 2>&1; then
    rouge "Xvfb n'est pas installe. C'est LA cause de l'ecran noir."
    echo "          Firefox tourne sans ecran : pilotable, mais invisible, et"
    echo "          aucune frappe clavier n'est possible tant qu'il manque."
    echo "          Une seule ligne repare, puis retapez allume :"
    echo
    echo "              pkg install -y x11-repo && pkg install -y xorg-server-xvfb x11vnc xdotool"
    echo
    return 1
  fi
  attend "demarrage de l'ecran virtuel $E"
  local res
  res="${HPP_RESOLUTION:-1920x1080x24}"
  nohup Xvfb "$E" -screen 0 "$res" -nolisten tcp > "$D/xvfb.log" 2>&1 &
  echo $! > "$D/xvfb.pid"
  for i in $(seq 1 20); do ecran_present && break; sleep 1; done
  if ! ecran_present; then
    rouge "Xvfb n'a pas demarre"
    echo "          Journal de Xvfb, c'est la que la cause est ecrite :"
    tail -n 15 "$D/xvfb.log" 2>/dev/null | detail
    return 1
  fi
  vert "ecran virtuel $E cree en $res"
  return 0
}

reparer_ecran() {
  if ! ecran_present; then
    demarrer_xvfb || return 1
  fi
  if ! command -v x11vnc >/dev/null 2>&1; then
    rouge "x11vnc n'est pas installe."
    echo "          L'ecran existe mais rien ne le diffuse. Une ligne repare :"
    echo
    echo "              pkg install -y x11vnc"
    echo
    echo "          Puis retapez : allume"
    return 1
  fi
  attend "diffusion de l'affichage"
  bash "$ICI/ecran.sh" 2>&1 | detail
  for i in $(seq 1 15); do vnc_repond && break; sleep 1; done
  vnc_repond && return 0
  rouge "l'ecran ne repond toujours pas sur $V"
  echo "          Journal de x11vnc, les 15 dernieres lignes :"
  tail -n 15 "$D/x11vnc.log" 2>/dev/null | detail
  return 1
}

# Rattache Firefox a l'ecran. Mesure du 19 septembre 2026 : relancer.sh refuse de
# travailler si le tunnel n'est pas deja leve, et demarrer.sh refuse si le pont
# tourne encore. Il faut donc choisir la bonne porte, sinon Firefox reste aveugle
# et l'ecran reste noir avec sa croix.
rattacher_firefox() {
  attend "rattachement de Firefox a l'ecran, les sessions ouvertes sont conservees"
  export DISPLAY="$E"
  if tunnel_vivant; then
    bash "$ICI/relancer.sh" 2>&1 | detail
  else
    bash "$ICI/arreter.sh" >/dev/null 2>&1
    bash "$ICI/demarrer.sh" 2>&1 | detail
  fi
  for i in $(seq 1 60); do pont_repond && break; sleep 1; done
  for i in $(seq 1 20); do firefox_sur_ecran && break; sleep 1; done
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

# L'ecran d'abord. S'il naît avant le pont, Firefox naît dessus et rien n'a besoin
# d'etre relance ensuite. C'est l'ordre qui manquait.
ecran_neuf=0
pont_etait_vivant=0
pont_repond && pont_etait_vivant=1
if ! ecran_present; then
  demarrer_xvfb && ecran_neuf=1
fi
ecran_present && export DISPLAY="$E"

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

# Firefox etait deja ne aveugle : il faut le faire renaitre sur l'ecran neuf.
if [ "$ecran_neuf" = "1" ] && [ "$pont_etait_vivant" = "1" ]; then
  rattacher_firefox
fi

if vnc_repond && ecran_present; then
  vert "affichage diffuse sur 127.0.0.1:$V"
else
  reparer_ecran && vert "affichage diffuse sur 127.0.0.1:$V"
fi

# Le controle qui manquait : un ecran noir avec une croix passe tous les tests
# precedents. Celui-ci ne se laisse pas tromper.
if ecran_present; then
  if firefox_sur_ecran; then
    vert "Firefox est bien SUR l'ecran, l'image doit etre la"
  else
    rouge "l'ecran existe mais Firefox n'est pas dessus"
    echo "          C'est le fond noir avec le curseur en croix : la racine de X toute nue."
    attend "nouvelle tentative de rattachement"
    rattacher_firefox
    if firefox_sur_ecran; then
      vert "Firefox rattache, l'image doit etre la maintenant"
    else
      rouge "Firefox refuse de se rattacher a $E"
      echo "          Dernieres lignes du serveur MCP :"
      tail -n 15 "$D/enfant.stderr.log" 2>/dev/null | detail
    fi
  fi
fi

echo
etat
