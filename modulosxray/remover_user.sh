#!/bin/bash
# remover_user.sh - Remoção de Usuário (FIX)
# - Garante jq
# - Checa inbound existente
# - Só diz "removido" se realmente removeu algo
# - try-reload-or-restart

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

CONFIG_PATH="/usr/local/etc/xray/config.json"
USER_DB="/opt/XrayTools/users.db"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive
APT_UPDATED=0

ensure_cmd() {
  local cmd="$1" pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [ "$APT_UPDATED" -eq 0 ]; then apt-get update -y >/dev/null 2>&1 || true; APT_UPDATED=1; fi
    apt-get install -y "$pkg" >/dev/null 2>&1
  fi
}

ensure_cmd jq jq

clear
echo -e "${TITLE_BAR}   REMOVER USUÁRIO   ${RESET}"
read -rp "Nome ou UUID (0 p/ voltar): " identifier

if [ -z "${identifier:-}" ] || [ "${identifier:-}" = "0" ]; then exit 0; fi
if [ ! -s "$CONFIG_PATH" ]; then echo -e "${TXT_RED}Erro: config não encontrada.${RESET}"; sleep 2; exit 1; fi

# Confere inbound
if ! jq -e '.inbounds[]? | select(.tag=="inbound-dragoncore")' "$CONFIG_PATH" >/dev/null; then
  echo -e "${TXT_RED}Erro: inbound-dragoncore não encontrado no config.json${RESET}"
  sleep 2
  exit 1
fi

# Contagem antes (JSON)
before_json="$(jq '[.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients[]?] | length' "$CONFIG_PATH" 2>/dev/null || echo 0)"

# Remove do JSON
tmp_cfg="${CONFIG_PATH}.tmp"
jq --arg id "$identifier" '
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
    (if type=="array" then . else [] end)
  |
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
    map(select(.id != $id and .email != $id))
' "$CONFIG_PATH" > "$tmp_cfg"
mv "$tmp_cfg" "$CONFIG_PATH"

after_json="$(jq '[.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients[]?] | length' "$CONFIG_PATH" 2>/dev/null || echo 0)"

# Remove do DB
removed_db=0
if [ -f "$USER_DB" ]; then
  if awk -F'|' -v id="$identifier" '($1==id || $2==id){found=1} END{exit found?0:1}' "$USER_DB"; then
    removed_db=1
  fi
  awk -F'|' -v id="$identifier" '($1!=id && $2!=id){print $0}' "$USER_DB" > "${USER_DB}.tmp"
  mv "${USER_DB}.tmp" "$USER_DB"
fi

# Aplica
systemctl try-reload-or-restart xray >/dev/null 2>&1 || systemctl restart xray >/dev/null 2>&1 || true

# Resultado
if [ "$after_json" -lt "$before_json" ] || [ "$removed_db" -eq 1 ]; then
  echo -e "${TXT_GREEN}Removido com sucesso.${RESET}"
else
  echo -e "${TXT_RED}Nenhum usuário encontrado com esse Nome/UUID.${RESET}"
fi
sleep 1
