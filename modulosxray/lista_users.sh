#!/bin/bash
# lista_users.sh - Listagem de Usuários V7.5
# Melhorias: coluna STATUS (ativo/bloqueado/expirado/expira em breve),
#            colorização por status, UUID truncado na lista com opção
#            de ver completo, contagem por categoria.

set -uo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"

TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_YELLOW='\033[1;33m'
TXT_CYAN='\033[1;36m'
TXT_DIM='\033[2m'
RESET='\033[0m'

WARN_DAYS=7   # dias antes de expirar para alertar em amarelo

mkdir -p "$(dirname "$USER_DB")"
touch "$USER_DB"

# --- HELPERS DE DATA ---
# Retorna 0 se já expirou
is_expired() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    local exp_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || return 1
    today_ts=$(date +%s)
    [ "$exp_ts" -lt "$today_ts" ]
}

# Retorna 0 se expira em menos de WARN_DAYS dias
expires_soon() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    local exp_ts warn_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || return 1
    today_ts=$(date +%s)
    warn_ts=$(( today_ts + WARN_DAYS * 86400 ))
    [ "$exp_ts" -ge "$today_ts" ] && [ "$exp_ts" -le "$warn_ts" ]
}

# Dias restantes (positivo = ativo, negativo = expirado)
days_remaining() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "?"; return; }
    local exp_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || { echo "?"; return; }
    today_ts=$(date +%s)
    echo $(( (exp_ts - today_ts) / 86400 ))
}

# --- VERIFICA STATUS NO CONFIG ---
# Retorna: "locked" | "active" | "unknown"
get_config_status() {
    local nick="$1"
    [ ! -s "$CONFIG_PATH" ] && echo "unknown" && return
    jq empty "$CONFIG_PATH" 2>/dev/null || { echo "unknown"; return; }

    if jq -e --arg lock "LOCKED_${nick}" '
        any(.inbounds[]? | select(.tag=="inbound-dragoncore").settings.clients[]?; .email == $lock)
    ' "$CONFIG_PATH" >/dev/null 2>&1; then
        echo "locked"
    elif jq -e --arg nick "$nick" '
        any(.inbounds[]? | select(.tag=="inbound-dragoncore").settings.clients[]?; .email == $nick)
    ' "$CONFIG_PATH" >/dev/null 2>&1; then
        echo "active"
    else
        echo "unknown"
    fi
}

# --- INTERFACE ---
clear
echo -e "${TITLE_BAR}   LISTA DE USUÁRIOS   ${RESET}"
echo ""

if [ ! -s "$USER_DB" ]; then
    echo -e "${TXT_YELLOW}Nenhum usuário cadastrado.${RESET}"
    echo ""
    read -rp "Enter para voltar..."
    exit 0
fi

# Cabeçalho
printf "%-12s | %-19s | %-12s | %-5s | %s\n" \
    "USUÁRIO" "UUID (resumido)" "EXPIRA" "DIAS" "STATUS"
echo "------------------------------------------------------------------------"

count_total=0
count_active=0
count_locked=0
count_expired=0
count_warn=0

while IFS='|' read -r nick uuid expiry _rest; do
    [ -n "${nick:-}" ] || continue
    [ -n "${uuid:-}" ] || continue

    # UUID truncado: primeiros 8 + últimos 4 chars
    uuid_short="${uuid:0:8}...${uuid: -4}"

    # Status de expiração
    local_expired=false
    local_soon=false
    days="?"
    if [[ "${expiry:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        days=$(days_remaining "$expiry")
        is_expired "$expiry"  && local_expired=true
        expires_soon "$expiry" && local_soon=true
    fi

    # Status no Xray config
    cfg_status=$(get_config_status "$nick")

    # Monta linha colorida e label de status
    local_color="$RESET"
    status_label=""

    if [ "$cfg_status" = "locked" ]; then
        local_color="$TXT_RED"
        status_label="${TXT_RED}BLOQUEADO${RESET}"
        count_locked=$(( count_locked + 1 ))
    elif [ "$local_expired" = true ]; then
        local_color="$TXT_DIM"
        status_label="${TXT_RED}EXPIRADO${RESET}"
        count_expired=$(( count_expired + 1 ))
    elif [ "$local_soon" = true ]; then
        local_color="$TXT_YELLOW"
        status_label="${TXT_YELLOW}EXPIRA EM BREVE${RESET}"
        count_warn=$(( count_warn + 1 ))
        count_active=$(( count_active + 1 ))
    else
        local_color="$TXT_GREEN"
        status_label="${TXT_GREEN}ATIVO${RESET}"
        count_active=$(( count_active + 1 ))
    fi

    printf "${local_color}%-12s${RESET} | ${local_color}%-19s${RESET} | ${local_color}%-12s${RESET} | ${local_color}%-5s${RESET} | %b\n" \
        "$nick" "$uuid_short" "${expiry:-sem data}" "$days" "$status_label"

    count_total=$(( count_total + 1 ))
done < "$USER_DB"

echo "------------------------------------------------------------------------"
echo ""

# Resumo por categoria
echo -e " Total:          ${TXT_CYAN}${count_total}${RESET}"
echo -e " Ativos:         ${TXT_GREEN}${count_active}${RESET}"
[ "$count_warn"    -gt 0 ] && echo -e " Expirando logo: ${TXT_YELLOW}${count_warn}${RESET} (dentro de ${WARN_DAYS} dias)"
[ "$count_locked"  -gt 0 ] && echo -e " Bloqueados:     ${TXT_RED}${count_locked}${RESET}"
[ "$count_expired" -gt 0 ] && echo -e " Expirados:      ${TXT_RED}${count_expired}${RESET} (use opção 05 para limpar)"
echo ""

# Opção de ver UUID completo de um usuário
read -rp "Ver UUID completo de um usuário? (nome ou Enter para sair): " lookup
if [ -n "${lookup:-}" ]; then
    match=$(awk -F'|' -v u="$lookup" '$1==u {print $2; exit}' "$USER_DB" 2>/dev/null || true)
    if [ -n "$match" ]; then
        echo ""
        echo -e " Usuário: ${TXT_CYAN}${lookup}${RESET}"
        echo -e " UUID:    ${TXT_YELLOW}${match}${RESET}"
        echo ""
    else
        echo -e "${TXT_RED}Usuário '${lookup}' não encontrado.${RESET}"
    fi
    read -rp "Enter para voltar..."
fi
