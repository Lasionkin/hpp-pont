#!/data/data/com.termux/files/usr/bin/bash
# Veilleur HPP : surveille en boucle l'affichage VNC, le clavier, le pont et le tunnel,
# et les remet en marche seuls. Ne touche jamais au tunnel de ChatGPT.
# Intervalle : HPP_VEILLE_SECONDES, 30 secondes par defaut.
ICI="$(cd "$(dirname "$0")" && pwd)"
D="$HOME/.hpp-pont"; mkdir -p "$D"
L="$D/veilleur.log"

if [ -f "$D/veilleur.pid" ] && kill -0 "$(cat "$D/veilleur.pid")" 2>/dev/null; then
  echo "Le veilleur tourne deja."; exit 0
fi
echo $$ > "$D/veilleur.pid"
trap 'rm -f "$D/veilleur.pid"' EXIT

journal() { echo "$(date '+%F %T') $*" >> "$L"; }
vivant()  { [ -f "$D/$1.pid" ] && kill -0 "$(cat "$D/$1.pid")" 2>/dev/null; }
ecran_present() { [ -S /tmp/.X11-unix/X99 ] || [ -S "$PREFIX/tmp/.X11-unix/X99" ] || pgrep -f "Xvfb.*:99" >/dev/null; }
port_vnc_ouvert() {
  python -c 'import socket,sys
try:
    socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2).close()
except (OSError, ValueError):
    sys.exit(1)' "${HPP_VNC_PORT:-5900}" >/dev/null 2>&1
}

journal "veilleur demarre (intervalle ${HPP_VEILLE_SECONDES:-30}s)"

while true; do
  # 1. Affichage RealVNC. Sans lui, Enock ne voit plus l'ecran du telephone.
  #    Un x11vnc vivant ne suffit pas : apres un redemarrage du pilote il reste accroche
  #    a un ecran mort. Seul le port qui repond vraiment compte. ecran.sh fait le travail.
  if ecran_present && ! port_vnc_ouvert; then
    journal "l'ecran ne repond pas sur ${HPP_VNC_PORT:-5900} : reparation par ecran.sh"
    bash "$ICI/ecran.sh" >> "$L" 2>&1
    if port_vnc_ouvert; then journal "ecran verifie, l'image est revenue"
    else journal "ECHEC : l'ecran ne revient pas, voir $D/x11vnc.log"; fi
  fi

  # 2. Clavier : les touches a majuscule sautent apres chaque redemarrage de l'ecran.
  python "$ICI/clavier_hpp.py" --si-besoin 2>&1 | sed "s/^/$(date '+%F %T') clavier : /" >> "$L"

  # 3. Tunnel et pont.
  if ! vivant cf; then
    journal "tunnel absent : demarrage complet"
    bash "$ICI/arreter.sh" >> "$L" 2>&1
    bash "$ICI/demarrer.sh" >> "$L" 2>&1
  elif ! vivant pont; then
    journal "pont absent : relance"
    bash "$ICI/relancer.sh" >> "$L" 2>&1
  fi

  # 4. Adresse publique : le pont doit repondre de l'exterieur.
  if vivant pont && ! curl -fsS --max-time 8 http://127.0.0.1:"${HPP_PONT_PORT:-8765}"/sante >/dev/null 2>&1; then
    journal "le pont ne repond plus sur /sante : relance"
    bash "$ICI/relancer.sh" >> "$L" 2>&1
  fi

  tail -n 400 "$L" > "$L.tmp" 2>/dev/null && mv "$L.tmp" "$L"
  sleep "${HPP_VEILLE_SECONDES:-30}"
done
