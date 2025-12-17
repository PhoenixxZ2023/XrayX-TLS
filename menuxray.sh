#!/bin/bash
# menuxray.sh - Menu Interativo e Lógica Xray (Versão Blindada JSON)

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

# --- FUNÇÕES DE LÓGICA ---

db_query() {
    psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$1" 2>/dev/null
}

func_create_db_table() {
    local sql="CREATE TABLE IF NOT EXISTS xray (id SERIAL PRIMARY KEY, uuid TEXT, nick TEXT, expiry DATE, protocol TEXT, domain TEXT);"
    db_query "$sql"
    if [ $? -eq 0 ]; then echo "✅ Tabela verificada/criada."; else echo "❌ ERRO: Falha ao acessar o DB."; fi
}

func_is_installed() { [ -f "$XRAY_BIN" ] || [ -f "/usr/bin/xray" ]; }

func_select_protocol() {
    # Redireciona menu para stderr para aparecer na tela
    {
        clear
        echo "========================================="
        echo "⚙️  Seleção de Protocolo de Transporte"
        echo "========================================="
        echo "1. ws (WebSocket) - Compatível com CDNs (Cloudflare)"
        echo "2. grpc (gRPC) - ✅ Alta Performance"
        echo "3. xhttp (Novo HTTP/2) - Baixa Latência"
        echo "4. tcp (TCP Simples) - Apenas para testes/fallback"
        echo "5. vision (XTLS-Vision) - 🚀 Performance Máxima (Requer Porta 443 + Cert)"
        echo "0. Cancelar"
        echo "-----------------------------------------"
    } >&2
    
    read -rp "Digite o número da opção: " choice
    
    case "$choice" in
        1) echo "ws" ;;
        2) echo "grpc" ;;
        3) echo "xhttp" ;;
        4) echo "tcp" ;;
        5) echo "vision" ;;
        0) echo "cancel" ;;
        *) echo "invalid" ;;
    esac
}

func_check_cert() {
    if [ ! -f "$KEY_FILE" ] || [ ! -f "$CRT_FILE" ]; then
        echo "❌ ERRO CRÍTICO: Certificado TLS não encontrado."
        echo "Este protocolo EXIGE certificado. Use a opção 5 para gerar um."
        return 1
    fi
    return 0
}

func_check_domain_ip() {
    local domain="$1"
    local vps_ip=$(curl -s icanhazip.com)
    
    if [ -z "$domain" ]; then echo "❌ Domínio vazio."; return 1; fi

    local domain_ip=$(dig +short "$domain" | head -n 1)

    if [ -z "$domain_ip" ]; then
        echo "❌ Erro DNS: Não foi possível resolver '$domain'."
        return 1
    fi
    
    if [ "$domain_ip" != "$vps_ip" ]; then
        echo "⚠️  AVISO: O IP do domínio ($domain_ip) é diferente do IP desta VPS ($vps_ip)."
        echo "Isso pode ser normal se usar Cloudflare Proxy, mas impede TCP/Vision direto."
        read -rp "Deseja continuar? (s/n): " confirm
        [[ "$confirm" != "s" ]] && return 1
    fi
    echo "✅ Domínio verificado."
    return 0
}

