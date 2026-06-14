#!/bin/bash
# certxray.sh - DragonCore V8.0
# Correções: validação RFC 1123 do domínio, need_cmd com detecção de distro,
#            IP via HTTPS + timeout, backup de certs antes de apagar,
#            script de renovação com verificação pós-restart,
#            get_public_ip com max-time.

set -Eeuo pipefail

RAW_INPUT="$*"
DOMAIN="$(echo "$RAW_INPUT" | awk '{print $NF}')"

SSL_DIR="/opt/DragonCoreSSL"
LE_DIR=""
RENEW_SCRIPT="$SSL_DIR/renew_cert.sh"
ACTIVE_DOMAIN_FILE="/opt/XrayTools/active_domain"
LOG_FILE="/tmp/certxray.log"

XRAY_USER="nobody"
XRAY_GROUP="nogroup"

YB='\033[1;33m'
RB='\033[1;31m'
GB='\033[1;32m'
CB='\033[1;36m'
BG_RED='\033[41;1;37m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

# --- DETECÇÃO DE DISTRO (consistente com os outros módulos) ---
_PKG_MANAGER=""
_APT_UPDATED=0
_detect_pkg_manager() {
    [ -n "$_PKG_MANAGER" ] && return
    if   command -v apt-get &>/dev/null; then _PKG_MANAGER="apt"
    elif command -v dnf     &>/dev/null; then _PKG_MANAGER="dnf"
    elif command -v yum     &>/dev/null; then _PKG_MANAGER="yum"
    elif command -v pacman  &>/dev/null; then _PKG_MANAGER="pacman"
    else echo -e "${RB}❌ Gerenciador de pacotes não detectado.${RESET}"; exit 1; fi
}

# need_cmd renomeado para ensure_cmd para consistência entre módulos
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

