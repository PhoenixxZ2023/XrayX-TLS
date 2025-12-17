#!/bin/bash
# menuxray.sh - Versão: Suporte Automático a Bug Host/SNI

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
BUG_HOST_FILE="$XRAY_DIR/bughost" 

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
    echo "📥 Instalando/Atualizando Xray Core (Oficial)"
    echo "========================================="
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    if [ $? -eq 0 ]; then
        echo "✅ Xray Core instalado com sucesso!"
    else
        echo "❌ Falha ao baixar/instalar Xray Core."
        read -rp "Pressione ENTER para continuar mesmo assim..."
    fi
}

func_select_protocol() {
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
    
    # Se o IP for diferente, avisa mas permite (pode ser Cloudflare ou Bug Host intencional)
    if [ "$domain_ip" != "$vps_ip" ]; then
        echo "⚠️  AVISO: O IP do domínio ($domain_ip) é diferente do IP desta VPS ($vps_ip)."
        echo "Isso pode ser normal se usar Cloudflare Proxy."
        read -rp "Deseja continuar? (s/n): " confirm
        [[ "$confirm" != "s" ]] && return 1
    fi
    echo "✅ Domínio verificado."
    return 0
}

func_xray_cert() {
    local domain="$1"
    if [ -z "$domain" ]; then echo "Erro: Domínio necessário."; return 1; fi
    if ! func_check_domain_ip "$domain"; then return 1; fi
    
    mkdir -p "$SSL_DIR"
    
    echo "Gerando certificado autoassinado para $domain..."
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=DragonCore/OU=VPN/CN=$domain" \
        -keyout "$KEY_FILE" -out "$CRT_FILE" 2>/dev/null
    
    chmod 755 "$SSL_DIR"
    chmod 644 "$KEY_FILE"
    chmod 644 "$CRT_FILE"

    if [ -f "$KEY_FILE" ]; then
        echo "✅ Certificado gerado e permissões ajustadas."
    else
        echo "❌ Falha ao gerar certificado."
        return 1
    fi
}

