#!/bin/bash
# botxray.sh - Instalador Automatizado (DragonCore V7.7)

# --- CONFIGURAÇÃO ---
REPO_BASE="https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main"

# --- CORES ---
VERMELHO='\033[1;31m'
VERDE='\033[1;32m'
AMARELO='\033[1;33m'
AZUL='\033[1;34m'
RESET='\033[0m'

clear
echo -e "${AZUL}==================================================${RESET}"
echo -e "${AMARELO}      🤖 CONFIGURAÇÃO DO BOT TELEGRAM 🤖       ${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo ""

# 1. Instala Dependências (Versão Async Correta)
echo "Preparando ambiente..."
if ! command -v python3 &> /dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y > /dev/null 2>&1
    apt-get install python3 python3-pip -y > /dev/null 2>&1
fi

pip3 install python-telegram-bot --break-system-packages > /dev/null 2>&1
pip3 install requests --break-system-packages > /dev/null 2>&1

echo -e "${VERDE}Dependências instaladas.${RESET}"

# 2. Coleta de Dados
echo ""
echo -e "${AMARELO}1. Digite o Token do BotFather:${RESET}"
read -rp "Token: " bot_token

echo ""
echo -e "${AMARELO}2. Digite o SEU ID Numérico (Admin):${RESET}"
read -rp "ID Admin: " admin_id

if [ -z "$bot_token" ] || [ -z "$admin_id" ]; then
    echo -e "${VERMELHO}❌ Dados incompletos!${RESET}"; sleep 2; exit 1
fi

# 3. Baixa e Configura
echo ""
echo "Baixando bot..."
mkdir -p /opt/XrayTools
rm -f /opt/XrayTools/botxray.py

# Baixa do GitHub
curl -s -L -o /opt/XrayTools/botxray.py "$REPO_BASE/botxray.py"

if [ ! -s "/opt/XrayTools/botxray.py" ]; then
    echo -e "${VERMELHO}Erro ao baixar botxray.py do GitHub!${RESET}"
    echo "Verifique se o arquivo está no repositório."
    exit 1
fi

# Substituição Automática dos Dados
sed -i "s|SEU_TOKEN_AQUI|$bot_token|g" /opt/XrayTools/botxray.py
sed -i "s|123456789|$admin_id|g" /opt/XrayTools/botxray.py

# 4. Serviço Systemd
cat <<EOF > /etc/systemd/system/botxray.service
[Unit]
Description=DragonCore Telegram Bot
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/XrayTools
ExecStart=/usr/bin/python3 /opt/XrayTools/botxray.py
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable botxray
systemctl restart botxray

echo ""
echo -e "${VERDE}🤖 BOT ATIVADO COM SUCESSO!${RESET}"
echo "Vá no Telegram e digite /menu ou /start."
echo ""
read -rp "Pressione ENTER para voltar..."
