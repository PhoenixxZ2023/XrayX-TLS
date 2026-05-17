#!/bin/bash
# unblock_user.sh - Desbloqueio Seguro (FIX)
# Método: reverte LOCKED_nick para nick e restaura UUID real do users.db

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"

TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_CYAN='\033[1;36m'
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

if [ ! -s "$CONFIG_PATH" ]; then
  echo -e "${TXT_RED}Erro: config.json não encontrado.${RESET}"
  exit 1
fi

if [ ! -s "$USER_DB" ]; then
  echo -e "${TXT_RED}Erro: users.db não encontrado ou vazio.${RESET}"
  exit 1
fi

clear
echo -e "${TXT_GREEN}🔓 DESBLOQUEAR USUÁRIO (REATIVAR)${RESET}"
echo ""

# Lista bloqueados via jq (sem grep)
echo "--- Usuários Suspensos ---"
locked_list="$(
  jq -r '
    .inbounds[]? | select(.tag=="inbound-dragoncore") | .settings.clients[]? |
    select(.email? and (.email | startswith("LOCKED_"))) |
    .email
  ' "$CONFIG_PATH"
)"

if [ -z "${locked_list:-}" ]; then
  echo "Nenhum usuário bloqueado no momento."
  echo "--------------------------"
  echo ""
  read -rp "Pressione ENTER para voltar..."
  exit 0
fi

# Mostra sem o prefixo
while IFS= read -r line; do
  [ -n "$line" ] || continue
  echo " • ${line#LOCKED_}"
done <<< "$locked_list"

echo "--------------------------"
echo ""

read -rp "Digite o usuário para desbloquear: " user_input
[ -n "${user_input:-}" ] || exit 0

if ! validate_nick "$user_input"; then
  echo -e "${TXT_RED}Nick inválido. Use 5-9 letras/números.${RESET}"
  sleep 2
  exit 1
fi

LOCKED_NAME="LOCKED_${user_input}"

# Confirma que existe bloqueado no config
if ! jq -e --arg lock "$LOCKED_NAME" '
  any(.inbounds[]? | select(.tag=="inbound-dragoncore").settings.clients[]?; .email == $lock)
' "$CONFIG_PATH" >/dev/null; then
  echo -e "${TXT_RED}❌ Usuário não encontrado na lista de bloqueios!${RESET}"
  sleep 2
  exit 1
fi

echo "Recuperando dados originais..."

# UUID real do DB (campo 2)
REAL_UUID="$(awk -F'|' -v u="$user_input" '$1==u {print $2; exit}' "$USER_DB")"

if [ -z "${REAL_UUID:-}" ]; then
  echo -e "${TXT_RED}ERRO CRÍTICO:${RESET} UUID original não encontrado em $USER_DB."
  exit 1
fi

# Restaura no config.json (garante array)
tmpcfg="${CONFIG_PATH}.tmp"
jq --arg nick "$user_input" --arg locked "$LOCKED_NAME" --arg uuid "$REAL_UUID" '
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
    (if type=="array" then . else [] end)
  |
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
    map(if .email == $locked then .email = $nick | .id = $uuid else . end)
' "$CONFIG_PATH" > "$tmpcfg"
mv "$tmpcfg" "$CONFIG_PATH"

# Aplica (não depende de reload)
systemctl try-reload-or-restart xray >/dev/null 2>&1 || systemctl restart xray >/dev/null 2>&1 || true

echo -e "${TXT_GREEN}✅ Usuário $user_input reativado com sucesso!${RESET}"
echo "UUID original restaurado: $REAL_UUID"
sleep 2
