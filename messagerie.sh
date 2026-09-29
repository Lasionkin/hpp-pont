#!/data/data/com.termux/files/usr/bin/bash
# Second Firefox reserve aux messages (1 Boston, 2 ChatGPT, 3 Claude), sur l'ecran virtuel :98,
# avec son propre profil. Le pilote garde son Firefox sur :99 : plus aucune frappe ne se croise.
# Idempotent : ne relance que ce qui manque. Vue a distance : RealVNC sur 127.0.0.1:5901.
set -u
export LANG=C.UTF-8 LC_ALL=C.UTF-8
E=":98"; P="$HOME/.hpp-pont/messagerie-ff"; SRC="$HOME/.tbp/firefox_profile"; ICI="$(cd "$(dirname "$0")" && pwd)"
U=("https://muse.ai/" "https://chatgpt.com/c/6ab8cccd-4048-83ea-9584-b04d7c4aeccc" "https://claude.ai/chat/e412f7ab-20f3-4556-b744-bde25be3b243")
F="$HOME/.hpp-pont/onglets.txt"
if [ -s "$F" ]; then mapfile -t L < <(grep -E '^https://' "$F" | head -5); [ ${#L[@]} -gt 0 ] && U=("${L[@]}"); fi
pgrep -f "Xvfb $E " >/dev/null || { Xvfb $E -screen 0 1920x886x24 -ac -nolisten tcp >/dev/null 2>&1 & sleep 3; }
if [ ! -d "$P" ]; then
  mkdir -p "$P"; chmod 700 "$P"
  # Les sessions deja ouvertes du profil du pilote (cookies seulement) : aucune connexion a refaire.
  for f in cookies.sqlite cookies.sqlite-wal cert9.db key4.db permissions.sqlite; do [ -e "$SRC/$f" ] && cp "$SRC/$f" "$P/"; done
  printf 'user_pref("browser.shell.checkDefaultBrowser", false);\nuser_pref("browser.sessionstore.resume_from_crash", false);\nuser_pref("browser.tabs.warnOnClose", false);\n' > "$P/user.js"
fi
if ! pgrep -f "profile $P" >/dev/null; then
  DISPLAY=$E nohup firefox --no-remote --width=1920 --height=886 --profile "$P" "${U[@]}" >/dev/null 2>&1 &
  for i in $(seq 1 40); do DISPLAY=$E xdotool search --onlyvisible --name "Mozilla Firefox" >/dev/null 2>&1 && break; sleep 1; done
  sleep 8
fi
HPP_DISPLAY=$E python "$ICI/clavier_hpp.py" --si-besoin >/dev/null 2>&1
HPP_DISPLAY=$E python "$ICI/accents_hpp.py" --si-besoin >/dev/null 2>&1
pgrep -f "x11vnc -display $E" >/dev/null || x11vnc -display $E -localhost -nopw -forever -shared -rfbport 5901 -bg -o "$HOME/.hpp-pont/x11vnc-98.log" >/dev/null 2>&1
w=$(DISPLAY=$E xdotool search --onlyvisible --name "Mozilla Firefox" 2>/dev/null | head -1)
[ -n "$w" ] && echo "messagerie prete sur $E : $(DISPLAY=$E xdotool getwindowname "$w")" || { echo "ECHEC : pas de Firefox sur $E"; exit 1; }
