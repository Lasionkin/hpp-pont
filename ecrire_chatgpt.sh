#!/data/data/com.termux/files/usr/bin/bash
# Ecrit a ChatGPT, dans la conversation unique du circuit, depuis le Firefox de messagerie (:98, onglet 2).
#   ECRIRE_FICHIER=chemin bash ecrire_chatgpt.sh   (message multi-lignes ; signature et heure ajoutees si absentes)
# La relance de Boston est mise en pause pendant la frappe, pour que les deux ne se croisent pas.
set -u
export LANG=C.UTF-8 LC_ALL=C.UTF-8 DISPLAY=:98
D="$HOME/.hpp-pont"; J="$D/chatgpt.log"; CIBLE="Concevoir une veille"
note() { echo "$(date '+%F %T') $*" >> "$J"; }
F="${ECRIRE_FICHIER:-}"
[ -s "$F" ] || { echo "message absent ou vide"; exit 1; }
grep -q "envoyé à" "$F" || sed -i "1s/^/Claude, envoyé à $(date '+%Hh%M') (heure de Montréal) : /" "$F"
touch "$D/relance.pause"; trap 'rm -f "$D/relance.pause"' EXIT
w=$(xdotool search --onlyvisible --name "Mozilla Firefox" 2>/dev/null | head -1)
[ -z "$w" ] && { note "Firefox de messagerie absent"; echo "Firefox de messagerie absent"; exit 1; }
xdotool windowactivate --sync "$w" 2>/dev/null
for k in 1 2 3 4 5; do
  case "$(xdotool getwindowname "$w")" in *"$CIBLE"*) break;; esac
  xdotool key ctrl+l; sleep 0.2; xdotool key Escape; xdotool key ctrl+Next; sleep 1.5
done
case "$(xdotool getwindowname "$w")" in *"$CIBLE"*) ;; *) note "onglet ChatGPT introuvable"; echo "onglet ChatGPT introuvable"; exit 1;; esac
xdotool key Escape; sleep 0.5
n=0; while IFS= read -r l; do [ $n -gt 0 ] && xdotool key shift+Return; xdotool type --delay 15 "$l"; n=$((n+1)); done < "$F"
sleep 2; xdotool key Return
note "message envoye ($n lignes)"; echo "envoye ($n lignes)"
