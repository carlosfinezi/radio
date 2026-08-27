#!/usr/bin/env bash
# Canal de alerta. Recebe a mensagem como $1.
# Substituir pelo canal real (Telegram/e-mail) na homologação.
logger -t webradio-alerta "$1"
echo "[$(date -Is)] $1" >> /var/log/webradio/alertas.log
