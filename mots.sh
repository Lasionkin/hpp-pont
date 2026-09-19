#!/data/data/com.termux/files/usr/bin/bash
# MOTS : rattrape les fautes de frappe sur les mots du navigateur HPP.
#
# A lire depuis ~/.bashrc par la ligne :
#   [ -f ~/hpp-pont/mots.sh ] && . ~/hpp-pont/mots.sh
#
# Tape "allulme", "alume", "allumer", "demarre", "reveil" : ca allume quand meme.
# Tape "saisie", "mdp", "tape" : ca ouvre la saisie du mot de passe.
# Tape "etat" : ca rend l'etat. Tape "froid" ou "relance" : ca rallume proprement.
# Tout autre mot inconnu retombe sur le comportement normal de Termux.

# On garde l'ancien gestionnaire de Termux, celui qui suggere des paquets,
# pour ne rien lui enlever. On ne le remplace que pour nos propres mots.
if declare -f command_not_found_handle >/dev/null 2>&1 \
   && ! declare -f hpp_mot_precedent >/dev/null 2>&1; then
  eval "hpp_mot_precedent() $(declare -f command_not_found_handle | tail -n +2)"
fi

command_not_found_handle() {
  local tape="$1"; shift
  local cible
  cible="$(python "$HOME/hpp-pont/mot_proche.py" "$tape" 2>/dev/null)"
  if [ -n "$cible" ]; then
    printf '  (lu "%s", je lance "%s")\n' "$tape" "$cible"
    # shellcheck disable=SC2086
    command $cible "$@"
    return $?
  fi
  if declare -f hpp_mot_precedent >/dev/null 2>&1; then
    hpp_mot_precedent "$tape" "$@"
    return $?
  fi
  printf 'bash: %s : commande introuvable\n' "$tape" >&2
  return 127
}
