#!/bin/bash
# remover_expirados.sh - DragonCore V7.5.1
# Correções aplicadas:
#   - _cleanup() separado da mensagem de erro — não exibe [ERRO] em saída normal
#   - chmod 777 → _apply_config_perms() (640 root:nogroup) nos 3 pontos
#   - Rollbacks usam _apply_config_perms() — garante chown correto
#   - _wait_xray_active() com retry de 5s — substitui sleep 1 + is-active simples
#   - Passo 3 reutiliza expired_nicks_file — elimina dupla execução de is_expired()
#   - _TMP_FILES limpo após mv -f — cleanup não tenta deletar arquivos já promovidos
#   - chmod 600 explícito no USER_DB após mv

set -Eeuo pipefail

# --- CLEANUP CENTRALIZADO ---
# CORREÇÃO: _cleanup() apenas remove tmpfiles — sem mensagem de erro.
# A mensagem de erro fica exclusivamente no trap ERR, que só dispara em falhas reais.
# trap EXIT com mensagem de erro causava exibição de "[ERRO]" em saída normal (exit 0).
_TMP_FILES=()
_cleanup() {
    for f in "${_TMP_FILES[@]:-}"; do rm -f "$f" 2>/dev/null || true; done
}
trap '_cleanup' EXIT
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
CONN_INFO_DIR="/opt/XrayTools/users"
LOG_FILE="/tmp/remover_expirados.log"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_YELLOW='\033[1;33m'
TXT_CYAN='\033[1;36m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

