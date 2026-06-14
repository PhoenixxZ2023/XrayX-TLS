#!/bin/bash
# menuxray.sh - DragonCore V7.5.1
# Correções aplicadas:
#   - Aritmética de cache segura com set -e (substituído ((...)) por [...])
#   - Validação de shebang robusta com suporte a BOM UTF-8
#   - Opção 99 reutiliza run_module() — elimina ~80 linhas de lógica duplicada
#   - FORCE_UPDATE sem export — não vaza para subshells/módulos filhos
#   - trap ERR não dispara em comandos esperados (systemctl, jq empty)
#   - LOG_FILE com rotação de 512KB ao iniciar

set -Eeuo pipefail

# CORREÇÃO: trap ERR só reporta erros genuínos. Comandos que podem falhar
# com intenção (systemctl, jq) devem usar || true/|| echo localmente.
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

export DEBIAN_FRONTEND=noninteractive

# --- CONFIGURAÇÃO ---
REPO_OWNER="PhoenixxZ2023"
REPO_NAME="XrayX-TLS"

_validate_ref() {
    local ref="$1"
    if [[ ! "$ref" =~ ^[a-zA-Z0-9._/-]{1,128}$ ]]; then
        echo -e "\033[1;31m❌ PINNED_REF inválido: '${ref}'\033[0m"
        exit 1
    fi
}

PINNED_REF="${PINNED_REF:-main}"
_validate_ref "$PINNED_REF"

REPO_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${PINNED_REF}"
MODULES_URL="${REPO_BASE}/modulosxray"
LOCAL_BIN="/usr/local/bin"
LOG_FILE="/tmp/menuxray.log"

XRAY_DIR="/opt/XrayTools"
USER_DB="${XRAY_DIR}/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"

# CORES
TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'

# --- CACHE DE STATUS DO MENU ---
_STATUS_CACHE_TTL=5
_STATUS_CACHE_TIME=0
_CACHED_XRAY_ACTIVE=""
_CACHED_BOT_ACTIVE=""
_CACHED_NET=""
_CACHED_PORT=""
_CACHED_USERS=""

_refresh_status_cache() {
    local now
    now=$(date +%s)

    # CORREÇÃO: substituído (( expr >= n )) por [ $((expr)) -ge n ]
    # Com set -e ativo, (( resultado == 0 )) retorna exit code 1 e dispara o trap ERR.
    if [ $((now - _STATUS_CACHE_TIME)) -ge "$_STATUS_CACHE_TTL" ]; then
        # CORREÇÃO: || echo "inactive" evita que set -e/trap ERR dispare quando
        # systemctl retorna 3 (serviço inativo) — comportamento esperado, não erro.
        _CACHED_XRAY_ACTIVE=$(systemctl is-active xray 2>/dev/null || echo "inactive")
        _CACHED_BOT_ACTIVE=$(systemctl is-active botxray 2>/dev/null || echo "inactive")
        _CACHED_USERS=$([ -f "$USER_DB" ] && wc -l < "$USER_DB" 2>/dev/null || echo "0")
        _CACHED_NET=""
        _CACHED_PORT=""

        if [ "$_CACHED_XRAY_ACTIVE" = "active" ]; then
            if [ -f "$PRESET_FILE" ] && jq empty "$PRESET_FILE" 2>/dev/null; then
                _CACHED_NET=$(jq -r '.network // empty' "$PRESET_FILE" 2>/dev/null || echo "")
                _CACHED_PORT=$(jq -r '.port // empty' "$PRESET_FILE" 2>/dev/null || echo "")
            fi
            if [ -z "$_CACHED_NET" ] && [ -f "$CONFIG_PATH" ] && jq empty "$CONFIG_PATH" 2>/dev/null; then
                _CACHED_NET=$(jq -r '.inbounds[] | select(.tag=="inbound-dragoncore").streamSettings.network // empty' \
                    "$CONFIG_PATH" 2>/dev/null || echo "")
            fi
            if [ -z "$_CACHED_PORT" ] && [ -f "$CONFIG_PATH" ] && jq empty "$CONFIG_PATH" 2>/dev/null; then
                _CACHED_PORT=$(jq -r '.inbounds[] | select(.tag=="inbound-dragoncore").port // empty' \
                    "$CONFIG_PATH" 2>/dev/null || echo "")
            fi
        fi

        _STATUS_CACHE_TIME=$now
    fi
}