func_generate_config() {
    local port=${1:-443}
    local network=${2:-ws}
    local domain="$3"
    
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -le 0 ] || [ "$port" -gt 65535 ]; then port=443; fi

    mkdir -p "$(dirname "$CONFIG_PATH")"
    
    if [ -d "$SSL_DIR" ]; then
        chmod 755 "$SSL_DIR"
        chmod 644 "$SSL_DIR"/* 2>/dev/null
    fi

    local stream_settings=""
    
    if [ "$network" == "xhttp" ]; then
        stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
            '{
                network: "xhttp", security: "tls",
                tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}], alpn: ["h2", "http/1.1"]},
                xhttpSettings: {path: "/", scMaxBufferedPosts: 30}
            }')
    elif [ "$network" == "ws" ]; then
        stream_settings=$(jq -n \
            '{
                network: "ws", security: "none",
                wsSettings: {acceptProxyProtocol: false, path: "/"}
            }')
    elif [ "$network" == "grpc" ]; then
        stream_settings=$(jq -n \
            '{
                network: "grpc", security: "none",
                grpcSettings: {serviceName: "gRPC"}
            }')
    elif [ "$network" == "vision" ]; then
        stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
            '{
                network: "tcp", 
                security: "tls",
                tlsSettings: {
                    serverName: $dom, 
                    certificates: [{certificateFile: $crt, keyFile: $key}], 
                    minVersion: "1.2", 
                    allowInsecure: true
                },
                tcpSettings: {
                    header: {type: "none"}
                }
            }')
    else 
        stream_settings=$(jq -n '{network: "tcp", security: "none"}')
    fi

    jq -n --argjson stream "$stream_settings" --arg port "$port" \
      '{
          log: {loglevel: "warning"}, 
          api: {services: ["HandlerService", "LoggerService", "StatsService"], tag: "api"}, 
          inbounds: [
            {tag: "api", port: 1080, protocol: "dokodemo-door", settings: {address: "127.0.0.1"}, listen: "127.0.0.1"}, 
            {tag: "inbound-dragoncore", port: ($port | tonumber), protocol: "vless", settings: {clients: [], decryption: "none", fallbacks: []}, streamSettings: $stream}
          ], 
          outbounds: [{protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "blocked"}], 
          routing: {domainStrategy: "AsIs", rules: [{type: "field", inboundTag: ["api"], outboundTag: "api"}]}
      }' > "$CONFIG_PATH"

    if [ "$network" == "vision" ]; then
        jq '(.inbounds[] | select(.tag == "inbound-dragoncore").settings) += {"flow": "xtls-rprx-vision"}' \
           "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi

    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
        echo "✅ Config Xray aplicada com sucesso!"
        echo "   - Protocolo: $network"
        echo "   - Porta: $port"
        echo "   - Domínio: $domain"
    else
        echo "❌ ERRO: Xray falhou ao iniciar. Verifique permissões ou log."
        journalctl -u xray -n 10 --no-pager
    fi
}

func_add_user() {
    local nick="$1"
    local expiry_days=${2:-30} 
    
    if [ -z "$nick" ]; then echo "❌ Erro: O nome de usuário não pode ser vazio."; return 1; fi
    if [ ! -f "$CONFIG_PATH" ]; then echo "❌ Erro: Xray não configurado."; return 1; fi

    local port=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").port' "$CONFIG_PATH")
    local net=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.network' "$CONFIG_PATH")
    local sec=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.security' "$CONFIG_PATH")
    
    local domain=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.tlsSettings.serverName // empty' "$CONFIG_PATH")
    if [ -z "$domain" ]; then
        domain=$(cat "$ACTIVE_DOMAIN_FILE" 2>/dev/null)
        if [ -z "$domain" ]; then domain=$(curl -s icanhazip.com); fi
    fi
    
    # --- LOGICA DE BUG HOST AUTOMÁTICO ---
    # Verifica se existe um bug host configurado
    local bughost_saved=$(cat "$BUG_HOST_FILE" 2>/dev/null)
    local final_addr="$domain"
    local final_sni="$domain"
    
    if [ -n "$bughost_saved" ]; then
        # Se tiver bug host salvo, o Endereço e o SNI viram o Bug Host
        final_addr="$bughost_saved"
        final_sni="$bughost_saved"
        # O "host=" continua sendo o $domain (real) para roteamento interno
    fi
    # -------------------------------------

    local uuid=$(uuidgen)
    local expiry=$(date -d "+$expiry_days days" +%F)

    jq --arg uuid "$uuid" --arg nick_arg "$nick" \
       '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) += [{"id": $uuid, "email": $nick_arg, "level": 0}]' \
       "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    db_query "INSERT INTO xray (uuid, nick, expiry, protocol, domain) VALUES ('$uuid', '$nick', '$expiry', '$net', '$domain')"
    systemctl restart xray 2>/dev/null
    
    echo "✅ Usuário criado: $nick (Expira: $expiry)"
    echo "UUID: $uuid"
    
    # --- GERADOR DE LINK (Com suporte a BugHost) ---
    local link=""
    local path_encoded="%2F" 
    
    if [ "$net" == "grpc" ]; then
        local serviceName=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.grpcSettings.serviceName' "$CONFIG_PATH")
        link="vless://${uuid}@${final_addr}:${port}?security=${sec}&encryption=none&type=grpc&serviceName=${serviceName}&sni=${final_sni}#${nick}"
    
    elif [ "$net" == "ws" ]; then
        local path=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.wsSettings.path' "$CONFIG_PATH")
        if [ "$path" == "/" ]; then path="%2F"; fi
        # WS geralmente precisa do Host Real no header 'host' se estiver usando CDN, ou Bug se for direto
        # Pela sua regra: Host HTTP = Dominio Real
        link="vless://${uuid}@${final_addr}:${port}?path=${path}&security=${sec}&encryption=none&host=${domain}&type=ws&sni=${final_sni}#${nick}"
    
    elif [ "$net" == "xhttp" ]; then
        local path=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.xhttpSettings.path' "$CONFIG_PATH")
        if [ "$path" == "/" ]; then path="%2F"; fi
        # XHTTP: Address=Bug, SNI=Bug, Host=Real
        link="vless://${uuid}@${final_addr}:${port}?mode=auto&path=${path}&security=tls&encryption=none&host=${domain}&type=xhttp&sni=${final_sni}#${nick}"
    
    elif [ "$net" == "tcp" ] && [ "$sec" == "tls" ]; then
        # Vision (Cuidado: Vision geralmente precisa de SNI real, mas se for spoofing...)
        local flow=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").settings.flow // empty' "$CONFIG_PATH")
        if [ "$flow" == "xtls-rprx-vision" ]; then
            link="vless://${uuid}@${final_addr}:${port}?security=tls&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=${final_sni}#${nick}"
        else
            link="vless://${uuid}@${final_addr}:${port}?security=tls&encryption=none&type=tcp&sni=${final_sni}#${nick}"
        fi
    else 
        link="vless://${uuid}@${final_addr}:${port}?security=none&encryption=none&type=tcp#${nick}"
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
    
    # 1. Carrega configs globais para remontar os links
    local port=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").port' "$CONFIG_PATH")
    local sec=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.security' "$CONFIG_PATH")
    local ws_path=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.wsSettings.path // "/"' "$CONFIG_PATH")
    local grpc_service=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.grpcSettings.serviceName // ""' "$CONFIG_PATH")
    local xhttp_path=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.xhttpSettings.path // "/"' "$CONFIG_PATH")
    local flow=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").settings.flow // empty' "$CONFIG_PATH")
    
    local bughost=$(cat "$BUG_HOST_FILE" 2>/dev/null)

    echo "========================================="
    echo "📋 LISTA COMPLETA DE USUÁRIOS"
    echo "========================================="

    # Loop para ler cada usuário do banco
    while IFS='|' read -r id nick uuid expiry protocol domain; do
        
        # Lógica de BugHost
        local final_addr="$domain"
        local final_sni="$domain"
        if [ -n "$bughost" ]; then final_addr="$bughost"; final_sni="$bughost"; fi
        
        local link=""
        local path_encoded="%2F"

        # Reconstrói o link
        if [ "$protocol" == "grpc" ]; then
            link="vless://${uuid}@${final_addr}:${port}?security=${sec}&encryption=none&type=grpc&serviceName=${grpc_service}&sni=${final_sni}#${nick}"
        elif [ "$protocol" == "ws" ]; then
            if [ "$ws_path" != "/" ]; then path_encoded="$ws_path"; fi
            link="vless://${uuid}@${final_addr}:${port}?path=${path_encoded}&security=${sec}&encryption=none&host=${domain}&type=ws&sni=${final_sni}#${nick}"
        elif [ "$protocol" == "xhttp" ]; then
            if [ "$xhttp_path" != "/" ]; then path_encoded="$xhttp_path"; fi
            link="vless://${uuid}@${final_addr}:${port}?mode=auto&path=${path_encoded}&security=tls&encryption=none&host=${domain}&type=xhttp&sni=${final_sni}#${nick}"
        elif [ "$protocol" == "tcp" ] || [ "$protocol" == "vision" ]; then
             if [ "$flow" == "xtls-rprx-vision" ] && [ "$sec" == "tls" ]; then
                link="vless://${uuid}@${final_addr}:${port}?security=tls&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=${final_sni}#${nick}"
             else
                link="vless://${uuid}@${final_addr}:${port}?security=${sec}&encryption=none&type=tcp&sni=${final_sni}#${nick}"
             fi
        fi

        echo "🆔 ID: $id | Usuário: $nick | Exp: $expiry"
        echo "🔑 UUID: $uuid"
        echo "🔗 $link"
        echo "-----------------------------------------"
        
    done < <(db_query "SELECT id, nick, uuid, expiry, protocol, domain FROM xray ORDER BY id")
    
    # Pausa para leitura
    echo ""
    read -rp "Pressione ENTER para voltar ao menu..."
}

func_purge_expired() {
    local today=$(date +%F)
    local expired_uuids=$(db_query "SELECT uuid FROM xray WHERE expiry < '$today'")
    for uuid in $expired_uuids; do func_remove_user "$uuid"; done
}

func_uninstall_xray() {
    echo "========================================="
    echo "⚠️  DESINSTALAÇÃO COMPLETA (Deep Clean)"
    echo "========================================="
    echo "Isso removerá:"
    echo " - Serviço Xray e binários"
    echo " - Todas as configurações e certificados"
    echo " - Banco de Dados '$DB_NAME' e Usuário '$DB_USER'"
    echo " - Cronjobs e atalhos"
    echo "-----------------------------------------"
    read -rp "Digite 'SIM' para confirmar: " confirm
    
    if [ "$confirm" != "SIM" ]; then echo "❌ Cancelado."; return; fi

    echo "1. Parando serviços..."
    systemctl stop xray 2>/dev/null
    systemctl disable xray 2>/dev/null
    
    echo "2. Removendo Xray Core..."
    rm -f /usr/local/bin/xray
    rm -rf /usr/local/etc/xray
    rm -rf /usr/local/share/xray
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/xray@.service
    systemctl daemon-reload

    echo "3. Limpando Script..."
    rm -rf "$XRAY_DIR"
    rm -rf "$SSL_DIR"
    rm -f /bin/xray-menu
    (crontab -l | grep -v "func_purge_expired") | crontab -

    echo "4. Removendo Banco de Dados..."
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME;" >/dev/null 2>&1
    sudo -u postgres psql -c "DROP USER IF EXISTS $DB_USER;" >/dev/null 2>&1
    
    echo "✅ Desinstalação Completa! O sistema está limpo."
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
    echo "6. Instalar e Configurar Xray Core"
    echo "8. Limpar Expirados"
    echo "9. Desinstalar (Completo)"
    echo "0. Sair"
    read -rp "Opção: " choice
}

if [ -z "$1" ]; then
    while true; do
        menu_display
        case "$choice" in
            1) 
                while true; do
                    echo "-----------------------------------------"
                    read -rp "Nome de usuário (ou 0 para voltar): " n
                    if [ "$n" == "0" ] || [ -z "$n" ]; then break; fi
                    check_exists=$(db_query "SELECT id FROM xray WHERE nick = '$n' LIMIT 1")
                    if [ -n "$check_exists" ]; then
                        echo "❌ ERRO: O usuário '$n' JÁ EXISTE!"
                        continue 
                    fi
                    read -rp "Digite os dias: " d
                    [ -z "$d" ] && d=30
                    func_add_user "$n" "$d"
                    break 
                done
                ;;
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
                    
                    # --- NOVO: Configuração de BUG HOST ---
                    echo "-----------------------------------------"
                    echo "OPCIONAL: Deseja definir um BugHost/SNI padrão para os links?"
                    echo "Ex: m.ofertas.tim.com.br"
                    read -rp "Digite o BugHost (ou ENTER para usar conexão direta): " input_bughost
                    
                    if [ -n "$input_bughost" ]; then
                        echo "$input_bughost" > "$BUG_HOST_FILE"
                        echo "✅ BugHost definido: $input_bughost"
                    else
                        rm -f "$BUG_HOST_FILE"
                        echo "✅ Modo Direto (Sem BugHost)."
                    fi
                    # ----------------------------------------
                    
                    echo "-----------------------------------------"
                    read -rp "Deseja baixar/atualizar o binário Xray Oficial agora? (s/n): " install_now
                    if [[ "$install_now" =~ ^[Ss]$ ]]; then
                        func_install_official_core
                    fi
                    
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
