#!/bin/bash
# certxray.sh - VERSÃO CLÁSSICA (Visual Original + Correção de Permissão)

# --- CORREÇÃO DE INPUT (Evita erro se digitar 'bash certxray.sh') ---
RAW_INPUT="$*"
DOMAIN=$(echo "$RAW_INPUT" | awk '{print $NF}')

SSL_DIR="/opt/DragonCoreSSL"
LE_DIR="/etc/letsencrypt/live/$DOMAIN"
RENEW_SCRIPT="$SSL_DIR/renew_cert.sh"

# --- CORES ---
YB='\033[1;33m'       # Amarelo Negrito
RB='\033[1;31m'       # Vermelho Negrito
BG_RED='\033[41;1;37m' # Fundo Vermelho
RESET='\033[0m'

# Se não recebeu domínio por argumento, pede agora
if [ -z "$DOMAIN" ]; then
    echo -e "${RB}Erro: Nenhum domínio recebido.${RESET}"
    read -rp "Digite o domínio manualmente: " DOMAIN
fi

# Prepara a pasta com permissões corretas (Segurança para o Xray não travar)
mkdir -p "$SSL_DIR"
chown -R nobody:nogroup "$SSL_DIR"
chmod 777 "$SSL_DIR"

clear
echo -e "${YB}====================================================${RESET}"
echo -e "${YB}            GERENCIADOR DE CERTIFICADOS SSL          ${RESET}"
echo -e "${YB}====================================================${RESET}"
echo ""
echo -e "${YB}DOMÍNIO ALVO: $DOMAIN${RESET}"
echo ""
echo -e "${YB}ESCOLHA O TIPO DE CERTIFICADO:${RESET}"
echo ""
# --- AVISOS CRÍTICOS DA PORTA 80 (IGUAL AO SEU PEDIDO) ---
echo -e "${YB} [1] CERTIFICADO OFICIAL LET'S ENCRYPT (Cadeado)${RESET}"
echo -e "${RB}     ⚠️  REQ 1: PORTA 80 DEVE ESTAR LIVRE NA VPS${RESET}"
echo -e "${RB}     ⚠️  REQ 2: PORTA 80 DEVE ESTAR ABERTA NO FIREWALL (ORACLE/AWS)${RESET}"
echo ""
echo -e "${YB} [2] CERTIFICADO AUTO-ASSINADO (LOCAL)${RESET}"
echo -e "${YB}     ✅  Não precisa de porta 80 / Instalação Rápida${RESET}"
echo ""
echo -e "${YB}====================================================${RESET}"
echo ""
read -rp "OPÇÃO: " cert_opt

# Limpa certificados antigos
rm -f "$SSL_DIR/fullchain.pem"
rm -f "$SSL_DIR/privkey.pem"

case $cert_opt in
    1)
        # Tela de Confirmação Crítica
        clear
        echo -e "${BG_RED}                ⚠️  LEIA COM ATENÇÃO  ⚠️                ${RESET}"
        echo ""
        echo -e "${YB}Você escolheu LET'S ENCRYPT. Para funcionar:${RESET}"
        echo ""
        echo -e "1. ${RB}PORTA 80 LIVRE:${RESET} O script vai parar o Xray/Nginx temporariamente."
        echo -e "2. ${RB}PORTA 80 ABERTA:${RESET} Se usa Oracle Cloud, abra a porta 80 na lista de segurança."
        echo ""
        read -rp "Pressione [ENTER] se você confirma os requisitos..." confirm_80

        echo -e "${YB}>>> PREPARANDO AMBIENTE...${RESET}"
        
        # Instala Certbot se não tiver
        export DEBIAN_FRONTEND=noninteractive
        if ! command -v certbot &> /dev/null; then 
            apt-get update -y >/dev/null 2>&1
            apt-get install certbot -y >/dev/null 2>&1
        fi

        # --- TENTA LIBERAR A PORTA 80 NA MARRA ---
        echo "Parando serviços que usam a porta 80..."
        systemctl stop xray >/dev/null 2>&1
        systemctl stop nginx >/dev/null 2>&1
        fuser -k 80/tcp >/dev/null 2>&1
        sleep 2
        
        echo -e "${YB}>>> GERANDO CERTIFICADO (Aguarde)...${RESET}"
        # Gera o certificado (Modo Standalone usa a porta 80)
        certbot certonly --standalone -d "$DOMAIN" --register-unsafely-without-email --agree-tos --non-interactive

        if [ -f "$LE_DIR/fullchain.pem" ]; then
            # Copia para a pasta do Xray
            cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
            cp -f "$LE_DIR/privkey.pem" "$SSL_DIR/privkey.pem"
            
            # --- AJUSTE TÉCNICO: Troquei chmod 777 por chown nobody (Para funcionar) ---
            chown -R nobody:nogroup "$SSL_DIR"
            chmod 777 "$SSL_DIR/fullchain.pem"
            chmod 777 "$SSL_DIR/privkey.pem"
            
            # --- CRIA O SCRIPT DE RENOVAÇÃO AUTOMÁTICA ---
            cat > "$RENEW_SCRIPT" <<EOF
#!/bin/bash
# Script de Renovação Automática DragonCore
systemctl stop xray
fuser -k 80/tcp
certbot renew --quiet
cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
cp -f "$LE_DIR/privkey.pem" "$SSL_DIR/privkey.pem"
# Permissões Seguras na Renovação
chown -R nobody:nogroup "$SSL_DIR"
chmod 777 "$SSL_DIR/fullchain.pem"
chmod 777 "$SSL_DIR/privkey.pem"
systemctl restart xray
EOF
            chmod +x "$RENEW_SCRIPT"
            
            # Adiciona no Crontab
            (crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 3 1 * * $RENEW_SCRIPT >/dev/null 2>&1") | crontab -
            
            echo -e "${YB}✅ SUCESSO! Certificado Let's Encrypt Instalado.${RESET}"
        else
            echo ""
            echo -e "${BG_RED}  FALHA NA VALIDAÇÃO  ${RESET}"
            echo -e "${RB}Não foi possível gerar o certificado oficial.${RESET}"
            echo "Motivo provável: Porta 80 fechada (Oracle/Claro) ou Domínio incorreto."
            echo ""
            echo -e "${YB}>>> Instalando Auto-assinado de emergência...${RESET}"
            openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
            -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1
            
            # Permissões Seguras
            chown -R nobody:nogroup "$SSL_DIR"
            chmod 777 "$SSL_DIR/fullchain.pem"
            chmod 777 "$SSL_DIR/privkey.pem"
        fi
        ;;
    
    *)
        echo "Gerando Auto-assinado (Opção Segura)..."
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
        -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1
        
        # Permissões Seguras
        chown -R nobody:nogroup "$SSL_DIR"
        chmod 777 "$SSL_DIR/fullchain.pem"
        chmod 777 "$SSL_DIR/privkey.pem"
        echo -e "${YB}✅ Certificado Auto-assinado criado.${RESET}"
        ;;
esac