# --- VERIFICAÇÃO DE ROOT ---
require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo -e "${TXT_RED}❌ Execute como root!${RESET}"
        exit 1
    fi
}

# --- DETECÇÃO DE GERENCIADOR DE PACOTES ---
_detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        echo ""
    fi
}

# --- INSTALAÇÃO DE DEPENDÊNCIAS ---
ensure_deps() {
    local pkgmgr
    pkgmgr=$(_detect_pkg_manager)
    local missing=()

    command -v curl &>/dev/null || missing+=("curl")
    command -v jq   &>/dev/null || missing+=("jq")

    if [ ${#missing[@]} -eq 0 ]; then
        return 0
    fi

    echo -e "${TXT_YELLOW}Instalando dependências: ${missing[*]}...${RESET}"
    case "$pkgmgr" in
        apt)
            apt-get update -y >>"$LOG_FILE" 2>&1
            apt-get install -y "${missing[@]}" >>"$LOG_FILE" 2>&1
            ;;
        dnf|yum)
            "$pkgmgr" install -y "${missing[@]}" >>"$LOG_FILE" 2>&1
            ;;
        pacman)
            pacman -Sy --noconfirm "${missing[@]}" >>"$LOG_FILE" 2>&1
            ;;
        *)
            echo -e "${TXT_RED}❌ Gerenciador de pacotes não detectado. Instale curl e jq manualmente.${RESET}"
            exit 1
            ;;
    esac
}

# --- INICIALIZAÇÃO DO SISTEMA ---
init_system() {
    mkdir -p "$XRAY_DIR" "$LOCAL_BIN"
    touch "$USER_DB"

    # CORREÇÃO: rotação de log — mantém últimos 512KB para evitar crescimento
    # ilimitado em /tmp entre sessões num servidor de uso intenso.
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 524288 ]; then
        tail -c 524288 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE" || true
    fi
    : >> "$LOG_FILE"
}

# --- VERIFICAÇÃO DE INTEGRIDADE DO MÓDULO ---
_verify_module_hash() {
    local file="$1"
    local module_name="$2"
    local sha256_url="${MODULES_URL}/${module_name}.sha256"
    local expected

    expected=$(curl -fLsS --max-time 10 --connect-timeout 5 \
        "$sha256_url" 2>/dev/null | awk '{print $1}')

    if [ -z "$expected" ]; then
        echo -e "${TXT_YELLOW}⚠  Hash não encontrado para ${module_name} — verificação ignorada.${RESET}" >&2
        return 0
    fi

    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')

    if [ "$expected" != "$actual" ]; then
        echo -e "${TXT_RED}❌ Falha de integridade em ${module_name}!${RESET}" >&2
        echo -e "   Esperado: ${expected}" >&2
        echo -e "   Obtido:   ${actual}" >&2
        return 1
    fi

    return 0
}

# --- EXECUÇÃO DE MÓDULO ---
run_module() {
    local script_name="$1"
    local description="$2"
    local local_path="${LOCAL_BIN}/${script_name}"

    # CORREÇÃO: FORCE_UPDATE consultado sem export — variável de ambiente local ao processo.
    # Usar `FORCE_UPDATE=1 run_module ...` na chamada quando necessário.
    if [ "${FORCE_UPDATE:-0}" = "1" ] || [ ! -s "$local_path" ]; then
        echo -e "${TXT_YELLOW}Baixando módulo: ${description}...${RESET}"
        local tmp_path
        tmp_path=$(mktemp /tmp/xray_module_XXXXXX)

        if ! curl -fLsS \
                --retry 3 \
                --retry-delay 2 \
                --max-time 60 \
                --connect-timeout 10 \
                -o "$tmp_path" \
                "${MODULES_URL}/${script_name}" 2>>"$LOG_FILE"; then
            echo -e "${TXT_RED}❌ Erro ao baixar ${script_name}. Veja: ${LOG_FILE}${RESET}"
            rm -f "$tmp_path"
            sleep 2
            return 1
        fi

        if [ ! -s "$tmp_path" ]; then
            echo -e "${TXT_RED}❌ Arquivo ${script_name} baixado está vazio.${RESET}"
            rm -f "$tmp_path"
            sleep 2
            return 1
        fi

        # CORREÇÃO: validação de shebang com suporte a BOM UTF-8 (0xEF 0xBB 0xBF).
        # Usa grep com LC_ALL=C para tratar bytes brutos sem problemas de locale.
        if ! LC_ALL=C head -n 1 "$tmp_path" | grep -qP '^(\xEF\xBB\xBF)?#!.*(bash|env\s)'; then
            echo -e "${TXT_RED}❌ Arquivo ${script_name} não parece um shell script válido.${RESET}"
            rm -f "$tmp_path"
            sleep 2
            return 1
        fi

        if ! _verify_module_hash "$tmp_path" "$script_name"; then
            echo -e "${TXT_RED}❌ Módulo ${script_name} rejeitado por falha de integridade.${RESET}"
            rm -f "$tmp_path"
            sleep 2
            return 1
        fi

        mv -f "$tmp_path" "$local_path"
        chmod 0755 "$local_path"
    fi

    bash "$local_path"
}

