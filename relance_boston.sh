#!/data/data/com.termux/files/usr/bin/bash
# Ecrit a Boston dans son chat muse.ai. Deux usages :
#  1) relance automatique (appelee par veilleur.sh) quand le Gardien constate un silence ou une stagnation ;
#  2) RELANCE_FICHIER=chemin : envoie tel quel le message contenu dans ce fichier (consigne du Juge).
# Sans IA, sans frais. Journal : ~/.hpp-pont/relance.log
#   RELANCE_SEUIL_MIN  minutes sans progres avant relance automatique (defaut 60)
#   RELANCE_PAUSE_MIN  minutes minimum entre deux relances automatiques (defaut 30)
#   RELANCE_ESSAI=1    n'ecrit rien, affiche seulement le message (test)
set -u
export LANG=C.UTF-8 LC_ALL=C.UTF-8 DISPLAY=:99
SEUIL_MIN="${RELANCE_SEUIL_MIN:-60}"
PAUSE_MIN="${RELANCE_PAUSE_MIN:-30}"
D="$HOME/.hpp-pont"; J="$D/relance.log"; DERNIERE="$D/relance.derniere"
mkdir -p "$D"
note() { echo "$(date '+%F %T') $*" >> "$J"; }

if [ -n "${RELANCE_FICHIER:-}" ]; then
  [ -s "$RELANCE_FICHIER" ] || { note "consigne absente ou vide : $RELANCE_FICHIER"; echo "consigne absente ou vide"; exit 1; }
  msg=$(tr '\r\n' '  ' < "$RELANCE_FICHIER" | cut -c1-1500)
  cause="consigne"; minutes=0; cliquet="-"
else
  etat="${RELANCE_ETAT_JSON:-$(curl -s -m 20 https://gardien-boston.kasiam-gardien.workers.dev/etat)}"
  decision=$(printf '%s' "$etat" | python -c '
import json, sys
try:
    d = json.load(sys.stdin)
    now, vu, prog = int(d["maintenant"]), int(d.get("vu_le") or 0), int(d.get("progres_le") or 0)
    cliquet = int(d.get("cliquet") or 0)
except Exception:
    print("illisible 0 0"); sys.exit()
seuil = int(sys.argv[1]) * 60000
if not vu or now - vu > 180000: print("silence", (now - vu) // 60000 if vu else 0, cliquet)
elif now - prog > seuil: print("stagnation", (now - prog) // 60000, cliquet)
else: print("ok 0", cliquet)
' "$SEUIL_MIN")
  read -r cause minutes cliquet <<< "$decision"
  [ "$cause" = "illisible" ] && { note "etat du Gardien illisible"; exit 0; }
  [ "$cause" = "ok" ] && exit 0
  if [ -f "$DERNIERE" ] && [ $(( $(date +%s) - $(cat "$DERNIERE") )) -lt $(( PAUSE_MIN * 60 )) ]; then exit 0; fi
  if [ "$cause" = "silence" ]; then quoi="aucun battement depuis $minutes min"; else quoi="aucun progrès depuis $minutes min"; fi
  msg="Boston, relance automatique du Gardien, ordre de Seigneur Enock : $cause, $quoi, cliquet $cliquet. Reprends maintenant le critère suivant et donne ici sa preuve (fichier et empreinte)."
fi
if [ "${RELANCE_ESSAI:-0}" = "1" ]; then echo "RELANCE: $msg"; exit 0; fi

# La fenetre principale de Firefox, jamais celle des outils de developpement.
w=""
for id in $(xdotool search --onlyvisible --name "Mozilla Firefox" 2>/dev/null); do
  nom=$(xdotool getwindowname "$id" 2>/dev/null)
  case "$nom" in *"Developer Tools"*) ;; *Boston*) w="$id"; break ;; esac
done
[ -z "$w" ] && { note "fenetre du chat Boston introuvable : message non envoye ($cause)"; echo "fenetre introuvable"; exit 1; }
xdotool windowactivate --sync "$w" 2>/dev/null
eval "$(xdotool getwindowgeometry --shell "$w")"
cx=$(( X + WIDTH * 808 / 1920 )); cy=$(( Y + HEIGHT * 815 / 886 ))
xdotool mousemove --sync "$cx" "$cy" click 1; sleep 0.5
xdotool type --delay 40 "$msg"; sleep 0.5
xdotool key Return
[ "$cause" = "consigne" ] || date +%s > "$DERNIERE"
note "message envoye ($cause, $minutes min, cliquet $cliquet)"
echo "envoye"
