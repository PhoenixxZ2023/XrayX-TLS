#!/bin/bash
# lista_users.sh - DragonCore V7.5.1
# Correções aplicadas:
#   - set -Eeuo pipefail — consistente com demais módulos
#   - Status do config.json pré-carregado em um único jq antes do loop (O(1) vs O(2n))
#   - Status "unknown" exibido como "FORA DE SYNC" em amarelo — não mostra ATIVO enganosamente
#   - lookup normalizado para minúsculas — consistente com add_user.sh corrigido
#   - Resumo com subcontagem explícita de "expirando" dentro dos ativos
#   - days_remaining() retorna sentinela numérico -999 em vez de "?" para robustez futura

set -Eeuo pipefail
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

WARN_DAYS=7

mkdir -p "$(dirname "$USER_DB")"
touch "$USER_DB"

# --- HELPERS DE DATA ---
is_expired() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    local exp_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || return 1
    today_ts=$(date +%s)
    [ "$exp_ts" -lt "$today_ts" ]
}

expires_soon() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    local exp_ts warn_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || return 1
    today_ts=$(date +%s)
    warn_ts=$(( today_ts + WARN_DAYS * 86400 ))
    [ "$exp_ts" -ge "$today_ts" ] && [ "$exp_ts" -le "$warn_ts" ]
}

# CORREÇÃO: retorna sentinela numérico -999 em vez de "?" quando formato inválido —
# evita quebra se código futuro usar o valor aritmeticamente.
days_remaining() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "-999"; return; }
    local exp_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || { echo "-999"; return; }
    today_ts=$(date +%s)
    echo $(( (exp_ts - today_ts) / 86400 ))
}

# --- PRÉ-CARREGAMENTO DO STATUS DO CONFIG ---
# CORREÇÃO: uma única chamada jq antes do loop — gera mapa JSON {email: "active"|"locked"}.
# Versão original chamava jq duas vezes por usuário (O(2n)), causando lentidão com muitos usuários.
# Agora: 1 leitura do config + consultas em memória sobre o mapa já carregado.
_build_status_map() {
    if [ ! -s "$CONFIG_PATH" ]; then echo '{}'; return; fi
    if ! jq empty "$CONFIG_PATH" 2>/dev/null; then echo '{}'; return; fi
    jq -c '
        [ .inbounds[]?
          | select(.tag=="inbound-dragoncore")
          | .settings.clients[]?
          | select(.email?)
          | { key: .email,
              value: (if (.email | startswith("LOCKED_")) then "locked" else "active" end) }
        ] | from_entries
    ' "$CONFIG_PATH" 2>/dev/null || echo '{}'
}

# Consulta o mapa em memória — sem I/O de disco no loop principal.
get_config_status() {
    local nick="$1"
    local locked_key="LOCKED_${nick}"

    # Verifica locked primeiro (prefixo LOCKED_ no mapa)
    if jq -e --arg k "$locked_key" 'has($k)' <<< "$STATUS_MAP" >/dev/null 2>&1; then
        echo "locked"
    elif jq -e --arg k "$nick" 'has($k)' <<< "$STATUS_MAP" >/dev/null 2>&1; then
        echo "active"
    else
        # Usuário no DB mas não no config — DB e config dessincronizados
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

# Carrega mapa de status uma única vez antes do loop
STATUS_MAP=$(_build_status_map)

# Cabeçalho
printf "%-12s | %-19s | %-12s | %-5s | %s\n" \
    "USUÁRIO" "UUID (resumido)" "EXPIRA" "DIAS" "STATUS"
echo "------------------------------------------------------------------------"

count_total=0
count_active=0
count_locked=0
count_expired=0
count_warn=0
count_unknown=0

while IFS='|' read -r nick uuid expiry _rest; do
    [ -n "${nick:-}" ] || continue
    [ -n "${uuid:-}" ] || continue

    uuid_short="${uuid:0:8}...${uuid: -4}"

    local_expired=false
    local_soon=false
    days=-999
    if [[ "${expiry:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        days=$(days_remaining "$expiry")
        is_expired "$expiry"   && local_expired=true || true
        expires_soon "$expiry" && local_soon=true    || true
    fi

    cfg_status=$(get_config_status "$nick")

    # Monta cor e label de status
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
    elif [ "$cfg_status" = "unknown" ]; then
        # CORREÇÃO: "unknown" exibido como FORA DE SYNC — não mostra ATIVO enganosamente
        # quando o DB e o config.json estão dessincronizados.
        local_color="$TXT_YELLOW"
        status_label="${TXT_YELLOW}FORA DE SYNC${RESET}"
        count_unknown=$(( count_unknown + 1 ))
        count_active=$(( count_active + 1 ))
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

    # Exibe dias: sentinela -999 vira "?" na saída visual
    days_display="$days"
    [ "$days" = "-999" ] && days_display="?"

    printf "${local_color}%-12s${RESET} | ${local_color}%-19s${RESET} | ${local_color}%-12s${RESET} | ${local_color}%-5s${RESET} | %b\n" \
        "$nick" "$uuid_short" "${expiry:-sem data}" "$days_display" "$status_label"

    count_total=$(( count_total + 1 ))
done < "$USER_DB"

echo "------------------------------------------------------------------------"
echo ""

# CORREÇÃO: resumo com subcontagem explícita — "Ativos (total)" inclui
# todos os não-bloqueados/não-expirados, com subcategorias indentadas.
echo -e " Total:            ${TXT_CYAN}${count_total}${RESET}"
echo -e " Ativos (total):   ${TXT_GREEN}${count_active}${RESET}"
[ "$count_warn"    -gt 0 ] && echo -e "  ↳ Expirando:    ${TXT_YELLOW}${count_warn}${RESET} (dentro de ${WARN_DAYS} dias)"
[ "$count_unknown" -gt 0 ] && echo -e "  ↳ Fora de sync: ${TXT_YELLOW}${count_unknown}${RESET} (DB sem correspondência no config)"
[ "$count_locked"  -gt 0 ] && echo -e " Bloqueados:       ${TXT_RED}${count_locked}${RESET}"
[ "$count_expired" -gt 0 ] && echo -e " Expirados:        ${TXT_RED}${count_expired}${RESET} (use opção 05 para limpar)"
echo ""

# Lookup de UUID completo — normalizado para minúsculas
read -rp "Ver UUID completo de um usuário? (nome ou Enter para sair): " lookup
if [ -n "${lookup:-}" ]; then
    # CORREÇÃO: normaliza para minúsculas — consistente com add_user.sh que
    # grava nomes em minúsculas no DB.
    lookup=$(echo "$lookup" | tr '[:upper:]' '[:lower:]')
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
