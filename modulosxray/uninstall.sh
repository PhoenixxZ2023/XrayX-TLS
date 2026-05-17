#!/bin/bash
# uninstall.sh - Desinstalação Total e Forçada (Prompt curto S/N)
# Remove vestígios, ignora erros se arquivos não existirem.

set -euo pipefail

# --- CORES ---
TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;41;37m'
RESET='\033[0m'

ask_sn() {
  local prompt="${1:-Confirmar?}"
  local ans=""
  while true; do
    read -rp "$prompt [s/n]: " ans
    ans="${ans,,}"  # lower
    case "$ans" in
      s) return 0 ;;
      n) return 1 ;;
      *) echo "Digite apenas s(sim) ou n(não)." ;;
    esac
  done
}

clear
echo -e "${TITLE_BAR}   DESINSTALAÇÃO TOTAL   ${RESET}"
echo ""
echo -e "${TXT_YELLOW}Vai remover:${RESET} xray, bot, configs, usuários, certificados e scripts."
echo ""

if ! ask_sn "Continuar"; then
  echo "Cancelado."
  exit 0
fi

echo -e "${TXT_YELLOW}>>> Limpando...${RESET}"

# 1) SERVIÇOS
systemctl stop xray >/dev/null 2>&1 || true
systemctl disable xray >/dev/null 2>&1 || true
systemctl stop botxray >/dev/null 2>&1 || true
systemctl disable botxray >/dev/null 2>&1 || true

# 2) SYSTEMD UNITS
rm -f /etc/systemd/system/xray.service
rm -f /etc/systemd/system/botxray.service
rm -rf /etc/systemd/system/xray.service.d
systemctl daemon-reload >/dev/null 2>&1 || true

# 3) DADOS/CONFIGS
rm -rf /usr/local/etc/xray
rm -rf /opt/XrayTools
rm -rf /opt/DragonCoreSSL
rm -rf /var/log/xray

# 4) BINÁRIO XRAY (se foi instalado em /usr/local/bin)
rm -f /usr/local/bin/xray

# 5) SCRIPTS / ATALHOS
rm -f /usr/bin/xray-menu
rm -f /usr/local/bin/xray-menu

rm -f /usr/local/bin/menuxray.sh
rm -f /usr/local/bin/installxray.sh

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

# Variações antigas/renomeadas
rm -f /usr/local/bin/remover_user.sh
rm -f /usr/local/bin/rem_user.sh
rm -f /usr/local/bin/lista_users.sh
rm -f /usr/local/bin/list_users.sh
rm -f /usr/local/bin/remover_expirados.sh
rm -f /usr/local/bin/purge_users.sh

# 6) CRON (remove só linhas do DragonCore)
(crontab -l 2>/dev/null | grep -v "limiterxray" | grep -v "renew_cert.sh" | grep -v "renew_cert") | crontab - 2>/dev/null || true

echo ""
echo -e "${TXT_GREEN}✅ Desinstalação concluída.${RESET}"
exit 0
