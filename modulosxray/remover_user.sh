#!/bin/bash
# remover_user.sh - DragonCore V7.5
# Correções: backup antes de editar, jq empty antes de mv, DB só atualizado
#            após restart confirmado, rollback completo em falha, validação
#            de identifier, permissões no config, limpeza do arquivo de info,
#            listagem de usuários antes do prompt, detecção de distro.

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

CONFIG_PATH="/usr/local/etc/xray/config.json"
USER_DB="/opt/XrayTools/users.db"
CONN_INFO_DIR="/opt/XrayTools/users"
LOG_FILE="/tmp/remover_user.log"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;47;34m'
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

# --- VALIDAÇÃO DE IDENTIFIER ---
# Aceita nome (5-9 alfanum) OU UUID no formato padrão
validate_identifier() {
    local id="$1"
    [[ "$id" =~ ^[a-zA-Z0-9]{5,9}$ ]] && return 0
    [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] && return 0
    return 1
}

# --- INICIALIZAÇÃO ---
: > "$LOG_FILE"
ensure_cmd jq jq
mkdir -p "$(dirname "$USER_DB")" "$CONN_INFO_DIR"
[ -f "$USER_DB" ] || touch "$USER_DB"

# Valida config
if [ ! -s "$CONFIG_PATH" ]; then
    echo -e "${TXT_RED}❌ Config não encontrada: $CONFIG_PATH${RESET}"
    sleep 2; exit 1
fi
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Config JSON inválido.${RESET}"
    sleep 2; exit 1
fi
if ! jq -e '.inbounds[]? | select(.tag=="inbound-dragoncore")' "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ inbound-dragoncore não encontrado no config.${RESET}"
    sleep 2; exit 1
fi

# --- INTERFACE ---
clear
echo -e "${TITLE_BAR}   REMOVER USUÁRIO   ${RESET}"
echo ""

# Mostra lista de usuários do DB antes do prompt
if [ -s "$USER_DB" ]; then
    echo -e "${TXT_CYAN}Usuários cadastrados:${RESET}"
    echo "-----------------------------------------"
    printf "%-12s %-38s %-12s\n" "NOME" "UUID" "EXPIRA"
    echo "-----------------------------------------"
    while IFS='|' read -r name uuid expiry _rest; do
        printf "%-12s %-38s %-12s\n" "$name" "$uuid" "$expiry"
    done < "$USER_DB"
    echo "-----------------------------------------"
    echo ""
else
    echo -e "${TXT_YELLOW}Nenhum usuário cadastrado no DB.${RESET}"
    echo ""
fi

read -rp "Nome ou UUID para remover (0 para voltar): " identifier

[ "${identifier:-0}" = "0" ] || [ -z "${identifier:-}" ] && exit 0

# Valida formato do identificador
if ! validate_identifier "$identifier"; then
    echo -e "${TXT_RED}❌ Identificador inválido. Use o nome (5-9 chars) ou UUID completo.${RESET}"
    sleep 2; exit 1
fi

# Confirma existência antes de agir
found_in_config=0
if jq -e --arg id "$identifier" '
    .inbounds[]? | select(.tag=="inbound-dragoncore")
    | .settings.clients[]?
    | select(.id == $id or .email == $id)
' "$CONFIG_PATH" >/dev/null 2>&1; then
    found_in_config=1
fi

found_in_db=0
if [ -s "$USER_DB" ] && \
   awk -F'|' -v id="$identifier" '($1==id || $2==id){found=1} END{exit found?0:1}' "$USER_DB" 2>/dev/null; then
    found_in_db=1
fi

if [ "$found_in_config" -eq 0 ] && [ "$found_in_db" -eq 0 ]; then
    echo -e "${TXT_RED}❌ Nenhum usuário encontrado com: '${identifier}'${RESET}"
    sleep 2; exit 0
fi

# Resolve nome real para limpeza do arquivo de info
nick_real=""
if [ "$found_in_db" -eq 1 ] && [ -s "$USER_DB" ]; then
    nick_real=$(awk -F'|' -v id="$identifier" '($1==id || $2==id){print $1; exit}' "$USER_DB" 2>/dev/null || echo "")
