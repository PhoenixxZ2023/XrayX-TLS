#!/bin/bash
# lista_users.sh - Listagem de Usuários

USER_DB="/opt/XrayTools/users.db"
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

clear
echo -e "${TITLE_BAR}   LISTA DE USUÁRIOS   ${RESET}"
printf "%-15s | %-37s | %s\n" "USER" "UUID" "EXPIRA"
echo "-----------------------------------------------------------------------"
if [ -f "$USER_DB" ]; then
    while IFS='|' read -r nick uuid expiry; do
        # Verifica se a linha não está vazia antes de imprimir
        [ -n "$nick" ] && printf "%-15s | %-37s | %s\n" "$nick" "$uuid" "$expiry"
    done < "$USER_DB"
else
    echo "Nenhum usuário cadastrado."
fi
echo "-----------------------------------------------------------------------"
read -rp "Enter para voltar..."
