#!/bin/bash
# limiterxray.sh - Controle de Consumo V7.4
# Correções: lock exclusivo contra race condition cron+UI, backup+jq empty antes
#            de cada escrita no config, mktemp em db_delete_key, UUID fake com
#            fallback, aritmética inteira nativa (sem bc onde possível),
#            timeout na API do Xray, permissões nos DBs, view cruzada com user_db,
#            detecção de distro em ensure_cmd.

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

XRAY_BIN="/usr/local/bin/xray"
CONFIG_PATH="/usr/local/etc/xray/config.json"
LIMITS_DB="/opt/XrayTools/limits.db"
USAGE_DB="/opt/XrayTools/usage.db"
SESSION_DB="/opt/XrayTools/session.db"
USER_DB="/opt/XrayTools/users.db"
LOG_FILE="/tmp/limiterxray.log"
LOCK_FILE="/tmp/limiterxray.lock"
XRAY_API_PORT="1080"
XRAY_API_TIMEOUT=5   # segundos por chamada à API

TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'

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
    else echo -e "${TXT_RED}❌ Gerenciador de pacotes não detectado.${RESET}"; exit 1; fi
}

ensure_cmd() {
    local cmd="$1" pkg="$2"
    command -v "$cmd" &>/dev/null && return 0
    _detect_pkg_manager
    case "$_PKG_MANAGER" in
        apt)
            [ "$_APT_UPDATED" -eq 0 ] && { apt-get update -y >>"$LOG_FILE" 2>&1 || true; _APT_UPDATED=1; }
            apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        pacman)  pacman -Sy --noconfirm "$pkg"      >>"$LOG_FILE" 2>&1 ;;
    esac
}

validate_nick() {
    local n="${1:-}"
    [[ "$n" =~ ^[a-zA-Z0-9]{5,9}$ ]]
}

# --- UUID COM FALLBACK ---
generate_uuid() {
    local u=""
    if command -v uuidgen &>/dev/null; then
        u=$(uuidgen | tr '[:upper:]' '[:lower:]')
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        u=$(cat /proc/sys/kernel/random/uuid)
    else
        u=$(od -x /dev/urandom | head -1 | \
            awk '{printf "%s%s-%s-4%s-%s%s-%s%s\n",$2,$3,$4,substr($5,2),substr($6,1,1),substr($6,2),$7,$8}' | \
            tr '[:upper:]' '[:lower:]')
    fi
    [[ "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
        echo -e "${TXT_RED}❌ Falha ao gerar UUID.${RESET}" >&2; return 1
    }
    echo "$u"
}

# --- LOCK EXCLUSIVO (evita race condition cron vs UI) ---
acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo -e "${TXT_RED}⚠  Outra instância do limiter está rodando. Aguarde.${RESET}"
        exit 1
    fi
}
release_lock() { flock -u 9; rm -f "$LOCK_FILE"; }

# --- INICIALIZAÇÃO ---
: > "$LOG_FILE"
mkdir -p "/opt/XrayTools"
touch "$LIMITS_DB" "$USAGE_DB" "$SESSION_DB" "$USER_DB"
chmod 0600 "$LIMITS_DB" "$USAGE_DB" "$SESSION_DB"

ensure_cmd jq jq
ensure_cmd bc bc   # ainda necessário para float em bytes_to_human

header_limit() {
    clear
    echo -e "${TITLE_BAR}   CONTROLE DE CONSUMO (PERSISTENTE)   ${RESET}"
    echo ""
}

