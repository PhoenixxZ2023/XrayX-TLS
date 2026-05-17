#!/bin/bash
# block_user.sh - Bloqueio Seguro V7.5
# Correções: backup + jq empty antes do mv, UUID fake com fallback,
#            verificação de restart + rollback, permissões no config,
#            confirmação antes de bloquear, detecção de distro.

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
LOG_FILE="/tmp/block_user.log"

TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_YELLOW='\033[1;33m'
TXT_CYAN='\033[1;36m'
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

# --- UUID COM FALLBACK E VALIDAÇÃO ---
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
        echo -e "${TXT_RED}❌ Falha ao gerar UUID válido.${RESET}" >&2
        return 1
    }
    echo "$u"
}

# --- INICIALIZAÇÃO ---
: > "$LOG_FILE"
ensure_cmd jq jq

clear
echo -e "${TXT_RED}🔒 BLOQUEAR USUÁRIO (SUSPENDER)${RESET}"
echo "Impede conexão, mas mantém o cadastro."
echo ""

# Valida config
if [ ! -s "$CONFIG_PATH" ]; then
    echo -e "${TXT_RED}❌ config.json não encontrado.${RESET}"
    sleep 2; exit 1
fi
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    echo -e "${TXT_RED}❌ config.json inválido (JSON corrompido).${RESET}"
    sleep 2; exit 1
fi

# Lista apenas usuários ATIVOS (sem prefixo LOCKED_)
echo -e "${TXT_CYAN}--- Usuários Ativos ---${RESET}"
jq -r '
    .inbounds[]? | select(.tag=="inbound-dragoncore")
    | .settings.clients[]?
    | select(.email? and (.email | startswith("LOCKED_") | not))
    | .email
' "$CONFIG_PATH" | awk 'NF{print " • " $0}'
echo "-----------------------"
echo ""

read -rp "Usuário para suspender (0 para voltar): " user_block
[ "${user_block:-0}" = "0" ] || [ -z "${user_block:-}" ] && exit 0

# Valida formato
if ! validate_nick "$user_block"; then
    echo -e "${TXT_RED}❌ Nick inválido. Use 5-9 letras/números.${RESET}"
    sleep 2; exit 1
fi

# Confirma existência no DB
if [ ! -f "$USER_DB" ] || \
   ! awk -F'|' -v u="$user_block" '$1==u{found=1} END{exit found?0:1}' "$USER_DB" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Usuário não encontrado no banco de dados.${RESET}"
    sleep 2; exit 1
fi

# Verifica se já está bloqueado
if jq -e --arg lock "LOCKED_${user_block}" '
    any(.inbounds[]? | select(.tag=="inbound-dragoncore").settings.clients[]?; .email == $lock)
' "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_YELLOW}⚠  Usuário '${user_block}' já está bloqueado.${RESET}"
    sleep 2; exit 0
fi

# Confirmação explícita antes de bloquear
echo ""
echo -e "${TXT_YELLOW}⚠  Isso suspenderá o acesso de '${user_block}' imediatamente.${RESET}"
read -rp "Confirmar bloqueio? [s/N]: " confirm
[[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; exit 0; }

echo "Suspendendo acesso..."

# Gera UUID falso com fallback
FAKE_UUID=$(generate_uuid) || { sleep 2; exit 1; }

# Backup do config antes de modificar
cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"

# Grava em tmp, valida JSON, aplica atomicamente
tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
trap 'rm -f "$tmp_cfg"' EXIT

jq --arg nick "$user_block" \
   --arg locked "LOCKED_$user_block" \
   --arg fake "$FAKE_UUID" '
    (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
        (if type == "array" then . else [] end)
    |
    (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
        map(if .email == $nick then .email = $locked | .id = $fake else . end)
' "$CONFIG_PATH" > "$tmp_cfg" 2>>"$LOG_FILE"

# Valida JSON resultante antes de aplicar
if ! jq empty "$tmp_cfg" 2>/dev/null; then
    rm -f "$tmp_cfg"
    echo -e "${TXT_RED}❌ Erro interno: JSON inválido gerado. Config não alterado.${RESET}"
    sleep 2; exit 1
fi

# Aplica e corrige permissões
mv -f "$tmp_cfg" "$CONFIG_PATH"
chmod 777 "$CONFIG_PATH"
chown root:nogroup "$CONFIG_PATH"

# Restart com verificação e rollback em falha
if ! systemctl try-reload-or-restart xray >/dev/null 2>&1 && \
   ! systemctl restart xray >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Falha ao reiniciar Xray. Revertendo config...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    chmod 777 "$CONFIG_PATH"
    echo -e "${TXT_YELLOW}Config revertido. Usuário NÃO bloqueado.${RESET}"
    journalctl -u xray -n 15 --no-pager 2>/dev/null || true
    sleep 3; exit 1
fi

sleep 1
if ! systemctl is-active --quiet xray 2>/dev/null; then
    echo -e "${TXT_RED}❌ Xray não ficou ativo. Revertendo...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    chmod 777 "$CONFIG_PATH"
    systemctl restart xray >/dev/null 2>&1 || true
    sleep 2; exit 1
fi

echo ""
echo -e "${TXT_GREEN}✅ Usuário '${user_block}' suspenso com sucesso!${RESET}"
echo -e " UUID substituído por falso e prefixo ${TXT_YELLOW}LOCKED_${RESET} adicionado."
echo -e " Para reativar, use a opção ${TXT_CYAN}Desbloquear Usuário${RESET} no menu."
sleep 2
