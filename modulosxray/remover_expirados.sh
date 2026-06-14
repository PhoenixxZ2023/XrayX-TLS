#!/bin/bash
# remover_expirados.sh - Limpeza de Usuários Vencidos
# Baseado na sua lógica original.

set -euo pipefail

# --- CONFIGURAÇÕES ---
USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"

# --- CORES ---
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

# --- INÍCIO ---
clear
echo -e "${TITLE_BAR}   LIMPEZA DE EXPIRADOS   ${RESET}"
echo ""

today=$(date +%F)
count=0

# Verifica se o DB existe e tem conteúdo
if [ ! -f "$USER_DB" ] || [ ! -s "$USER_DB" ]; then
    echo "Banco de dados vazio."
    read -rp "Enter para voltar..."
    exit 0
fi

echo -e "${TXT_YELLOW}Verificando vencimentos...${RESET}"
echo ""
printf "%-20s | %s\n" "USUÁRIO" "VENCIMENTO"
echo "-----------------------------------"

found=false

# 1. Primeira Passada: Apenas LISTAR
while IFS='|' read -r nick uuid expiry; do
    # Valida formato de data e compara string (YYYY-MM-DD funciona com < no bash)
    if [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$expiry" < "$today" ]]; then
        printf "${TXT_RED}%-20s${RESET} | ${TXT_RED}%s${RESET}\n" "$nick" "$expiry"
        found=true
        ((count++))
    fi
done < "$USER_DB"

echo "-----------------------------------"
echo ""

if [ "$found" = false ]; then
    echo -e "${TXT_GREEN}Nenhum usuário vencido.${RESET}"
    read -rp "Enter para voltar..."
    exit 0
fi

echo -e "Encontrados ${TXT_RED}${count}${RESET} usuários vencidos."
read -rp "Excluir agora? [s/n]: " confirm
if [[ "$confirm" != "s" && "$confirm" != "S" ]]; then
    echo "Cancelado."
    sleep 2
    exit 0
fi

# 2. Segunda Passada: REMOVER
# Cria arquivo temporário vazio
> "${USER_DB}.tmp"

echo ""
while IFS='|' read -r nick uuid expiry; do
    if [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$expiry" < "$today" ]]; then
        echo -e "Removendo: ${TXT_RED}${nick}${RESET}"
        
        # Remove do Xray Config (JSON)
        jq --arg id "$uuid" \
           '(.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |= map(select(.id != $id))' \
           "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
           
    else
        # Se não venceu, mantém no DB novo
        echo "${nick}|${uuid}|${expiry}" >> "${USER_DB}.tmp"
    fi
done < "$USER_DB"

# Substitui o DB antigo pelo novo (limpo)
mv "${USER_DB}.tmp" "$USER_DB"

# Reinicia para aplicar
systemctl restart xray >/dev/null 2>&1 || true

echo ""
echo -e "${TXT_GREEN}Limpeza concluída com sucesso.${RESET}"
read -rp "Enter para voltar..."
