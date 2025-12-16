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

# Variável de Senha para psql
export PGPASSWORD=$DB_PASS

# --- FUNÇÕES DE LÓGICA (DB e Xray) ---

db_query() {
    psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$1" 2>/dev/null
}

func_create_db_table() {
    local sql="CREATE TABLE IF NOT EXISTS xray (id SERIAL PRIMARY KEY, uuid TEXT, nick TEXT, expiry DATE, protocol TEXT);"
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
    echo "5. vision (XTLS-Vision) - 🚀 Mais Avançado (Requer Certificado TLS)"
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
        echo "O protocolo '$1' (XTLS-Vision) **REQUER** um certificado TLS válido."
        echo "Por favor, retorne ao Menu Principal e use a **Opção 5** para gerar o certificado TLS autoassinado."
        echo "=========================================================================="
        return 1
    fi
    return 0
}

func_generate_config() {
    local port=${1:-443}
    local network=${2:-ws}
    local stream_settings=""

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -le 0 ] || [ "$port" -gt 65535 ]; then port=443; fi
    case "$network" in ws|xhttp|grpc|tcp|vision) ;; *) network="ws" ;; esac
    
    # Checagem de certificado para Vision antes de gerar a config
    if [ "$network" == "vision" ]; then
        if ! func_check_cert "XTLS-Vision"; then
            echo "❌ Configuração abortada. Gere o certificado primeiro."
            return 1
        fi
    fi

    mkdir -p "$(dirname "$CONFIG_PATH")"

    if [ "$network" == "xhttp" ]; then
        stream_settings=$(cat <<EOF
            {
                "network": "xhttp", "security": "tls",
                "tlsSettings": {
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

    systemctl restart xray 2>/dev/null
    echo "✅ Config Xray gerado em $CONFIG_PATH (Porta $port, Protocolo $network)"
}

func_add_user() {
    local nick="$1"
    local protocol="${2:-ws}"
    if [ -z "$nick" ]; then echo "Erro: Nick necessário."; return; fi
    if [ ! -f "$CONFIG_PATH" ]; then echo "Erro: Gere a configuração primeiro."; return; fi

    # Checagem de certificado para Vision antes de adicionar o usuário
    if [ "$protocol" == "vision" ]; then
        if ! func_check_cert "XTLS-Vision"; then
            echo "❌ Usuário não criado. Gere o certificado primeiro."
            return
        fi
    fi

    local uuid=$(uuidgen)
    local expiry=$(date -d "+30 days" +%F)

    jq --arg uuid "$uuid" --arg nick_arg "$nick" \
       '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) += [{"id": $uuid, "email": $nick_arg, "level": 0}]' \
       "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    db_query "INSERT INTO xray (uuid, nick, expiry, protocol) VALUES ('$uuid', '$nick', '$expiry', '$protocol')"
    systemctl restart xray 2>/dev/null

    local public_ip=$(curl -s icanhazip.com)
    if [ -z "$public_ip" ]; then
        local public_ip=$(hostname -I | awk '{print $1}')
        echo "⚠️ Aviso: Falha ao obter IP público externo. Usando IP interno/local: $public_ip"
    fi

    local domain="${public_ip}" 
    local port=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").port' "$CONFIG_PATH" 2>/dev/null)
    
    echo "✅ Usuário criado: $nick"
    echo "UUID: $uuid"
    echo "PROTOCOLO: $protocol"
    
    # URI Format based on protocol (VLESS is the base)
    if [ "$protocol" == "grpc" ]; then
        echo "URI gRPC: vless://${uuid}@${domain}:${port}?type=grpc&serviceName=gRPC#${nick}"
    elif [ "$protocol" == "ws" ]; then
        echo "URI WS: vless://${uuid}@${domain}:${port}?type=ws&path=/#${nick}"
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
    db_query "SELECT 'ID: ' || id || ' | NICK: ' || nick || ' | UUID: ' || uuid || ' | EXPIRA: ' || expiry || ' | PROTO: ' || protocol FROM xray ORDER BY id"
    echo "-------------------------------"
}

func_info() {
    local ver="Desconhecido"
    if func_is_installed; then ver=$($XRAY_BIN -version 2>&1 | head -n1 | awk '{print $2}'); fi
    local count=$(db_query "SELECT COUNT(*) FROM xray")
    local protocols=$(db_query "SELECT DISTINCT protocol FROM xray ORDER BY protocol" | tr '\n' ',' | sed 's/,$//')
    echo "--- Status do Sistema Xray ---"
    echo "Versão do Binário: $ver"
    echo "Total de Usuários: $count"
    echo "Protocolos em Uso: $protocols"
    echo "-------------------------------"
}

func_xray_cert() {
    local domain="$1"
    if [ -z "$domain" ]; then echo "Erro: Informe o domínio/IP."; return; fi
    mkdir -p "$SSL_DIR"
    openssl req -x509 -nodes -newkey rsa:2048 -days 9999 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=DragonCore/OU=VPN/CN=$domain" \
        -keyout "$KEY_FILE" -out "$CRT_FILE" 2>/dev/null
    if [ -f "$KEY_FILE" ] && [ -f "$CRT_FILE" ]; then echo "✅ Certificado TLS autoassinado gerado para $domain"; else echo "❌ Falha ao gerar certificado."; fi
}

func_purge_expired() {
    local today=$(date +%F)
    local expired_uuids=$(db_query "SELECT uuid FROM xray WHERE expiry < '$today'")
    if [ -z "$expired_uuids" ]; then echo "Nenhum usuário expirado encontrado."; return; fi
    for uuid in $expired_uuids; do func_remove_user "$uuid"; done
    echo "✅ Purge concluído."
}

# --- FUNÇÃO DE DESINSTALAÇÃO GERAL ---

func_uninstall_xray() {
    echo "========================================="
    echo "⚠️ DESINSTALAÇÃO COMPLETA DO XRAYX-TLS"
    echo "========================================="
    
    read -rp "Confirma a desinstalação de Xray, arquivos e DB? (S/N): " confirm
    if [[ ! "$confirm" =~ ^[Ss]$ ]]; then
        echo "❌ Desinstalação cancelada."
        return
    fi

    # 1. Parar e remover o serviço Xray
    echo "1. Removendo binário e serviço Xray Core..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove >/dev/null 2>&1
    if [ $? -eq 0 ]; then echo "✅ Binário Xray removido."; else echo "⚠️ Aviso: Falha ao remover o binário Xray ou já estava ausente."; fi

    # 2. Remover diretórios de configuração e dados
    echo "2. Limpando diretórios de configuração..."
    rm -rf /usr/local/etc/xray
    rm -rf "$XRAY_DIR"
    rm -rf "$SSL_DIR"
    echo "✅ Diretórios (/usr/local/etc/xray, $XRAY_DIR, $SSL_DIR) removidos."

    # 3. Remover o atalho do menu e o cronjob
    echo "3. Removendo atalho e cronjob..."
    rm -f /bin/xray-menu
    
    # Remove a linha do cronjob de limpeza
    (crontab -l 2>/dev/null | grep -v "menuxray.sh func_purge_expired") | crontab -
    echo "✅ Atalho e Cronjob removidos."

    # 4. Remover a tabela 'xray' do PostgreSQL
    read -rp "Deseja APAGAR a tabela 'xray' no DB '$DB_NAME'? (S/N): " confirm_db
    if [[ "$confirm_db" =~ ^[Ss]$ ]]; then
        echo "4. Removendo tabela do Banco de Dados..."
        db_query "DROP TABLE IF EXISTS xray"
        if [ $? -eq 0 ]; then echo "✅ Tabela 'xray' removida do DB."; else echo "❌ ERRO: Falha ao remover a tabela. Verifique manualmente o DB."; fi
    else
        echo "⚠️ Tabela do DB mantida (Você pode querer reusar o DB)."
    fi

    echo ""
    echo "========================================="
    echo "🎉 DESINSTALAÇÃO CONCLUÍDA!"
    echo "========================================="
    exit 0
}


# --- FUNÇÃO DE MENU XRAY (Interface do Usuário) ---
menu_display() {
    clear
    echo "========================================="
    echo "⚡ Gerenciamento Xray Core"
    echo "========================================="
    func_info
    echo "-----------------------------------------"

    echo "1. Criar Usuário Xray"
    echo "2. Remover Usuário Xray"
    echo "3. Listar Usuários Xray"
    echo "5. Gerar Certificado TLS (Autoassinado)"
    echo "6. Configurar Xray Core (Porta e Protocolo Principal)"
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
                proto_result=$(func_select_protocol)
                if [ "$proto_result" == "cancel" ] || [ "$proto_result" == "invalid" ]; then continue; fi
                func_add_user "$nick" "$proto_result" 
                ;;
            2) read -rp "ID ou UUID para remover > " identifier; func_remove_user "$identifier" ;;
            3) func_list_users ;;
            5) read -rp "Domínio (ex: vpn.seudominio.com) > " domain; func_xray_cert "$domain" ;;
            6) 
                read -rp "Porta do inbound [443] > " p; [ -z "$p" ] && p=443
                proto_result=$(func_select_protocol)
                if [ "$proto_result" == "cancel" ] || [ "$proto_result" == "invalid" ]; then continue; fi
                
                # Se o certificado estiver ausente E o protocolo for vision, interrompe a configuração
                if [ "$proto_result" == "vision" ] && ! func_check_cert "XTLS-Vision"; then 
                    read -rp "Pressione ENTER para retornar ao menu principal..."; 
                    continue;
                fi

                func_create_db_table; func_generate_config "$p" "$proto_result"
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
