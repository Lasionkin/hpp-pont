#!/data/data/com.termux/files/usr/bin/bash
# Relance Claude Code dans la Debian du telephone, en un mot.
#
#   royal              ouvre Claude Code dans le dossier de travail
#   royal --shell      ouvre seulement un shell Debian, sans Claude Code
#   royal /root/site   ouvre Claude Code dans ce dossier de Debian
#
# Reglages possibles, sans toucher au script :
#   HPP_DISTRO=debian        nom de la distribution proot
#   HPP_PROJETS=/root/projets  dossier de travail par defaut
set -u
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
DISTRO="${HPP_DISTRO:-debian}"
DOSSIER="${HPP_PROJETS:-/root/projets}"
PORT="${HPP_PONT_PORT:-8765}"
case "$DISTRO" in */*|*..*|"") echo "Nom de distribution invalide : $DISTRO"; exit 1 ;; esac

if ! command -v proot-distro >/dev/null 2>&1; then
  echo "proot-distro n'est pas installe. Dans Termux : pkg install -y proot-distro"
  exit 1
fi

# Le pont doit repondre, sinon le connecteur hpp sera muet dans Claude Code.
if curl -fsS --max-time 5 "http://127.0.0.1:$PORT/sante" >/dev/null 2>&1; then
  echo "Pont HPP : en marche, le connecteur hpp repondra."
else
  echo "Pont HPP : NE REPOND PAS sur 127.0.0.1:$PORT."
  echo "Claude Code va s'ouvrir quand meme, mais sans le navigateur."
  echo "Pour remettre le pont, dans un autre onglet Termux : bash ~/hpp-pont/demarrer.sh"
fi

ouvrir() {
  # On ne devine jamais l'emplacement des distributions : c'est proot-distro qui sait.
  # On tente, et on n'explique qu'en cas de refus.
  "$@"
  code=$?
  if [ "$code" -ne 0 ]; then
    echo
    echo "proot-distro a refuse d'ouvrir \"$DISTRO\" (code $code)."
    echo "Distributions reellement installees :"
    { proot-distro list --installed 2>/dev/null || proot-distro list 2>/dev/null; } | sed 's/^/  /'
    echo
    echo "Relancez avec le bon nom, par exemple : HPP_DISTRO=debian-bookworm royal"
  fi
  return "$code"
}

if [ "${1:-}" = "--shell" ]; then
  ouvrir proot-distro login "$DISTRO"
  exit $?
fi
CIBLE="${1:-$DOSSIER}"
echo "Ouverture de Claude Code dans $CIBLE ..."
ouvrir proot-distro login "$DISTRO" -- bash -lc 'mkdir -p "$1" && cd "$1" && exec claude' _ "$CIBLE"
exit $?
