#!/bin/bash
# menuxray.sh - DragonCore V7.5
# Correções: verificação de integridade, validação de PINNED_REF, recursão removida,
#            run_module com retorno correto, timeout no curl, confirmação em ações destrutivas,
#            FORCE_UPDATE resetado após update, cache de status, detecção de distro.

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

export DEBIAN_FRONTEND=noninteractive

# --- CONFIGURAÇÃO ---
REPO_OWNER="PhoenixxZ2023"
REPO_NAME="XrayX-TLS"

# Valida PINNED_REF antes de usar na URL — evita injeção de paths
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

# DIRETÓRIOS LOCAIS
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
# Evita chamar systemctl/jq repetidamente a cada render
_STATUS_CACHE_TTL=5  # segundos
_STATUS_CACHE_TIME=0
_CACHED_XRAY_ACTIVE=""
_CACHED_BOT_ACTIVE=""
_CACHED_NET=""
_CACHED_PORT=""
_CACHED_USERS=""

_refresh_status_cache() {
    local now
    now=$(date +%s)
    if (( now - _STATUS_CACHE_TIME >= _STATUS_CACHE_TTL )); then
        _CACHED_XRAY_ACTIVE=$(systemctl is-active xray 2>/dev/null || echo "inactive")
        _CACHED_BOT_ACTIVE=$(systemctl is-active botxray 2>/dev/null || echo "inactive")
        _CACHED_USERS=$([ -f "$USER_DB" ] && wc -l < "$USER_DB" 2>/dev/null || echo "0")
        _CACHED_NET=""
        _CACHED_PORT=""
        if [ "$_CACHED_XRAY_ACTIVE" = "active" ]; then
            # Valida JSON antes de fazer queries
            if [ -f "$PRESET_FILE" ] && jq empty "$PRESET_FILE" 2>/dev/null; then
                _CACHED_NET=$(jq -r '.network // empty' "$PRESET_FILE" 2>/dev/null || echo "")
                _CACHED_PORT=$(jq -r '.port // empty' "$PRESET_FILE" 2>/dev/null || echo "")
            fi
            if [ -z "$_CACHED_NET" ] && [ -f "$CONFIG_PATH" ] && jq empty "$CONFIG_PATH" 2>/dev/null; then
                _CACHED_NET=$(jq -r '.inbounds[] | select(.tag=="inbound-dragoncore").streamSettings.network // empty' "$CONFIG_PATH" 2>/dev/null || echo "")
            fi
            if [ -z "$_CACHED_PORT" ] && [ -f "$CONFIG_PATH" ] && jq empty "$CONFIG_PATH" 2>/dev/null; then
                _CACHED_PORT=$(jq -r '.inbounds[] | select(.tag=="inbound-dragoncore").port // empty' "$CONFIG_PATH" 2>/dev/null || echo "")
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

# --- INSTALAÇÃO DE DEPENDÊNCIAS (com suporte multi-distro) ---
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
    : > "$LOG_FILE"
}

# --- VERIFICAÇÃO DE INTEGRIDADE DO MÓDULO ---
# Baixa o SHA256 do módulo e valida. Retorna 0 se OK ou se hash não existir (opcional).
_verify_module_hash() {
    local file="$1"
    local module_name="$2"
    local sha256_url="${MODULES_URL}/${module_name}.sha256"
    local expected

    expected=$(curl -fLsS --max-time 10 --connect-timeout 5 "$sha256_url" 2>/dev/null | awk '{print $1}')

    # Se não existir arquivo de hash, emite aviso mas não bloqueia
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
# Retorna 1 em caso de falha (não mais 0 silencioso)
run_module() {
    local script_name="$1"
    local description="$2"
    local local_path="${LOCAL_BIN}/${script_name}"

    if [ "${FORCE_UPDATE:-0}" = "1" ] || [ ! -s "$local_path" ]; then
        echo -e "${TXT_YELLOW}Baixando módulo: ${description}...${RESET}"
        local tmp_path
        tmp_path=$(mktemp /tmp/xray_module_XXXXXX)

        # Download com timeout — evita travar o menu
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
            return 1  # CORRIGIDO: era return 0, sinalizava sucesso mesmo em falha
        fi

        # Valida que o arquivo não está vazio e parece um shell script
        if [ ! -s "$tmp_path" ]; then
            echo -e "${TXT_RED}❌ Arquivo ${script_name} baixado está vazio.${RESET}"
            rm -f "$tmp_path"
            sleep 2
            return 1
        fi

        local head_bytes
        head_bytes=$(head -c 12 "$tmp_path")
        if [[ "$head_bytes" != "#!/bin/bash"* ]] && [[ "$head_bytes" != "#!/usr/bin/e"* ]]; then
            echo -e "${TXT_RED}❌ Arquivo ${script_name} não parece um shell script válido.${RESET}"
            rm -f "$tmp_path"
            sleep 2
            return 1
        fi

        # Verifica integridade via SHA256 (se disponível no repo)
        if ! _verify_module_hash "$tmp_path" "$script_name"; then
            echo -e "${TXT_RED}❌ Módulo ${script_name} rejeitado por falha de integridade.${RESET}"
            rm -f "$tmp_path"
            sleep 2
            return 1
        fi

        # Move para destino final apenas após todas as validações
        mv -f "$tmp_path" "$local_path"
        chmod 0755 "$local_path"
    fi

    bash "$local_path"
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
        99)
            # CORRIGIDO: não recursivo — seta flag, invalida cache e deixa o loop principal repetir
            echo -e "${TXT_YELLOW}Forçando re-download de todos os módulos na próxima execução...${RESET}"
            export FORCE_UPDATE=1
            _STATUS_CACHE_TIME=0  # invalida cache de status
            sleep 1
            # Força download de todos os módulos conhecidos agora
            local modules=(
                add_user.sh remover_user.sh lista_users.sh core_manager.sh
                remover_expirados.sh uninstall.sh limiterxray.sh botxray.sh
                backup.sh block_user.sh unblock_user.sh onlinexray.sh
            )
            for mod in "${modules[@]}"; do
                local mod_path="${LOCAL_BIN}/${mod}"
                echo -ne "${TXT_YELLOW}Atualizando ${mod}...${RESET} "
                local tmp
                tmp=$(mktemp /tmp/xray_module_XXXXXX)
                if curl -fLsS --max-time 30 --connect-timeout 5 \
                        -o "$tmp" "${MODULES_URL}/${mod}" 2>>"$LOG_FILE"; then
                    if _verify_module_hash "$tmp" "$mod" 2>/dev/null; then
                        mv -f "$tmp" "$mod_path"
                        chmod 0755 "$mod_path"
                        echo -e "${TXT_GREEN}OK${RESET}"
                    else
                        rm -f "$tmp"
                        echo -e "${TXT_RED}FALHOU (hash)${RESET}"
                    fi
                else
                    rm -f "$tmp"
                    echo -e "${TXT_RED}FALHOU (download)${RESET}"
                fi
            done
            # Reseta FORCE_UPDATE após completar o ciclo — não afeta sessões futuras
            export FORCE_UPDATE=0
            echo ""
            echo -e "${TXT_GREEN}Atualização concluída.${RESET}"
            sleep 2
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

# Loop principal — menu_display NUNCA se chama recursivamente
while true; do
    menu_display
done