func_generate_config() {
    local port=${1:-443}
    local network=${2:-ws}
    local domain="$3"
    local stream_settings=""
    local flow_setting=""

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -le 0 ] || [ "$port" -gt 65535 ]; then port=443; fi

    mkdir -p "$(dirname "$CONFIG_PATH")"
    
    # 1. Configurar StreamSettings (Em linha única para evitar erro de indentação EOF)
    if [ "$network" == "xhttp" ]; then
        stream_settings="{\"network\": \"xhttp\", \"security\": \"tls\", \"tlsSettings\": {\"serverName\": \"$domain\", \"certificates\": [{\"certificateFile\": \"$CRT_FILE\", \"keyFile\": \"$KEY_FILE\"}], \"alpn\": [\"h2\", \"http/1.1\"]}, \"xhttpSettings\": {\"path\": \"/\", \"scMaxBufferedPosts\": 30}}"
    elif [ "$network" == "ws" ]; then
        stream_settings="{\"network\": \"ws\", \"security\": \"none\", \"wsSettings\": {\"acceptProxyProtocol\": false, \"path\": \"/\"}}"
    elif [ "$network" == "grpc" ]; then
        stream_settings="{\"network\": \"grpc\", \"security\": \"none\", \"grpcSettings\": {\"serviceName\": \"gRPC\"}}"
    elif [ "$network" == "vision" ]; then
        stream_settings="{\"network\": \"tcp\", \"security\": \"tls\", \"tlsSettings\": {\"serverName\": \"$domain\", \"certificates\": [{\"certificateFile\": \"$CRT_FILE\", \"keyFile\": \"$KEY_FILE\"}], \"minVersion\": \"1.2\"}}"
        flow_setting="xtls-rprx-vision"
    else 
        stream_settings='{ "network": "tcp", "security": "none" }'
    fi

    # 2. Gerar Config JSON via JQ (Comando em linha única para evitar quebra)
    jq -n --argjson streamSettings "$stream_settings" --arg port "$port" '{ "api": { "services": [ "HandlerService", "LoggerService", "StatsService" ], "tag": "api" }, "inbounds": [ { "tag": "api", "port": 1080, "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" }, "listen": "127.0.0.1" }, { "tag": "inbound-dragoncore", "port": ($port | tonumber), "protocol": "vless", "settings": { "clients": [], "decryption": "none", "fallbacks": [] }, "streamSettings": $streamSettings } ], "outbounds": [{ "protocol": "freedom", "tag": "direct" }, { "protocol": "blackhole", "tag": "blocked" }], "routing": { "domainStrategy": "AsIs", "rules": [ { "type": "field", "inboundTag": ["api"], "outboundTag": "api" } ] } }' > "$CONFIG_PATH"

    # Inserir flow (apenas para Vision)
    if [ -n "$flow_setting" ]; then
        jq --arg flow "$flow_setting" '(.inbounds[] | select(.tag == "inbound-dragoncore").settings) += {"flow": $flow}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi

    systemctl restart xray 2>/dev/null
    echo "✅ Config Xray atualizada (Porta: $port | Proto: $network | Domain: $domain)"
}

func_add_user() {
    local nick="$1"
    local expiry_days=${2:-30} 
    
    if [ -z "$nick" ]; then echo "Erro: Nick necessário."; return 1; fi
    if [ ! -f "$CONFIG_PATH" ]; then echo "Erro: Xray não configurado."; return 1; fi

    local port=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").port' "$CONFIG_PATH")
    local net=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.network' "$CONFIG_PATH")
    local sec=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.security' "$CONFIG_PATH")
    
    local domain=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.tlsSettings.serverName // empty' "$CONFIG_PATH")
    if [ -z "$domain" ]; then
        domain=$(cat "$ACTIVE_DOMAIN_FILE" 2>/dev/null)
        if [ -z "$domain" ]; then domain=$(curl -s icanhazip.com); fi
    fi

    local uuid=$(uuidgen)
    local expiry=$(date -d "+$expiry_days days" +%F)

    jq --arg uuid "$uuid" --arg nick_arg "$nick" \
       '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) += [{"id": $uuid, "email": $nick_arg, "level": 0}]' \
       "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    db_query "INSERT INTO xray (uuid, nick, expiry, protocol, domain) VALUES ('$uuid', '$nick', '$expiry', '$net', '$domain')"
    systemctl restart xray 2>/dev/null
    
    echo "✅ Usuário criado: $nick ($expiry)"
    echo "UUID: $uuid"
    
    local link=""
    if [ "$net" == "grpc" ]; then
        local serviceName=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.grpcSettings.serviceName' "$CONFIG_PATH")
        link="vless://${uuid}@${domain}:${port}?type=grpc&serviceName=${serviceName}&security=${sec}#${nick}"
    elif [ "$net" == "ws" ]; then
        local path=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.wsSettings.path' "$CONFIG_PATH")
        link="vless://${uuid}@${domain}:${port}?type=ws&path=${path}&security=${sec}#${nick}"
    elif [ "$net" == "xhttp" ]; then
        local path=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.xhttpSettings.path' "$CONFIG_PATH")
        link="vless://${uuid}@${domain}:${port}?type=xhttp&path=${path}&security=tls#${nick}"
    elif [ "$net" == "tcp" ] && [ "$sec" == "tls" ]; then
        local flow=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").settings.flow // empty' "$CONFIG_PATH")
        if [ "$flow" == "xtls-rprx-vision" ]; then
            link="vless://${uuid}@${domain}:${port}?security=tls&flow=xtls-rprx-vision&encryption=none#${nick}"
        else
            link="vless://${uuid}@${domain}:${port}?security=tls#${nick}"
        fi
    else 
        link="vless://${uuid}@${domain}:${port}?security=none#${nick}"
    fi
    echo "------------------------------------------------"
    echo "$link"
    echo "------------------------------------------------"
}

