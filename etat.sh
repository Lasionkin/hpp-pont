#!/data/data/com.termux/files/usr/bin/bash
# Affiche l'etat du pont sans reveler aucun secret.
D="$HOME/.hpp-pont"
for f in pont cf; do
  if [ -f "$D/$f.pid" ] && kill -0 "$(cat "$D/$f.pid")" 2>/dev/null; then echo "$f : en marche"; else echo "$f : arrete"; fi
done
[ -f "$D/adresse.txt" ] && { echo "adresse : $(cat "$D/adresse.txt")"; curl -s -o /dev/null -w "test public sans jeton (401 attendu) : %{http_code}\n" -X POST "$(cat "$D/adresse.txt")"; }
echo "--- 8 dernieres lignes du journal"; tail -n 8 "$D/pont.log" 2>/dev/null
