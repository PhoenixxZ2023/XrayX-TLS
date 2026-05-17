#!/bin/bash
# certxray.sh - DragonCore (FIXED) V7.9
# - Fallback automático: Let's Encrypt -> Autoassinado (não aborta)
# - Garantia de criação do /opt/DragonCoreSSL ANTES do cp (bug corrigido)
# - Permissões seguras (sem 777) compatível com xray.service User=nobody
# - Renovação automática apenas para Let's Encrypt
# - Detecção DNS/CDN (Azion/Cloudflare) para avisar sobre HTTP-01

set -Eeuo pipefail

# --- INPUT (Evita erro se digitar 'bash certxray.sh dominio') ---
RAW_INPUT="$*"
DOMAIN="$(echo "$RAW_INPUT" | awk '{print $NF}')"

SSL_DIR="/opt/DragonCoreSSL"
LE_DIR=""
RENEW_SCRIPT="$SSL_DIR/renew_cert.sh"
ACTIVE_DOMAIN_FILE="/opt/XrayTools/active_domain"

# Xray (seu systemd: User=nobody)
XRAY_USER="nobody"
XRAY_GROUP="nogroup"

# --- CORES ---
YB='\033[1;33m'        # Amarelo Negrito
RB='\033[1;31m'        # Vermelho Negrito
GB='\033[1;32m'        # Verde Negrito
CB='\033[1;36m'        # Ciano
BG_RED='\033[41;1;37m' # Fundo Vermelho
RESET='\033[0m'

need_cmd() {
  local cmd="$1" pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "$pkg" >/dev/null 2>&1
  fi
}

get_public_ip() {
  curl -4fsSL ifconfig.me 2>/dev/null || curl -4fsSL icanhazip.com 2>/dev/null || echo ""
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
  if [ ! -d "$SSL_DIR" ]; then
    echo -e "${RB}ERRO: não foi possível criar ${SSL_DIR}${RESET}"
    return 1
  fi
  return 0
}

apply_perms() {
  # Permissões seguras (sem 777)
  ensure_ssl_dir || return 1
  chown -R "$XRAY_USER:$XRAY_GROUP" "$SSL_DIR" 2>/dev/null || true
  chmod 750 "$SSL_DIR" 2>/dev/null || true
  chmod 640 "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem" 2>/dev/null || true
  return 0
}

make_selfsigned() {
  echo -e "${YB}>>> Gerando certificado AUTO-ASSINADO...${RESET}"
  need_cmd openssl openssl
  ensure_ssl_dir || exit 1

  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
    -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1

  apply_perms
  echo -e "${GB}✅ Certificado autoassinado criado em:${RESET} ${CB}$SSL_DIR${RESET}"
}

install_letsencrypt() {
  echo -e "${YB}>>> Preparando ambiente para Let's Encrypt...${RESET}"
  need_cmd certbot certbot
  need_cmd fuser psmisc
  need_cmd systemctl systemd

  # >>> BUGFIX: garante diretório antes de qualquer cp
  ensure_ssl_dir || return 1

  echo -e "${YB}Parando serviços que usam a porta 80...${RESET}"
  systemctl stop xray >/dev/null 2>&1 || true
  systemctl stop nginx >/dev/null 2>&1 || true
  fuser -k 80/tcp >/dev/null 2>&1 || true
  sleep 2

  echo -e "${YB}>>> GERANDO CERTIFICADO LET'S ENCRYPT (HTTP-01)...${RESET}"

  LE_DIR="/etc/letsencrypt/live/$DOMAIN"
  rm -f "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem" 2>/dev/null || true

  CERT_FAIL=0
  certbot certonly --standalone -d "$DOMAIN" \
    --register-unsafely-without-email --agree-tos --non-interactive || CERT_FAIL=1

  if [ "$CERT_FAIL" -ne 0 ] || [ ! -f "$LE_DIR/fullchain.pem" ] || [ ! -f "$LE_DIR/privkey.pem" ]; then
    return 1
  fi

  # >>> BUGFIX: diretório já garantido por ensure_ssl_dir
  cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
  cp -f "$LE_DIR/privkey.pem" "$SSL_DIR/privkey.pem"
  apply_perms

  # Script de renovação (apenas LE)
  cat > "$RENEW_SCRIPT" <<EOF
#!/bin/bash
set -Eeuo pipefail
systemctl stop xray >/dev/null 2>&1 || true
systemctl stop nginx >/dev/null 2>&1 || true
fuser -k 80/tcp >/dev/null 2>&1 || true
certbot renew --quiet
mkdir -p "$SSL_DIR"
cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
cp -f "$LE_DIR/privkey.pem" "$SSL_DIR/privkey.pem"
chown -R $XRAY_USER:$XRAY_GROUP "$SSL_DIR" 2>/dev/null || true
chmod 750 "$SSL_DIR" 2>/dev/null || true
chmod 640 "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem" 2>/dev/null || true
systemctl restart xray >/dev/null 2>&1 || true
EOF
  chmod +x "$RENEW_SCRIPT"

  # Agenda cron mensal (evita duplicar)
  (crontab -l 2>/dev/null | grep -v "renew_cert.sh" ; echo "0 3 1 * * $RENEW_SCRIPT >/dev/null 2>&1") | crontab -

  echo -e "${GB}✅ Let's Encrypt instalado com sucesso.${RESET}"
  return 0
}