func_remove_user() {
    local identifier="$1"
    local uuid=""
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then uuid=$(db_query "SELECT uuid FROM xray WHERE id = $identifier");
    else uuid=$(db_query "SELECT uuid FROM xray WHERE uuid = '$identifier'"); fi
    
    if [ -z "$uuid" ]; then echo "❌ Usuário não encontrado."; return 1; fi
    jq --arg uuid "$uuid" '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(select(.id != $uuid))' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    db_query "DELETE FROM xray WHERE uuid = '$uuid'"
    systemctl restart xray 2>/dev/null
    echo "✅ Usuário removido."
}

func_list_users() {
    echo "--- Usuários ---"
    db_query "SELECT id, nick, expiry, protocol FROM xray ORDER BY id"
    echo "----------------"
}

func_xray_cert() {
    local domain="$1"
    if [ -z "$domain" ]; then echo "Erro: Domínio necessário."; return 1; fi
    if ! func_check_domain_ip "$domain"; then return 1; fi
    mkdir -p "$SSL_DIR"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=DragonCore/OU=VPN/CN=$domain" \
        -keyout "$KEY_FILE" -out "$CRT_FILE" 2>/dev/null
    echo "✅ Certificado gerado para $domain"
}

func_purge_expired() {
    local today=$(date +%F)
    local expired_uuids=$(db_query "SELECT uuid FROM xray WHERE expiry < '$today'")
    for uuid in $expired_uuids; do func_remove_user "$uuid"; done
}

func_uninstall_xray() {
    systemctl stop xray; systemctl disable xray
    rm -f /usr/local/bin/xray
    rm -rf /usr/local/etc/xray "$XRAY_DIR" "$SSL_DIR"
    rm -f /bin/xray-menu
    db_query "DROP TABLE IF EXISTS xray"
    echo "✅ Desinstalado."
    exit 0
}

# --- MENU ---
menu_display() {
    clear
    echo "⚡ DragonCore Xray Manager"
    echo "1. Criar Usuário"
    echo "2. Remover Usuário"
    echo "3. Listar Usuários"
    echo "5. Gerar Certificado TLS"
    echo "6. Configurar Xray (Porta/Proto)"
    echo "8. Limpar Expirados"
    echo "9. Desinstalar"
    echo "0. Sair"
    read -rp "Opção: " choice
}

if [ -z "$1" ]; then
    while true; do
        menu_display
        case "$choice" in
            1) read -rp "Nick: " n; read -rp "Dias: " d; func_add_user "$n" "$d" ;;
            2) read -rp "ID/UUID: " i; func_remove_user "$i" ;;
            3) func_list_users ;;
            5) read -rp "Domínio: " d; func_xray_cert "$d" ;;
            6) 
                res=$(func_select_protocol)
                if [ "$res" == "invalid" ]; then
                    echo "❌ Opção inválida."
                    read -rp "Enter..."
                elif [ "$res" != "cancel" ]; then
                    read -rp "Porta [443]: " p; [ -z "$p" ] && p=443
                    read -rp "Domínio/IP: " d
                    
                    if [ "$res" == "vision" ] || [ "$res" == "xhttp" ]; then
                         if func_check_cert && func_check_domain_ip "$d"; then
                             func_generate_config "$p" "$res" "$d"
                         fi
                    else
                         func_generate_config "$p" "$res" "$d"
                    fi
                    echo "$d" > "$ACTIVE_DOMAIN_FILE"
                fi
                ;;
            8) func_purge_expired ;;
            9) func_uninstall_xray ;; 
            0) exit 0 ;;
        esac
        [ "$choice" != "0" ] && read -rp "Enter para voltar..."
    done
else
    "$1" "${@:2}"
fi
