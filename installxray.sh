#!/bin/bash
# installxray.sh - Instalador Premium com Barra de Progresso
# Repositório: https://github.com/PhoenixxZ2023/XrayX-TLS

# --- CORES ---
VERMELHO='\033[1;31m'
VERDE='\033[1;32m'
AMARELO='\033[1;33m'
AZUL='\033[1;34m'
RESET='\033[0m'

# --- CONFIGURAÇÕES ---
XRAY_DIR="/opt/XrayTools"
MENU_DESTINATION="$XRAY_DIR/menuxray.sh"
MENU_GITHUB_URL="https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/menuxray.sh"

DB_HOST="127.0.0.1"
DB_NAME="dragoncore"
DB_USER="root"
DB_PASS="senha"

# --- FUNÇÃO DE BARRA DE PROGRESSO ---
# Uso: comando & fun_bar $! "Texto da Ação"
fun_bar() {
    local pid=$1
    local text=$2
    local delay=0.1
    local spin='-\|/'
    local i=0
    local percent=0
    
    # Esconde o cursor
    tput civis
    
    while kill -0 $pid 2>/dev/null; do
        # Logica de porcentagem falsa (vai até 95% e espera)
        if [ $percent -lt 95 ]; then
            percent=$((percent + 1))
        fi
        
        # Calcula barras
        local filled=$((percent / 5))
        local unfilled=$((20 - filled))
        
        # Monta a barra: [#####.....] 45%
        printf "\r${AZUL}[${text}]${RESET} ["
        printf "%0.s#" $(seq 1 $filled)
        printf "%0.s." $(seq 1 $unfilled)
        printf "] ${AMARELO}%d%%${RESET} " "$percent"
        
        # Gira o spinner
        # i=$(( (i+1) %4 ))
        # printf "${spin:$i:1}"
        
        sleep $delay
    done

    # Quando o processo morre (terminou), completa 100%
    printf "\r${AZUL}[${text}]${RESET} ["
    printf "%0.s#" {1..20}
    printf "] ${VERDE}100%%${RESET} - ${VERDE}OK!${RESET}    \n"
    
    # Mostra cursor
    tput cnorm
}

# --- INÍCIO ---
clear
echo -e "${AZUL}==================================================${RESET}"
echo -e "${AMARELO}🚀 DRAGONCORE XRAY MANAGER - INSTALADOR${RESET}"
echo -e "${AZUL}==================================================${RESET}"

# Verificação de Root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${VERMELHO}❌ Execute como root!${RESET}"
    exit 1
fi

# 1. Atualizando repositórios
# Rodamos o comando em background (&) e passamos o PID ($!) para a barra
(apt-get update -y) > /dev/null 2>&1 &
fun_bar $! "Atualizando Sistema"

# 2. Instalando Dependências
# Lista de pacotes
PACKAGES="uuid-runtime curl jq net-tools openssl wget postgresql postgresql-contrib cron"
(apt-get install -y $PACKAGES) > /dev/null 2>&1 &
fun_bar $! "Instalando Dependências"

# 3. Configurando Banco de Dados
(
    export PGPASSWORD=$DB_PASS
    systemctl start postgresql
    systemctl enable postgresql
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null || true
    sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>/dev/null || true
) > /dev/null 2>&1 &
fun_bar $! "Configurando Database"

# 4. Baixando e Configurando Menu
(
    mkdir -p "$XRAY_DIR"
    wget -qO "$MENU_DESTINATION" "$MENU_GITHUB_URL"
    chmod +x "$MENU_DESTINATION"
    
    # Injeta credenciais
    sed -i "s|{DB_HOST}|$DB_HOST|g" "$MENU_DESTINATION"
    sed -i "s|{DB_NAME}|$DB_NAME|g" "$MENU_DESTINATION"
    sed -i "s|{DB_USER}|$DB_USER|g" "$MENU_DESTINATION"
    sed -i "s|{DB_PASS}|$DB_PASS|g" "$MENU_DESTINATION"

    # Cria atalho
    ln -sf "$MENU_DESTINATION" /bin/xray-menu
    chmod +x /bin/xray-menu
) > /dev/null 2>&1 &
fun_bar $! "Instalando Menu"

# 5. Inicializando Tabelas e Cron
(
    export PGPASSWORD=$DB_PASS
    "$MENU_DESTINATION" func_create_db_table
    (crontab -l 2>/dev/null | grep -v "func_purge_expired"; echo "0 1 * * * $MENU_DESTINATION func_purge_expired > /dev/null 2>&1") | crontab -
) > /dev/null 2>&1 &
fun_bar $! "Finalizando Ajustes"

echo -e "${AZUL}==================================================${RESET}"
echo -e "${VERDE}🎉 INSTALAÇÃO CONCLUÍDA COM SUCESSO!${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo -e "Comando principal: ${VERDE}xray-menu${RESET}"
echo -e "👉 Digite ${VERDE}xray-menu${RESET} e vá na ${AMARELO}OPÇÃO 4${RESET} para instalar o Core."
echo -e "${AZUL}==================================================${RESET}"
