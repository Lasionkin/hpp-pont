#!/data/data/com.termux/files/usr/bin/bash
# Demarre le tunnel HTTPS puis le pont MCP. N'arrete ni ne touche le tunnel de ChatGPT.
set -u
D="$HOME/.hpp-pont"; mkdir -p "$D"; chmod 700 "$D"
P="${HPP_PONT_PORT:-8765}"
CMD="${HPP_CMD:-tbp-mcp}"
ICI="$(cd "$(dirname "$0")" && pwd)"
# Outils interdits (un nom par ligne) : ceux qui arretent ou reinitialisent le navigateur partage
[ -f "$ICI/bloques.txt" ] && export HPP_BLOQUER="$(grep -v '^#' "$ICI/bloques.txt" | tr -s ' \n' ',')"
command -v cloudflared >/dev/null || { echo "Manque cloudflared. Lancez : pkg install -y cloudflared"; exit 1; }
if [ -f "$D/pont.pid" ] && kill -0 "$(cat "$D/pont.pid")" 2>/dev/null; then
  echo "Le pont tourne deja. Adresse du connecteur :"; cat "$D/adresse.txt"; exit 0
fi
# Arrete un ancien pont reste orphelin (ne vise que ce fichier, jamais le tunnel de ChatGPT)
pkill -f "$ICI/hpp_pont.py" 2>/dev/null && sleep 2
command -v termux-wake-lock >/dev/null && termux-wake-lock
FIXE="$D/tunnel-fixe.conf"
: > "$D/cf.log"
if [ -f "$FIXE" ]; then
  # Tunnel nomme Cloudflare : adresse fixe
  URL="$(sed -n 's/^ADRESSE=//p' "$FIXE" | head -n 1)"
  CONF="$(sed -n 's/^CONFIG=//p' "$FIXE" | head -n 1)"
  nohup cloudflared tunnel --no-autoupdate --config "$CONF" run > "$D/cf.log" 2>&1 &
  echo $! > "$D/cf.pid"
  for i in $(seq 1 40); do
    grep -q "Registered tunnel connection" "$D/cf.log" && break
    kill -0 "$(cat "$D/cf.pid")" 2>/dev/null || break
    sleep 1
  done
  if ! grep -q "Registered tunnel connection" "$D/cf.log"; then
    echo "ECHEC : le tunnel fixe ne s'est pas connecte en 40 secondes. Dernieres lignes :"; tail -n 5 "$D/cf.log"
    kill "$(cat "$D/cf.pid")" 2>/dev/null; rm -f "$D/cf.pid"; exit 1
  fi
else
  # Tunnel rapide : adresse qui change a chaque demarrage
  nohup cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:$P" > "$D/cf.log" 2>&1 &
  echo $! > "$D/cf.pid"
  URL=""
  for i in $(seq 1 40); do
    URL="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$D/cf.log" | head -n 1)"
    [ -n "$URL" ] && break
    sleep 1
  done
  if [ -z "$URL" ]; then
    echo "ECHEC : aucune adresse de tunnel en 40 secondes. Dernieres lignes :"; tail -n 5 "$D/cf.log"
    kill "$(cat "$D/cf.pid")" 2>/dev/null; rm -f "$D/cf.pid"; exit 1
  fi
fi
nohup python -u "$ICI/hpp_pont.py" --port "$P" --public-url "$URL" -- $CMD > "$D/pont.out" 2>&1 &
echo $! > "$D/pont.pid"
for i in $(seq 1 60); do
  grep -q "a l'ecoute" "$D/pont.out" && break
  kill -0 "$(cat "$D/pont.pid")" 2>/dev/null || break
  sleep 1
done
cat "$D/pont.out"
if ! grep -q "a l'ecoute" "$D/pont.out"; then
  echo "ECHEC : le pont n'a pas demarre. Erreurs du serveur MCP :"; tail -n 15 "$D/enfant.stderr.log" 2>/dev/null
  kill "$(cat "$D/pont.pid")" 2>/dev/null; kill "$(cat "$D/cf.pid")" 2>/dev/null; rm -f "$D/cf.pid" "$D/pont.pid"; exit 1
fi
echo "$URL/mcp" > "$D/adresse.txt"
echo
echo "ADRESSE DU CONNECTEUR (a coller dans Claude) :"
echo "$URL/mcp"
