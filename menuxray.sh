#!/bin/bash
# menuxray.sh - Versão Estável (Vision/XHTTP/WS/gRPC) - Sem Reality

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

# Variável de Senha para psql
export PGPASSWORD=$DB_PASS

# Garantir diretórios
mkdir -p "$XRAY_DIR"
mkdir -p "$SSL_DIR"

# --- CORES E VISUAL ---
BLUE_BOLD='\033[1;34m'
GREEN='\033[1;32m'
RESET='\033[0m'

# Função Header Padrão
header_blue() {
    clear
    echo -e "${BLUE_BOLD}=========================================${RESET}"
    echo -e "${BLUE_BOLD}   $1${RESET}"
    echo -e "${BLUE_BOLD}=========================================${RESET}"
    echo ""
}

# --- FUNÇÕES DE LÓGICA ---

db_query() {
    psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$1" 2>/dev/null
}

func_install_official_core() {
    header_blue "INSTALANDO XRAY CORE"
    echo "Baixando versão oficial..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    if [ $? -eq 0 ]; then
        echo "✅ Xray Core pronto!"
        sleep 2
    else
        echo "❌ Falha ao baixar Xray Core."
        read -rp "Pressione ENTER para continuar..."
    fi
}

func_check_cert() {
    if [ ! -f "$KEY_FILE" ] || [ ! -f "$CRT_FILE" ]; then return 1; fi
    return 0
}

func_check_domain_ip() {
    local domain="$1"
    local vps_ip=$(curl -s icanhazip.com)
    if [ -z "$domain" ]; then echo "❌ Domínio vazio."; return 1; fi
    local domain_ip=$(dig +short "$domain" | head -n 1)
    if [ -z "$domain_ip" ]; then echo "❌ Erro DNS: Não resolveu '$domain'."; return 1; fi
    if [ "$domain_ip" != "$vps_ip" ]; then
        echo "⚠️  AVISO: IP do domínio ($domain_ip) difere do IP da VPS ($vps_ip)."
        read -rp "Continuar? (s/n): " confirm; [[ "$confirm" != "s" ]] && return 1
    fi
    echo "✅ Domínio verificado."
    return 0
}

func_xray_cert() {
    local domain="$1"
    if [ -z "$domain" ]; then echo "Erro: Domínio necessário."; return 1; fi
    
    mkdir -p "$SSL_DIR"
    echo "Gerando certificado para $domain..."
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=DragonCore/OU=VPN/CN=$domain" \
        -keyout "$KEY_FILE" -out "$CRT_FILE" 2>/dev/null
    chmod 755 "$SSL_DIR"; chmod 644 "$KEY_FILE"; chmod 644 "$CRT_FILE"
    if [ -f "$KEY_FILE" ]; then echo "✅ Certificado OK."; else echo "❌ Falha ao gerar."; return 1; fi
}

