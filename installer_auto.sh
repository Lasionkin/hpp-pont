#!/data/data/com.termux/files/usr/bin/bash
# Installe le demarrage automatique (integre a Termux Google Play, ou application Termux:Boot) et lance le veilleur.
ICI="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.termux/boot"
cat > "$HOME/.termux/boot/hpp-demarrage" <<FIN
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
sleep 30
exec bash "$ICI/veilleur.sh"
FIN
chmod 700 "$HOME/.termux/boot/hpp-demarrage"
echo "Demarrage automatique installe : $HOME/.termux/boot/hpp-demarrage"

# Commande "royal" utilisable partout, y compris dans un script ou un shell non interactif,
# la ou un alias de ~/.bashrc ne vaut rien. Le lien pointe vers le script gere depuis GitHub.
if [ -x "$ICI/royal.sh" ]; then
  mkdir -p "$PREFIX/bin"
  if ln -sf "$ICI/royal.sh" "$PREFIX/bin/royal" 2>/dev/null && [ -x "$PREFIX/bin/royal" ]; then
    echo "Commande royal installee : $PREFIX/bin/royal"
  else
    echo "ECHEC : la commande royal n'a pas pu etre creee dans $PREFIX/bin"
  fi
else
  echo "royal.sh absent ou non executable, commande royal non installee"
fi
nohup bash "$ICI/veilleur.sh" >/dev/null 2>&1 &
sleep 2
if [ -f "$HOME/.hpp-pont/veilleur.pid" ] && kill -0 "$(cat "$HOME/.hpp-pont/veilleur.pid")" 2>/dev/null; then
  echo "Veilleur en marche."
else
  echo "ECHEC : le veilleur ne tourne pas."
fi
