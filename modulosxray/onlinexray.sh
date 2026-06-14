#!/bin/bash
# onlinexray.sh - DragonCore V7.5.1
# Correções aplicadas:
#   - API_PORT fallback 10085 → 1080 (alinhado com core_manager)
#   - bytes_human() usa awk — elimina dependência de bc
#   - set -Eeuo pipefail — consistente com demais módulos
#   - Delta real por ciclo (down+up separados) — coluna "DELTA CICLO" mostra valor correto
#   - xray_ok persistido fora do loop — aviso não some entre verificações
#   - Chamadas API reduzidas: down+up coletados uma vez por usuário por ciclo (era 4 chamadas)

set -Eeuo pipefail
trap 'echo -e "\n\033[1;33mSaindo...\033[0m"; exit 0' INT TERM

GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
DIM='\033[2m'
RESET='\033[0m'

CONF="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
WINDOW=15
SLEEP=3
API_TIMEOUT=3

export DEBIAN_FRONTEND=noninteractive

# --- DETECÇÃO DE DISTRO ---
_PKG_MANAGER=""
_APT_UPDATED=0
_detect_pkg_manager() {
    [ -n "$_PKG_MANAGER" ] && return
    if   command -v apt-get &>/dev/null; then _PKG_MANAGER="apt"
    elif command -v dnf     &>/dev/null; then _PKG_MANAGER="dnf"
    elif command -v yum     &>/dev/null; then _PKG_MANAGER="yum"
    elif command -v pacman  &>/dev/null; then _PKG_MANAGER="pacman"
    else echo -e "${RED}❌ Gerenciador de pacotes não detectado.${RESET}"; exit 1; fi
}

ensure_cmd() {
    local cmd="$1" pkg="$2"
    command -v "$cmd" &>/dev/null && return 0
    _detect_pkg_manager
    case "$_PKG_MANAGER" in
        apt)
            [ "$_APT_UPDATED" -eq 0 ] && { apt-get update -y >/dev/null 2>&1 || true; _APT_UPDATED=1; }
            apt-get install -y "$pkg" >/dev/null 2>&1 ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >/dev/null 2>&1 ;;
        pacman)  pacman -Sy --noconfirm "$pkg"      >/dev/null 2>&1 ;;
    esac
}

ensure_cmd jq jq

# --- PRÉ-CONDIÇÕES ---
if [ ! -s "$CONF" ]; then
    echo -e "${RED}❌ config.json não encontrado.${RESET}"; exit 1
fi
if ! jq empty "$CONF" 2>/dev/null; then
    echo -e "${RED}❌ config.json inválido.${RESET}"; exit 1
fi
if [ ! -x "$XRAY_BIN" ]; then
    echo -e "${RED}❌ xray não encontrado em $XRAY_BIN.${RESET}"; exit 1
fi
if ! jq -e '.inbounds[]? | select(.tag=="api")' "$CONF" >/dev/null 2>&1; then
    echo -e "${RED}❌ Inbound API (tag: api) não configurado no Xray.${RESET}"; exit 1
fi

# CORREÇÃO: fallback 1080 — alinhado com core_manager (porta padrão do projeto).
API_PORT="$(jq -r '.inbounds[]? | select(.tag=="api") | .port // empty' "$CONF" 2>/dev/null || true)"
[ -n "${API_PORT:-}" ] || API_PORT="1080"