func_generate_config() {
    local port="$1"
    local network="$2"
    local domain="$3"
    local api_port="$4"
    local use_tls="$5" 
    
    mkdir -p "$(dirname "$CONFIG_PATH")"
    if [ -d "$SSL_DIR" ]; then chmod 755 "$SSL_DIR"; chmod 644 "$SSL_DIR"/* 2>/dev/null; fi

    local stream_settings=""
    
    if [ "$network" == "xhttp" ]; then
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

    jq -n --argjson stream "$stream_settings" --arg port "$port" --arg api "$api_port" \
      '{log: {loglevel: "warning"}, api: {services: ["HandlerService", "LoggerService", "StatsService"], tag: "api"}, inbounds: [{tag: "api", port: ($api | tonumber), protocol: "dokodemo-door", settings: {address: "127.0.0.1"}, listen: "127.0.0.1"}, {tag: "inbound-dragoncore", port: ($port | tonumber), protocol: "vless", settings: {clients: [], decryption: "none", fallbacks: []}, streamSettings: $stream}], outbounds: [{protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "blocked"}], routing: {domainStrategy: "AsIs", rules: [{type: "field", inboundTag: ["api"], outboundTag: "api"}]}}' > "$CONFIG_PATH"

    if [ "$network" == "vision" ]; then
        jq '(.inbounds[] | select(.tag == "inbound-dragoncore").settings) += {"flow": "xtls-rprx-vision"}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi

    systemctl restart xray
    sleep 2
    
    header_blue "STATUS DA INSTALAÇÃO"
    if systemctl is-active --quiet xray; then
        echo "✅ Configuração Aplicada com Sucesso!"
        echo "========================================="
        echo "📊 Resumo:"
        echo "   ► Protocolo:  $network"
        echo "   ► Porta Pub:  $port"
        echo "   ► Porta Int:  $api_port"
        echo "   ► TLS Ativo:  $use_tls"
        echo "   ► Domínio:    $domain"
    else
        echo "❌ ERRO CRÍTICO: Xray falhou ao iniciar."
        journalctl -u xray -n 10 --no-pager
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
    local domain=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.tlsSettings.serverName // empty' "$CONFIG_PATH")
    if [ -z "$domain" ]; then domain=$(curl -s icanhazip.com); fi

    local uuid=$(uuidgen)
    local expiry=$(date -d "+$expiry_days days" +%F)

    jq --arg uuid "$uuid" --arg nick_arg "$nick" \
       '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) += [{"id": $uuid, "email": $nick_arg, "level": 0}]' \
       "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    db_query "INSERT INTO xray (uuid, nick, expiry, protocol, domain) VALUES ('$uuid', '$nick', '$expiry', '$net', '$domain')"
    systemctl restart xray 2>/dev/null
    
    # --- GERADOR DE LINK ---
    local link=""
    
    if [ "$net" == "grpc" ]; then
        local serviceName=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.grpcSettings.serviceName' "$CONFIG_PATH")
        link="vless://${uuid}@${domain}:${port}?security=${sec}&encryption=none&type=grpc&serviceName=${serviceName}&sni=${domain}#${nick}"
    elif [ "$net" == "ws" ]; then
        local path=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.wsSettings.path' "$CONFIG_PATH")
        if [ "$path" == "/" ]; then path="%2F"; fi
        link="vless://${uuid}@${domain}:${port}?path=${path}&security=${sec}&encryption=none&host=${domain}&type=ws&sni=${domain}#${nick}"
    elif [ "$net" == "xhttp" ]; then
        local path=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.xhttpSettings.path' "$CONFIG_PATH")
        if [ "$path" == "/" ]; then path="%2F"; fi
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

# --- PÁGINAS DO MENU ---

func_page_create_user() {
    while true; do
        header_blue "CRIAR USUÁRIO"
        read -rp "Nome do usuário (0 p/ voltar): " nick
        if [ "$nick" == "0" ] || [ -z "$nick" ]; then break; fi
        check_exists=$(db_query "SELECT id FROM xray WHERE nick = '$nick' LIMIT 1")
        if [ -n "$check_exists" ]; then echo "❌ ERRO: O usuário '$nick' JÁ EXISTE!"; read -rp "Enter..."; continue; fi
        read -rp "Dias de validade (Padrão 30): " days
        [ -z "$days" ] && days=30
        echo ""; func_add_user_logic "$nick" "$days"; echo ""
        read -rp "Pressione ENTER para continuar..."
    done
}

func_page_remove_user() {
    header_blue "REMOVER USUÁRIO"
    echo "Digite o ID ou UUID do usuário."
    read -rp "Identificador: " id_input
    if [ -n "$id_input" ]; then func_remove_user_logic "$id_input"; fi
    echo ""; read -rp "Pressione ENTER para voltar..."
}

func_page_list_users() {
    if [ ! -f "$CONFIG_PATH" ]; then echo "❌ Xray não configurado."; read -rp "Enter..."; return; fi
    header_blue "LISTAR USUÁRIOS"
    while IFS='|' read -r id nick uuid expiry; do
        echo "🆔 ID: $id | 👤 Usuário: $nick | 📅 Expira: $expiry | 🔑 UUID: $uuid"
    done < <(db_query "SELECT id, nick, uuid, expiry FROM xray ORDER BY id")
    echo ""; read -rp "Pressione ENTER para voltar..."
}

func_page_purge_expired() {
    header_blue "LIMPEZA DE EXPIRADOS"
    local today=$(date +%F)
    echo "Buscando usuários vencidos antes de $today..."
    local expired_uuids=$(db_query "SELECT uuid FROM xray WHERE expiry < '$today'")
    if [ -z "$expired_uuids" ]; then echo "✅ Nenhum usuário expirado encontrado."; else
        for uuid in $expired_uuids; do func_remove_user_logic "$uuid"; done
        echo "✅ Limpeza concluída."
    fi
    echo ""; read -rp "Pressione ENTER para voltar..."
}

func_page_uninstall() {
    header_blue "DESINSTALAR SISTEMA"
    echo "⚠️  ATENÇÃO: ISSO APAGARÁ TUDO!"
    echo " - Xray Core e Configurações"
    echo " - Banco de Dados e Usuários"
    echo ""; read -rp "Digite 'SIM' para confirmar: " confirm
    if [ "$confirm" != "SIM" ]; then echo "❌ Cancelado."; return; fi
    systemctl stop xray 2>/dev/null; systemctl disable xray 2>/dev/null
    rm -f /usr/local/bin/xray; rm -rf /usr/local/etc/xray; rm -rf /usr/local/share/xray
    rm -f /etc/systemd/system/xray.service; rm -f /etc/systemd/system/xray@.service; systemctl daemon-reload
    rm -rf "$XRAY_DIR"; rm -rf "$SSL_DIR"; rm -f /bin/xray-menu
    (crontab -l | grep -v "func_purge_expired") | crontab -
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME;" >/dev/null 2>&1
    sudo -u postgres psql -c "DROP USER IF EXISTS $DB_USER;" >/dev/null 2>&1
    echo "✅ Desinstalação Completa!"; exit 0
}

# --- WIZARD DE INSTALAÇÃO (Opção 4) ---
func_wizard_install() {
    # PASSO 1
    header_blue "INSTALAÇÃO GUIADA - PASSO 1/5"
    read -rp "Deseja instalar/atualizar o Xray Core? (s/n): " install_opt
    if [[ "$install_opt" =~ ^[Ss]$ ]]; then func_install_official_core; fi

    # PASSO 2
    header_blue "CONFIGURAÇÃO - PASSO 2/5"
    echo "Deseja usar criptografia TLS/SSL (HTTPS)?"
    echo "1) SIM - Requer domínio (Recomendado)"
    echo "2) NÃO - Conexão simples (Pode usar IP)"
    read -rp "Opção [1/2]: " tls_opt
    local use_tls="false"
    if [ "$tls_opt" == "1" ]; then use_tls="true"; fi

    # PASSO 3
    header_blue "CONFIGURAÇÃO - PASSO 3/5"
    read -rp "Digite a porta interna do Xray [Padrão 1080]: " api_port
    if [ -z "$api_port" ]; then api_port="1080"; fi

    # PASSO 4
    header_blue "CONFIGURAÇÃO - PASSO 4/5"
    read -rp "Digite a porta de conexão pública (Ex: 443, 80, 8080): " pub_port
    if [ -z "$pub_port" ]; then pub_port="80"; fi

    # PASSO 5 - Domínio e Protocolo
    header_blue "CONFIGURAÇÃO - PASSO 5/5"
    local domain_val=""
    if [ "$use_tls" == "true" ]; then
        echo "⚠️  Modo TLS selecionado. DOMÍNIO É OBRIGATÓRIO."
        read -rp "Digite seu domínio (Ex: vpn.site.com): " domain_val
        if ! func_check_domain_ip "$domain_val"; then return; fi
        func_xray_cert "$domain_val" 
        if ! func_check_cert; then echo "❌ Erro no certificado."; return; fi
    else
        echo "ℹ️  Modo sem TLS. Pode usar IP ou Domínio."
        read -rp "Digite o Domínio ou IP (Enter para Auto-Detectar): " domain_val
        if [ -z "$domain_val" ]; then domain_val=$(curl -s icanhazip.com); fi
    fi
    echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"

    # Seleção de Protocolo (SEMPRE MOSTRA TODOS)
    sleep 1
    header_blue "SELECIONE O PROTOCOLO"
    echo "1. ws (WebSocket)"
    echo "2. grpc (gRPC)"
    echo "3. xhttp (HTTP/2)"
    echo "4. tcp (Simples)"
    echo "5. vision (XTLS-Vision) - 🚀"
    echo "0. Cancelar"
    echo ""
    read -rp "Digite o número da opção: " prot_opt
    
    local selected_net=""
    case "$prot_opt" in
        1) selected_net="ws" ;;
        2) selected_net="grpc" ;;
        3) selected_net="xhttp" ;;
        4) selected_net="tcp" ;;
        5) 
            selected_net="vision"
            # CORREÇÃO AUTOMÁTICA DE TLS PARA VISION
            if [ "$use_tls" == "false" ]; then
                echo ""
                echo "⚠️  O protocolo Vision EXIGE TLS/SSL."
                echo "Vamos configurar o domínio e certificado agora."
                echo ""
                read -rp "Digite seu domínio (Ex: vpn.site.com): " domain_val
                if ! func_check_domain_ip "$domain_val"; then return; fi
                func_xray_cert "$domain_val"
                if ! func_check_cert; then echo "❌ Erro no certificado."; return; fi
                use_tls="true" # Força TLS para true
                echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"
            fi
            ;;
        0) return ;;
        *) echo "❌ Inválido."; sleep 2; return ;;
    esac

    func_generate_config "$pub_port" "$selected_net" "$domain_val" "$api_port" "$use_tls"
}

# --- MENU PRINCIPAL ---
menu_display() {
    clear
    echo -e "${BLUE_BOLD}⚡ DRAGONCORE XRAY MANAGER${RESET}"
    echo "-----------------------------------------"
    echo "1. Criar Usuário"
    echo "2. Remover Usuário"
    echo "3. Listar Usuários"
    echo "4. Instalar e Configurar Xray (Assistente)"
    echo "5. Limpar Expirados"
    echo "6. Desinstalar (Completo)"
    echo "0. Sair"
    echo "-----------------------------------------"
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
