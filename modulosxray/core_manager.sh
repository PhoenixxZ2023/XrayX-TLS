#!/bin/bash
# core_manager.sh - DragonCore V7.7 (FIX)
# Protocolos detalhados (XHTTP/Vision/TLS 1.2) + Wizard permissivo

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; read -rp "Enter...";' ERR

# --- CONFIGURAÇÕES ---
CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"

XRAYTOOLS_DIR="/opt/XrayTools"
ACTIVE_DOMAIN_FILE="${XRAYTOOLS_DIR}/active_domain"

SSL_DIR="/opt/DragonCoreSSL"
KEY_FILE="$SSL_DIR/privkey.pem"
CRT_FILE="$SSL_DIR/fullchain.pem"

# URL de Dependências
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main}"
CERT_SCRIPT_URL="$REPO_BASE/modulosxray/certxray.sh"

# CORES
TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TXT_BLUE='\033[1;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive
APT_UPDATED=0

# --- FUNÇÕES BÁSICAS ---
header_blue() {
  clear
  echo -e "${TITLE_BAR}   $1   ${RESET}"
  echo ""
}

ensure_cmd() {
  local cmd="$1"
  local pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [ "$APT_UPDATED" -eq 0 ]; then
      apt-get update -y >/dev/null 2>&1 || true
      APT_UPDATED=1
    fi
    apt-get install -y "$pkg" >/dev/null 2>&1
  fi
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"
    exit 1
  fi
}

validate_port() {
  local p="$1"
  if [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( p >= 1 && p <= 65535 )); then return 0; fi
  return 1
}

validate_domain_basic() {
  local d="${1:-}"
  [ -n "$d" ] || return 1
  [[ "$d" =~ ^[^[:space:]]+$ ]] || return 1
  return 0
}

# --- INSTALADOR XRAY ---
func_install_official_core() {
  header_blue "INSTALANDO XRAY CORE"
  ensure_cmd unzip unzip
  ensure_cmd curl curl
  ensure_cmd socat socat

  echo "Baixando instalador oficial..."
  rm -f /tmp/install_xray.sh
  curl -fLsS --retry 3 --retry-delay 1 -o /tmp/install_xray.sh \
    "https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

  if [ ! -s "/tmp/install_xray.sh" ]; then
    echo -e "${TXT_RED}Erro no download.${RESET}"
    sleep 2
    return 1
  fi

  chmod +x /tmp/install_xray.sh
  bash /tmp/install_xray.sh install
  rm -f /tmp/install_xray.sh
  echo "Instalação concluída."
  sleep 1
}

# --- CHAMADA DO CERTIFICADO ---
func_xray_cert() {
  local dom="$1"
  local cert_script="/usr/local/bin/certxray.sh"

  ensure_cmd curl curl

  if [ ! -s "$cert_script" ]; then
    curl -fLsS --retry 3 --retry-delay 1 -o "$cert_script" "$CERT_SCRIPT_URL"
    chmod 0755 "$cert_script"
  fi

  bash "$cert_script" "$dom"
}