# --- LISTA DE USUÁRIOS ATIVOS (sem LOCKED_) ---
mapfile -t USERS < <(jq -r '
    .inbounds[]? | select(.tag=="inbound-dragoncore")
    | .settings.clients[]?
    | select(.email? and (.email | startswith("LOCKED_") | not))
    | .email
' "$CONF" 2>/dev/null | awk 'NF')

if [ ${#USERS[@]} -eq 0 ]; then
    echo -e "${RED}Nenhum usuário ativo no inbound-dragoncore.${RESET}"; exit 0
fi

# --- CONSULTA À API COM TIMEOUT ---
_api_stat() {
    local name="$1"
    timeout "$API_TIMEOUT" \
        "$XRAY_BIN" api stats \
            -server="127.0.0.1:${API_PORT}" \
            -name "$name" 2>/dev/null \
        | awk '/value/ {print $2; exit}' \
        || echo "0"
}

# CORREÇÃO: bytes_human() usa awk — elimina dependência de bc.
# bc pode não estar instalado; awk está disponível em qualquer Unix.
bytes_human() {
    local b="${1:-0}"
    awk -v b="$b" 'BEGIN {
        if      (b >= 1073741824) printf "%.1f GB\n", b/1073741824
        else if (b >= 1048576)    printf "%.1f MB\n", b/1048576
        else if (b >= 1024)       printf "%.1f KB\n", b/1024
        else                      printf "%d B\n",    b
    }'
}

# --- INICIALIZAÇÃO ---
# CORREÇÃO: last_down e last_up separados — permite calcular delta real por ciclo.
# Versão anterior usava soma (get_total_bytes) e o "delta" exibido era o total acumulado.
declare -A last_down last_up last_seen

now="$(date +%s)"

echo -e "${CYAN}Inicializando monitor para ${#USERS[@]} usuário(s)...${RESET}"
for u in "${USERS[@]}"; do
    d=$(_api_stat "user>>>${u}>>>traffic>>>downlink")
    up=$(_api_stat "user>>>${u}>>>traffic>>>uplink")
    [ -n "${d:-}"  ] || d=0
    [ -n "${up:-}" ] || up=0
    last_down["$u"]="$d"
    last_up["$u"]="$up"
    # Se já tem tráfego no momento de abertura, considera online agora
    if [ $(( d + up )) -gt 0 ]; then
        last_seen["$u"]="$now"
    else
        last_seen["$u"]=0
    fi
done

# CORREÇÃO: xray_ok declarado fora do loop — persiste entre ciclos.
# Versão anterior resetava para true a cada ciclo, zerando o aviso nos 4 ciclos
# entre verificações mesmo se o Xray tivesse caído.
xray_ok=true
cycle=0

# --- LOOP PRINCIPAL ---
while true; do
    now="$(date +%s)"
    cycle=$(( cycle + 1 ))

    # Verifica saúde do Xray a cada 5 ciclos — atualiza flag persistente
    if (( cycle % 5 == 1 )); then
        systemctl is-active --quiet xray 2>/dev/null && xray_ok=true || xray_ok=false
    fi

    # CORREÇÃO: coleta down e up separados uma única vez por usuário por ciclo.
    # Versão anterior chamava _api_stat 4 vezes para usuários ativos (2 em get_total_bytes
    # + 2 novamente para o split). Agora são sempre 2 chamadas por usuário.
    declare -A cur_down cur_up delta_d delta_u delta_total

    for u in "${USERS[@]}"; do
        d=$(_api_stat "user>>>${u}>>>traffic>>>downlink")
        up=$(_api_stat "user>>>${u}>>>traffic>>>uplink")
        [ -n "${d:-}"  ] || d=0
        [ -n "${up:-}" ] || up=0

        cur_down["$u"]="$d"
        cur_up["$u"]="$up"

        # Delta real desde o último ciclo — robusto contra reset de contadores
        dd=$(( d  - last_down["$u"] ))
        du=$(( up - last_up["$u"]   ))
        [ "$dd" -lt 0 ] && dd="$d"
        [ "$du" -lt 0 ] && du="$up"

        delta_d["$u"]="$dd"
        delta_u["$u"]="$du"
        delta_total["$u"]=$(( dd + du ))

        if [ $(( dd + du )) -gt 0 ]; then
            last_seen["$u"]="$now"
        fi

        last_down["$u"]="$d"
        last_up["$u"]="$up"
    done

    # Renderiza tela
    clear
    echo -e "${CYAN}================================================${RESET}"
    echo -e "${CYAN}      MONITOR DE USUÁRIOS ONLINE (API)         ${RESET}"
    echo -e "${CYAN}================================================${RESET}"
    echo -e " Janela: ${YELLOW}${WINDOW}s${RESET}  Poll: ${YELLOW}${SLEEP}s${RESET}  Timeout API: ${YELLOW}${API_TIMEOUT}s${RESET}  Ciclo: ${DIM}#${cycle}${RESET}"

    if [ "$xray_ok" = false ]; then
        echo -e " ${RED}⚠  Xray não está ativo — stats podem estar zeradas!${RESET}"
    fi

    echo -e " Hora: $(date '+%H:%M:%S')  Usuários monitorados: ${#USERS[@]}"
    echo -e "${CYAN}------------------------------------------------${RESET}"
    printf " ${CYAN}%-14s${RESET} | ${CYAN}%-12s${RESET} | ${CYAN}%s${RESET}\n" "USUÁRIO" "DELTA CICLO" "STATUS"
    echo -e "${CYAN}------------------------------------------------${RESET}"

    online_count=0
    for u in "${USERS[@]}"; do
        seen="${last_seen["$u"]:-0}"
        age=$(( now - seen ))
        dt="${delta_total["$u"]:-0}"

        if [ "$seen" -gt 0 ] && [ "$age" -le "$WINDOW" ]; then
            # CORREÇÃO: exibe delta real do ciclo atual (down+up deste período),
            # não o total acumulado desde o início do Xray.
            delta_h="$(bytes_human "$dt")"
            printf " ${GREEN}%-14s${RESET} | ${YELLOW}%-12s${RESET} | ${GREEN}● Online${RESET} ${DIM}(há ${age}s)${RESET}\n" \
                "$u" "$delta_h"
            online_count=$(( online_count + 1 ))
        else
            if [ "$seen" -gt 0 ]; then
                printf " ${DIM}%-14s${RESET} | ${DIM}%-12s${RESET} | ${DIM}○ Inativo (há ${age}s)${RESET}\n" \
                    "$u" "-"
            else
                printf " ${DIM}%-14s${RESET} | ${DIM}%-12s${RESET} | ${DIM}○ Sem atividade${RESET}\n" \
                    "$u" "-"
            fi
        fi
    done

    echo -e "${CYAN}------------------------------------------------${RESET}"
    if [ "$online_count" -eq 0 ]; then
        echo -e " ${RED}Nenhum usuário ativo na janela de ${WINDOW}s.${RESET}"
    else
        echo -e " ${GREEN}${online_count} usuário(s) online agora.${RESET}"
    fi
    echo -e "${CYAN}================================================${RESET}"
    echo -e " ${DIM}CTRL+C para sair${RESET}"

    sleep "$SLEEP"
done
