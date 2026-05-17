#!/bin/bash
# lista_users.sh - Listagem de Usuários (FIX)

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
TITLE_BAR='\033[1;47;34m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'

mkdir -p "$(dirname "$USER_DB")"
touch "$USER_DB"

clear
echo -e "${TITLE_BAR}   LISTA DE USUÁRIOS   ${RESET}"
printf "%-15s | %-37s | %s\n" "USER" "UUID" "EXPIRA"
echo "-----------------------------------------------------------------------"

count=0
while IFS='|' read -r nick uuid expiry; do
  # pula vazias / lixo
  [ -n "${nick:-}" ] || continue
  [ -n "${uuid:-}" ] || continue

  # imprime
  printf "%-15s | %-37s | %s\n" "$nick" "$uuid" "${expiry:-}"
  count=$((count + 1))
done < "$USER_DB"

echo "-----------------------------------------------------------------------"
echo -e "${TXT_YELLOW}Total: ${count}${RESET}"
read -rp "Enter para voltar..."