# --- VALIDAÇÃO DE DOMÍNIO (RFC 1123) ---
validate_domain() {
    local d="${1:-}"
    [ -n "$d" ] || return 1
    # Rejeita IPs puros
    [[ "$d" =~ ^[0-9.]+$ ]] && return 1
    # Valida formato: labels separadas por ponto, mínimo 2 labels
    [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

# --- IP PÚBLICO COM HTTPS E TIMEOUT ---
get_public_ip() {
    curl -4fsSL --max-time 10 --connect-timeout 5 \
        "https://icanhazip.com" 2>/dev/null \
    || curl -4fsSL --max-time 10 --connect-timeout 5 \
        "https://api.ipify.org" 2>/dev/null \
    || echo ""
}

dns_points_to_vps() {
    local ip="$1"
    [ -n "$ip" ] || return 1
    local ans
    ans="$(dig +short A "$DOMAIN" 2>/dev/null || true)"
    echo "$ans" | grep -qx "$ip"
}

ensure_ssl_dir() {
    mkdir -p "$SSL_DIR"
    [ -d "$SSL_DIR" ] || { echo -e "${RB}❌ Não foi possível criar ${SSL_DIR}${RESET}"; return 1; }
}

apply_perms() {
    ensure_ssl_dir || return 1
    chown -R "$XRAY_USER:$XRAY_GROUP" "$SSL_DIR" 2>/dev/null || true
    chmod 777 "$SSL_DIR" 2>/dev/null || true
    chmod 777 "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem" 2>/dev/null || true
}

# --- BACKUP DOS CERTS ATUAIS ---
backup_existing_certs() {
    if [ -f "$SSL_DIR/fullchain.pem" ] || [ -f "$SSL_DIR/privkey.pem" ]; then
        cp -f "$SSL_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem.bak" 2>/dev/null || true
        cp -f "$SSL_DIR/privkey.pem"   "$SSL_DIR/privkey.pem.bak"   2>/dev/null || true
    fi
}

restore_cert_backup() {
    if [ -f "$SSL_DIR/fullchain.pem.bak" ] && [ -f "$SSL_DIR/privkey.pem.bak" ]; then
        cp -f "$SSL_DIR/fullchain.pem.bak" "$SSL_DIR/fullchain.pem"
        cp -f "$SSL_DIR/privkey.pem.bak"   "$SSL_DIR/privkey.pem"
        apply_perms
        echo -e "${YB}Certificado anterior restaurado.${RESET}"
    fi
}

make_selfsigned() {
    echo -e "${YB}>>> Gerando certificado AUTO-ASSINADO...${RESET}"
    ensure_cmd openssl openssl
    ensure_ssl_dir || exit 1

    if ! openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
        -keyout "$SSL_DIR/privkey.pem" \
        -out "$SSL_DIR/fullchain.pem" >>"$LOG_FILE" 2>&1; then
        echo -e "${RB}❌ Falha ao gerar certificado autoassinado.${RESET}"
        restore_cert_backup
        exit 1
    fi

    apply_perms
    echo -e "${GB}✅ Certificado autoassinado criado em:${RESET} ${CB}$SSL_DIR${RESET}"
}

install_letsencrypt() {
    echo -e "${YB}>>> Preparando Let's Encrypt...${RESET}"
    ensure_cmd certbot certbot
    ensure_cmd fuser psmisc
    ensure_ssl_dir || return 1

    echo -e "${YB}Parando serviços na porta 80...${RESET}"
    systemctl stop xray  >/dev/null 2>&1 || true
    systemctl stop nginx >/dev/null 2>&1 || true
    fuser -k 80/tcp >/dev/null 2>&1 || true
    sleep 2

    LE_DIR="/etc/letsencrypt/live/$DOMAIN"
    rm -f "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem" 2>/dev/null || true

    local CERT_FAIL=0
    certbot certonly --standalone -d "$DOMAIN" \
        --register-unsafely-without-email --agree-tos --non-interactive \
        >>"$LOG_FILE" 2>&1 || CERT_FAIL=1

    if [ "$CERT_FAIL" -ne 0 ] || [ ! -f "$LE_DIR/fullchain.pem" ] || [ ! -f "$LE_DIR/privkey.pem" ]; then
        return 1
    fi

    cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
    cp -f "$LE_DIR/privkey.pem"   "$SSL_DIR/privkey.pem"
    apply_perms

    # Script de renovação com verificação pós-restart
    cat > "$RENEW_SCRIPT" <<RENEW_EOF
#!/bin/bash
# renew_cert.sh — gerado por certxray.sh
set -Eeuo pipefail
LOG="/tmp/renew_cert.log"
: > "\$LOG"
echo "=== Renovação: \$(date) ===" >> "\$LOG"

systemctl stop xray  >/dev/null 2>&1 || true
systemctl stop nginx >/dev/null 2>&1 || true
fuser -k 80/tcp >/dev/null 2>&1 || true

if ! certbot renew --quiet >>\$LOG 2>&1; then
    echo "FALHA: certbot renew falhou" >> "\$LOG"
    systemctl start xray >/dev/null 2>&1 || true
    exit 1
fi

mkdir -p "${SSL_DIR}"
cp -f "${LE_DIR}/fullchain.pem" "${SSL_DIR}/fullchain.pem"
cp -f "${LE_DIR}/privkey.pem"   "${SSL_DIR}/privkey.pem"
chown -R ${XRAY_USER}:${XRAY_GROUP} "${SSL_DIR}" 2>/dev/null || true
chmod 777 "${SSL_DIR}" 2>/dev/null || true
chmod 777 "${SSL_DIR}/fullchain.pem" "${SSL_DIR}/privkey.pem" 2>/dev/null || true

systemctl restart xray >/dev/null 2>&1 || true
sleep 3

# Verifica se Xray subiu após renovação
if ! systemctl is-active --quiet xray 2>/dev/null; then
    echo "AVISO: Xray não ficou ativo após renovação!" >> "\$LOG"
    journalctl -u xray -n 20 --no-pager >> "\$LOG" 2>/dev/null || true
    exit 1
fi

echo "Renovação concluída com sucesso." >> "\$LOG"
RENEW_EOF

    chmod 777 "$RENEW_SCRIPT"
    chown root:root "$RENEW_SCRIPT"

    # Agenda cron mensal sem duplicatas
    (crontab -l 2>/dev/null | grep -v "renew_cert.sh"; \
     echo "0 3 1 * * $RENEW_SCRIPT >>/tmp/renew_cert.log 2>&1") | crontab -

    echo -e "${GB}✅ Let's Encrypt instalado. Renovação agendada mensalmente.${RESET}"
    return 0
}

# --- MAIN ---
: > "$LOG_FILE"
clear
echo -e "${YB}====================================================${RESET}"
echo -e "${YB}         GERENCIADOR DE CERTIFICADOS SSL            ${RESET}"
echo -e "${YB}====================================================${RESET}"
echo ""

# Solicita domínio se não fornecido como argumento
if [ -z "${DOMAIN:-}" ] || [ "$DOMAIN" = "certxray.sh" ]; then
    read -rp "Digite o domínio: " DOMAIN
fi

[ -n "${DOMAIN:-}" ] || { echo -e "${RB}❌ Domínio vazio.${RESET}"; exit 1; }

# Validação RFC 1123
if ! validate_domain "$DOMAIN"; then
    echo -e "${RB}❌ Domínio inválido: '${DOMAIN}'${RESET}"
    echo -e "${YB}   Use o formato: exemplo.com ou sub.exemplo.com${RESET}"
    exit 1
fi

mkdir -p /opt/XrayTools 2>/dev/null || true
echo "$DOMAIN" > "$ACTIVE_DOMAIN_FILE" 2>/dev/null || true

echo -e "${YB}DOMÍNIO ALVO:${RESET} ${CB}$DOMAIN${RESET}"
echo ""
echo -e "${YB}TIPO DE CERTIFICADO:${RESET}"
echo ""
echo -e "${YB} [1] LET'S ENCRYPT (Oficial)${RESET}"
echo -e "${RB}     ⚠ Requer porta 80 aberta e DNS apontando para esta VPS${RESET}"
echo ""
echo -e "${YB} [2] AUTO-ASSINADO (Local)${RESET}"
echo -e "${GB}     ✅ Sem porta 80 / Funciona com CDN (Azion/Cloudflare)${RESET}"
echo ""
echo -e "${YB}====================================================${RESET}"
read -rp "OPÇÃO [1/2]: " cert_opt

# Backup dos certs atuais ANTES de qualquer remoção
ensure_ssl_dir
backup_existing_certs

case "${cert_opt:-2}" in
  1)
    clear
    echo -e "${BG_RED}             ⚠  LEIA COM ATENÇÃO  ⚠             ${RESET}"
    echo ""
    echo -e "${YB}LET'S ENCRYPT (HTTP-01) requer:${RESET}"
    echo -e " 1) ${RB}DNS do domínio apontando para o IP desta VPS${RESET}"
    echo -e " 2) ${RB}Porta 80 aberta na internet${RESET}"
    echo ""

    ensure_cmd dig  dnsutils
    ensure_cmd curl curl

    VPS_IP="$(get_public_ip)"
    echo -e "${YB}IP público desta VPS:${RESET} ${CB}${VPS_IP:-"(não detectado)"}${RESET}"
    echo -e "${YB}IPs no DNS do domínio:${RESET}"
    dig +short A "$DOMAIN" 2>/dev/null || echo "  (falha na consulta DNS)"
    echo ""

    if ! dns_points_to_vps "${VPS_IP:-}"; then
        echo -e "${RB}⚠  DNS NÃO aponta para esta VPS — Let's Encrypt provavelmente falhará.${RESET}"
        echo ""
        echo " [1] Tentar Let's Encrypt mesmo assim"
        echo " [2] Gerar autoassinado (recomendado)"
        echo " [0] Cancelar"
        read -rp "Opção: " fallback_opt
        case "$fallback_opt" in
            2) make_selfsigned; exit 0 ;;
            0) restore_cert_backup; exit 0 ;;
            *) ;;
        esac
    fi

    read -rp "Pressione Enter para confirmar e continuar..." _

    # Remove certs antigos só agora — após backup já feito
    rm -f "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem" 2>/dev/null || true

    if install_letsencrypt; then
        echo -e "${GB}✅ Certificado Let's Encrypt pronto em ${CB}$SSL_DIR${RESET}"
        rm -f "$SSL_DIR/fullchain.pem.bak" "$SSL_DIR/privkey.pem.bak" 2>/dev/null || true
        exit 0
    else
        echo ""
        echo -e "${BG_RED}  FALHA NA VALIDAÇÃO LET'S ENCRYPT  ${RESET}"
        echo -e "${YB}>>> Fallback automático: gerando autoassinado...${RESET}"
        make_selfsigned
        exit 0
    fi
    ;;

  2|*)
    rm -f "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem" 2>/dev/null || true
    make_selfsigned
    rm -f "$SSL_DIR/fullchain.pem.bak" "$SSL_DIR/privkey.pem.bak" 2>/dev/null || true
    exit 0
    ;;
esac
