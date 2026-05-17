#!/bin/bash
# onlinexray.sh - Monitor Online via API (SEM RESTART)
# Mostra usuários com tráfego recente (janela de 15s)

set -Eeuo pipefail
trap 'echo -e "\n\033[1;33mSaindo...\033[0m"; exit 0' INT

GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

CONF="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
WINDOW=15   # segundos (considera online se teve tráfego nesse período)
SLEEP=3     # intervalo de polling

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

if [ ! -s "$CONF" ]; then
  echo -e "${RED}Erro: config.json não encontrado.${RESET}"
  exit 1
fi
if [ ! -x "$XRAY_BIN" ]; then
  echo -e "${RED}Erro: xray bin não encontrado em $XRAY_BIN.${RESET}"
  exit 1
fi

# Pega porta da API (fallback 1080)
API_PORT="$(jq -r '.inbounds[]? | select(.tag=="api") | .port // empty' "$CONF" 2>/dev/null || true)"
[ -n "${API_PORT:-}" ] || API_PORT="1080"

# Valida se API existe
if ! jq -e '.inbounds[]? | select(.tag=="api")' "$CONF" >/dev/null; then
  echo -e "${RED}Erro: inbound API (tag: api) não está configurado no Xray.${RESET}"
  exit 1
fi

clear
echo -e "${CYAN}================================================${RESET}"
echo -e "${CYAN}         MONITOR DE USUÁRIOS ONLINE (API)       ${RESET}"
echo -e "${CYAN}================================================${RESET}"
echo -e "${YELLOW}Janela: ${WINDOW}s | Poll: ${SLEEP}s | CTRL+C para sair${RESET}"
echo ""

# Lista de usuários (não LOCKED_)
mapfile -t USERS < <(jq -r '
  .inbounds[]? | select(.tag=="inbound-dragoncore") | .settings.clients[]? |
  select(.email? and (.email | startswith("LOCKED_") | not)) |
  .email
' "$CONF" | awk 'NF')

if [ ${#USERS[@]} -eq 0 ]; then
  echo -e "${RED}Nenhum usuário encontrado no inbound-dragoncore.${RESET}"
  exit 0
fi

declare -A last_bytes
declare -A last_seen

get_total_bytes() {
  local nick="$1"
  local down up
  down="$($XRAY_BIN api stats -server="127.0.0.1:${API_PORT}" -name "user>>>${nick}>>>traffic>>>downlink" 2>/dev/null | awk '/value/ {print $2; exit}')"
  up="$($XRAY_BIN api stats -server="127.0.0.1:${API_PORT}" -name "user>>>${nick}>>>traffic>>>uplink" 2>/dev/null | awk '/value/ {print $2; exit}')"
  [ -n "${down:-}" ] || down=0
  [ -n "${up:-}" ] || up=0
  echo $((down + up))
}

# init
now="$(date +%s)"
for u in "${USERS[@]}"; do
  b="$(get_total_bytes "$u")"
  last_bytes["$u"]="$b"
  last_seen["$u"]=0
done

while true; do
  now="$(date +%s)"

  # Atualiza deltas
  for u in "${USERS[@]}"; do
    b="$(get_total_bytes "$u")"
    prev="${last_bytes["$u"]:-0}"
    if [ "$b" -gt "$prev" ]; then
      last_seen["$u"]="$now"
    fi
    last_bytes["$u"]="$b"
  done

  clear
  echo -e "${CYAN}================================================${RESET}"
  echo -e "${CYAN}         MONITOR DE USUÁRIOS ONLINE (API)       ${RESET}"
  echo -e "${CYAN}================================================${RESET}"
  echo -e "${YELLOW}Janela: ${WINDOW}s | Poll: ${SLEEP}s | CTRL+C para sair${RESET}"
  echo ""

  online_count=0
  for u in "${USERS[@]}"; do
    seen="${last_seen["$u"]:-0}"
    if [ "$seen" -gt 0 ] && [ $((now - seen)) -le "$WINDOW" ]; then
      printf "${CYAN}[%s]${RESET} Usuário: ${GREEN}%s${RESET} ${YELLOW}(Online)${RESET}\n" "$(date +%H:%M:%S)" "$u"
      online_count=$((online_count + 1))
    fi
  done

  if [ "$online_count" -eq 0 ]; then
    echo -e "${RED}Nenhuma atividade recente na janela.${RESET}"
  fi

  sleep "$SLEEP"
done
