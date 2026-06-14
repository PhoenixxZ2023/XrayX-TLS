#!/bin/bash
# add_user.sh - DragonCore V7.5
# Correções: rollback completo em falha, UUID com fallback + validação,
#            jq empty antes de aplicar, permissões no config,
#            link VLESS completo gerado via preset.json, distro-agnostic.

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

CONFIG_PATH="/usr/local/etc/xray/config.json"
USER_DB="/opt/XrayTools/users.db"
PRESET_FILE="/usr/local/etc/xray/preset.json"
CONN_INFO_DIR="/opt/XrayTools/users"
LOG_FILE="/tmp/add_user.log"

# Cores
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'
TITLE_BAR='\033[1;47;34m'

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
        # fallback via od + /dev/urandom
        u=$(od -x /dev/urandom | head -1 | \
            awk '{printf "%s%s-%s-4%s-%s%s-%s%s\n",$2,$3,$4,substr($5,2),substr($6,1,1),substr($6,2),$7,$8}' | \
            tr '[:upper:]' '[:lower:]')
    fi
    # Valida formato UUID
    if [[ ! "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo -e "${TXT_RED}❌ Falha ao gerar UUID válido.${RESET}" >&2
        return 1
    fi
    echo "$u"
}

# --- GERAÇÃO DO LINK VLESS A PARTIR DO PRESET ---
generate_link() {
    local uuid="$1" nick="$2"
    [ ! -f "$PRESET_FILE" ] && echo "" && return

    # Valida JSON do preset antes de ler
    jq empty "$PRESET_FILE" 2>/dev/null || { echo ""; return; }

    local network port domain tls
    network=$(jq -r '.network // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    port=$(jq -r    '.port    // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    domain=$(jq -r  '.domain  // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    tls=$(jq -r     '.tls     // "false"' "$PRESET_FILE" 2>/dev/null || echo "false")

    [ -z "$network" ] || [ -z "$port" ] || [ -z "$domain" ] && echo "" && return

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

# --- INICIALIZAÇÃO ---
: > "$LOG_FILE"
ensure_cmd jq jq
mkdir -p "$(dirname "$USER_DB")" "$CONN_INFO_DIR"
touch "$USER_DB"

# Valida config existente e legível
if [ ! -s "$CONFIG_PATH" ]; then
    echo -e "${TXT_RED}❌ Config não encontrada: $CONFIG_PATH${RESET}"
    sleep 2; exit 1
fi
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Config JSON inválido: $CONFIG_PATH${RESET}"
    sleep 2; exit 1
fi
# Confere inbound obrigatório
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

# Validação de formato
if ! [[ "$raw_nick" =~ ^[a-zA-Z0-9]{5,9}$ ]]; then
    echo -e "${TXT_RED}❌ Nome inválido. Use de 5 a 9 letras/números.${RESET}"
    sleep 2; exit 1
fi

# Duplicidade no DB (ancorado início da linha)
if grep -q "^${raw_nick}|" "$USER_DB" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Usuário '${raw_nick}' já existe.${RESET}"
    sleep 2; exit 1
fi

# Duplicidade no config.json (pelo campo email)
if jq -e --arg nick "$raw_nick" \
    '.inbounds[]? | select(.tag=="inbound-dragoncore") | .settings.clients[]? | select(.email==$nick)' \
    "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Usuário '${raw_nick}' já existe no config.json.${RESET}"
    sleep 2; exit 1
fi

# Validade
read -rp "Dias de validade [Enter = 30]: " days
[ -z "${days:-}" ] && days=30
[[ "$days" =~ ^[0-9]+$ ]] || days=30
(( days < 1 || days > 3650 )) && days=30

# Gera UUID com fallback e valida
uuid=$(generate_uuid) || { sleep 2; exit 1; }

expiry="$(date -d "+${days} days" +%F)"

# --- APLICA NO CONFIG (atômico + validação antes de mv) ---
tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")

# Garante limpeza do tmp em qualquer saída
trap 'rm -f "$tmp_cfg"; echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

jq --arg uuid "$uuid" --arg nick "$raw_nick" '
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |=
    (if type == "array" then . else [] end)
  |
  (.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) +=
    [{"id": $uuid, "email": $nick, "level": 0}]
' "$CONFIG_PATH" > "$tmp_cfg"

# Valida JSON gerado ANTES de aplicar
if ! jq empty "$tmp_cfg" 2>/dev/null; then
    rm -f "$tmp_cfg"
    echo -e "${TXT_RED}❌ jq gerou JSON inválido. Config não alterado.${RESET}"
    sleep 2; exit 1
fi

# Backup do config anterior
cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"

# Aplica atomicamente e corrige permissões
mv -f "$tmp_cfg" "$CONFIG_PATH"
chmod 777 "$CONFIG_PATH"
chown root:nogroup "$CONFIG_PATH"

# --- RESTART COM VERIFICAÇÃO E ROLLBACK ---
if ! systemctl try-reload-or-restart xray >/dev/null 2>&1 && \
   ! systemctl restart xray >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Falha ao reiniciar Xray. Revertendo config...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    chmod 777 "$CONFIG_PATH"
    echo -e "${TXT_YELLOW}Config revertido. Usuário NÃO criado.${RESET}"
    journalctl -u xray -n 15 --no-pager 2>/dev/null || true
    sleep 3; exit 1
fi

# Aguarda Xray estabilizar e confirma que está ativo
sleep 1
if ! systemctl is-active --quiet xray 2>/dev/null; then
    echo -e "${TXT_RED}❌ Xray não ficou ativo após restart. Revertendo...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    chmod 777 "$CONFIG_PATH"
    systemctl restart xray >/dev/null 2>&1 || true
    sleep 2; exit 1
fi

# --- GRAVA NO DB SOMENTE APÓS RESTART OK ---
echo "${raw_nick}|${uuid}|${expiry}" >> "$USER_DB"

# Gera link completo
link=$(generate_link "$uuid" "$raw_nick")

# Salva info do usuário em arquivo seguro
user_file="${CONN_INFO_DIR}/${raw_nick}.txt"
{
    echo "# DragonCore - Usuário: ${raw_nick}"
    echo "# Criado em: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "NOME=${raw_nick}"
    echo "UUID=${uuid}"
    echo "EXPIRA=${expiry}"
    [ -n "$link" ] && echo "LINK=${link}"
} > "$user_file"
chmod 0600 "$user_file"

# --- RESULTADO ---
clear
echo -e "${TXT_GREEN}✅ Usuário criado com sucesso!${RESET}"
echo "-----------------------------------------"
echo -e " Nome:   ${TXT_CYAN}${raw_nick}${RESET}"
echo -e " UUID:   ${TXT_YELLOW}${uuid}${RESET}"
echo -e " Expira: ${expiry} (${days} dias)"
if [ -n "$link" ]; then
    echo ""
    echo -e " ${TXT_YELLOW}Link VLESS:${RESET}"
    echo -e " ${TXT_CYAN}${link}${RESET}"
fi
echo "-----------------------------------------"
echo -e " Salvo em: ${user_file}"
echo "-----------------------------------------"
read -rp "Enter para voltar..."
