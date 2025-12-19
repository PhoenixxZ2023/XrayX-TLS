#!/bin/bash
# menuxray.sh - Versão Final: Sequência Numérica Perfeita (1 a 6)

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

func_install_official_core() {
    echo "========================================="
    echo "📥 Instalando/Atualizando Xray Core..."
    echo "========================================="
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    if [ $? -eq 0 ]; then
        echo "✅ Xray Core pronto!"
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
    if ! func_check_domain_ip "$domain"; then return 1; fi
    
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
    local use_tls="$5" # true ou false
    
    mkdir -p "$(dirname "$CONFIG_PATH")"
    if [ -d "$SSL_DIR" ]; then chmod 755 "$SSL_DIR"; chmod 644 "$SSL_DIR"/* 2>/dev/null; fi

    local stream_settings=""
    
    if [ "$network" == "xhttp" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                '{network: "xhttp", security: "tls", tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}], alpn: ["h2", "http/1.1"]}, xhttpSettings: {path: "/", scMaxBufferedPosts: 30}}')
        else
            stream_settings=$(jq -n '{network: "xhttp", security: "none", xhttpSettings: {path: "/", scMaxBufferedPosts: 30}}')
        fi
    elif [ "$network" == "ws" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                '{network: "ws", security: "tls", tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}]}, wsSettings: {acceptProxyProtocol: false, path: "/"}}')
        else
            stream_settings=$(jq -n '{network: "ws", security: "none", wsSettings: {acceptProxyProtocol: false, path: "/"}}')
        fi
    elif [ "$network" == "grpc" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                '{network: "grpc", security: "tls", tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}]}, grpcSettings: {serviceName: "gRPC"}}')
        else
            stream_settings=$(jq -n '{network: "grpc", security: "none", grpcSettings: {serviceName: "gRPC"}}')
        fi
    elif [ "$network" == "vision" ]; then
        stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
            '{network: "tcp", security: "tls", tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}], minVersion: "1.2", allowInsecure: true}, tcpSettings: {header: {type: "none"}}}')
    else 
        if [ "$use_tls" = "true" ]; then
             stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                '{network: "tcp", security: "tls", tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}]}}')
        else
             stream_settings=$(jq -n '{network: "tcp", security: "none"}')
        fi
    fi

    jq -n --argjson stream "$stream_settings" --arg port "$port" --arg api "$api_port" \
      '{
          log: {loglevel: "warning"}, 
          api: {services: ["HandlerService", "LoggerService", "StatsService"], tag: "api"}, 
          inbounds: [
            {tag: "api", port: ($api | tonumber), protocol: "dokodemo-door", settings: {address: "127.0.0.1"}, listen: "127.0.0.1"}, 
            {tag: "inbound-dragoncore", port: ($port | tonumber), protocol: "vless", settings: {clients: [], decryption: "none", fallbacks: []}, streamSettings: $stream}
          ], 
          outbounds: [{protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "blocked"}], 
          routing: {domainStrategy: "AsIs", rules: [{type: "field", inboundTag: ["api"], outboundTag: "api"}]}
      }' > "$CONFIG_PATH"

    if [ "$network" == "vision" ]; then
        jq '(.inbounds[] | select(.tag == "inbound-dragoncore").settings) += {"flow": "xtls-rprx-vision"}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi

    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
        echo "✅ Config Xray aplicada com sucesso!"
        echo "   - Protocolo: $network"
        echo "   - Porta Pub: $port"
        echo "   - Porta Int: $api_port"
        echo "   - TLS: $use_tls"
        echo "   - Host: $domain"
    else
        echo "❌ ERRO: Xray falhou ao iniciar."
        journalctl -u xray -n 10 --no-pager
    fi
}

func_add_user() {
    local nick="$1"
    local expiry_days=${2:-30} 
    if [ -z "$nick" ]; then echo "❌ Erro: Nome vazio."; return 1; fi
    if [ ! -f "$CONFIG_PATH" ]; then echo "❌ Erro: Xray não configurado."; return 1; fi

    local port=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").port' "$CONFIG_PATH")
    local net=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.network' "$CONFIG_PATH")
    local sec=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.security' "$CONFIG_PATH")
    local domain=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.tlsSettings.serverName // empty' "$CONFIG_PATH")
    
    if [ -z "$domain" ]; then
        domain=$(curl -s icanhazip.com)
    fi

    local uuid=$(uuidgen)
    local expiry=$(date -d "+$expiry_days days" +%F)

    jq --arg uuid "$uuid" --arg nick_arg "$nick" \
       '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) += [{"id": $uuid, "email": $nick_arg, "level": 0}]' \
       "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    db_query "INSERT INTO xray (uuid, nick, expiry, protocol, domain) VALUES ('$uuid', '$nick', '$expiry', '$net', '$domain')"
    systemctl restart xray 2>/dev/null
    
    echo "✅ Usuário criado: $nick (Expira: $expiry)"
    echo "UUID: $uuid"
    
    # --- GERADOR DE LINK ---
    local link=""
    local path_encoded="%2F" 
    
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
    if [ ! -f "$CONFIG_PATH" ]; then echo "❌ Xray não configurado."; return; fi
    echo "========================================="
    echo "📋 LISTA DE USUÁRIOS"
    echo "========================================="
    while IFS='|' read -r id nick uuid expiry; do
        echo "🆔 ID: $id | 👤 Usuário: $nick | 📅 Expira: $expiry | 🔑 UUID: $uuid"
    done < <(db_query "SELECT id, nick, uuid, expiry FROM xray ORDER BY id")
    echo ""; read -rp "Pressione ENTER para voltar ao menu..."
}

func_purge_expired() {
    local today=$(date +%F)
    local expired_uuids=$(db_query "SELECT uuid FROM xray WHERE expiry < '$today'")
    for uuid in $expired_uuids; do func_remove_user "$uuid"; done
}

func_uninstall_xray() {
    echo "========================================="
    echo "⚠️  DESINSTALAÇÃO COMPLETA"
    echo "========================================="
    read -rp "Digite 'SIM' para confirmar: " confirm
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
    echo "========================================="
    echo "🛠️  Configuração Avançada do Xray"
    echo "========================================="
    
    # 1. Instalar Binário?
    read -rp "Deseja instalar/atualizar o Xray Core? (s/n): " install_opt
    if [[ "$install_opt" =~ ^[Ss]$ ]]; then
        func_install_official_core
    fi

    # 2. TLS/SSL?
    echo "-----------------------------------------"
    echo "Deseja usar criptografia TLS/SSL (HTTPS)?"
    echo "1) SIM - Requer domínio (Recomendado)"
    echo "2) NÃO - Conexão simples (Pode usar IP)"
    read -rp "Opção [1/2]: " tls_opt
    
    local use_tls="false"
    if [ "$tls_opt" == "1" ]; then use_tls="true"; fi

    # 3. Porta Interna
    echo "-----------------------------------------"
    read -rp "Digite a porta interna do Xray [Padrão 1080]: " api_port
    if [ -z "$api_port" ]; then api_port="1080"; fi

    # 4. Porta de Conexão
    echo "-----------------------------------------"
    read -rp "Digite a porta de conexão pública (Ex: 443, 80, 8080): " pub_port
    if [ -z "$pub_port" ]; then pub_port="80"; fi

    # 5. Domínio / IP
    echo "-----------------------------------------"
    local domain_val=""
    if [ "$use_tls" == "true" ]; then
        echo "⚠️  Como você escolheu TLS, o DOMÍNIO É OBRIGATÓRIO."
        read -rp "Digite seu domínio (Ex: vpn.meusite.com): " domain_val
        if ! func_check_domain_ip "$domain_val"; then return; fi
        func_xray_cert "$domain_val" # Gera cert imediatamente
        if ! func_check_cert; then echo "❌ Erro no certificado. Abortando."; return; fi
    else
        echo "ℹ️  Modo sem TLS. Pode usar IP ou Domínio."
        read -rp "Digite o Domínio ou IP (Enter para Auto-Detectar): " domain_val
        if [ -z "$domain_val" ]; then domain_val=$(curl -s icanhazip.com); fi
    fi
    echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"

    # 6. Protocolo
    echo "-----------------------------------------"
    echo "Selecione o Protocolo:"
    echo "1. ws (WebSocket)"
    echo "2. grpc (gRPC)"
    echo "3. xhttp (HTTP/2)"
    echo "4. tcp (Simples)"
    if [ "$use_tls" == "true" ]; then
        echo "5. vision (XTLS-Vision) - 🚀"
    fi
    echo "0. Cancelar"
    read -rp "Opção: " prot_opt
    
    local selected_net=""
    case "$prot_opt" in
        1) selected_net="ws" ;;
        2) selected_net="grpc" ;;
        3) selected_net="xhttp" ;;
        4) selected_net="tcp" ;;
        5) 
            if [ "$use_tls" == "true" ]; then selected_net="vision"; 
            else echo "❌ Vision requer TLS."; return; fi 
            ;;
        0) return ;;
        *) echo "❌ Inválido."; return ;;
    esac

    # FINALIZAR
    func_generate_config "$pub_port" "$selected_net" "$domain_val" "$api_port" "$use_tls"
}

# --- MENU ---
menu_display() {
    clear
    echo "⚡ DragonCore Xray Manager"
    echo "1. Criar Usuário"
    echo "2. Remover Usuário"
    echo "3. Listar Usuários"
    echo "4. Instalar e Configurar Xray (Assistente)"
    echo "5. Limpar Expirados"
    echo "6. Desinstalar (Completo)"
    echo "0. Sair"
    read -rp "Opção: " choice
}

if [ -z "$1" ]; then
    while true; do
        menu_display
        case "$choice" in
            1) 
                while true; do
                    echo "-----------------------------------------"; read -rp "Nome de usuário (ou 0 para voltar): " n
                    if [ "$n" == "0" ] || [ -z "$n" ]; then break; fi
                    check_exists=$(db_query "SELECT id FROM xray WHERE nick = '$n' LIMIT 1")
                    if [ -n "$check_exists" ]; then echo "❌ ERRO: O usuário '$n' JÁ EXISTE!"; continue; fi
                    read -rp "Digite os dias: " d; [ -z "$d" ] && d=30; func_add_user "$n" "$d"; break 
                done ;;
            2) read -rp "ID/UUID: " i; func_remove_user "$i" ;;
            3) func_list_users ;;
            4) func_wizard_install ;;
            5) func_purge_expired ;;
            6) func_uninstall_xray ;; 
            0) exit 0 ;;
        esac
        [ "$choice" != "0" ] && [ "$choice" != "3" ] && read -rp "Enter para voltar..."
    done
else "$1" "${@:2}"; 
fi
