#!/bin/bash
# unblock_user.sh - Desbloqueio Seguro V7.5
# Correções: backup + jq empty antes do mv, validação do UUID restaurado,
#            verificação de restart + rollback, permissões no config,
#            UUID truncado na exibição, detecção de distro.

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
LOG_FILE="/tmp/unblock_user.log"

TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
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

validate_nick() { [[ "${1:-}" =~ ^[a-zA-Z0-9]{5,9}$ ]]; }

# Valida formato UUID padrão
validate_uuid() {
    [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# --- INICIALIZAÇÃO ---
: > "$LOG_FILE"
ensure_cmd jq jq

# Valida pré-condições
if [ ! -s "$CONFIG_PATH" ]; then
    echo -e "${TXT_RED}❌ config.json não encontrado.${RESET}"
    sleep 2; exit 1
fi
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    echo -e "${TXT_RED}❌ config.json inválido (JSON corrompido).${RESET}"
    sleep 2; exit 1
fi
if [ ! -s "$USER_DB" ]; then
    echo -e "${TXT_RED}❌ users.db não encontrado ou vazio.${RESET}"
    sleep 2; exit 1
fi

clear
echo -e "${TXT_GREEN}🔓 DESBLOQUEAR USUÁRIO (REATIVAR)${RESET}"
echo ""

# Lista usuários BLOQUEADOS via jq (sem grep)
echo -e "${TXT_CYAN}--- Usuários Suspensos ---${RESET}"
locked_list="$(
    jq -r '
        .inbounds[]? | select(.tag=="inbound-dragoncore")
        | .settings.clients[]?
        | select(.email? and (.email | startswith("LOCKED_")))
        | .email
    ' "$CONFIG_PATH" 2>/dev/null || true
)"

if [ -z "${locked_list:-}" ]; then
    echo "Nenhum usuário bloqueado no momento."
    echo "--------------------------"
    echo ""
    read -rp "Pressione Enter para voltar..."
    exit 0
fi

# Exibe sem o prefixo LOCKED_
while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo " • ${line#LOCKED_}"
done <<< "$locked_list"
echo "--------------------------"
echo ""

read -rp "Usuário para desbloquear (0 para voltar): " user_input
[ "${user_input:-0}" = "0" ] || [ -z "${user_input:-}" ] && exit 0

# Valida formato do nick
if ! validate_nick "$user_input"; then
    echo -e "${TXT_RED}❌ Nick inválido. Use 5-9 letras/números.${RESET}"
    sleep 2; exit 1
fi

LOCKED_NAME="LOCKED_${user_input}"

# Confirma que está bloqueado no config
if ! jq -e --arg lock "$LOCKED_NAME" '
    any(.inbounds[]? | select(.tag=="inbound-dragoncore").settings.clients[]?; .email == $lock)
' "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Usuário '${user_input}' não está na lista de bloqueados.${RESET}"
    sleep 2; exit 1
fi

# Recupera UUID real do DB
echo "Recuperando dados originais..."
REAL_UUID="$(awk -F'|' -v u="$user_input" '$1==u {print $2; exit}' "$USER_DB" 2>/dev/null || true)"

if [ -z "${REAL_UUID:-}" ]; then
    echo -e "${TXT_RED}❌ UUID original não encontrado em users.db.${RESET}"
    echo -e "${TXT_YELLOW}   O usuário pode ter sido removido do banco.${RESET}"
    sleep 3; exit 1
fi

# Valida formato do UUID recuperado antes de usar
if ! validate_uuid "$REAL_UUID"; then
    echo -e "${TXT_RED}❌ UUID no users.db está corrompido: '${REAL_UUID}'${RESET}"
    echo -e "${TXT_YELLOW}   Recrie o usuário com add_user.sh.${RESET}"
    sleep 3; exit 1
fi

# Confirmação antes de desbloquear
echo ""
echo -e "${TXT_YELLOW}⚠  Reativar acesso de '${user_input}'?${RESET}"
read -rp "Confirmar? [s/N]: " confirm
[[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; exit 0; }

# Backup do config antes de modificar
cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"

# Grava em tmp, valida JSON, aplica atomicamente
tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
trap 'rm -f "$tmp_cfg"' EXIT

jq --arg nick    "$user_input" \
   --arg locked  "$LOCKED_NAME" \
   --arg uuid    "$REAL_UUID" '
    (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
        (if type == "array" then . else [] end)
    |
    (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
        map(if .email == $locked then .email = $nick | .id = $uuid else . end)
' "$CONFIG_PATH" > "$tmp_cfg" 2>>"$LOG_FILE"

# Valida JSON resultante antes de aplicar
if ! jq empty "$tmp_cfg" 2>/dev/null; then
    rm -f "$tmp_cfg"
    echo -e "${TXT_RED}❌ Erro interno: JSON inválido gerado. Config não alterado.${RESET}"
    sleep 2; exit 1
fi

# Aplica e corrige permissões
mv -f "$tmp_cfg" "$CONFIG_PATH"
chmod 0640 "$CONFIG_PATH"
chown root:nogroup "$CONFIG_PATH"

# Restart com verificação e rollback em falha
if ! systemctl try-reload-or-restart xray >/dev/null 2>&1 && \
   ! systemctl restart xray >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Falha ao reiniciar Xray. Revertendo config...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    chmod 0640 "$CONFIG_PATH"
    echo -e "${TXT_YELLOW}Config revertido. Usuário permanece bloqueado.${RESET}"
    journalctl -u xray -n 15 --no-pager 2>/dev/null || true
    sleep 3; exit 1
fi

sleep 1
if ! systemctl is-active --quiet xray 2>/dev/null; then
    echo -e "${TXT_RED}❌ Xray não ficou ativo. Revertendo...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    chmod 0640 "$CONFIG_PATH"
    systemctl restart xray >/dev/null 2>&1 || true
    sleep 2; exit 1
fi

# UUID truncado na exibição — não expõe credencial completa no terminal
UUID_DISPLAY="${REAL_UUID:0:8}...${REAL_UUID: -4}"

echo ""
echo -e "${TXT_GREEN}✅ Usuário '${user_input}' reativado com sucesso!${RESET}"
echo -e " UUID restaurado: ${TXT_CYAN}${UUID_DISPLAY}${RESET} (completo em users.db)"
echo -e " Prefixo ${TXT_YELLOW}LOCKED_${RESET} removido. Conexões normalizadas."
sleep 2
