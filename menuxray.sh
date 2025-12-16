#!/bin/bash
# menuxray.sh - Menu Interativo e Lógica Xray (Backend e Frontend)

# --- Variáveis de Ambiente (Preenchidas pelo instalador) ---
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
DOMAIN_FILE="$XRAY_DIR/active_domain"
PROTOCOL_FILE="$XRAY_DIR/active_protocol" # Novo arquivo para salvar o protocolo padrão

# Variável de Senha para psql
export PGPASSWORD=$DB_PASS

# --- FUNÇÕES DE LÓGICA (DB e Xray) ---

db_query() {
    psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$1" 2>/dev/null
}

func_create_db_table() {
    local sql="CREATE TABLE IF NOT EXISTS xray (id SERIAL PRIMARY KEY, uuid TEXT, nick TEXT, expiry DATE, protocol TEXT, domain TEXT);"
    db_query "$sql"
    if [ $? -eq 0 ]; then echo "✅ Tabela verificada/criada."; else echo "❌ ERRO: Falha ao acessar o DB."; fi
}

func_is_installed() { [ -f "$XRAY_BIN" ] || [ -f "/usr/bin/xray" ]; }

# FUNÇÃO PARA SELECIONAR PROTOCOLO POR NÚMEROS
func_select_protocol() {
    clear
    echo "========================================="
    echo "⚙️  Seleção de Protocolo de Transporte"
    echo "========================================="
    echo "1. ws (WebSocket) - Boa Compatibilidade"
    echo "2. grpc (gRPC) - ✅ RECOMENDADO: Alto Desempenho e Resiliência"
    echo "3. xhttp (TCP c/ Camuflagem) - Alternativa ao WS"
    echo "4. tcp (TCP Simples) - APENAS para testes/fallback"
    echo "5. vision (XTLS-Vision) - 🚀 Mais Avançado (Requer Certificado TLS/Domínio)"
    echo "0. Cancelar"
    echo "-----------------------------------------"
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
        echo "=========================================================================="
        echo "❌ AVISO CRÍTICO: Certificado TLS Ausente!"
        echo "O protocolo '$1' (XTLS-Vision ou XHTTP) **REQUER** um certificado TLS."
        echo "Por favor, use a **Opção 5** para gerar o certificado TLS."
        echo "=========================================================================="
        return 1
    fi
    return 0
}

func_check_domain_ip() {
    local domain="$1"
    local vps_ip=$(curl -s icanhazip.com)
    if [ -z "$domain" ]; then
        echo "❌ Domínio não pode ser vazio."
        return 1
    fi

    local domain_ip=$(dig +short "$domain" | head -n 1)

    if [ -z "$domain_ip" ]; then
        echo "❌ Erro ao resolver o domínio '$domain'. Verifique se ele está ativo."
        return 1
    fi
    
    if [ "$domain_ip" != "$vps_ip" ]; then
        echo "=========================================================================="
        echo "❌ ERRO DE APONTAMENTO: O IP resolvido para $domain ($domain_ip) "
        echo "não corresponde ao IP público desta VPS ($vps_ip)."
        echo "Corrija o registro A/AAAA do seu DNS e tente novamente."
        echo "=========================================================================="
        return 1
    fi

    echo "✅ Domínio '$domain' resolvido e apontando corretamente para o IP da VPS."
    return 0
}

