#!/bin/bash
# menuxray.sh - Versão V3.1 (Correção de Chaves Reality)

# --- Variáveis de Ambiente ---
DB_HOST="{DB_HOST}"
DB_NAME="{DB_NAME}"
DB_USER="{DB_USER}"
DB_PASS="{DB_PASS}"

XRAY_BIN="/usr/local/bin/xray"
CONFIG_PATH="/usr/local/etc/xray/config.json"
SSL_DIR="/opt/DragonCoreSSL"
KEY_FILE="$SSL_DIR/privkey.pem"
CRT_FILE="$SSL_DIR/fullchain.pem"
XRAY_DIR="/opt/XrayTools"
ACTIVE_DOMAIN_FILE="$XRAY_DIR/active_domain"
REALITY_PUB_FILE="$XRAY_DIR/reality.pub" 

export PGPASSWORD=$DB_PASS

mkdir -p "$XRAY_DIR"
mkdir -p "$SSL_DIR"

# --- CORES ---
BLUE_BOLD='\033[1;34m'
GREEN='\033[1;32m'
RED='\033[1;31m'
RESET='\033[0m'

header_blue() {
    clear
    echo -e "${BLUE_BOLD}=========================================${RESET}"
    echo -e "${BLUE_BOLD}   $1${RESET}"
    echo -e "${BLUE_BOLD}=========================================${RESET}"
    echo ""
}

db_query() {
    psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$1" 2>/dev/null
}

func_install_official_core() {
    header_blue "INSTALANDO XRAY CORE"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    if [ $? -eq 0 ]; then echo "✅ Xray Core pronto!"; sleep 1; else echo "❌ Falha no download."; read -rp "Enter..."; fi
}

func_check_cert() {
    if [ ! -f "$KEY_FILE" ] || [ ! -f "$CRT_FILE" ]; then return 1; fi
    return 0
}

func_xray_cert() {
    local domain="$1"
    [ -z "$domain" ] && return 1
    mkdir -p "$SSL_DIR"
    echo "Gerando certificado auto-assinado para $domain..."
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=DragonCore/OU=VPN/CN=$domain" \
        -keyout "$KEY_FILE" -out "$CRT_FILE" 2>/dev/null
    chmod 644 "$KEY_FILE" "$CRT_FILE"
}

func_generate_config() {
    local port="$1"
    local network="$2"
    local domain="$3"
    local api_port="$4"
    local use_tls="$5"
    local reality_dest="$6"
    local reality_names="$7"
    local reality_private="$8"
    local reality_shortid="$9"
    
    mkdir -p "$(dirname "$CONFIG_PATH")"

    local stream_settings=""
    local protocol_settings='{clients: [], decryption: "none", fallbacks: []}'
    
    if [ "$network" == "reality" ]; then
        protocol_settings=$(jq -n --arg dest "$reality_dest" '{clients: [], decryption: "none", fallbacks: [{dest: $dest, xver: 0}]}')
        stream_settings=$(jq -n \
            --arg dest "$reality_dest" \
            --argjson names "$reality_names" \
            --arg pk "$reality_private" \
            --argjson sid "[\"$reality_shortid\"]" \
            '{network: "tcp", security: "reality", realitySettings: {show: false, dest: $dest, xver: 0, serverNames: $names, privateKey: $pk, shortIds: $sid}, tcpSettings: {header: {type: "none"}}}')

    elif [ "$network" == "xhttp" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '{network: "xhttp", security: "tls", tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}], alpn: ["h2", "http/1.1"]}, xhttpSettings: {path: "/", scMaxBufferedPosts: 30}}')
        else
            stream_settings=$(jq -n '{network: "xhttp", security: "none", xhttpSettings: {path: "/", scMaxBufferedPosts: 30}}')
        fi
    elif [ "$network" == "ws" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '{network: "ws", security: "tls", tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}]}, wsSettings: {acceptProxyProtocol: false, path: "/"}}')
        else
            stream_settings=$(jq -n '{network: "ws", security: "none", wsSettings: {acceptProxyProtocol: false, path: "/"}}')
        fi
    elif [ "$network" == "grpc" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '{network: "grpc", security: "tls", tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}]}, grpcSettings: {serviceName: "gRPC"}}')
        else
            stream_settings=$(jq -n '{network: "grpc", security: "none", grpcSettings: {serviceName: "gRPC"}}')
        fi
    elif [ "$network" == "vision" ]; then
        stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '{network: "tcp", security: "tls", tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}], minVersion: "1.2", allowInsecure: true}, tcpSettings: {header: {type: "none"}}}')
    else 
        if [ "$use_tls" = "true" ]; then
             stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '{network: "tcp", security: "tls", tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}]}}')
        else
             stream_settings=$(jq -n '{network: "tcp", security: "none"}')
        fi
    fi

    jq -n --argjson stream "$stream_settings" \
          --argjson proto "$protocol_settings" \
          --arg port "$port" \
          --arg api "$api_port" \
      '{log: {loglevel: "warning"}, api: {services: ["HandlerService", "LoggerService", "StatsService"], tag: "api"}, inbounds: [{tag: "api", port: ($api | tonumber), protocol: "dokodemo-door", settings: {address: "127.0.0.1"}, listen: "127.0.0.1"}, {tag: "inbound-dragoncore", port: ($port | tonumber), protocol: "vless", settings: $proto, streamSettings: $stream}], outbounds: [{protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "blocked"}], routing: {domainStrategy: "AsIs", rules: [{type: "field", inboundTag: ["api"], outboundTag: "api"}]}}' > "$CONFIG_PATH"

    if [ "$network" == "vision" ] || [ "$network" == "reality" ]; then
        jq '(.inbounds[] | select(.tag == "inbound-dragoncore").settings) += {"flow": "xtls-rprx-vision"}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi

    systemctl restart xray
    sleep 2
    
    header_blue "STATUS DA INSTALAÇÃO"
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✅ Configuração Aplicada!${RESET}"
        [ "$network" == "reality" ] && echo "   ► Modo: REALITY (Camuflagem: $reality_dest)"
    else
        echo -e "${RED}❌ ERRO CRÍTICO: Xray falhou ao iniciar.${RESET}"
        journalctl -u xray -n 15 --no-pager
    fi
    echo "========================================="
    read -rp "Pressione ENTER para voltar..."
}

