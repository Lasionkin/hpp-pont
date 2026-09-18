#!/data/data/com.termux/files/usr/bin/bash
# Rend l'ecran du navigateur HPP a Enock, tout seul.
# A coller dans Termux uniquement si l'image reste noire apres une reparation :
#   bash ~/hpp-pont/ecran.sh
# Ne touche ni au pont, ni au tunnel, ni au profil Firefox, ni au tunnel de ChatGPT.
set -u
D="$HOME/.hpp-pont"; mkdir -p "$D"
E="${HPP_ECRAN:-:99}"
N="${E#:}"
P="${HPP_VNC_PORT:-5900}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

ecran_present() {
  [ -S "/tmp/.X11-unix/X$N" ] || [ -S "$PREFIX/tmp/.X11-unix/X$N" ] || pgrep -f "Xvfb.*:$N" >/dev/null
}
port_ouvert() {
  if command -v nc >/dev/null 2>&1; then nc -z 127.0.0.1 "$P" >/dev/null 2>&1
  else python -c 'import socket,sys
try:
    socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2).close()
except (OSError, ValueError):
    sys.exit(1)' "$P" >/dev/null 2>&1
  fi
}

echo "1. attente de l'ecran virtuel $E"
for i in $(seq 1 25); do ecran_present && break; sleep 1; done
if ! ecran_present; then
  echo "   ECHEC : l'ecran virtuel $E n'existe pas."
  echo "   Le pilote n'est pas lance. Faites d'abord : bash ~/hpp-pont/relancer.sh"
  exit 1
fi
echo "   ecran virtuel $E present"

if pgrep -x x11vnc >/dev/null && port_ouvert; then
  echo "2. x11vnc repond deja sur 127.0.0.1:$P, rien a relancer"
else
  pgrep -x x11vnc >/dev/null && { echo "2. x11vnc tourne mais ne repond plus : remplacement"; pkill -x x11vnc; sleep 1; } \
                             || echo "2. x11vnc absent : demarrage"
  x11vnc -display "$E" -localhost -nopw -forever -shared -rfbport "$P" -bg -o "$D/x11vnc.log" >/dev/null 2>&1
fi

echo "3. verification reelle du port $P"
for i in $(seq 1 12); do port_ouvert && break; sleep 1; done
if port_ouvert; then
  echo "   OK. Ouvrez RealVNC sur 127.0.0.1:$P, l'image est revenue."
else
  echo "   ECHEC : rien n'ecoute sur $P. Dernieres lignes de $D/x11vnc.log :"
  tail -n 10 "$D/x11vnc.log" 2>/dev/null
  exit 1
fi

# Les touches a majuscule sautent apres chaque nouvel ecran.
python "$(cd "$(dirname "$0")" && pwd)/clavier_hpp.py" --si-besoin 2>&1 | sed 's/^/4. clavier : /'