fi
if [ -z "$nick_real" ] && [ "$found_in_config" -eq 1 ]; then
    nick_real=$(jq -r --arg id "$identifier" '
        .inbounds[]? | select(.tag=="inbound-dragoncore")
        | .settings.clients[]?
        | select(.id == $id or .email == $id)
        | .email // ""
    ' "$CONFIG_PATH" 2>/dev/null | head -1 || echo "")
fi

# Confirmação explícita
echo ""
echo -e "${TXT_YELLOW}⚠  Remover usuário: '${nick_real:-$identifier}'?${RESET}"
read -rp "Confirmar? [s/N]: " confirm
[[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; exit 0; }

# --- BACKUP DO CONFIG ANTES DE MODIFICAR ---
cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"

# --- APLICA REMOÇÃO NO CONFIG ---
tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
trap 'rm -f "$tmp_cfg"' EXIT

jq --arg id "$identifier" '
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
    (if type == "array" then . else [] end)
  |
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
    map(select(.id != $id and .email != $id))
' "$CONFIG_PATH" > "$tmp_cfg"

# Valida JSON gerado ANTES de aplicar
if ! jq empty "$tmp_cfg" 2>/dev/null; then
    rm -f "$tmp_cfg"
    echo -e "${TXT_RED}❌ jq gerou JSON inválido. Config não alterado.${RESET}"
    sleep 2; exit 1
fi

# Contagem antes/depois para confirmar remoção real
before_count=$(jq '[.inbounds[]? | select(.tag=="inbound-dragoncore").settings.clients[]?] | length' "$CONFIG_PATH" 2>/dev/null || echo 0)
after_count=$(jq  '[.inbounds[]? | select(.tag=="inbound-dragoncore").settings.clients[]?] | length' "$tmp_cfg"    2>/dev/null || echo 0)

# Aplica atomicamente e corrige permissões
mv -f "$tmp_cfg" "$CONFIG_PATH"
chmod 777 "$CONFIG_PATH"
chown root:nogroup "$CONFIG_PATH"

# --- RESTART COM VERIFICAÇÃO E ROLLBACK COMPLETO ---
if ! systemctl try-reload-or-restart xray >/dev/null 2>&1 && \
   ! systemctl restart xray >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Falha ao reiniciar Xray. Revertendo config...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    chmod 777 "$CONFIG_PATH"
    journalctl -u xray -n 15 --no-pager 2>/dev/null || true
    echo -e "${TXT_YELLOW}Config revertido. Usuário NÃO removido.${RESET}"
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

# --- SÓ AGORA ATUALIZA O DB (após restart confirmado) ---
if [ "$found_in_db" -eq 1 ] && [ -s "$USER_DB" ]; then
    tmp_db=$(mktemp "${USER_DB}.tmp.XXXXXX")
    awk -F'|' -v id="$identifier" '($1!=id && $2!=id){print $0}' "$USER_DB" > "$tmp_db"
    mv -f "$tmp_db" "$USER_DB"
fi

# Remove arquivo de info do usuário se existir
if [ -n "$nick_real" ]; then
    user_file="${CONN_INFO_DIR}/${nick_real}.txt"
    [ -f "$user_file" ] && rm -f "$user_file"
fi

# --- RESULTADO ---
removed_config=$(( before_count - after_count ))

clear
if [ "$removed_config" -gt 0 ] || [ "$found_in_db" -eq 1 ]; then
    echo -e "${TXT_GREEN}✅ Usuário '${nick_real:-$identifier}' removido com sucesso.${RESET}"
    echo "-----------------------------------------"
    [ "$removed_config" -gt 0 ] && echo -e " Config:  ${TXT_GREEN}removido do Xray${RESET}"
    [ "$found_in_db"    -eq 1 ] && echo -e " DB:      ${TXT_GREEN}removido do banco${RESET}"
    [ -n "$nick_real" ] && [ -f "${CONN_INFO_DIR}/${nick_real}.txt" ] || \
        echo -e " Arquivo: ${TXT_GREEN}${CONN_INFO_DIR}/${nick_real}.txt apagado${RESET}"
    echo "-----------------------------------------"
else
    echo -e "${TXT_RED}⚠  Nenhum dado removido (usuário não estava no config).${RESET}"
fi

sleep 1
read -rp "Enter para voltar..."
