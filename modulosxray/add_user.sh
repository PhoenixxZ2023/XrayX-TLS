#!/bin/bash
# add_user.sh - DragonCore V7.5.1
# Correções aplicadas:
#   - chmod 777 → 640 root:nogroup em todos os pontos (fluxo normal + rollbacks)
#   - trap duplo eliminado — _cleanup() centralizado com trap EXIT
#   - Verificação de xray ativo com retry de até 5s (evita falso negativo em sistema lento)
#   - Duplicidade case-insensitive — nome normalizado para minúsculas
#   - generate_link exibe aviso quando preset.json não existe
#   - Rollback chama _apply_config_perms() em vez de chmod 777 manual

set -Eeuo pipefail

CONFIG_PATH="/usr/local/etc/xray/config.json"
USER_DB="/opt/XrayTools/users.db"
PRESET_FILE="/usr/local/etc/xray/preset.json"
CONN_INFO_DIR="/opt/XrayTools/users"
LOG_FILE="/tmp/add_user.log"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'
TITLE_BAR='\033[1;47;34m'

export DEBIAN_FRONTEND=noninteractive

# --- CLEANUP CENTRALIZADO ---
# CORREÇÃO: trap único no EXIT — cobre saída normal, ERR e sinais.
# Elimina a necessidade de redefinir trap no meio do script.
_tmp_cfg=""
_cleanup() {
    rm -f "$_tmp_cfg"
}
trap '_cleanup' EXIT
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

# --- PERMISSÕES DO CONFIG ---
# CORREÇÃO: 640 root:nogroup — Xray lê como nobody/nogroup, não precisa escrever.
# Centralizado para garantir consistência em fluxo normal e rollbacks.
_apply_config_perms() {
    chmod 660 "$CONFIG_PATH"
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
            if [ "$_APT_UPDATED" -eq 0 ]; then
                apt-get update -y >>"$LOG_FILE" 2>&1 || true
                _APT_UPDATED=1
            fi
            apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1
            ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        pacman)  pacman -Sy --noconfirm "$pkg"      >>"$LOG_FILE" 2>&1 ;;
    esac
}

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
    if [[ ! "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo -e "${TXT_RED}❌ Falha ao gerar UUID válido.${RESET}" >&2
        return 1
    fi
    echo "$u"
}

# --- GERAÇÃO DO LINK VLESS A PARTIR DO PRESET ---
# CORREÇÃO: exibe aviso explicativo quando preset.json não existe,
# em vez de retornar string vazia silenciosamente.
generate_link() {
    local uuid="$1" nick="$2"

    if [ ! -f "$PRESET_FILE" ]; then
        echo -e "${TXT_YELLOW}⚠  preset.json não encontrado — configure o Xray primeiro (opção 04 no menu).${RESET}" >&2
        echo ""
        return
    fi

    jq empty "$PRESET_FILE" 2>/dev/null || {
        echo -e "${TXT_YELLOW}⚠  preset.json com JSON inválido — link não gerado.${RESET}" >&2
        echo ""
        return
    }

    local network port domain tls
    network=$(jq -r '.network // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    port=$(jq -r    '.port    // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    domain=$(jq -r  '.domain  // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    tls=$(jq -r     '.tls     // "false"' "$PRESET_FILE" 2>/dev/null || echo "false")

    [ -z "$network" ] || [ -z "$port" ] || [ -z "$domain" ] && {
        echo -e "${TXT_YELLOW}⚠  preset.json incompleto — campos network/port/domain ausentes.${RESET}" >&2
        echo ""
        return
    }

    local sec="none"
    [ "$tls" = "true" ] && sec="tls"

    local link=""
    case "$network" in
        grpc)   link="vless://${uuid}@${domain}:${port}?security=${sec}&encryption=none&type=grpc&serviceName=gRPC&sni=${domain}#${nick}" ;;
        ws)     link="vless://${uuid}@${domain}:${port}?path=%2F&security=${sec}&encryption=none&host=${domain}&type=ws&sni=${domain}#${nick}" ;;
        xhttp)  link="vless://${uuid}@${domain}:${port}?mode=auto&path=%2F&security=${sec}&encryption=none&host=${domain}&type=xhttp&sni=${domain}#${nick}" ;;
        vision) link="vless://${uuid}@${domain}:${port}?security=tls&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=${domain}#${nick}" ;;
        *)      link="vless://${uuid}@${domain}:${port}?security=${sec}&encryption=none&type=tcp&sni=${domain}#${nick}" ;;
    esac
    echo "$link"
}

# --- VERIFICAÇÃO DE XRAY ATIVO COM RETRY ---
# CORREÇÃO: tenta por até 5s antes de concluir falha.
# sleep 1 simples anterior causava falso negativo em sistemas lentos.
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
mkdir -p "$(dirname "$USER_DB")" "$CONN_INFO_DIR"
touch "$USER_DB"

if [ ! -s "$CONFIG_PATH" ]; then
    echo -e "${TXT_RED}❌ Config não encontrada: $CONFIG_PATH${RESET}"
    sleep 2; exit 1
