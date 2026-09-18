#!/data/data/com.termux/files/usr/bin/bash
# Arrete uniquement le pont et le tunnel lances par demarrer.sh (par numero de processus).
D="$HOME/.hpp-pont"
for f in pont cf; do
  if [ -f "$D/$f.pid" ]; then kill "$(cat "$D/$f.pid")" 2>/dev/null && echo "arrete : $f"; rm -f "$D/$f.pid"; fi
done
rm -f "$D/adresse.txt"
command -v termux-wake-unlock >/dev/null && termux-wake-unlock
echo "Termine. Le tunnel de ChatGPT n'a pas ete touche."