func_add_user_logic() {
    local nick="$1"
    local expiry_days="$2"
    if [ -z "$nick" ]; then echo "❌ Erro: Nome vazio."; return 1; fi
    if [ ! -f "$CONFIG_PATH" ]; then echo "❌ Erro: Xray não configurado."; return 1; fi

    local port=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").port' "$CONFIG_PATH")
    local net=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.network' "$CONFIG_PATH")
    local sec=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.security' "$CONFIG_PATH")
    
    local domain=""
    if [ "$sec" == "reality" ]; then
        domain=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.realitySettings.serverNames[0]' "$CONFIG_PATH")
    else
        domain=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.tlsSettings.serverName // empty' "$CONFIG_PATH")
    fi
    local vps_ip=$(curl -s icanhazip.com)
    if [ -z "$domain" ]; then domain=$vps_ip; fi

    local uuid=$(uuidgen)
    local expiry=$(date -d "+$expiry_days days" +%F)

    jq --arg uuid "$uuid" --arg nick_arg "$nick" \
       '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) += [{"id": $uuid, "email": $nick_arg, "level": 0}]' \
       "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    if [ "$sec" == "reality" ] || [ "$net" == "vision" ]; then
         jq --arg uuid "$uuid" \
           '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients[] | select(.id == $uuid)) += {"flow": "xtls-rprx-vision"}' \
           "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi

    db_query "INSERT INTO xray (uuid, nick, expiry, protocol, domain) VALUES ('$uuid', '$nick', '$expiry', '$net', '$domain')"
    systemctl restart xray 2>/dev/null
    
    local link=""
    if [ "$sec" == "reality" ]; then
        local pbk=$(cat "$REALITY_PUB_FILE")
        local sid=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.realitySettings.shortIds[0]' "$CONFIG_PATH")
        link="vless://${uuid}@${vps_ip}:${port}?security=reality&encryption=none&pbk=${pbk}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${domain}&sid=${sid}#${nick}"
    elif [ "$net" == "ws" ]; then
        local path=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.wsSettings.path' "$CONFIG_PATH")
        [ "$path" == "/" ] && path="%2F"
        link="vless://${uuid}@${domain}:${port}?path=${path}&security=${sec}&encryption=none&host=${domain}&type=ws&sni=${domain}#${nick}"
    elif [ "$net" == "xhttp" ]; then
        local path=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.xhttpSettings.path' "$CONFIG_PATH")
        [ "$path" == "/" ] && path="%2F"
        if [ "$sec" == "tls" ]; then
            link="vless://${uuid}@${domain}:${port}?mode=auto&path=${path}&security=tls&encryption=none&host=${domain}&type=xhttp&sni=${domain}#${nick}"
        else
            link="vless://${uuid}@${domain}:${port}?mode=auto&path=${path}&security=none&encryption=none&host=${domain}&type=xhttp#${nick}"
        fi
    elif [ "$net" == "tcp" ] || [ "$net" == "vision" ]; then
        local flow=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").settings.flow // empty' "$CONFIG_PATH")
        if [ "$flow" == "xtls-rprx-vision" ]; then
            link="vless://${uuid}@${domain}:${port}?security=tls&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=${domain}#${nick}"
        elif [ "$sec" == "tls" ]; then
            link="vless://${uuid}@${domain}:${port}?security=tls&encryption=none&type=tcp&sni=${domain}#${nick}"
        else
            link="vless://${uuid}@${domain}:${port}?security=none&encryption=none&type=tcp#${nick}"
        fi
    fi

    echo -e "${GREEN}✅ Usuário criado com sucesso!${RESET}"
    echo "-----------------------------------------"
    echo "👤 Usuário: $nick"
    echo "📅 Expira:  $expiry"
    echo "🔑 UUID:    $uuid"
    echo "-----------------------------------------"
    echo -e "${BLUE_BOLD}🔗 Link de Conexão:${RESET}"
    echo "$link"
    echo "-----------------------------------------"
}