# --- MAIN ---
clear
echo -e "${YB}====================================================${RESET}"
echo -e "${YB}            GERENCIADOR DE CERTIFICADOS SSL          ${RESET}"
echo -e "${YB}====================================================${RESET}"
echo ""

if [ -z "${DOMAIN:-}" ] || [ "$DOMAIN" = "certxray.sh" ]; then
  echo -e "${RB}Erro: Nenhum domínio recebido.${RESET}"
  read -rp "DIGITE DOMÍNIO: " DOMAIN
fi

if [ -z "${DOMAIN:-}" ]; then
  echo -e "${RB}Erro: Domínio vazio.${RESET}"
  exit 1
fi

if [[ "$DOMAIN" =~ [[:space:]] ]]; then
  echo -e "${RB}Erro: Domínio inválido (contém espaços).${RESET}"
  exit 1
fi

mkdir -p /opt/XrayTools 2>/dev/null || true
echo "$DOMAIN" > "$ACTIVE_DOMAIN_FILE" 2>/dev/null || true

echo -e "${YB}DOMÍNIO ALVO:${RESET} ${CB}$DOMAIN${RESET}"
echo ""

echo -e "${YB}ESCOLHA O TIPO DE CERTIFICADO:${RESET}"
echo ""
echo -e "${YB} [1] LET'S ENCRYPT (Oficial)${RESET}"
echo -e "${RB}     ⚠️ Requer porta 80 aberta e DNS apontando para esta VPS${RESET}"
echo ""
echo -e "${YB} [2] AUTO-ASSINADO (Local)${RESET}"
echo -e "${GB}     ✅ Não precisa de porta 80 / Funciona mesmo em CDN (Azion/Cloudflare)${RESET}"
echo ""
echo -e "${YB}====================================================${RESET}"
read -rp "OPÇÃO: " cert_opt

# limpa antigos (sem apagar diretório)
mkdir -p "$SSL_DIR" 2>/dev/null || true
rm -f "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem" 2>/dev/null || true

case "${cert_opt:-}" in
  1)
    clear
    echo -e "${BG_RED}                ⚠️  LEIA COM ATENÇÃO  ⚠️                ${RESET}"
    echo ""
    echo -e "${YB}Você escolheu LET'S ENCRYPT (HTTP-01). Para funcionar:${RESET}"
    echo -e "1) ${RB}DNS do domínio deve apontar para o IP público da VPS${RESET}"
    echo -e "2) ${RB}Porta 80 deve estar aberta para a internet${RESET}"
    echo ""

    need_cmd dig dnsutils
    need_cmd curl curl

    VPS_IP="$(get_public_ip)"
    echo -e "${YB}IP público desta VPS:${RESET} ${CB}${VPS_IP:-"(não detectado)"}${RESET}"
    echo -e "${YB}IPs do DNS do domínio:${RESET}"
    dig +short A "$DOMAIN" 2>/dev/null || true
    echo ""

    if ! dns_points_to_vps "${VPS_IP:-}"; then
      echo -e "${RB}⚠️ ALERTA:${RESET} O DNS do domínio NÃO aponta para esta VPS."
      echo -e "${RB}Isso causa erro 504/unauthorized no Let's Encrypt (comum em Azion/Cloudflare).${RESET}"
      echo ""
      echo -e "${YB}Deseja continuar mesmo assim?${RESET}"
      echo " [1] Tentar Let's Encrypt mesmo assim"
      echo " [2] Gerar Autoassinado agora (recomendado)"
      echo " [0] Sair"
      read -rp "Opção: " f
      case "$f" in
        2) make_selfsigned; exit 0 ;;
        0) exit 0 ;;
        *) ;;
      esac
    fi

    read -rp "Pressione [ENTER] se você confirma os requisitos..." _

    if install_letsencrypt; then
      echo -e "${GB}✅ Certificado pronto em ${CB}$SSL_DIR${RESET}"
      exit 0
    else
      echo ""
      echo -e "${BG_RED}  FALHA NA VALIDAÇÃO LET'S ENCRYPT  ${RESET}"
      echo -e "${RB}Não foi possível gerar o certificado oficial.${RESET}"
      echo -e "${YB}>>> Fallback automático: gerando Autoassinado...${RESET}"
      make_selfsigned
      exit 0
    fi
    ;;
  2|*)
    make_selfsigned
    exit 0
    ;;
esac
