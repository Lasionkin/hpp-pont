#!/data/data/com.termux/files/usr/bin/bash
# SAISIR : un mot pour taper un mot de passe dans le navigateur HPP,
# sans qu'aucune intelligence artificielle ne le voie passer.
ICI="$(cd "$(dirname "$0")" && pwd)"
exec python "$ICI/saisir.py" "$@"