func_remove_user_logic() {
    local identifier="$1"
    local uuid=""
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then uuid=$(db_query "SELECT uuid FROM xray WHERE id = $identifier");
    else uuid=$(db_query "SELECT uuid FROM xray WHERE uuid = '$identifier'"); fi
    if [ -z "$uuid" ]; then echo "❌ Usuário não encontrado."; return 1; fi
    jq --arg uuid "$uuid" '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(select(.id != $uuid))' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    db_query "DELETE FROM xray WHERE uuid = '$uuid'"
    systemctl restart xray 2>/dev/null
    echo "✅ Usuário removido com sucesso."
}

func_page_create_user() {
    while true; do
        header_blue "CRIAR USUÁRIO"
        read -rp "Nome do usuário (0 p/ voltar): " nick
        if [ "$nick" == "0" ] || [ -z "$nick" ]; then break; fi
        check_exists=$(db_query "SELECT id FROM xray WHERE nick = '$nick' LIMIT 1")
        if [ -n "$check_exists" ]; then echo "❌ ERRO: Usuário já existe!"; read -rp "Enter..."; continue; fi
        read -rp "Dias de validade (Padrão 30): " days
        [ -z "$days" ] && days=30
        echo ""; func_add_user_logic "$nick" "$days"; echo ""
        read -rp "Pressione ENTER para continuar..."
    done
}

func_page_remove_user() {
    header_blue "REMOVER USUÁRIO"
    read -rp "Digite o ID ou UUID: " id_input
    if [ -n "$id_input" ]; then func_remove_user_logic "$id_input"; fi
    echo ""; read -rp "Pressione ENTER para voltar..."
}

func_page_list_users() {
    header_blue "LISTAR USUÁRIOS"
    while IFS='|' read -r id nick uuid expiry; do
        echo "🆔 ID: $id | 👤 $nick | 📅 $expiry | 🔑 $uuid"
    done < <(db_query "SELECT id, nick, uuid, expiry FROM xray ORDER BY id")
    echo ""; read -rp "Pressione ENTER para voltar..."
}

func_page_purge_expired() {
    header_blue "LIMPEZA DE EXPIRADOS"
    local today=$(date +%F)
    local expired_uuids=$(db_query "SELECT uuid FROM xray WHERE expiry < '$today'")
    if [ -z "$expired_uuids" ]; then echo "✅ Nenhum expirado."; else
        for uuid in $expired_uuids; do func_remove_user_logic "$uuid"; done
        echo "✅ Limpeza concluída."
    fi
    echo ""; read -rp "Pressione ENTER para voltar..."
}

func_page_uninstall() {
    header_blue "DESINSTALAR SISTEMA"
    echo "⚠️  ATENÇÃO: ISSO APAGARÁ TUDO!"
    read -rp "Digite 'SIM' para confirmar: " confirm
    if [ "$confirm" != "SIM" ]; then echo "❌ Cancelado."; return; fi
    systemctl stop xray 2>/dev/null; systemctl disable xray 2>/dev/null
    rm -f /usr/local/bin/xray; rm -rf /usr/local/etc/xray; rm -rf /usr/local/share/xray
    rm -f /etc/systemd/system/xray.service; systemctl daemon-reload
    rm -rf "$XRAY_DIR"; rm -rf "$SSL_DIR"; rm -f /bin/xray-menu
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME;" >/dev/null 2>&1
    sudo -u postgres psql -c "DROP USER IF EXISTS $DB_USER;" >/dev/null 2>&1
    echo "✅ Desinstalação Completa!"; exit 0
}