# --- PERMISSÕES DO CONFIG ---
# CORREÇÃO: centralizada — 640 root:nogroup em fluxo normal e todos os rollbacks.
_apply_config_perms() {
    chmod 0640 "$CONFIG_PATH"
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

# --- COMPARAÇÃO DE DATA ROBUSTA ---
# Retorna 0 se $1 (YYYY-MM-DD) é anterior a hoje (timestamp Unix)
is_expired() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    local exp_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || return 1
    today_ts=$(date +%s)
    [ "$exp_ts" -lt "$today_ts" ]
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
echo -e "${TITLE_BAR}   LIMPEZA DE EXPIRADOS   ${RESET}"
echo ""

if [ ! -f "$USER_DB" ] || [ ! -s "$USER_DB" ]; then
    echo "Banco de dados vazio ou inexistente."
    read -rp "Enter para voltar..."; exit 0
fi
if [ ! -s "$CONFIG_PATH" ]; then
    echo -e "${TXT_RED}❌ config.json não encontrado.${RESET}"
    read -rp "Enter para voltar..."; exit 1
fi
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    echo -e "${TXT_RED}❌ config.json inválido.${RESET}"
    read -rp "Enter para voltar..."; exit 1
fi
if ! jq -e '.inbounds[]? | select(.tag=="inbound-dragoncore")' "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ inbound-dragoncore não encontrado no config.${RESET}"
    read -rp "Enter para voltar..."; exit 1
fi

echo -e "${TXT_YELLOW}Verificando vencimentos...${RESET}"
echo ""
printf "%-20s | %s\n" "USUÁRIO" "VENCIMENTO"
echo "-----------------------------------"

# Coleta expirados em arquivos temporários registrados para cleanup
expired_uuids_file=$(mktemp /tmp/expired_uuids_XXXXXX)
expired_nicks_file=$(mktemp /tmp/expired_nicks_XXXXXX)
_TMP_FILES+=("$expired_uuids_file" "$expired_nicks_file")

count=0
while IFS='|' read -r nick uuid expiry _rest; do
    [ -n "${nick:-}" ] && [ -n "${uuid:-}" ] || continue
    if is_expired "${expiry:-}"; then
        printf "${TXT_RED}%-20s${RESET} | ${TXT_RED}%s${RESET}\n" "$nick" "${expiry:-sem data}"
        echo "$uuid" >> "$expired_uuids_file"
        echo "$nick" >> "$expired_nicks_file"
        count=$(( count + 1 ))
    fi
done < "$USER_DB"

echo "-----------------------------------"
echo ""

if [ "$count" -eq 0 ]; then
    echo -e "${TXT_GREEN}✅ Nenhum usuário vencido.${RESET}"
    read -rp "Enter para voltar..."; exit 0
fi

echo -e "Encontrados ${TXT_RED}${count}${RESET} usuário(s) vencido(s)."
read -rp "Excluir agora? [s/N]: " confirm
[[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; exit 0; }

# --- PASSO 1: MODIFICA CONFIG ---
expired_json=$(jq -R -s -c 'split("\n") | map(select(length > 0))' "$expired_uuids_file")

cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"

tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
_TMP_FILES+=("$tmp_cfg")

jq --argjson dead "$expired_json" '
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
    (if type == "array" then . else [] end)
  |
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
    map(select((.id as $id | ($dead | index($id)) == null)))
' "$CONFIG_PATH" > "$tmp_cfg" 2>>"$LOG_FILE"

if ! jq empty "$tmp_cfg" 2>/dev/null; then
    echo -e "${TXT_RED}❌ JSON inválido gerado. Config não alterado.${RESET}"
    sleep 2; exit 1
fi

mv -f "$tmp_cfg" "$CONFIG_PATH"
# CORREÇÃO: remove da lista de cleanup — arquivo foi promovido para config.json,
# não é mais temporário. Sem isso, _cleanup tentaria deletar o config.json.
_TMP_FILES=("${_TMP_FILES[@]/$tmp_cfg}")
# CORREÇÃO: _apply_config_perms() em vez de chmod 777.
_apply_config_perms

# --- PASSO 2: RESTART COM VERIFICAÇÃO ---
echo -e "Reiniciando Xray..."
if ! systemctl try-reload-or-restart xray >/dev/null 2>&1 && \
   ! systemctl restart xray >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Falha ao reiniciar Xray. Revertendo config...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    # CORREÇÃO: rollback usa _apply_config_perms() — não volta para 777.
    _apply_config_perms
    journalctl -u xray -n 15 --no-pager 2>/dev/null || true
    echo -e "${TXT_YELLOW}Config revertido. Nenhum usuário foi removido.${RESET}"
    sleep 3; exit 1
fi

# CORREÇÃO: retry de até 5s para confirmar xray ativo.
if ! _wait_xray_active; then
    echo -e "${TXT_RED}❌ Xray não ficou ativo. Revertendo config...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    # CORREÇÃO: rollback usa _apply_config_perms() — não volta para 777.
    _apply_config_perms
    systemctl restart xray >/dev/null 2>&1 || true
    sleep 2; exit 1
fi

# --- PASSO 3: ATUALIZA O DB (após restart confirmado) ---
# CORREÇÃO: reutiliza expired_nicks_file já coletado no Passo 1 em vez de
# reler o DB e reexecutar is_expired() — elimina risco de divergência de clock
# entre os dois loops (ex: NTP sync em VM durante a execução).
tmp_db=$(mktemp "${USER_DB}.tmp.XXXXXX")
_TMP_FILES+=("$tmp_db")

# Filtra o DB removendo os nicks expirados já identificados
# grep -vFf: remove linhas que iniciam com qualquer nick do arquivo de expirados
while IFS='|' read -r nick uuid expiry _rest; do
    [ -n "${nick:-}" ] && [ -n "${uuid:-}" ] || continue
    if ! grep -qxF "$nick" "$expired_nicks_file" 2>/dev/null; then
        echo "${nick}|${uuid}|${expiry:-}" >> "$tmp_db"
    else
        echo -e " ${TXT_RED}Removido DB:${RESET} ${nick}"
    fi
done < "$USER_DB"

mv -f "$tmp_db" "$USER_DB"
# CORREÇÃO: remove da lista de cleanup — arquivo promovido para users.db.
_TMP_FILES=("${_TMP_FILES[@]/$tmp_db}")
# CORREÇÃO: permissão explícita no DB — independe da umask do processo.
chmod 600 "$USER_DB"

# --- PASSO 4: LIMPA ARQUIVOS DE INFO ---
if [ -d "$CONN_INFO_DIR" ] && [ -s "$expired_nicks_file" ]; then
    while IFS= read -r nick; do
        [ -n "$nick" ] || continue
        local_info="${CONN_INFO_DIR}/${nick}.txt"
        if [ -f "$local_info" ]; then
            rm -f "$local_info"
            echo -e " ${TXT_CYAN}Arquivo removido:${RESET} ${nick}.txt"
        fi
    done < "$expired_nicks_file"
fi

echo ""
echo -e "${TXT_GREEN}✅ Limpeza concluída: ${count} usuário(s) removido(s).${RESET}"
read -rp "Enter para voltar..."
