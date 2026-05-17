#!/bin/bash
# remover_expirados.sh - Limpeza de Usuários Vencidos (FIX)
# - Remove expirados do DB e do config.json com 1 jq (mais seguro/rápido)

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_YELLOW='\033[1;33m'
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
echo -e "${TITLE_BAR}   LIMPEZA DE EXPIRADOS   ${RESET}"
echo ""

today="$(date +%F)"
count=0
found=false

# DB existe?
if [ ! -f "$USER_DB" ] || [ ! -s "$USER_DB" ]; then
  echo "Banco de dados vazio."
  read -rp "Enter para voltar..."
  exit 0
fi

# Config existe?
if [ ! -s "$CONFIG_PATH" ]; then
  echo -e "${TXT_RED}Erro: config não encontrada em $CONFIG_PATH${RESET}"
  read -rp "Enter para voltar..."
  exit 1
fi

# Inbound existe?
if ! jq -e '.inbounds[]? | select(.tag=="inbound-dragoncore")' "$CONFIG_PATH" >/dev/null; then
  echo -e "${TXT_RED}Erro: inbound-dragoncore não encontrado no config.json${RESET}"
  read -rp "Enter para voltar..."
  exit 1
fi

echo -e "${TXT_YELLOW}Verificando vencimentos...${RESET}"
echo ""
printf "%-20s | %s\n" "USUÁRIO" "VENCIMENTO"
echo "-----------------------------------"

# Coleta UUIDs expirados em um arquivo temporário
expired_uuids_file="$(mktemp)"
trap 'rm -f "$expired_uuids_file" 2>/dev/null || true' EXIT

while IFS='|' read -r nick uuid expiry; do
  if [[ "${expiry:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$expiry" < "$today" ]]; then
    printf "${TXT_RED}%-20s${RESET} | ${TXT_RED}%s${RESET}\n" "${nick:-}" "$expiry"
    echo "$uuid" >> "$expired_uuids_file"
    found=true
    count=$((count + 1))
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
if [[ "${confirm:-n}" != "s" && "${confirm:-n}" != "S" ]]; then
  echo "Cancelado."
  sleep 1
  exit 0
fi

# 1) Reescreve DB mantendo só não-expirados
tmpdb="${USER_DB}.tmp"
> "$tmpdb"

while IFS='|' read -r nick uuid expiry; do
  # mantém linhas válidas não expiradas; se expiry inválida, mantém (não decide apagar)
  if [[ "${expiry:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$expiry" < "$today" ]]; then
    echo -e "Removendo: ${TXT_RED}${nick:-}${RESET}"
  else
    [ -n "${nick:-}" ] && [ -n "${uuid:-}" ] && echo "${nick}|${uuid}|${expiry:-}" >> "$tmpdb"
  fi
done < "$USER_DB"

mv "$tmpdb" "$USER_DB"

# 2) Remove todos UUIDs expirados do config.json em 1 jq
# Monta um array JSON ["uuid1","uuid2",...]
expired_json="$(jq -R -s -c 'split("\n") | map(select(length>0))' "$expired_uuids_file")"

tmpcfg="${CONFIG_PATH}.tmp"
jq --argjson dead "$expired_json" '
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
    (if type=="array" then . else [] end)
  |
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
    map(select((.id as $id | ($dead | index($id)) == null)))
' "$CONFIG_PATH" > "$tmpcfg"
mv "$tmpcfg" "$CONFIG_PATH"

# Aplica
systemctl try-reload-or-restart xray >/dev/null 2>&1 || systemctl restart xray >/dev/null 2>&1 || true

echo ""
echo -e "${TXT_GREEN}Limpeza concluída com sucesso.${RESET}"
read -rp "Enter para voltar..."