# --- GERAÇÃO DA CONFIGURAÇÃO ---
func_generate_config() {
  local port="$1"
  local network="$2"
  local domain="$3"
  local api_port="$4"
  local use_tls="$5"

  ensure_cmd jq jq
  ensure_cmd uuidgen uuid-runtime

  mkdir -p "$(dirname "$CONFIG_PATH")" "$XRAYTOOLS_DIR" "$SSL_DIR"

  # Se TLS, exige cert/key válidos ANTES de escrever config
  if [ "$use_tls" = "true" ]; then
    if [ ! -s "$CRT_FILE" ] || [ ! -s "$KEY_FILE" ]; then
      echo -e "${TXT_RED}TLS ativo, mas certificado não encontrado/ inválido:${RESET}"
      echo " - $CRT_FILE"
      echo " - $KEY_FILE"
      echo ""
      read -rp "Pressione Enter..."
      return 0
    fi
  fi

  local stream_settings=""
  local policy='{"levels":{"0":{"statsUserUplink":true,"statsUserDownlink":true}},"system":{"statsInboundUplink":true,"statsInboundDownlink":true}}'
  local routing_rules='[{"type":"field","inboundTag":["api"],"outboundTag":"api"},{"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"},{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"}]'

  # --- BLOCOS DE PROTOCOLO ---
  if [ "$network" == "xhttp" ]; then
    if [ "$use_tls" = "true" ]; then
      stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '
      {
        network:"xhttp",
        security:"tls",
        tlsSettings:{
          serverName:$dom,
          certificates:[{certificateFile:$crt, keyFile:$key}],
          alpn:["h2","http/1.1"],
          minVersion:"1.2"
        },
        xhttpSettings:{
          path:"/",
          scMaxBufferedPosts:30,
          scMaxEachPostBytes:"1000000",
          scStreamUpServerSecs:"20-80",
          xPaddingBytes:"100-1000"
        }
      }')
    else
      stream_settings=$(jq -n '
      {
        network:"xhttp",
        security:"none",
        xhttpSettings:{
          path:"/",
          scMaxBufferedPosts:30,
          scMaxEachPostBytes:"1000000",
          scStreamUpServerSecs:"20-80",
          xPaddingBytes:"100-1000"
        }
      }')
    fi

  elif [ "$network" == "ws" ]; then
    if [ "$use_tls" = "true" ]; then
      stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '
      {
        network:"ws",
        security:"tls",
        tlsSettings:{
          serverName:$dom,
          certificates:[{certificateFile:$crt, keyFile:$key}],
          minVersion:"1.2"
        },
        wsSettings:{acceptProxyProtocol:false, path:"/"}
      }')
    else
      stream_settings=$(jq -n '{network:"ws",security:"none",wsSettings:{acceptProxyProtocol:false,path:"/"}}')
    fi

  elif [ "$network" == "grpc" ]; then
    if [ "$use_tls" = "true" ]; then
      stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '
      {
        network:"grpc",
        security:"tls",
        tlsSettings:{
          serverName:$dom,
          certificates:[{certificateFile:$crt, keyFile:$key}],
          minVersion:"1.2"
        },
        grpcSettings:{serviceName:"gRPC"}
      }')
    else
      stream_settings=$(jq -n '{network:"grpc",security:"none",grpcSettings:{serviceName:"gRPC"}}')
    fi

  elif [ "$network" == "vision" ]; then
    # Vision exige TLS
    stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '
    {
      network:"tcp",
      security:"tls",
      tlsSettings:{
        serverName:$dom,
        certificates:[{certificateFile:$crt, keyFile:$key}],
        minVersion:"1.2"
      },
      tcpSettings:{header:{type:"none"}}
    }')

  else
    if [ "$use_tls" = "true" ]; then
      stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '
      {
        network:"tcp",
        security:"tls",
        tlsSettings:{
          serverName:$dom,
          certificates:[{certificateFile:$crt, keyFile:$key}],
          minVersion:"1.2"
        }
      }')
    else
      stream_settings=$(jq -n '{network:"tcp",security:"none"}')
    fi
  fi

  # Gera 1 usuário (UUID) e inclui no inbound
  local uuid
  uuid="$(uuidgen)"

  local clients_json
  if [ "$network" = "vision" ]; then
    clients_json=$(jq -n --arg uuid "$uuid" '[{"id":$uuid,"level":0,"flow":"xtls-rprx-vision"}]')
  else
    clients_json=$(jq -n --arg uuid "$uuid" '[{"id":$uuid,"level":0}]')
  fi

  # Monta JSON final
  jq -n \
    --argjson stream "$stream_settings" \
    --arg port "$port" \
    --arg api "$api_port" \
    --argjson pol "$policy" \
    --argjson rules "$routing_rules" \
    --argjson clients "$clients_json" \
    '{
      log:{loglevel:"warning"},
      stats:{},
      api:{services:["HandlerService","LoggerService","StatsService"], tag:"api"},
      policy:$pol,
      inbounds:[
        {
          tag:"api",
          port:($api|tonumber),
          protocol:"dokodemo-door",
          settings:{address:"127.0.0.1"},
          listen:"127.0.0.1"
        },
        {
          tag:"inbound-dragoncore",
          port:($port|tonumber),
          protocol:"vless",
          settings:{clients:$clients, decryption:"none", fallbacks:[]},
          streamSettings:$stream
        }
      ],
      outbounds:[
        {protocol:"freedom", tag:"direct"},
        {protocol:"blackhole", tag:"blocked"}
      ],
      routing:{domainStrategy:"AsIs", rules:$rules}
    }' > "$CONFIG_PATH"

  # Preset sempre válido
  jq -n --arg network "$network" --arg port "$port" --arg domain "$domain" --arg tls "$use_tls" \
    '{network:$network,port:$port,domain:$domain,tls:$tls}' > "$PRESET_FILE"

  echo "$domain" > "$ACTIVE_DOMAIN_FILE"

  systemctl restart xray >/dev/null 2>&1 || true
  sleep 2

  header_blue "INSTALAÇÃO CONCLUÍDA"

  local status_show="${TXT_RED}FALHA${RESET}"
  if systemctl is-active --quiet xray 2>/dev/null; then status_show="${TXT_GREEN}ATIVO${RESET}"; fi

  local tls_msg="${TXT_RED}DESATIVADO${RESET}"
  if [ "$use_tls" = "true" ]; then tls_msg="${TXT_GREEN}ATIVADO (TLS 1.2 Strict)${RESET}"; fi

  echo "STATUS: $status_show"
  echo ""
  echo "========================================="
  echo -e " ${TXT_YELLOW}PROTOCOLO:${RESET}         ${TXT_CYAN}${network^^}${RESET}"
  echo -e " ${TXT_YELLOW}DOMÍNIO/SNI:${RESET}       ${TXT_CYAN}${domain}${RESET}"
  echo -e " ${TXT_YELLOW}PORTA:${RESET}             ${TXT_CYAN}${port}${RESET}"
  echo -e " ${TXT_YELLOW}CRIPTOGRAFIA:${RESET}      ${tls_msg}"
  echo "========================================="
  echo ""

  local sec="none"
  [ "$use_tls" = "true" ] && sec="tls"

  local link=""
  case "$network" in
    "grpc")  link="vless://${uuid}@${domain}:${port}?security=${sec}&encryption=none&type=grpc&serviceName=gRPC&sni=${domain}#VLESS" ;;
    "ws")    link="vless://${uuid}@${domain}:${port}?path=%2F&security=${sec}&encryption=none&host=${domain}&type=ws&sni=${domain}#VLESS" ;;
    "xhttp") link="vless://${uuid}@${domain}:${port}?mode=auto&path=%2F&security=${sec}&encryption=none&host=${domain}&type=xhttp&sni=${domain}#VLESS" ;;
    "vision")link="vless://${uuid}@${domain}:${port}?security=tls&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=${domain}#VLESS" ;;
    *)       link="vless://${uuid}@${domain}:${port}?security=${sec}&encryption=none&type=tcp&sni=${domain}#VLESS" ;;
  esac

  echo -e "${TXT_YELLOW}LINK DE CONEXÃO:${RESET}"
  echo -e "${TXT_BLUE}${link}${RESET}"
  echo ""
  read -rp "Pressione Enter para sair..."
}

