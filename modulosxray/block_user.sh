#!/bin/bash
# block_user.sh - Bloqueio Seguro (FIX)
# Método: Scramble (troca UUID por falso) + prefixo LOCKED_
# Aplica: try-reload-or-restart (sem depender de reload)

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"

TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_YELLOW='\033[1;33m'
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

validate_nick() { [[ "${1:-}" =~ ^[a-zA-Z0-9]{5,9}$ ]]; }

ensure_cmd jq jq
ensure_cmd uuidgen uuid-runtime

clear
echo -e "${TXT_RED}🔒 BLOQUEAR USUÁRIO (SUSPENDER)${RESET}"
echo "Isso impedirá a conexão, mas manterá o cadastro."
echo ""

if [ ! -s "$CONFIG_PATH" ]; then
  echo -e "${TXT_RED}Erro: config.json não encontrado.${RESET}"
  exit 1
fi

# Lista usuários ativos (não LOCKED_) via jq (sem grep)
echo "--- Usuários Ativos ---"
jq -r '
  .inbounds[]? | select(.tag=="inbound-dragoncore") | .settings.clients[]? |
  select(.email? and (.email | startswith("LOCKED_") | not)) |
  .email
' "$CONFIG_PATH" | awk 'NF{print " • " $0}'
echo "-----------------------"
echo ""

read -rp "Digite o usuário para suspender: " user_block
[ -n "${user_block:-}" ] || exit 0

if ! validate_nick "$user_block"; then
  echo -e "${TXT_RED}Nick inválido. Use 5-9 letras/números.${RESET}"
  sleep 2
  exit 1
fi

# Existe no DB?
if [ ! -f "$USER_DB" ] || ! awk -F'|' -v u="$user_block" '$1==u {found=1} END{exit found?0:1}' "$USER_DB"; then
  echo -e "${TXT_RED}❌ Usuário não encontrado no banco de dados!${RESET}"
  sleep 2
  exit 1
fi

# Já está bloqueado no config?
if jq -e --arg lock "LOCKED_${user_block}" '
  any(.inbounds[]? | select(.tag=="inbound-dragoncore").settings.clients[]?; .email == $lock)
' "$CONFIG_PATH" >/dev/null; then
  echo -e "${TXT_YELLOW}⚠️  Este usuário já está bloqueado!${RESET}"
  sleep 2
  exit 0
fi

echo "Suspendendo acesso..."

FAKE_UUID="$(uuidgen)"

tmpcfg="${CONFIG_PATH}.tmp"
jq --arg nick "$user_block" --arg locked "LOCKED_$user_block" --arg fake "$FAKE_UUID" '
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
    (if type=="array" then . else [] end)
  |
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
    map(if .email == $nick then .email = $locked | .id = $fake else . end)
' "$CONFIG_PATH" > "$tmpcfg"
mv "$tmpcfg" "$CONFIG_PATH"

systemctl try-reload-or-restart xray >/dev/null 2>&1 || systemctl restart xray >/dev/null 2>&1 || true

echo -e "${TXT_GREEN}✅ Usuário $user_block suspenso com sucesso!${RESET}"
echo "UUID alterado para falso e prefixo LOCKED_ adicionado."
sleep 2