# --- DOWNLOAD DE MÓDULO (SEM EXECUTAR) ---
# Usado pela opção 99 — baixa e valida o módulo mas NÃO executa.
# Evita o travamento causado por run_module que sempre executa o script após download.
download_module() {
    local script_name="$1"
    local local_path="${LOCAL_BIN}/${script_name}"
    local tmp_path

    tmp_path=$(mktemp /tmp/xray_module_XXXXXX)

    echo -ne "${TXT_YELLOW}Atualizando ${script_name}...${RESET} "

    if ! curl -fLsS             --retry 3             --retry-delay 2             --max-time 60             --connect-timeout 10             -o "$tmp_path"             "${MODULES_URL}/${script_name}" 2>>"$LOG_FILE"; then
        echo -e "${TXT_RED}FALHOU (download)${RESET}"
        rm -f "$tmp_path"
        return 1
    fi

    if [ ! -s "$tmp_path" ]; then
        echo -e "${TXT_RED}FALHOU (vazio)${RESET}"
        rm -f "$tmp_path"
        return 1
    fi

    if ! LC_ALL=C head -n 1 "$tmp_path" | grep -qP '^(\xEF\xBB\xBF)?#!.*(bash|env\s)'; then
        echo -e "${TXT_RED}FALHOU (shebang inválido)${RESET}"
        rm -f "$tmp_path"
        return 1
    fi

    if ! _verify_module_hash "$tmp_path" "$script_name" 2>/dev/null; then
        echo -e "${TXT_RED}FALHOU (hash)${RESET}"
        rm -f "$tmp_path"
        return 1
    fi

    mv -f "$tmp_path" "$local_path"
    chmod 0755 "$local_path"
    echo -e "${TXT_GREEN}OK${RESET}"
    return 0
}

# --- CONFIRMAÇÃO PARA AÇÕES DESTRUTIVAS ---
_confirm_destructive() {
    local msg="$1"
    echo -e "${TXT_YELLOW}⚠  ${msg}${RESET}"
    read -rp "Confirmar? [s/N]: " confirm
    case "$confirm" in
        s|S|sim|Sim|SIM) return 0 ;;
        *) echo "Operação cancelada."; sleep 1; return 1 ;;
    esac
}

