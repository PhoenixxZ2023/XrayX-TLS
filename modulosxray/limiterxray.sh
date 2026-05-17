#!/bin/bash
# limiterxray.sh - Controle de Consumo V7.3 (FIX)
# - Sem grep em JSON (usa jq)
# - Deps garantidas (jq/bc/uuidgen)
# - Validação de nick
# - Remove por campos (awk) em vez de sed regex
# - Aplica try-reload-or-restart

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

XRAY_BIN="/usr/local/bin/xray"
CONFIG_PATH="/usr/local/etc/xray/config.json"
LIMITS_DB="/opt/XrayTools/limits.db"
USAGE_DB="/opt/XrayTools/usage.db"
SESSION_DB="/opt/XrayTools/session.db"
USER_DB="/opt/XrayTools/users.db"
XRAY_API_PORT="1080"

TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_BLUE='\033[1;34m'
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

validate_nick() {
  local n="${1:-}"
  [[ "$n" =~ ^[a-zA-Z0-9]{5,9}$ ]]
}

mkdir -p "/opt/XrayTools"
touch "$LIMITS_DB" "$USAGE_DB" "$SESSION_DB" "$USER_DB"

ensure_cmd jq jq
ensure_cmd bc bc
ensure_cmd uuidgen uuid-runtime

header_limit() {
  clear
  echo -e "${TITLE_BAR}   CONTROLE DE CONSUMO (PERSISTENTE)   ${RESET}"
  echo ""
}

func_get_api_port() {
  if [ -f "$CONFIG_PATH" ]; then
    local p
    p="$(jq -r '.inbounds[]? | select(.tag=="api") | .port // empty' "$CONFIG_PATH" 2>/dev/null || true)"
    [ -n "${p:-}" ] && XRAY_API_PORT="$p"
  fi
}

is_user_locked() {
  local nick="$1"
  jq -e --arg lock "LOCKED_${nick}" '
    any(.inbounds[]? | select(.tag=="inbound-dragoncore").settings.clients[]?; .email == $lock)
  ' "$CONFIG_PATH" >/dev/null 2>&1
}

user_exists_in_config() {
  local nick="$1"
  jq -e --arg email "$nick" '
    any(.inbounds[]? | select(.tag=="inbound-dragoncore").settings.clients[]?; .email == $email)
  ' "$CONFIG_PATH" >/dev/null 2>&1
}

get_real_uuid_from_db() {
  local nick="$1"
  awk -F'|' -v n="$nick" '$1==n {print $2; exit}' "$USER_DB" 2>/dev/null || true
}

func_bytes_to_human() {
  local b=${1:-0}
  if [ "$b" -ge 1073741824 ]; then
    echo "$(echo "scale=2; $b/1073741824" | bc) GB"
  elif [ "$b" -ge 1048576 ]; then
    echo "$(echo "scale=2; $b/1048576" | bc) MB"
  else
    echo "$(echo "scale=2; $b/1024" | bc) KB"
  fi
}