func_generate_config() {
    local port=${1:-443}
    local network=${2:-ws}
    local domain="$3"
    local stream_settings=""

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -le 0 ] || [ "$port" -gt 65535 ]; then port=443; fi
    case "$network" in ws|xhttp|grpc|tcp|vision) ;; *) network="ws" ;; esac
    
    # 1. Checagens de Requisito
    if [ "$network" == "vision" ] || [ "$network" == "xhttp" ]; then
        if ! func_check_cert "$network"; then return 1; fi
        if ! func_check_domain_ip "$domain"; then return 1; fi
    fi

    mkdir -p "$(dirname "$CONFIG_PATH")"
    
    # 2. Gerar Stream Settings
    if [ "$network" == "xhttp" ]; then
        stream_settings=$(cat <<EOF
            {
                "network": "xhttp", "security": "tls",
                "tlsSettings": {
                    "serverName": "$domain",
                    "certificates": [{"certificateFile": "$CRT_FILE", "keyFile": "$KEY_FILE"}],
                    "alpn": ["http/1.1"]
                },
                "xhttpSettings": {"path": "/", "scMaxBufferedPosts": 30, "scMaxEachPostBytes": "1000000", "scStreamUpServerSecs": "20-80", "xPaddingBytes": "100-1000"}
            }
EOF
        )
    elif [ "$network" == "ws" ]; then
        stream_settings=$(cat <<EOF
            {
                "network": "ws", "security": "none",
                "wsSettings": {"acceptProxyProtocol": false, "path": "/"}
            }
EOF
        )
    elif [ "$network" == "grpc" ]; then
        stream_settings=$(cat <<EOF
            {
                "network": "grpc", "security": "none",
                "grpcSettings": {"serviceName": "gRPC"}
            }
EOF
        )
    elif [ "$network" == "vision" ]; then
        # XTLS-Vision (TCP + TLS + Flow Control)
        stream_settings=$(cat <<EOF
            {
                "network": "tcp", "security": "tls",
                "tlsSettings": {
                    "serverName": "$domain",
                    "certificates": [{"certificateFile": "$CRT_FILE", "keyFile": "$KEY_FILE"}],
                    "minVersion": "1.2", "allowInsecure": true
                },
                "tcpSettings": {"header": {"type": "none"}},
                "realitySettings": null
            }
EOF
        )
    else # tcp (TCP Simples)
        stream_settings='{ "network": "tcp", "security": "none" }'
    fi

    # 3. Gerar Config.json
    jq -n --argjson streamSettings "$stream_settings" --arg port "$port" --arg network "$network" '
{
  "api": { "services": [ "HandlerService", "LoggerService", "StatsService" ], "tag": "api" },
  "inbounds": [
    { "tag": "api", "port": 1080, "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" }, "listen": "127.0.0.1" },
    {
      "tag": "inbound-dragoncore", "port": ($port | tonumber), "protocol": "vless",
      "settings": { 
          "clients": [], 
          "decryption": "none", 
          "fallbacks": [],
          "flow": ($network == "vision" ? "xtls-rprx-vision" : "")
      },
      "streamSettings": $stream_settings
    }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }, { "protocol": "blackhole", "tag": "blocked" }],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "inboundTag": ["api"], "outboundTag": "api" },
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "blocked" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked" }
    ]
  },
  "stats": {}
}' > "$CONFIG_PATH"

    # 4. Salvar Configurações Padrão
    echo "$domain" > "$DOMAIN_FILE"
    echo "$network" > "$PROTOCOL_FILE"
    
    # 5. Reiniciar Xray
    systemctl restart xray 2>/dev/null
    
    echo "✅ Config Xray salvo (Porta $port, Protocolo $network, Domínio $domain)"
    echo "🔔 Estas configurações (Porta: $port, Protocolo: $network) agora são o PADRÃO para novos usuários."
}

