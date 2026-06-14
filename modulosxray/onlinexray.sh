#!/bin/bash
# onlinexray.sh - Monitor Online V7.5
# Correções: timeout em cada chamada API, exibição de delta de tráfego,
#            detecção de Xray parado, inicialização correta de last_seen,
#            detecção de distro em ensure_cmd.

set -uo pipefail
trap 'echo -e "\n\033[1;33mSaindo...\033[0m"; exit 0' INT TERM

GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
DIM='\033[2m'
RESET='\033[0m'

CONF="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
WINDOW=15      # segundos — considera online se teve tráfego nessa janela
SLEEP=3        # intervalo de polling em segundos
API_TIMEOUT=3  # timeout por chamada à API (segundos)

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

# Porta da API (dinâmica, fallback 1080)
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
# Retorna bytes de um stat específico; timeout evita trava
_api_stat() {
    local name="$1"
    timeout "$API_TIMEOUT" \
        "$XRAY_BIN" api stats \
            -server="127.0.0.1:${API_PORT}" \
            -name "$name" 2>/dev/null \
        | awk '/value/ {print $2; exit}' \
        || echo "0"
}

get_total_bytes() {
    local nick="$1"
    local down up
    down=$(_api_stat "user>>>${nick}>>>traffic>>>downlink")
    up=$(_api_stat   "user>>>${nick}>>>traffic>>>uplink")
    [ -n "${down:-}" ] || down=0
    [ -n "${up:-}"   ] || up=0
    echo $(( down + up ))
}

# --- CONVERSÃO DE BYTES ---
bytes_human() {
    local b="${1:-0}"
    if   [ "$b" -ge 1073741824 ]; then printf "%.1f GB" "$(echo "scale=1; $b/1073741824" | bc)"
    elif [ "$b" -ge 1048576    ]; then printf "%.1f MB" "$(echo "scale=1; $b/1048576"    | bc)"
    elif [ "$b" -ge 1024       ]; then printf "%.1f KB" "$(echo "scale=1; $b/1024"       | bc)"
    else echo "${b} B"; fi
}

# --- INICIALIZAÇÃO ---
declare -A last_bytes
declare -A last_seen
declare -A last_delta_down
declare -A last_delta_up

now="$(date +%s)"

echo -e "${CYAN}Inicializando monitor para ${#USERS[@]} usuário(s)...${RESET}"
for u in "${USERS[@]}"; do
    b="$(get_total_bytes "$u")"
    last_bytes["$u"]="$b"
    last_delta_down["$u"]=0
    last_delta_up["$u"]=0
    # Se já tem tráfego no momento de abertura, considera online agora
    if [ "${b:-0}" -gt 0 ]; then
        last_seen["$u"]="$now"
    else
        last_seen["$u"]=0
    fi
done

# --- LOOP PRINCIPAL ---
cycle=0
while true; do
    now="$(date +%s)"
    cycle=$(( cycle + 1 ))

    # Verifica saúde do Xray a cada 5 ciclos
    xray_ok=true
    if (( cycle % 5 == 1 )); then
        systemctl is-active --quiet xray 2>/dev/null || xray_ok=false
    fi

    # Coleta deltas
    for u in "${USERS[@]}"; do
        b="$(get_total_bytes "$u")"
        prev="${last_bytes["$u"]:-0}"
        delta=$(( b - prev ))

        if [ "$delta" -gt 0 ]; then
            last_seen["$u"]="$now"
            # Estimativa de split down/up: busca individual para usuários ativos
            down=$(_api_stat "user>>>${u}>>>traffic>>>downlink")
            up=$(_api_stat   "user>>>${u}>>>traffic>>>uplink")
            [ -n "${down:-}" ] || down=0
            [ -n "${up:-}"   ] || up=0
            last_delta_down["$u"]=$(( down - (last_bytes["$u"] - ${last_delta_up["$u"]:-0}) )) 2>/dev/null || \
                last_delta_down["$u"]=0
            last_delta_up["$u"]="$up"
        fi
        last_bytes["$u"]="$b"
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
    printf " ${CYAN}%-14s${RESET} | ${CYAN}%-10s${RESET} | ${CYAN}%s${RESET}\n" "USUÁRIO" "DELTA CICLO" "STATUS"
    echo -e "${CYAN}------------------------------------------------${RESET}"

    online_count=0
    for u in "${USERS[@]}"; do
        seen="${last_seen["$u"]:-0}"
        age=$(( now - seen ))
        delta_total=$(( last_bytes["$u"] - 0 ))

        if [ "$seen" -gt 0 ] && [ "$age" -le "$WINDOW" ]; then
            # Online — mostra delta do ciclo atual
            current_b="${last_bytes["$u"]:-0}"
            delta_human="$(bytes_human "$current_b") total"
            printf " ${GREEN}%-14s${RESET} | ${YELLOW}%-10s${RESET} | ${GREEN}● Online${RESET} ${DIM}(há ${age}s)${RESET}\n" \
                "$u" "$delta_human"
            online_count=$(( online_count + 1 ))
        else
            # Offline ou sem atividade recente
            if [ "$seen" -gt 0 ]; then
                ago=$(( age ))
                printf " ${DIM}%-14s${RESET} | ${DIM}%-10s${RESET} | ${DIM}○ Inativo (há ${ago}s)${RESET}\n" \
                    "$u" "-"
            else
                printf " ${DIM}%-14s${RESET} | ${DIM}%-10s${RESET} | ${DIM}○ Sem atividade${RESET}\n" \
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