db_delete_key() {
  # remove linhas cujo $1==nick
  local file="$1" nick="$2"
  awk -F'|' -v n="$nick" '$1!=n' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

db_get_value() {
  local file="$1" nick="$2"
  awk -F'|' -v n="$nick" '$1==n {print $2; exit}' "$file" 2>/dev/null || true
}

db_set_value() {
  local file="$1" nick="$2" value="$3"
  db_delete_key "$file" "$nick"
  echo "$nick|$value" >> "$file"
}

apply_config_change_and_reload() {
  systemctl try-reload-or-restart xray >/dev/null 2>&1 || systemctl restart xray >/dev/null 2>&1 || true
}

func_set_limit() {
  header_limit
  echo "Definir Limite de Dados"
  echo "--------------------------------------"
  read -rp "Digite o Usuário (Nick): " nick
  [ -n "${nick:-}" ] || return

  if ! validate_nick "$nick"; then
    echo -e "${TXT_RED}Nick inválido. Use 5-9 letras/números.${RESET}"
    read -rp "Enter..."
    return
  fi

  if [ ! -s "$CONFIG_PATH" ]; then
    echo -e "${TXT_RED}Config não encontrada.${RESET}"
    read -rp "Enter..."
    return
  fi

  local is_locked=false
  if is_user_locked "$nick"; then
    is_locked=true
  elif ! user_exists_in_config "$nick"; then
    echo -e "${TXT_RED}Usuário não encontrado no Xray!${RESET}"
    read -rp "Enter..."
    return
  fi

  echo "Qual o limite de internet?"
  read -rp "Limite (GB): " gb_limit
  if ! [[ "${gb_limit:-}" =~ ^[0-9]+$ ]]; then echo "Inválido."; sleep 1; return; fi

  local bytes_limit
  bytes_limit="$(echo "$gb_limit * 1073741824" | bc)"

  db_set_value "$LIMITS_DB" "$nick" "$bytes_limit"

  echo ""
  read -rp "Deseja ZERAR o consumo atual deste usuário? [s/n]: " zerar
  if [[ "${zerar:-n}" =~ ^[Ss]$ ]]; then
    db_delete_key "$USAGE_DB" "$nick"
    db_delete_key "$SESSION_DB" "$nick"
    echo -e "${TXT_CYAN}Histórico zerado.${RESET}"
  fi

  # Se estava bloqueado, restaura email/id do DB
  if [ "$is_locked" = true ]; then
    local real_uuid
    real_uuid="$(get_real_uuid_from_db "$nick")"
    if [ -n "${real_uuid:-}" ]; then
      jq --arg nick "$nick" --arg locked "LOCKED_$nick" --arg uuid "$real_uuid" '
        (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
          (if type=="array" then . else [] end)
        |
        (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
          map(if .email == $locked then .email = $nick | .id = $uuid else . end)
      ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

      apply_config_change_and_reload
      echo -e "${TXT_GREEN}Usuário desbloqueado!${RESET}"
    else
      echo -e "${TXT_YELLOW}Aviso: UUID real não encontrado no users.db para desbloquear.${RESET}"
    fi
  fi

  echo -e "${TXT_GREEN}Limite salvo!${RESET}"
  read -rp "Enter para voltar..."
}

func_view_usage() {
  func_get_api_port
  header_limit

  printf "%-18s | %-12s | %-12s | %s\n" "USUÁRIO" "USADO (DB)" "LIMITE" "STATUS"
  echo "------------------------------------------------------------"

  while IFS='|' read -r nick limit_bytes; do
    [ -n "${nick:-}" ] || continue

    local usage_total
    usage_total="$(db_get_value "$USAGE_DB" "$nick")"
    [ -n "${usage_total:-}" ] || usage_total=0

    local total_h limit_h status
    total_h="$(func_bytes_to_human "$usage_total")"
    limit_h="$(func_bytes_to_human "$limit_bytes")"
    status="${TXT_GREEN}OK${RESET}"

    if is_user_locked "$nick"; then
      status="${TXT_RED}BLOQUEADO${RESET}"
    elif [ "$usage_total" -ge "$limit_bytes" ]; then
      status="${TXT_RED}EXCEDIDO${RESET}"
    else
      local pct
      pct="$(echo "scale=0; ($usage_total * 100) / $limit_bytes" | bc)"
      status="${TXT_CYAN}${pct}%${RESET}"
    fi

    printf "%-18s | %-12s | %-12s | %b\n" "$nick" "$total_h" "$limit_h" "$status"
  done < "$LIMITS_DB"

  echo "------------------------------------------------------------"
  echo "Nota: Este consumo não zera se reiniciar a VPS."
  echo ""
  read -rp "Enter para voltar..."
}

func_remove_limit() {
  header_limit
  read -rp "Usuário para remover limite: " nick
  [ -n "${nick:-}" ] || return

  if ! validate_nick "$nick"; then
    echo -e "${TXT_RED}Nick inválido.${RESET}"
    sleep 1
    return
  fi

  db_delete_key "$LIMITS_DB" "$nick"
  db_delete_key "$USAGE_DB" "$nick"
  db_delete_key "$SESSION_DB" "$nick"

  if is_user_locked "$nick"; then
    local real_uuid
    real_uuid="$(get_real_uuid_from_db "$nick")"
    if [ -n "${real_uuid:-}" ]; then
      jq --arg nick "$nick" --arg locked "LOCKED_$nick" --arg uuid "$real_uuid" '
        (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
          (if type=="array" then . else [] end)
        |
        (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
          map(if .email == $locked then .email = $nick | .id = $uuid else . end)
      ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
      apply_config_change_and_reload
    fi
  fi

  echo -e "${TXT_GREEN}Limite removido e histórico limpo!${RESET}"
  sleep 2
}

func_check_and_block() {
  local MODE="$1"
  func_get_api_port

  if [ "$MODE" != "--cron" ]; then
    header_limit
    if [ "$MODE" == "--sync-only" ]; then
      echo "Sincronizando dados (Sem bloquear)..."
    else
      echo "Sincronizando e aplicando regras..."
    fi
  fi

  # valida API inbound
  if ! jq -e '.inbounds[]? | select(.tag=="api")' "$CONFIG_PATH" >/dev/null; then
    echo -e "${TXT_RED}Erro: inbound api não configurado no config.json (tag: api).${RESET}"
    [ "$MODE" != "--cron" ] && read -rp "Enter..."
    return
  fi

  local blocked_count=0

  cp "$USAGE_DB" "${USAGE_DB}.tmp"
  cp "$SESSION_DB" "${SESSION_DB}.tmp"

  while IFS='|' read -r nick limit_bytes; do
    [ -n "${nick:-}" ] || continue

    # Se já bloqueado, ignora
    if is_user_locked "$nick"; then continue; fi

    # Stats (por email)
    local down up
    down="$($XRAY_BIN api stats -server="127.0.0.1:$XRAY_API_PORT" -name "user>>>${nick}>>>traffic>>>downlink" 2>/dev/null | awk '/value/ {print $2; exit}')"
    up="$($XRAY_BIN api stats -server="127.0.0.1:$XRAY_API_PORT" -name "user>>>${nick}>>>traffic>>>uplink" 2>/dev/null | awk '/value/ {print $2; exit}')"
    [ -n "${down:-}" ] || down=0
    [ -n "${up:-}" ] || up=0

    local current_session
    current_session="$(echo "$down + $up" | bc)"

    local last_session historical_usage
    last_session="$(db_get_value "${SESSION_DB}.tmp" "$nick")"; [ -n "${last_session:-}" ] || last_session=0
    historical_usage="$(db_get_value "${USAGE_DB}.tmp" "$nick")"; [ -n "${historical_usage:-}" ] || historical_usage=0

    local delta
    if [ "$current_session" -lt "$last_session" ]; then
      delta="$current_session"
    else
      delta="$(echo "$current_session - $last_session" | bc)"
    fi

    local new_historical
    new_historical="$(echo "$historical_usage + $delta" | bc)"

    db_set_value "${USAGE_DB}.tmp" "$nick" "$new_historical"
    db_set_value "${SESSION_DB}.tmp" "$nick" "$current_session"

    if [ "$new_historical" -ge "$limit_bytes" ]; then
      if [ "$MODE" == "--sync-only" ]; then
        [ "$MODE" != "--cron" ] && echo -e "${TXT_YELLOW}⚠️  $nick excedeu o limite! (Bloqueio pendente)${RESET}"
      else
        [ "$MODE" != "--cron" ] && echo -e "${TXT_RED}❌ $nick estourou. Bloqueando...${RESET}"

        local fake_uuid
        fake_uuid="$(uuidgen)"

        jq --arg nick "$nick" --arg locked "LOCKED_$nick" --arg fake "$fake_uuid" '
          (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
            (if type=="array" then . else [] end)
          |
          (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
            map(if .email == $nick then .email = $locked | .id = $fake else . end)
        ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

        blocked_count=$((blocked_count + 1))
      fi
    fi
  done < "$LIMITS_DB"

  mv "${USAGE_DB}.tmp" "$USAGE_DB"
  mv "${SESSION_DB}.tmp" "$SESSION_DB"

  if [ "$blocked_count" -gt 0 ]; then
    apply_config_change_and_reload
    [ "$MODE" != "--cron" ] && echo -e "${TXT_RED}🚫 $blocked_count bloqueados (aplicado).${RESET}"
  else
    [ "$MODE" != "--cron" ] && echo -e "${TXT_GREEN}Dados atualizados com sucesso.${RESET}"
  fi

  [ "$MODE" != "--cron" ] && read -rp "Enter..."
}

# Cron
if [ "${1:-}" == "--cron" ]; then
  func_check_and_block "--cron"
  exit 0
fi

# Menu
while true; do
  header_limit
  echo -e "${TXT_CYAN}[1]. DEFINIR/ALTERAR LIMITE${RESET}"
  echo -e "${TXT_CYAN}[2]. VER CONSUMO ACUMULADO${RESET}"
  echo -e "${TXT_CYAN}[3]. REMOVER LIMITE${RESET}"
  echo -e "${TXT_RED}[4]. VERIFICAR E BLOQUEAR EXCEDENTES${RESET}"
  echo -e "${TXT_YELLOW}[5]. APENAS SINCRONIZAR (SEM BLOQUEIO)${RESET}"
  echo -e "${TXT_CYAN}[0]. VOLTAR AO MENU PRINCIPAL${RESET}"
  echo "--------------------------------------"

  read -rp "Opção: " choice
  case "${choice:-}" in
    1) func_set_limit ;;
    2) func_view_usage ;;
    3) func_remove_limit ;;
    4) func_check_and_block "--enforce" ;;
    5) func_check_and_block "--sync-only" ;;
    0) exit 0 ;;
    *) echo "Inválido"; sleep 1 ;;
  esac
done