# --- EXIBIÇÃO DO MENU ---
menu_display() {
    clear
    _refresh_status_cache

    echo -e "${TITLE_BAR}        DRAGONCORE XRAY MANAGER (V7.5)        ${RESET}"
    echo ""

    local status_txt="${TXT_RED}DESATIVADO${RESET}"
    local protocol_line=""

    if [ "$_CACHED_XRAY_ACTIVE" = "active" ]; then
        status_txt="${TXT_GREEN}ATIVADO${RESET}"
        if [ -n "$_CACHED_NET" ] && [ -n "$_CACHED_PORT" ]; then
            protocol_line=" ${TXT_CYAN}PROTOCOLO/PORTA:${RESET}  ${_CACHED_NET^^} (${_CACHED_PORT})"
        fi
    fi

    local bot_status="${TXT_RED}DESATIVADO${RESET}"
    if [ "$_CACHED_BOT_ACTIVE" = "active" ]; then
        bot_status="${TXT_GREEN}ONLINE${RESET}"
    fi

    echo "-----------------------------------------"
    echo -e " ${TXT_CYAN}STATUS XRAY:${RESET}      $status_txt"
    echo -e " ${TXT_CYAN}USUÁRIOS:${RESET}         ${_CACHED_USERS}"
    [ -n "$protocol_line" ] && echo -e "$protocol_line"
    echo -e " ${TXT_CYAN}BOT TELEGRAM:${RESET}     $bot_status"
    echo "-----------------------------------------"
    echo ""
    echo -e "${TXT_CYAN}[01] CRIAR USUÁRIO${RESET}"
    echo -e "${TXT_CYAN}[02] REMOVER USUÁRIO${RESET}"
    echo -e "${TXT_CYAN}[03] LISTAR USUÁRIOS${RESET}"
    echo -e "${TXT_CYAN}[04] INSTALAR/CONFIGURAR XRAY${RESET}"
    echo -e "${TXT_CYAN}[05] LIMPAR EXPIRADOS${RESET}"
    echo -e "${TXT_RED}[06] DESINSTALAR XRAY${RESET}"
    echo -e "${TXT_CYAN}[07] LIMITADOR CONSUMO (GB)${RESET}"
    echo -e "${TXT_CYAN}[08] BOT TELEGRAM${RESET}"
    echo -e "${TXT_CYAN}[09] BACKUP / RESTORE${RESET}"
    echo -e "${TXT_CYAN}[10] BLOQUEAR USUÁRIOS${RESET}"
    echo -e "${TXT_CYAN}[11] DESBLOQUEAR USUÁRIOS${RESET}"
    echo -e "${TXT_CYAN}[12] MONITOR ONLINE${RESET}"
    echo -e "${TXT_CYAN}[13] ATIVAR BBR (OTIMIZAÇÃO TCP)${RESET}"
    echo -e "${TXT_YELLOW}[99] ATUALIZAR MÓDULOS (FORÇA DOWNLOAD)${RESET}"
    echo -e "${TXT_CYAN}[00] SAIR${RESET}"
    echo "-----------------------------------------"
    read -rp "Opção: " choice

    case "$choice" in
        1|01) run_module "add_user.sh"          "Criar Usuário" ;;
        2|02) run_module "remover_user.sh"      "Remover Usuário" ;;
        3|03) run_module "lista_users.sh"       "Listar Usuários" ;;
        4|04) run_module "core_manager.sh"      "Gerenciador Xray" ;;
        5|05)
            _confirm_destructive "Isso removerá todos os usuários expirados." \
                && run_module "remover_expirados.sh" "Limpeza"
            ;;
        6|06)
            _confirm_destructive "Isso DESINSTALARÁ completamente o Xray do sistema." \
                && run_module "uninstall.sh" "Desinstalador"
            ;;
        7|07) run_module "limiterxray.sh"       "Limitador" ;;
        8|08) run_module "botxray.sh"           "Instalador Bot" ;;
        9|09) run_module "backup.sh"            "Backup System" ;;
        10)   run_module "block_user.sh"        "Bloqueio" ;;
        11)   run_module "unblock_user.sh"      "Desbloqueio" ;;
        12)   run_module "onlinexray.sh"        "Monitor" ;;
        13)   run_module "bbr.sh"               "Ativar BBR" ;;
        99)
            # Usa download_module() — baixa e valida SEM executar.
            # run_module() sempre executa o script após download, travando em módulos
            # que aguardam input do usuário (botxray.sh, backup.sh, etc.)
            clear
            echo -e "${TXT_YELLOW}================================================${RESET}"
            echo -e "${TXT_YELLOW}   ATUALIZANDO TODOS OS MÓDULOS               ${RESET}"
            echo -e "${TXT_YELLOW}================================================${RESET}"
            echo ""
            _STATUS_CACHE_TIME=0

            local modules=(
                add_user.sh remover_user.sh lista_users.sh core_manager.sh
                remover_expirados.sh uninstall.sh limiterxray.sh botxray.sh
                backup.sh block_user.sh unblock_user.sh onlinexray.sh
                certxray.sh bbr.sh
            )

            local ok=0 fail=0
            for mod in "${modules[@]}"; do
                if download_module "$mod"; then
                    ok=$((ok + 1))
                else
                    fail=$((fail + 1))
                fi
            done

            echo ""
            echo -e "${TXT_GREEN}================================================${RESET}"
            echo -e "${TXT_GREEN}Concluído: ${ok} OK${RESET}  ${TXT_RED}${fail} falharam${RESET}"
            echo -e "${TXT_GREEN}================================================${RESET}"
            sleep 3
            ;;
        0|00)
            echo -e "${TXT_GREEN}Saindo...${RESET}"
            exit 0
            ;;
        *)
            echo -e "${TXT_RED}Opção inválida: '${choice}'${RESET}"
            sleep 1
            ;;
    esac
}

# --- INICIALIZAÇÃO ---
require_root
ensure_deps
init_system

# Loop principal — menu_display nunca se chama recursivamente
while true; do
    menu_display
done
