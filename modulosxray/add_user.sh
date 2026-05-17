#!/bin/bash
# add_user.sh - Criação de Usuário (FIX)
# - Garante deps (jq/uuidgen)
# - Verifica inbound e clients
# - Aplica config com segurança e mantém DB consistente

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

CONFIG_PATH="/usr/local/etc/xray/config.json"
USER_DB="/opt/XrayTools/users.db"

# Cores
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'
TITLE_BAR='\033[1;47;34m'

export DEBIAN_FRONTEND=noninteractive
APT_UPDATED=0

ensure_cmd() {
  local cmd="$1" pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [ "$APT_UPDATED" -eq 0 ]; then apt-get update -y >/dev/null 2>&1 || true; APT_UPDATED=1; fi
    apt-get install -y "$pkg" >/dev/null 2>&1
  fi
}

# Deps
ensure_cmd jq jq
ensure_cmd uuidgen uuid-runtime

# Garante que o DB existe
mkdir -p "$(dirname "$USER_DB")"
touch "$USER_DB"

# Valida config
if [ ! -s "$CONFIG_PATH" ]; then
  echo -e "${TXT_RED}Erro: Config não encontrada em $CONFIG_PATH${RESET}"
  sleep 2
  exit 1
fi

# Confere se inbound existe
if ! jq -e '.inbounds[]? | select(.tag=="inbound-dragoncore")' "$CONFIG_PATH" >/dev/null; then
  echo -e "${TXT_RED}Erro: inbound-dragoncore não encontrado no config.json${RESET}"
  sleep 2
  exit 1
fi

clear
echo -e "${TITLE_BAR}   CRIAR NOVO USUÁRIO   ${RESET}"
echo "Regras:"
echo " - Mínimo 5 e Máximo 9 caracteres"
echo " - Apenas letras e números"
echo ""

read -rp "Nome (0 p/ voltar): " raw_nick
if [ "${raw_nick:-}" = "0" ] || [ -z "${raw_nick:-}" ]; then exit 0; fi

# 1) Validação de caracteres
if ! [[ "$raw_nick" =~ ^[a-zA-Z0-9]{5,9}$ ]]; then
  echo -e "${TXT_RED}Formato inválido.${RESET}"
  sleep 2
  exit 1
fi

# 2) Duplicidade no DB (ancorado)
if grep -q "^${raw_nick}|" "$USER_DB"; then
  echo -e "${TXT_RED}Erro: Usuário já existe no DB!${RESET}"
  sleep 2
  exit 1
fi

read -rp "Dias de validade (padrão 30): " days
[ -z "${days:-}" ] && days=30
if ! [[ "$days" =~ ^[0-9]+$ ]]; then days=30; fi
if [ "$days" -lt 1 ] || [ "$days" -gt 3650 ]; then days=30; fi

uuid="$(uuidgen)"
expiry="$(date -d "+$days days" +%F)"

# 3) Atualiza JSON (garantindo clients como array)
tmp_cfg="${CONFIG_PATH}.tmp"
jq --arg uuid "$uuid" --arg nick "$raw_nick" '
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
    (if type=="array" then . else [] end)
  |
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) +=
    [{"id":$uuid,"email":$nick,"level":0}]
' "$CONFIG_PATH" > "$tmp_cfg"

# Se jq falhar, ERR trap pega; se ok, troca atomico
mv "$tmp_cfg" "$CONFIG_PATH"

# 4) Atualiza DB (após config OK)
echo "${raw_nick}|${uuid}|${expiry}" >> "$USER_DB"

# Aplica
systemctl try-reload-or-restart xray >/dev/null 2>&1 || systemctl restart xray >/dev/null 2>&1 || true

clear
echo -e "${TXT_GREEN}Usuário criado!${RESET}"
echo "-----------------------------------------"
echo -e "User:   ${TXT_CYAN}${raw_nick}${RESET}"
echo -e "UUID:   ${TXT_YELLOW}${uuid}${RESET}"
echo -e "Expira: ${expiry}"
echo "-----------------------------------------"
read -rp "Enter para voltar..."
