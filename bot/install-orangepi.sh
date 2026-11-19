#!/bin/bash
# Установка бота Депости на Orange Pi / Raspberry Pi / любой Linux с systemd.
# Запуск: положи рядом bot.py и codes.txt, затем:  bash install-orangepi.sh
set -e
cd "$(dirname "$0")"
DIR=/opt/depost-bot
USER_NAME=$(whoami)

command -v python3 >/dev/null || { echo "Ставлю Python..."; sudo apt-get update && sudo apt-get install -y python3; }
echo "Python: $(python3 --version)"

sudo mkdir -p "$DIR"
sudo cp bot.py "$DIR/"
if [ -f codes.txt ]; then sudo cp codes.txt "$DIR/"; else echo "!!! codes.txt не найден рядом со скриптом. Потом положи его в $DIR"; fi
sudo chown -R "$USER_NAME":"$USER_NAME" "$DIR"

if [ ! -s "$DIR/token.txt" ]; then
  read -rp "Вставь токен бота из @BotFather: " TOKEN
  echo "$TOKEN" > "$DIR/token.txt"
fi
chmod 600 "$DIR/token.txt"

echo
echo "Если Telegram на этой плате открывается только через VPN, укажи HTTP-прокси VPN-клиента."
read -rp "Прокси (например http://127.0.0.1:10809, пусто = без прокси): " PROXY

ENV_LINE=""
[ -n "$PROXY" ] && ENV_LINE="Environment=HTTPS_PROXY=$PROXY"

sudo tee /etc/systemd/system/depost-bot.service >/dev/null <<UNIT
[Unit]
Description=Depost Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
WorkingDirectory=$DIR
ExecStart=/usr/bin/python3 -u $DIR/bot.py
$ENV_LINE
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now depost-bot
sleep 3
echo
sudo systemctl --no-pager status depost-bot | head -n 12
echo
echo "Готово. Бот запускается сам при включении платы."
echo "Логи:        journalctl -u depost-bot -f"
echo "Перезапуск:  sudo systemctl restart depost-bot"
echo "Теперь напиши боту в Telegram /iamadmin"