func_wizard_install() {
    header_blue "INSTALAÇÃO GUIADA"
    read -rp "Deseja instalar/atualizar o Xray Core? (s/n): " install_opt
    [[ "$install_opt" =~ ^[Ss]$ ]] && func_install_official_core

    header_blue "SELECIONE O PROTOCOLO"
    echo "1. ws (WebSocket) - Para Cloudflare"
    echo "2. grpc (gRPC)"
    echo "3. xhttp (HTTP/2)"
    echo "4. tcp (Simples)"
    echo "5. vision (XTLS-Vision)"
    echo "6. reality (VLESS Reality) - 🏆 Burlas/SNI Livre"
    echo "0. Cancelar"
    read -rp "Opção: " prot_opt
    
    local selected_net=""
    case "$prot_opt" in
        1) selected_net="ws" ;;
        2) selected_net="grpc" ;;
        3) selected_net="xhttp" ;;
        4) selected_net="tcp" ;;
        5) selected_net="vision" ;;
        6) selected_net="reality" ;;
        *) return ;;
    esac

    read -rp "Porta Interna [1080]: " api_port; [ -z "$api_port" ] && api_port="1080"
    read -rp "Porta Pública [443]: " pub_port; [ -z "$pub_port" ] && pub_port="443"

    local use_tls="false"
    local domain_val=""
    local reality_dest=""
    local reality_names=""
    local reality_private=""
    local reality_shortid=""

    if [ "$selected_net" == "reality" ]; then
        header_blue "CONFIGURAÇÃO REALITY"
        echo "Gerando chaves..."
        
        # --- CORREÇÃO DE CHAVES AQUI ---
        local keys=$($XRAY_BIN x25519)
        reality_private=$(echo "$keys" | grep "Private" | awk '{print $NF}')
        local reality_pub=$(echo "$keys" | grep "Public" | awk '{print $NF}')
        
        if [ -z "$reality_private" ]; then
            echo "❌ Erro ao gerar chaves. Tentando método alternativo..."
            keys=$($XRAY_BIN x25519)
            reality_private=$(echo "$keys" | head -n 1 | cut -d: -f2 | tr -d ' ')
            reality_pub=$(echo "$keys" | tail -n 1 | cut -d: -f2 | tr -d ' ')
        fi

        echo "$reality_pub" > "$REALITY_PUB_FILE"
        reality_shortid=$(openssl rand -hex 4)
        
        echo "Escolha a camuflagem (SNI Destino):"
        echo "1) www.microsoft.com"
        echo "2) www.google.com"
        echo "3) www.amazon.com"
        read -rp "Opção: " sni_opt
        case "$sni_opt" in
            1) reality_dest="www.microsoft.com:443"; reality_names='["www.microsoft.com", "microsoft.com"]' ;;
            2) reality_dest="www.google.com:443"; reality_names='["www.google.com", "google.com"]' ;;
            3) reality_dest="www.amazon.com:443"; reality_names='["www.amazon.com"]' ;;
            *) reality_dest="www.microsoft.com:443"; reality_names='["www.microsoft.com", "microsoft.com"]' ;;
        esac
        domain_val=$(echo "$reality_names" | jq -r '.[0]')

    else
        echo "Usar TLS/SSL? (1=Sim, 2=Não)"
        read -rp "Opção: " tls_opt
        if [ "$tls_opt" == "1" ] || [ "$selected_net" == "vision" ]; then
            use_tls="true"
            read -rp "Digite seu domínio: " domain_val
            func_xray_cert "$domain_val"
        else
            domain_val=$(curl -s icanhazip.com)
        fi
    fi

    echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"
    func_generate_config "$pub_port" "$selected_net" "$domain_val" "$api_port" "$use_tls" \
        "$reality_dest" "$reality_names" "$reality_private" "$reality_shortid"
}

# --- MENU ---
menu_display() {
    clear
    echo -e "${BLUE_BOLD}⚡ DRAGONCORE XRAY MANAGER v3.1${RESET}"
    echo "1. Criar Usuário"
    echo "2. Remover Usuário"
    echo "3. Listar Usuários"
    echo "4. INSTALAR / RECONFIGURAR"
    echo "5. Limpar Expirados"
    echo "6. Desinstalar"
    echo "0. Sair"
    read -rp "Opção: " choice
}

if [ -z "$1" ]; then
    while true; do
        menu_display
        case "$choice" in
            1) func_page_create_user ;;
            2) func_page_remove_user ;;
            3) func_page_list_users ;;
            4) func_wizard_install ;;
            5) func_page_purge_expired ;;
            6) func_page_uninstall ;; 
            0) exit 0 ;;
        esac
    done
else "$1" "${@:2}"; 
fi