# --- WIZARD ---
func_wizard_install() {
  require_root

  header_blue "PASSO 1: INSTALAÇÃO"
  echo -e "${TXT_YELLOW}Deseja instalar/atualizar o Xray Core?${RESET}"
  read -rp "[s] Sim / [n] Não: " inst
  if [[ "$inst" =~ ^[Ss]$ ]]; then func_install_official_core || true; fi

  header_blue "PASSO 2: CRIPTOGRAFIA (TLS)"
  echo -e "${TXT_YELLOW}Deseja usar TLS (Cadeado/HTTPS)?${RESET}"
  echo " [1] SIM (Recomendado: Porta 443)"
  echo " [2] NÃO (Recomendado: Porta 80)"
  read -rp "Opção: " tls_opt

  local use_tls="false"
  [ "$tls_opt" = "1" ] && use_tls="true"

  header_blue "PASSO 3: PORTA DE CONEXÃO"
  if [ "$use_tls" = "true" ]; then
    echo -e "Sugestão TLS: 443, 8443, 2053"
  else
    echo -e "Sugestão SEM TLS: 80, 8080, 8880"
  fi
  read -rp "Digite a porta: " pub_port

  if [ -z "${pub_port:-}" ]; then
    [ "$use_tls" = "true" ] && pub_port="443" || pub_port="80"
  fi

  if ! validate_port "$pub_port"; then echo "Porta inválida."; read -rp "Enter..."; return 0; fi

  ensure_cmd lsof lsof
  if lsof -Pi :"$pub_port" -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo -e "${TXT_RED}Aviso: Porta $pub_port em uso.${RESET}"
    read -rp "Continuar mesmo assim? (s/n): " force
    [[ "${force:-n}" =~ ^[Ss]$ ]] || return 0
  fi

  header_blue "PASSO 4: DOMÍNIO / ENDEREÇO"
  local domain_val=""

  ensure_cmd curl curl

  if [ "$use_tls" = "true" ]; then
    echo -e "${TXT_YELLOW}Digite o DOMÍNIO para o certificado:${RESET}"
    echo -e "(Ex: meudominio.com - sem espaços)"
    read -rp "Domínio: " domain_val

    if ! validate_domain_basic "$domain_val"; then
      echo "Domínio inválido (sem espaços)."; read -rp "Enter..."; return 0
    fi

    # tenta gerar cert
    func_xray_cert "$domain_val" || true

    # valida cert/key antes de continuar
    if [ ! -s "$CRT_FILE" ] || [ ! -s "$KEY_FILE" ]; then
      echo -e "${TXT_RED}Falha ao obter certificado. TLS não pode ser ativado sem cert válido.${RESET}"
      read -rp "Pressione Enter..."
      return 0
    fi
  else
    echo -e "${TXT_YELLOW}Digite o IP da VPS ou Domínio Cloudflare:${RESET}"
    read -rp "Endereço: " domain_val
    if [ -z "${domain_val:-}" ]; then
      domain_val="$(curl -fsSL --retry 3 --retry-delay 1 icanhazip.com 2>/dev/null || true)"
    fi
    [ -n "${domain_val:-}" ] || { echo "Não foi possível obter IP."; read -rp "Enter..."; return 0; }
  fi

  mkdir -p "$XRAYTOOLS_DIR"
  echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"

  header_blue "PASSO 5: PROTOCOLO"
  echo " [1] WS (Websocket)"
  echo " [2] GRPC"
  echo " [3] XHTTP (Otimizado)"
  echo " [4] TCP"
  echo " [5] VISION (Exige TLS)"
  read -rp "Opção: " prot_opt

  local selected_net=""
  case "$prot_opt" in
    1) selected_net="ws" ;;
    2) selected_net="grpc" ;;
    3) selected_net="xhttp" ;;
    4) selected_net="tcp" ;;
    5) selected_net="vision" ;;
    *) return 0 ;;
  esac

  if [ "$selected_net" = "vision" ] && [ "$use_tls" = "false" ]; then
    echo "Erro: Vision exige TLS ativo."
    read -rp "Enter..."
    return 0
  fi

  func_generate_config "$pub_port" "$selected_net" "$domain_val" "1080" "$use_tls"
}

func_wizard_install
