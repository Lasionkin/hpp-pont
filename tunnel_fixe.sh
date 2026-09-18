#!/data/data/com.termux/files/usr/bin/bash
# Cree le tunnel Cloudflare nomme "hpp-pont" et l'adresse fixe, puis redemarre le pont dessus.
# Prealable : cloudflared tunnel login (une fois, choisir le domaine dans la page qui s'ouvre).
set -eu
H="${1:-}"
NOM="hpp-pont"
ICI="$(cd "$(dirname "$0")" && pwd)"
D="$HOME/.hpp-pont"; C="$HOME/.cloudflared"
P="${HPP_PONT_PORT:-8765}"
[ -n "$H" ] || { echo "Usage : bash tunnel_fixe.sh hpp.royalkelo.com"; exit 1; }
[ -f "$C/cert.pem" ] || { echo "Il manque l'autorisation Cloudflare. Lancez d'abord : cloudflared tunnel login"; exit 1; }
id_tunnel() { cloudflared tunnel list -o json 2>/dev/null | python -c "import sys,json; print(next((t['id'] for t in json.load(sys.stdin) or [] if t['name']=='$NOM'), ''))" || true; }
ID="$(id_tunnel)"
if [ -z "$ID" ]; then
  cloudflared tunnel create "$NOM"
  ID="$(id_tunnel)"
fi
[ -n "$ID" ] || { echo "ECHEC : tunnel $NOM introuvable apres creation."; exit 1; }
[ -f "$C/$ID.json" ] || { echo "ECHEC : fichier d'identification $C/$ID.json absent."; exit 1; }
cat > "$C/$NOM.yml" <<FIN
tunnel: $ID
credentials-file: $C/$ID.json
ingress:
  - hostname: $H
    service: http://127.0.0.1:$P
  - service: http_status:404
FIN
cloudflared tunnel route dns --overwrite-dns "$NOM" "$H"
mkdir -p "$D"
printf 'ADRESSE=https://%s\nCONFIG=%s\n' "$H" "$C/$NOM.yml" > "$D/tunnel-fixe.conf"
chmod 600 "$D/tunnel-fixe.conf" "$C/$NOM.yml"
echo "Tunnel fixe pret. Redemarrage du pont sur https://$H ..."
bash "$ICI/arreter.sh" >/dev/null
bash "$ICI/demarrer.sh"
