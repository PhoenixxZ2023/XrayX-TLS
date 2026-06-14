#!/bin/bash
# add_user.sh - Criação de Usuário
# CORREÇÃO: Proteção contra nomes parecidos (grep ^nome|)

set -euo pipefail

CONFIG_PATH="/usr/local/etc/xray/config.json"
USER_DB="/opt/XrayTools/users.db"

# Cores
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'
TITLE_BAR='\033[1;47;34m'

# Garante que o DB existe
mkdir -p "$(dirname "$USER_DB")"
touch "$USER_DB"

clear
echo -e "${TITLE_BAR}   CRIAR NOVO USUÁRIO   ${RESET}"
echo "Regras:"
echo " - Mínimo 5 e Máximo 9 caracteres"
echo " - Apenas letras e números"
echo ""

read -rp "Nome (0 p/ voltar): " raw_nick
if [ "$raw_nick" == "0" ] || [ -z "$raw_nick" ]; then exit 0; fi

# 1. Validação de Caracteres
if ! [[ "$raw_nick" =~ ^[a-zA-Z0-9]{5,9}$ ]]; then
    echo -e "${TXT_RED}Formato inválido.${RESET}"; sleep 2; exit 1
fi

# 2. A CORREÇÃO DE DUPLICIDADE (Sua lógica aqui)
if grep -q "^${raw_nick}|" "$USER_DB"; then
    echo -e "${TXT_RED}Erro: Usuário já existe no DB!${RESET}"
    sleep 2
    exit 1
fi

read -rp "Dias de validade (padrão 30): " days
[ -z "$days" ] && days=30
if ! [[ "$days" =~ ^[0-9]+$ ]]; then days=30; fi

if [ ! -f "$CONFIG_PATH" ]; then echo "Erro: Config não encontrada."; exit 1; fi

uuid=$(uuidgen)
expiry=$(date -d "+$days days" +%F)

# 3. Inserção no JSON
jq --arg uuid "$uuid" --arg nick_arg "$raw_nick" \
    '(.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) += [{"id":$uuid,"email":$nick_arg,"level":0}]' \
    "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

# 4. Inserção no Banco de Dados
echo "${raw_nick}|${uuid}|${expiry}" >> "$USER_DB"

# Reload para aplicar
systemctl restart xray >/dev/null 2>&1 || true

clear
echo -e "${TXT_GREEN}Usuário criado!${RESET}"
echo "-----------------------------------------"
echo -e "User: ${TXT_CYAN}${raw_nick}${RESET}"
echo -e "UUID: ${TXT_YELLOW}${uuid}${RESET}"
echo -e "Expira: ${expiry}"
echo "-----------------------------------------"
read -rp "Enter para voltar..."