func_add_user() {
    local nick="$1"
    local expiry_days=${2:-30} # Novo: aceitar validade em dias
    
    if [ -z "$nick" ]; then echo "Erro: Nick necessário."; return; fi
    if [ ! -f "$CONFIG_PATH" ]; then echo "Erro: Configure o Xray Core (Opção 6) primeiro."; return; fi

    local domain=$(cat "$DOMAIN_FILE" 2>/dev/null)
    local protocol=$(cat "$PROTOCOL_FILE" 2>/dev/null)
    
    if [ -z "$protocol" ] || [ -z "$domain" ]; then 
        echo "❌ Erro: Configurações padrão (Domínio/Protocolo) ausentes. Configure o Xray Core (Opção 6) primeiro."; 
        return; 
    fi

    local uuid=$(uuidgen)
    local expiry=$(date -d "+$expiry_days days" +%F)

    jq --arg uuid "$uuid" --arg nick_arg "$nick" \
       '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) += [{"id": $uuid, "email": $nick_arg, "level": 0}]' \
       "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    db_query "INSERT INTO xray (uuid, nick, expiry, protocol, domain) VALUES ('$uuid', '$nick', '$expiry', '$protocol', '$domain')"
    systemctl restart xray 2>/dev/null

    local port=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").port' "$CONFIG_PATH" 2>/dev/null)
    
    echo "✅ Usuário criado: $nick"
    echo "UUID: $uuid"
    echo "PROTOCOLO: $protocol (Padrão)"
    echo "EXPIRA EM: $expiry"
    
    # URI Format based on protocol (VLESS is the base)
    if [ "$protocol" == "grpc" ]; then
        echo "URI gRPC: vless://${uuid}@${domain}:${port}?type=grpc&serviceName=gRPC&security=none#${nick}"
    elif [ "$protocol" == "ws" ]; then
        echo "URI WS: vless://${uuid}@${domain}:${port}?type=ws&path=/&security=none#${nick}"
    elif [ "$protocol" == "xhttp" ]; then
        echo "URI XHTTP: vless://${uuid}@${domain}:${port}?type=http&security=tls#${nick}"
    elif [ "$protocol" == "vision" ]; then
        # XTLS-Vision URI
        echo "URI VISION: vless://${uuid}@${domain}:${port}?security=tls&flow=xtls-rprx-vision#${nick}"
    else # tcp
        echo "URI TCP: vless://${uuid}@${domain}:${port}#${nick}"
    fi
}

func_remove_user() {
    local identifier="$1"
    local uuid=""
    # Busca por ID ou UUID
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then uuid=$(db_query "SELECT uuid FROM xray WHERE id = $identifier");
    else uuid=$(db_query "SELECT uuid FROM xray WHERE uuid = '$identifier'"); fi
    
    if [ -z "$uuid" ]; then echo "❌ Usuário não encontrado."; return; fi

    jq --arg uuid "$uuid" \
       '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(select(.id != $uuid))' \
       "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    db_query "DELETE FROM xray WHERE uuid = '$uuid'"
    systemctl restart xray 2>/dev/null
    echo "✅ Usuário removido: $uuid"
}

func_list_users() {
    echo "--- Lista de Usuários Xray ---"
    db_query "SELECT 'ID: ' || id || ' | NICK: ' || nick || ' | EXPIRA: ' || expiry || ' | PROTO: ' || protocol || ' | DOMÍNIO: ' || domain FROM xray ORDER BY id"
    echo "-------------------------------"
}

func_info() {
    local ver="Desconhecido"
    if func_is_installed; then ver=$($XRAY_BIN -version 2>&1 | head -n1 | awk '{print $2}'); fi
    local count=$(db_query "SELECT COUNT(*) FROM xray")
    local protocols=$(cat "$PROTOCOL_FILE" 2>/dev/null || echo "Nenhum")
    local domain=$(cat "$DOMAIN_FILE" 2>/dev/null || echo "Nenhum")
    echo "--- Status do Sistema Xray ---"
    echo "Versão do Binário: $ver"
    echo "Total de Usuários: $count"
    echo "PROTOCOLO PADRÃO: $protocols"
    echo "DOMÍNIO PADRÃO: $domain"
    echo "-------------------------------"
}

func_xray_cert() {
    local domain="$1"
    if [ -z "$domain" ]; then echo "Erro: Informe o domínio FQDN."; return 1; fi
    
    if ! func_check_domain_ip "$domain"; then return 1; fi

    mkdir -p "$SSL_DIR"
    openssl req -x509 -nodes -newkey rsa:2048 -days 9999 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=DragonCore/OU=VPN/CN=$domain" \
        -keyout "$KEY_FILE" -out "$CRT_FILE" 2>/dev/null
    
    if [ -f "$KEY_FILE" ] && [ -f "$CRT_FILE" ]; then 
        echo "✅ Certificado TLS autoassinado gerado com sucesso para $domain"
        return 0
    else 
        echo "❌ Falha ao gerar certificado."
        return 1
    fi
}

