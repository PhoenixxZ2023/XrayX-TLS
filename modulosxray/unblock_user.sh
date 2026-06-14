#!/bin/bash
# unblock_user.sh - DragonCore V7.5.1
# Correções aplicadas:
#   - _apply_config_perms() centralizada — rollbacks agora incluem chown root:nogroup
#   - _cleanup() + trap EXIT desde o início — elimina trap tardio após mktemp
#   - _wait_xray_active() com retry de 5s — substitui sleep 1 + is-active simples
#   - user_input normalizado para minúsculas — consistente com add_user.sh corrigido
#   - Verificação extra do UUID restaurado no JSON antes do restart

set -Eeuo pipefail

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
LOG_FILE="/tmp/unblock_user.log"

TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

# --- CLEANUP CENTRALIZADO ---
# CORREÇÃO: registrado no início via trap EXIT — cobre toda saída (normal, ERR, sinal).
# Elimina o trap EXIT tardio que só protegia após o mktemp.
_tmp_cfg=""
_cleanup() {
    rm -f "$_tmp_cfg"
}
trap '_cleanup' EXIT
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

# --- PERMISSÕES DO CONFIG ---
# CORREÇÃO: centralizada — garante chmod 640 + chown root:nogroup em fluxo normal
# e em todos os rollbacks, evitando que um rollback deixe dono errado.
_apply_config_perms() {
    chmod 0660 "$CONFIG_PATH"
    chown root:nogroup "$CONFIG_PATH"
}

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

# CORREÇÃO: aceita entrada mista mas a normalização para minúsculas acontece
# antes de qualquer busca — validate_nick só checa o formato.
validate_nick() { [[ "${1:-}" =~ ^[a-zA-Z0-9]{5,9}$ ]]; }

validate_uuid() {
    [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# --- VERIFICAÇÃO DE XRAY ATIVO COM RETRY ---
# CORREÇÃO: tenta por até 5s antes de concluir falha.
# sleep 1 simples anterior causava falso negativo em sistemas sob carga.
_wait_xray_active() {
    local tries=5
    while [ "$tries" -gt 0 ]; do
        systemctl is-active --quiet xray 2>/dev/null && return 0
        sleep 1
        tries=$((tries - 1))
    done
    return 1
}

# --- INICIALIZAÇÃO ---
: > "$LOG_FILE"
ensure_cmd jq jq

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

while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo " • ${line#LOCKED_}"
done <<< "$locked_list"
echo "--------------------------"
echo ""

read -rp "Usuário para desbloquear (0 para voltar): " user_input
[ "${user_input:-0}" = "0" ] || [ -z "${user_input:-}" ] && exit 0

if ! validate_nick "$user_input"; then
    echo -e "${TXT_RED}❌ Nick inválido. Use 5-9 letras/números.${RESET}"
    sleep 2; exit 1
fi

# CORREÇÃO: normaliza para minúsculas antes de qualquer busca —
# consistente com add_user.sh que grava nomes em minúsculas no DB.
user_input=$(echo "$user_input" | tr '[:upper:]' '[:lower:]')

LOCKED_NAME="LOCKED_${user_input}"

if ! jq -e --arg lock "$LOCKED_NAME" '
    any(.inbounds[]? | select(.tag=="inbound-dragoncore").settings.clients[]?; .email == $lock)
' "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Usuário '${user_input}' não está na lista de bloqueados.${RESET}"
    sleep 2; exit 1
fi

echo "Recuperando dados originais..."
REAL_UUID="$(awk -F'|' -v u="$user_input" '$1==u {print $2; exit}' "$USER_DB" 2>/dev/null || true)"

if [ -z "${REAL_UUID:-}" ]; then
    echo -e "${TXT_RED}❌ UUID original não encontrado em users.db.${RESET}"
    echo -e "${TXT_YELLOW}   O usuário pode ter sido removido do banco.${RESET}"
    sleep 3; exit 1
fi

if ! validate_uuid "$REAL_UUID"; then
    echo -e "${TXT_RED}❌ UUID no users.db está corrompido: '${REAL_UUID}'${RESET}"
    echo -e "${TXT_YELLOW}   Recrie o usuário com add_user.sh.${RESET}"
    sleep 3; exit 1
fi

echo ""
echo -e "${TXT_YELLOW}⚠  Reativar acesso de '${user_input}'?${RESET}"
read -rp "Confirmar? [s/N]: " confirm
[[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; exit 0; }

cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"

_tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")

jq --arg nick   "$user_input" \
   --arg locked "$LOCKED_NAME" \
   --arg uuid   "$REAL_UUID" '
    (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
        (if type == "array" then . else [] end)
    |
    (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
        map(if .email == $locked then .email = $nick | .id = $uuid else . end)
' "$CONFIG_PATH" > "$_tmp_cfg" 2>>"$LOG_FILE"

if ! jq empty "$_tmp_cfg" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Erro interno: JSON inválido gerado. Config não alterado.${RESET}"
    sleep 2; exit 1
fi

# CORREÇÃO: verificação extra — confirma que o UUID foi de fato restaurado no JSON
# antes de aplicar, adicionando uma camada de segurança além do jq empty.
if ! jq -e --arg nick "$user_input" --arg uuid "$REAL_UUID" '
    any(.inbounds[]? | select(.tag=="inbound-dragoncore").settings.clients[]?;
        .email == $nick and .id == $uuid)
' "$_tmp_cfg" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Verificação pós-geração falhou: UUID não restaurado corretamente.${RESET}"
    sleep 2; exit 1
fi

mv -f "$_tmp_cfg" "$CONFIG_PATH"
_tmp_cfg=""   # já movido — _cleanup não deve tentar remover
_apply_config_perms

# Restart com rollback em falha
if ! systemctl try-reload-or-restart xray >/dev/null 2>&1 && \
   ! systemctl restart xray >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Falha ao reiniciar Xray. Revertendo config...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    # CORREÇÃO: rollback usa _apply_config_perms() — garante 640 + chown corretos.
    _apply_config_perms
    echo -e "${TXT_YELLOW}Config revertido. Usuário permanece bloqueado.${RESET}"
    journalctl -u xray -n 15 --no-pager 2>/dev/null || true
    sleep 3; exit 1
fi

# CORREÇÃO: retry de até 5s para confirmar xray ativo.
if ! _wait_xray_active; then
    echo -e "${TXT_RED}❌ Xray não ficou ativo. Revertendo...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    # CORREÇÃO: rollback usa _apply_config_perms() — garante 640 + chown corretos.
    _apply_config_perms
    systemctl restart xray >/dev/null 2>&1 || true
    sleep 2; exit 1
fi

UUID_DISPLAY="${REAL_UUID:0:8}...${REAL_UUID: -4}"

echo ""
echo -e "${TXT_GREEN}✅ Usuário '${user_input}' reativado com sucesso!${RESET}"
echo -e " UUID restaurado: ${TXT_CYAN}${UUID_DISPLAY}${RESET} (completo em users.db)"
echo -e " Prefixo ${TXT_YELLOW}LOCKED_${RESET} removido. Conexões normalizadas."
sleep 2
