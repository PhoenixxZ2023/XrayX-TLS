#!/bin/bash
# uninstall.sh - Desinstalação Total e Forçada (Blindada)
# Remove todos os vestígios, ignorando erros se arquivos não existirem.

# --- CORES ---
TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;41;37m' # Fundo Vermelho
RESET='\033[0m'

# --- INTERFACE ---
clear
echo -e "${TITLE_BAR}   DESINSTALAÇÃO E LIMPEZA TOTAL   ${RESET}"
echo ""
echo -e "${TXT_RED}ATENÇÃO:${RESET} Esta ação apagará TUDO:"
echo " • Xray Core e Bot Telegram"
echo " • Todos os usuários e configurações"
echo " • Todos os scripts (novos e antigos)"
echo ""
read -rp "Tem certeza que deseja continuar? [s/n]: " confirm

if [[ "$confirm" != "s" && "$confirm" != "S" ]]; then
    echo "Operação cancelada."
    exit 0
fi

echo ""
echo -e "${TXT_YELLOW}>>> Iniciando limpeza forçada...${RESET}"

# --- 1. SERVIÇOS (COM || true PARA NÃO TRAVAR) ---
echo "1. Parando serviços..."
systemctl stop xray >/dev/null 2>&1 || true
systemctl disable xray >/dev/null 2>&1 || true
systemctl stop botxray >/dev/null 2>&1 || true
systemctl disable botxray >/dev/null 2>&1 || true

# --- 2. REMOÇÃO DO SYSTEMD ---
echo "2. Removendo registros do sistema..."
rm -f /etc/systemd/system/xray.service
rm -f /etc/systemd/system/botxray.service
systemctl daemon-reload >/dev/null 2>&1 || true

# --- 3. PASTAS E DADOS ---
echo "3. Apagando arquivos e banco de dados..."
rm -rf /usr/local/etc/xray
rm -rf /opt/XrayTools        # Onde fica o users.db
rm -rf /opt/DragonCoreSSL    # Certificados
rm -rf /var/log/xray
rm -f /usr/local/bin/xray    # O binário do Xray

# --- 4. SCRIPTS (LISTA COMPLETA) ---
echo "4. Removendo todos os scripts..."

# Atalhos
rm -f /usr/bin/xray-menu
rm -f /usr/local/bin/xray-menu

# Scripts Principais
rm -f /usr/local/bin/menuxray.sh
rm -f /usr/local/bin/installxray.sh

# Módulos (Nomes atuais)
rm -f /usr/local/bin/core_manager.sh
rm -f /usr/local/bin/limiterxray.sh
rm -f /usr/local/bin/botxray.sh
rm -f /usr/local/bin/onlinexray.sh
rm -f /usr/local/bin/certxray.sh
rm -f /usr/local/bin/backup.sh
rm -f /usr/local/bin/add_user.sh
rm -f /usr/local/bin/block_user.sh
rm -f /usr/local/bin/unblock_user.sh
rm -f /usr/local/bin/uninstall.sh

# Variações de nomes (Antigos/Renomeados)
rm -f /usr/local/bin/remover_user.sh
rm -f /usr/local/bin/rem_user.sh
rm -f /usr/local/bin/lista_users.sh
rm -f /usr/local/bin/list_users.sh
rm -f /usr/local/bin/remover_expirados.sh
rm -f /usr/local/bin/purge_users.sh

# --- 5. LIMPEZA DO CRON ---
echo "5. Limpando tarefas agendadas..."
# Remove apenas as linhas do nosso script, mantendo outros crons do sistema intactos
(crontab -l 2>/dev/null | grep -v "limiterxray" | grep -v "renew_cert") | crontab -

echo ""
echo -e "${TXT_GREEN}VPS LIMPA! Todos os arquivos do script foram removidos.${RESET}"
exit 1