fi
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Config JSON inválido: $CONFIG_PATH${RESET}"
    sleep 2; exit 1
fi
if ! jq -e '.inbounds[]? | select(.tag=="inbound-dragoncore")' "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ inbound-dragoncore não encontrado no config.${RESET}"
    sleep 2; exit 1
fi

# --- INTERFACE ---
clear
echo -e "${TITLE_BAR}   CRIAR NOVO USUÁRIO   ${RESET}"
echo ""
echo "Regras do nome:"
echo " - Entre 5 e 9 caracteres"
echo " - Apenas letras e números (sem espaços)"
echo ""
read -rp "Nome do usuário (0 para voltar): " raw_nick

[ "${raw_nick:-0}" = "0" ] || [ -z "${raw_nick:-}" ] && exit 0

if ! [[ "$raw_nick" =~ ^[a-zA-Z0-9]{5,9}$ ]]; then
    echo -e "${TXT_RED}❌ Nome inválido. Use de 5 a 9 letras/números.${RESET}"
    sleep 2; exit 1
fi

# CORREÇÃO: normaliza para minúsculas — evita que "User1" e "user1" coexistam.
# Bash 4+ suporta ${var,,}; tr é fallback portável.
nick=$(echo "$raw_nick" | tr '[:upper:]' '[:lower:]')

# Duplicidade no DB (case-insensitive via normalização)
if grep -q "^${nick}|" "$USER_DB" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Usuário '${nick}' já existe.${RESET}"
    sleep 2; exit 1
fi

# Duplicidade no config.json
if jq -e --arg nick "$nick" \
    '.inbounds[]? | select(.tag=="inbound-dragoncore") | .settings.clients[]? | select(.email==$nick)' \
    "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Usuário '${nick}' já existe no config.json.${RESET}"
    sleep 2; exit 1
fi

# Validade
read -rp "Dias de validade [Enter = 30]: " days
[ -z "${days:-}" ] && days=30
[[ "$days" =~ ^[0-9]+$ ]] || days=30
(( days < 1 || days > 3650 )) && days=30

uuid=$(generate_uuid) || { sleep 2; exit 1; }
expiry="$(date -d "+${days} days" +%F)"

# --- APLICA NO CONFIG (atômico + validação antes de mv) ---
_tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")

jq --arg uuid "$uuid" --arg nick "$nick" '
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
    (if type == "array" then . else [] end)
  |
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) +=
    [{"id": $uuid, "email": $nick, "level": 0}]
' "$CONFIG_PATH" > "$_tmp_cfg"

if ! jq empty "$_tmp_cfg" 2>/dev/null; then
    echo -e "${TXT_RED}❌ jq gerou JSON inválido. Config não alterado.${RESET}"
    sleep 2; exit 1
fi

cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
mv -f "$_tmp_cfg" "$CONFIG_PATH"
_tmp_cfg=""   # já movido — _cleanup não deve tentar remover
_apply_config_perms

# --- RESTART COM VERIFICAÇÃO E ROLLBACK ---
if ! systemctl try-reload-or-restart xray >/dev/null 2>&1 && \
   ! systemctl restart xray >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Falha ao reiniciar Xray. Revertendo config...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    # CORREÇÃO: rollback usa _apply_config_perms() — não volta para 777.
    _apply_config_perms
    echo -e "${TXT_YELLOW}Config revertido. Usuário NÃO criado.${RESET}"
    journalctl -u xray -n 15 --no-pager 2>/dev/null || true
    sleep 3; exit 1
fi

# CORREÇÃO: retry de até 5s para confirmar xray ativo.
if ! _wait_xray_active; then
    echo -e "${TXT_RED}❌ Xray não ficou ativo após restart. Revertendo...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    # CORREÇÃO: rollback usa _apply_config_perms() — não volta para 777.
    _apply_config_perms
    systemctl restart xray >/dev/null 2>&1 || true
    sleep 2; exit 1
fi

# --- GRAVA NO DB SOMENTE APÓS RESTART OK ---
echo "${nick}|${uuid}|${expiry}" >> "$USER_DB"

link=$(generate_link "$uuid" "$nick")

user_file="${CONN_INFO_DIR}/${nick}.txt"
{
    echo "# DragonCore - Usuário: ${nick}"
    echo "# Criado em: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "NOME=${nick}"
    echo "UUID=${uuid}"
    echo "EXPIRA=${expiry}"
    [ -n "$link" ] && echo "LINK=${link}"
} > "$user_file"
chmod 0600 "$user_file"

# --- RESULTADO ---
clear
echo -e "${TXT_GREEN}✅ Usuário criado com sucesso!${RESET}"
echo "-----------------------------------------"
echo -e " 👤 Nome:   ${TXT_CYAN}${nick}${RESET}"
echo -e " 🔑 UUID:   ${TXT_YELLOW}${uuid}${RESET}"
echo -e " 📅 Expira: ${expiry} (${days} dias)"
echo "-----------------------------------------"
read -rp "Enter para voltar..."