func_get_api_port() {
    if [ -f "$CONFIG_PATH" ] && jq empty "$CONFIG_PATH" 2>/dev/null; then
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

# --- DB HELPERS COM mktemp (evita colisão entre processos paralelos) ---
db_delete_key() {
    local file="$1" nick="$2"
    local tmp
    tmp=$(mktemp "${file}.tmp.XXXXXX")
    awk -F'|' -v n="$nick" '$1!=n {print}' "$file" > "$tmp"
    mv -f "$tmp" "$file"
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

# --- ESCRITA SEGURA NO CONFIG (backup + jq empty + mv atômico + permissões) ---
safe_config_write() {
    local jq_filter="$1"
    shift
    local tmp
    tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")

    # Aplica filtro jq passando argumentos adicionais ("$@")
    if ! jq "$@" "$jq_filter" "$CONFIG_PATH" > "$tmp" 2>>"$LOG_FILE"; then
        rm -f "$tmp"
        echo -e "${TXT_RED}❌ Erro ao processar config com jq.${RESET}" >&2
        return 1
    fi

    # Valida JSON gerado
    if ! jq empty "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo -e "${TXT_RED}❌ Config gerado é JSON inválido. Abortando.${RESET}" >&2
        return 1
    fi

    # Backup antes de aplicar
    cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    mv -f "$tmp" "$CONFIG_PATH"
    chmod 0600 "$CONFIG_PATH"
    chown root:root "$CONFIG_PATH"
}

apply_config_change_and_reload() {
    if ! systemctl try-reload-or-restart xray >/dev/null 2>&1 && \
       ! systemctl restart xray >/dev/null 2>&1; then
        echo -e "${TXT_RED}❌ Falha ao recarregar Xray. Revertendo config...${RESET}" >&2
        [ -f "${CONFIG_PATH}.bak" ] && mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        return 1
    fi
}

# --- CHAMADA À API COM TIMEOUT ---
xray_api_stat() {
    local name="$1"
    timeout "$XRAY_API_TIMEOUT" \
        "$XRAY_BIN" api stats \
            -server="127.0.0.1:$XRAY_API_PORT" \
            -name "$name" 2>/dev/null \
        | awk '/value/ {print $2; exit}' \
        || echo "0"
}

# ============================================================
# FUNÇÕES DE MENU
# ============================================================

func_set_limit() {
    header_limit
    echo "Definir Limite de Dados"
    echo "--------------------------------------"
    read -rp "Nick do usuário: " nick
    [ -n "${nick:-}" ] || return

    if ! validate_nick "$nick"; then
        echo -e "${TXT_RED}❌ Nick inválido. Use 5-9 letras/números.${RESET}"
        read -rp "Enter..."; return
    fi

    if [ ! -s "$CONFIG_PATH" ] || ! jq empty "$CONFIG_PATH" 2>/dev/null; then
        echo -e "${TXT_RED}❌ Config inválida ou não encontrada.${RESET}"
        read -rp "Enter..."; return
    fi

    local is_locked=false
    if is_user_locked "$nick"; then
        is_locked=true
    elif ! user_exists_in_config "$nick"; then
        echo -e "${TXT_RED}❌ Usuário não encontrado no Xray!${RESET}"
        read -rp "Enter..."; return
    fi

    read -rp "Limite em GB: " gb_limit
    if ! [[ "${gb_limit:-}" =~ ^[0-9]+$ ]]; then
        echo "Inválido."; sleep 1; return
    fi

    # Aritmética inteira nativa (sem bc)
    local bytes_limit=$(( gb_limit * 1073741824 ))
    db_set_value "$LIMITS_DB" "$nick" "$bytes_limit"

    read -rp "Zerar consumo atual? [s/N]: " zerar
    if [[ "${zerar:-n}" =~ ^[Ss]$ ]]; then
        db_delete_key "$USAGE_DB" "$nick"
        db_delete_key "$SESSION_DB" "$nick"
        echo -e "${TXT_CYAN}Histórico zerado.${RESET}"
    fi

    # Desbloqueia se estava bloqueado
    if [ "$is_locked" = true ]; then
        local real_uuid
        real_uuid="$(get_real_uuid_from_db "$nick")"
        if [ -n "${real_uuid:-}" ]; then
            acquire_lock
            safe_config_write \
                '(.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
                  (if type=="array" then . else [] end)
                |
                (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
                  map(if .email == $locked then .email = $nick | .id = $uuid else . end)' \
                --arg nick "$nick" --arg locked "LOCKED_$nick" --arg uuid "$real_uuid"
            apply_config_change_and_reload && echo -e "${TXT_GREEN}✅ Usuário desbloqueado!${RESET}"
            release_lock
        else
            echo -e "${TXT_YELLOW}⚠  UUID real não encontrado. Desbloqueio manual necessário.${RESET}"
        fi
    fi

    echo -e "${TXT_GREEN}✅ Limite salvo: ${gb_limit} GB${RESET}"
    read -rp "Enter para voltar..."
}

func_view_usage() {
    func_get_api_port
    header_limit

    printf "%-14s | %-12s | %-12s | %s\n" "USUÁRIO" "USADO" "LIMITE" "STATUS"
    echo "-----------------------------------------------------------"

    # Coleta todos os usuários: union de users.db e limits.db
    local all_nicks=()
    while IFS='|' read -r name _; do
        [ -n "$name" ] && all_nicks+=("$name")
    done < "$USER_DB"
    while IFS='|' read -r name _; do
        [ -n "$name" ] || continue
        local found=0
        for n in "${all_nicks[@]:-}"; do [ "$n" = "$name" ] && found=1 && break; done
        [ "$found" -eq 0 ] && all_nicks+=("$name")
    done < "$LIMITS_DB"

    for nick in "${all_nicks[@]:-}"; do
        [ -n "$nick" ] || continue

        local usage_total limit_bytes
        usage_total="$(db_get_value "$USAGE_DB" "$nick")"; [ -n "${usage_total:-}" ] || usage_total=0
        limit_bytes="$(db_get_value "$LIMITS_DB" "$nick")"

        local limit_h status
        if [ -z "${limit_bytes:-}" ]; then
            limit_h="Sem limite"
            status="${TXT_GREEN}Livre${RESET}"
        else
            limit_h="$(func_bytes_to_human "$limit_bytes")"
            if is_user_locked "$nick" 2>/dev/null; then
                status="${TXT_RED}BLOQUEADO${RESET}"
            elif [ "$usage_total" -ge "$limit_bytes" ]; then
                status="${TXT_RED}EXCEDIDO${RESET}"
            else
                local pct=$(( usage_total * 100 / limit_bytes ))
                status="${TXT_CYAN}${pct}%${RESET}"
            fi
        fi

        local used_h
        used_h="$(func_bytes_to_human "$usage_total")"
        printf "%-14s | %-12s | %-12s | %b\n" "$nick" "$used_h" "$limit_h" "$status"
    done

    echo "-----------------------------------------------------------"
    echo ""
    read -rp "Enter para voltar..."
}

func_remove_limit() {
    header_limit
    read -rp "Usuário para remover limite: " nick
    [ -n "${nick:-}" ] || return

    if ! validate_nick "$nick"; then
        echo -e "${TXT_RED}❌ Nick inválido.${RESET}"; sleep 1; return
    fi

    db_delete_key "$LIMITS_DB"  "$nick"
    db_delete_key "$USAGE_DB"   "$nick"
    db_delete_key "$SESSION_DB" "$nick"

    if [ -s "$CONFIG_PATH" ] && jq empty "$CONFIG_PATH" 2>/dev/null && is_user_locked "$nick" 2>/dev/null; then
        local real_uuid
        real_uuid="$(get_real_uuid_from_db "$nick")"
        if [ -n "${real_uuid:-}" ]; then
            acquire_lock
            safe_config_write \
                '(.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
                  (if type=="array" then . else [] end)
                |
                (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
                  map(if .email == $locked then .email = $nick | .id = $uuid else . end)' \
                --arg nick "$nick" --arg locked "LOCKED_$nick" --arg uuid "$real_uuid"
            apply_config_change_and_reload
            release_lock
        fi
    fi

    echo -e "${TXT_GREEN}✅ Limite removido e histórico limpo.${RESET}"
    sleep 2
}

func_check_and_block() {
    local MODE="$1"
    func_get_api_port

    [ "$MODE" != "--cron" ] && {
        header_limit
        [ "$MODE" = "--sync-only" ] && echo "Sincronizando (sem bloqueio)..." || echo "Sincronizando e aplicando regras..."
    }

    # Valida config e API inbound
    if [ ! -s "$CONFIG_PATH" ] || ! jq empty "$CONFIG_PATH" 2>/dev/null; then
        [ "$MODE" != "--cron" ] && echo -e "${TXT_RED}❌ Config inválida.${RESET}"
        return 1
    fi
    if ! jq -e '.inbounds[]? | select(.tag=="api")' "$CONFIG_PATH" >/dev/null 2>&1; then
        [ "$MODE" != "--cron" ] && {
            echo -e "${TXT_RED}❌ Inbound API não configurado (tag: api).${RESET}"
            read -rp "Enter..."
        }
        return 1
    fi

    # Lock exclusivo — evita race condition cron vs UI
    acquire_lock

    local blocked_count=0
    local config_changed=false

    # Copia de trabalho dos DBs de sessão/uso
    local tmp_usage tmp_session
    tmp_usage=$(mktemp "${USAGE_DB}.work.XXXXXX")
    tmp_session=$(mktemp "${SESSION_DB}.work.XXXXXX")
    cp "$USAGE_DB"   "$tmp_usage"
    cp "$SESSION_DB" "$tmp_session"

    while IFS='|' read -r nick limit_bytes; do
        [ -n "${nick:-}" ] || continue

        # Se já bloqueado, pula
        is_user_locked "$nick" 2>/dev/null && continue

        # Consulta API com timeout
        local down up
        down=$(xray_api_stat "user>>>${nick}>>>traffic>>>downlink")
        up=$(xray_api_stat   "user>>>${nick}>>>traffic>>>uplink")
        [ -n "${down:-}" ] || down=0
        [ -n "${up:-}"   ] || up=0

        local current_session=$(( down + up ))

        local last_session historical_usage
        last_session="$(db_get_value "$tmp_session" "$nick")"; [ -n "${last_session:-}" ] || last_session=0
        historical_usage="$(db_get_value "$tmp_usage" "$nick")"; [ -n "${historical_usage:-}" ] || historical_usage=0

        # Delta robusto contra reset de contadores
        local delta
        if [ "$current_session" -lt "$last_session" ]; then
            delta="$current_session"
        else
            delta=$(( current_session - last_session ))
        fi

        local new_historical=$(( historical_usage + delta ))

        db_set_value "$tmp_usage"   "$nick" "$new_historical"
        db_set_value "$tmp_session" "$nick" "$current_session"

        if [ "$new_historical" -ge "$limit_bytes" ]; then
            if [ "$MODE" = "--sync-only" ]; then
                [ "$MODE" != "--cron" ] && \
                    echo -e "${TXT_YELLOW}⚠  $nick excedeu limite (bloqueio pendente).${RESET}"
            else
                [ "$MODE" != "--cron" ] && \
                    echo -e "${TXT_RED}❌ $nick estourou. Bloqueando...${RESET}"

                local fake_uuid
                fake_uuid=$(generate_uuid) || { echo -e "${TXT_RED}❌ UUID falhou para $nick.${RESET}" >&2; continue; }

                # Aplica bloqueio no config (sem reload ainda — acumulamos e recarregamos uma vez)
                local tmp_block
                tmp_block=$(mktemp "${CONFIG_PATH}.block.XXXXXX")
                if jq \
                    --arg nick "$nick" \
                    --arg locked "LOCKED_$nick" \
                    --arg fake "$fake_uuid" \
                    '(.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
                      (if type=="array" then . else [] end)
                    |
                    (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
                      map(if .email == $nick then .email = $locked | .id = $fake else . end)' \
                    "$CONFIG_PATH" > "$tmp_block" 2>>"$LOG_FILE" \
                    && jq empty "$tmp_block" 2>/dev/null; then
                    cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
                    mv -f "$tmp_block" "$CONFIG_PATH"
                    chmod 0600 "$CONFIG_PATH"
                    config_changed=true
                    blocked_count=$(( blocked_count + 1 ))
                else
                    rm -f "$tmp_block"
                    [ "$MODE" != "--cron" ] && \
                        echo -e "${TXT_RED}⚠  Falha ao bloquear $nick — config não alterado.${RESET}"
                fi
            fi
        fi
    done < "$LIMITS_DB"

    # Promove cópias de trabalho para DBs reais
    mv -f "$tmp_usage"   "$USAGE_DB"
    mv -f "$tmp_session" "$SESSION_DB"
    chmod 0600 "$USAGE_DB" "$SESSION_DB"

    # Reload único ao final, se houve bloqueios
    if [ "$config_changed" = true ]; then
        apply_config_change_and_reload || true
        [ "$MODE" != "--cron" ] && \
            echo -e "${TXT_RED}🚫 ${blocked_count} usuário(s) bloqueado(s).${RESET}"
    else
        [ "$MODE" != "--cron" ] && \
            echo -e "${TXT_GREEN}✅ Dados atualizados. Nenhum bloqueio necessário.${RESET}"
    fi

    release_lock
    [ "$MODE" != "--cron" ] && read -rp "Enter..."
}

# --- ENTRY POINT ---
if [ "${1:-}" = "--cron" ]; then
    func_check_and_block "--cron"
    exit 0
fi

while true; do
    header_limit
    echo -e "${TXT_CYAN}[1] DEFINIR/ALTERAR LIMITE${RESET}"
    echo -e "${TXT_CYAN}[2] VER CONSUMO ACUMULADO${RESET}"
    echo -e "${TXT_CYAN}[3] REMOVER LIMITE${RESET}"
    echo -e "${TXT_RED}[4] VERIFICAR E BLOQUEAR EXCEDENTES${RESET}"
    echo -e "${TXT_YELLOW}[5] APENAS SINCRONIZAR (SEM BLOQUEIO)${RESET}"
    echo -e "${TXT_CYAN}[0] VOLTAR${RESET}"
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
