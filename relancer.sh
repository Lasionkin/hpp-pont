#!/data/data/com.termux/files/usr/bin/bash
# Relance seulement le pont (apres une mise a jour) en gardant le tunnel : l'adresse du connecteur ne change pas.
set -u
D="$HOME/.hpp-pont"
P="${HPP_PONT_PORT:-8765}"
CMD="${HPP_CMD:-tbp-mcp}"
ICI="$(cd "$(dirname "$0")" && pwd)"
[ -f "$ICI/bloques.txt" ] && export HPP_BLOQUER="$(grep -v '^#' "$ICI/bloques.txt" | tr -s ' \n' ',')"
if ! { [ -f "$D/cf.pid" ] && kill -0 "$(cat "$D/cf.pid")" 2>/dev/null && [ -f "$D/adresse.txt" ]; }; then
  echo "Le tunnel ne tourne pas. Lancez plutot : bash ~/hpp-pont/demarrer.sh"; exit 1
fi
URL="$(sed 's#/mcp$##' "$D/adresse.txt")"
[ -f "$D/pont.pid" ] && kill "$(cat "$D/pont.pid")" 2>/dev/null
pkill -f "$ICI/hpp_pont.py" 2>/dev/null
sleep 2
nohup python -u "$ICI/hpp_pont.py" --port "$P" --public-url "$URL" -- $CMD > "$D/pont.out" 2>&1 &
echo $! > "$D/pont.pid"
for i in $(seq 1 60); do
  grep -q "a l'ecoute" "$D/pont.out" && break
  kill -0 "$(cat "$D/pont.pid")" 2>/dev/null || break
  sleep 1
done
cat "$D/pont.out"
if ! grep -q "a l'ecoute" "$D/pont.out"; then
  echo "ECHEC : le pont n'a pas redemarre. Erreurs du serveur MCP :"; tail -n 15 "$D/enfant.stderr.log" 2>/dev/null
  kill "$(cat "$D/pont.pid")" 2>/dev/null; rm -f "$D/pont.pid"; exit 1
fi
echo
echo "Pont relance. Adresse du connecteur inchangee :"
cat "$D/adresse.txt"
