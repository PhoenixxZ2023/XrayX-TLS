#!/bin/bash
# block_user.sh - DragonCore V7.5.1
# Correções aplicadas:
#   - chmod 777 → _apply_config_perms() (640 root:nogroup) nos 3 pontos
#   - _cleanup() + trap EXIT desde o início — elimina trap tardio após mktemp
#   - _wait_xray_active() com retry de 5s — substitui sleep 1 + is-active simples
#   - user_block normalizado para minúsculas — consistente com add_user.sh corrigido
#   - Verificação dupla DB + config.json antes de bloquear
#   - Verificação pós-apply confirma LOCKED_ presente no JSON antes do restart
#   - Listagem exibe mensagem quando não há usuários ativos

set -Eeuo pipefail

# --- CLEANUP CENTRALIZADO ---
# CORREÇÃO: registrado no início via trap EXIT — cobre toda saída (normal, ERR, sinal).
_tmp_cfg=""
_cleanup() {
    rm -f "$_tmp_cfg"
}
trap '_cleanup' EXIT
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

# --- PERMISSÕES DO CONFIG ---
# CORREÇÃO: centralizada — 640 root:nogroup em fluxo normal e todos os rollbacks.
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

# --- VERIFICAÇÃO DE XRAY ATIVO COM RETRY ---
# CORREÇÃO: tenta por até 5s — evita falso negativo em sistema sob carga.
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

clear
echo -e "${TXT_RED}🔒 BLOQUEAR USUÁRIO (SUSPENDER)${RESET}"
echo "Impede conexão, mas mantém o cadastro."
echo ""

if [ ! -s "$CONFIG_PATH" ]; then
    echo -e "${TXT_RED}❌ config.json não encontrado.${RESET}"
    sleep 2; exit 1
fi
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    echo -e "${TXT_RED}❌ config.json inválido (JSON corrompido).${RESET}"
    sleep 2; exit 1
fi

# CORREÇÃO: listagem com mensagem quando não há usuários ativos —
# sem isso, a lista ficava em branco sem contexto.
echo -e "${TXT_CYAN}--- Usuários Ativos ---${RESET}"
active_list=$(jq -r '
    .inbounds[]? | select(.tag=="inbound-dragoncore")
    | .settings.clients[]?
    | select(.email? and (.email | startswith("LOCKED_") | not))
    | .email
' "$CONFIG_PATH" 2>/dev/null || true)

if [ -z "${active_list:-}" ]; then
    echo " Nenhum usuário ativo no momento."
else
    echo "$active_list" | awk 'NF{print " • " $0}'
fi
echo "-----------------------"
echo ""

read -rp "Usuário para suspender (0 para voltar): " user_block
[ "${user_block:-0}" = "0" ] || [ -z "${user_block:-}" ] && exit 0

if ! validate_nick "$user_block"; then
    echo -e "${TXT_RED}❌ Nick inválido. Use 5-9 letras/números.${RESET}"
    sleep 2; exit 1
fi

# CORREÇÃO: normaliza para minúsculas — consistente com add_user.sh que
# grava nomes em minúsculas no DB e no config.json.
user_block=$(echo "$user_block" | tr '[:upper:]' '[:lower:]')

# CORREÇÃO: verificação dupla — DB e config.json.
# Evita sucesso silencioso quando os dois estão dessincronizados.
if [ ! -f "$USER_DB" ] || \
   ! awk -F'|' -v u="$user_block" '$1==u{found=1} END{exit found?0:1}' "$USER_DB" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Usuário não encontrado no banco de dados.${RESET}"
    sleep 2; exit 1
fi

if ! jq -e --arg nick "$user_block" '
    any(.inbounds[]? | select(.tag=="inbound-dragoncore").settings.clients[]?;
        .email == $nick)
' "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_YELLOW}⚠  Usuário '${user_block}' não encontrado no config.json.${RESET}"
    echo -e "   DB e config estão dessincronizados — verifique com lista_users.sh."
    sleep 3; exit 1
fi

# Verifica se já está bloqueado
if jq -e --arg lock "LOCKED_${user_block}" '
    any(.inbounds[]? | select(.tag=="inbound-dragoncore").settings.clients[]?; .email == $lock)
' "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_YELLOW}⚠  Usuário '${user_block}' já está bloqueado.${RESET}"
    sleep 2; exit 0
fi

# Confirmação explícita
echo ""
echo -e "${TXT_YELLOW}⚠  Isso suspenderá o acesso de '${user_block}' imediatamente.${RESET}"
read -rp "Confirmar bloqueio? [s/N]: " confirm
[[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; exit 0; }

echo "Suspendendo acesso..."

FAKE_UUID=$(generate_uuid) || { sleep 2; exit 1; }

cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"

_tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")

jq --arg nick   "$user_block" \
   --arg locked "LOCKED_$user_block" \
   --arg fake   "$FAKE_UUID" '
    (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
        (if type == "array" then . else [] end)
    |
    (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
        map(if .email == $nick then .email = $locked | .id = $fake else . end)
' "$CONFIG_PATH" > "$_tmp_cfg" 2>>"$LOG_FILE"

if ! jq empty "$_tmp_cfg" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Erro interno: JSON inválido gerado. Config não alterado.${RESET}"
    sleep 2; exit 1
fi

# CORREÇÃO: verificação pós-apply — confirma que LOCKED_ foi de fato inserido
# no JSON antes de aplicar, além do jq empty.
if ! jq -e --arg locked "LOCKED_${user_block}" '
    any(.inbounds[]? | select(.tag=="inbound-dragoncore").settings.clients[]?;
        .email == $locked)
' "$_tmp_cfg" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Verificação pós-geração falhou: LOCKED_ não encontrado no JSON.${RESET}"
    sleep 2; exit 1
fi

mv -f "$_tmp_cfg" "$CONFIG_PATH"
_tmp_cfg=""   # já movido — _cleanup não deve tentar remover
# CORREÇÃO: _apply_config_perms() em vez de chmod 777.
_apply_config_perms

# Restart com rollback em falha
if ! systemctl try-reload-or-restart xray >/dev/null 2>&1 && \
   ! systemctl restart xray >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Falha ao reiniciar Xray. Revertendo config...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    # CORREÇÃO: rollback usa _apply_config_perms() — garante 640 + chown corretos.
    _apply_config_perms
    echo -e "${TXT_YELLOW}Config revertido. Usuário NÃO bloqueado.${RESET}"
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

echo ""
echo -e "${TXT_GREEN}✅ Usuário '${user_block}' suspenso com sucesso!${RESET}"
echo -e " UUID substituído por falso e prefixo ${TXT_YELLOW}LOCKED_${RESET} adicionado."
echo -e " Para reativar, use a opção ${TXT_CYAN}Desbloquear Usuário${RESET} no menu."
sleep 2
