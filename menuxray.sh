#!/bin/bash
# menuxray.sh - Menu Interativo e Lógica Xray (Backend e Frontend)

# --- Variáveis de Ambiente (Preenchidas pelo instalador) ---
# O instalador irá substituir estas credenciais
DB_HOST="{DB_HOST}"
DB_NAME="{DB_NAME}"
DB_USER="{DB_USER}"
DB_PASS="{DB_PASS}"

XRAY_BIN="/usr/local/bin/xray"
CONFIG_PATH="/usr/local/etc/xray/config.json"
SSL_DIR="/opt/DragonCoreSSL"
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

func_generate_config() {
    local port=${1:-443}
    local network=${2:-ws}
    local stream_settings=""

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -le 0 ] || [ "$port" -gt 65535 ]; then port=443; fi
    case "$network" in ws|xhttp|grpc|tcp) ;; *) network="ws" ;; esac

    mkdir -p "$(dirname "$CONFIG_PATH")"

    if [ "$network" == "xhttp" ]; then
        stream_settings=$(cat <<EOF
            {
                "network": "xhttp", "security": "tls",
                "tlsSettings": {
                    "certificates": [{"certificateFile": "$SSL_DIR/fullchain.pem", "keyFile": "$SSL_DIR/privkey.pem"}],
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
    else
        stream_settings='{ "network": "'"$network"'", "security": "none" }'
    fi

    jq -n --argjson streamSettings "$stream_settings" --arg port "$port" '
{
  "api": { "services": [ "HandlerService", "LoggerService", "StatsService" ], "tag": "api" },
  "inbounds": [
    { "tag": "api", "port": 1080, "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" }, "listen": "127.0.0.1" },
    {
      "tag": "inbound-dragoncore", "port": ($port | tonumber), "protocol": "vless",
      "settings": { "clients": [], "decryption": "none", "fallbacks": [] },
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
    echo "URI: vless://${uuid}@${domain}:${port}#${nick}"
}

func_remove_user() {
    local identifier="$1"
    local uuid=""
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
    local key_file="$SSL_DIR/privkey.pem"
    local crt_file="$SSL_DIR/fullchain.pem"
    if [ -z "$domain" ]; then echo "Erro: Informe o domínio/IP."; return; fi
    mkdir -p "$SSL_DIR"
    openssl req -x509 -nodes -newkey rsa:2048 -days 9999 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=DragonCore/OU=VPN/CN=$domain" \
        -keyout "$key_file" -out "$crt_file" 2>/dev/null
    if [ -f "$key_file" ] && [ -f "$crt_file" ]; then echo "✅ Certificado TLS autoassinado gerado para $domain"; else echo "❌ Falha ao gerar certificado."; fi
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
    echo "6. Configurar Xray Core (Porta/Protocolo)"
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
            1) read -rp "Nome do usuário > " nick; read -rp "Protocolo (ws/xhttp/grpc/tcp) [ws] > " proto; func_add_user "$nick" "${proto:-ws}" ;;
            2) read -rp "ID ou UUID para remover > " identifier; func_remove_user "$identifier" ;;
            3) func_list_users ;;
            5) read -rp "Domínio (ex: vpn.seudominio.com) > " domain; func_xray_cert "$domain" ;;
            6) 
                read -rp "Porta do inbound [443] > " p; [ -z "$p" ] && p=443
                read -rp "Protocolo (ws/xhttp/grpc/tcp) [ws] > " pr; [ -z "$pr" ] && pr="ws"
                func_create_db_table; func_generate_config "$p" "$pr"
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