func_purge_expired() {
    local today=$(date +%F)
    local expired_uuids=$(db_query "SELECT uuid FROM xray WHERE expiry < '$today'")
    if [ -z "$expired_uuids" ]; then echo "Nenhum usuário expirado encontrado."; return; fi
    for uuid in $expired_uuids; do func_remove_user "$uuid"; done
    echo "✅ Purge concluído."
}

# --- FUNÇÃO DE DESINSTALAÇÃO GERAL (omissão por brevidade) ---

func_uninstall_xray() {
    # ... (Código da desinstalação omitido por brevidade)
    echo "Desinstalação omitida. Use o código anterior completo para desinstalar."
    return
}


# --- FUNÇÃO DE MENU XRAY (Interface do Usuário) ---
menu_display() {
    clear
    echo "========================================="
    echo "⚡ Gerenciamento Xray Core"
    echo "========================================="
    func_info
    echo "-----------------------------------------"

    echo "1. Criar Usuário Xray (Padrão: 30 dias)"
    echo "2. Remover Usuário Xray"
    echo "3. Listar Usuários Xray"
    echo "5. Gerar Certificado TLS (Autoassinado e Checagem DNS)"
    echo "6. **Configurar Xray Core (Porta, Protocolo e Domínio PADRÃO)**"
    echo "8. Limpar Usuários Expirados (Purge)"
    
    echo "-----------------------------------------"
    echo "9. **Desinstalar Xray e Scripts**"
    echo "0. Sair do Menu"
    echo "-----------------------------------------"
    read -rp "Digite sua opção: " choice
}

# --- LOOP PRINCIPAL OU EXECUÇÃO CLI ---
if [ -z "$1" ]; then
    while true; do
        menu_display
        
        case "$choice" in
            1) 
                read -rp "Nome do usuário > " nick 
                read -rp "Validade em dias [30] > " expiry_days; [ -z "$expiry_days" ] && expiry_days=30
                
                # Usa o protocolo e domínio PADRÃO salvos
                func_add_user "$nick" "$expiry_days" 
                ;;
            2) read -rp "ID ou UUID para remover > " identifier; func_remove_user "$identifier" ;;
            3) func_list_users ;;
            5) 
                read -rp "Domínio FQDN (ex: vpn.seudominio.com) > " domain 
                func_xray_cert "$domain"
                ;;
            6) 
                # NOVO FLUXO: Coleta de Domínio, Porta e Protocolo
                
                # 1. Porta
                read -rp "Porta do inbound [443] > " p; [ -z "$p" ] && p=443
                
                # 2. Domínio
                read -rp "Domínio FQDN apontando para este IP > " domain
                if [ -z "$domain" ]; then 
                    echo "❌ Configuração abortada: Domínio é obrigatório."; 
                    read -rp "Pressione ENTER para retornar ao menu principal..."; 
                    continue; 
                fi

                # 3. Protocolo (Menu Numérico)
                proto_result=$(func_select_protocol)
                if [ "$proto_result" == "cancel" ] || [ "$proto_result" == "invalid" ]; then continue; fi
                
                # 4. Checagens e Configuração
                func_create_db_table
                func_generate_config "$p" "$proto_result" "$domain"
                ;;
            8) func_purge_expired ;;
            9) func_uninstall_xray ;; 
            0) echo "Saindo. Até logo!"; exit 0 ;;
            *) echo "Opção inválida. Tente novamente." ;;
        esac
        if [ "$choice" != "0" ] && [ "$choice" != "9" ]; then read -rp "Pressione ENTER para voltar ao menu..."; fi
    done
else
    "$1" "${@:2}"
fi
