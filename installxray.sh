#!/bin/bash
# installxray.sh - Instalador Premium V7.4 (Modular Launcher)
# Repositório: https://github.com/PhoenixxZ2023/XrayX-TLS
# FUNÇÃO: Prepara o sistema e baixa o Menu Maestro. Os módulos fazem o resto.

# --- CORES ---
VERMELHO='\033[1;31m'
VERDE='\033[1;32m'
AMARELO='\033[1;33m'
AZUL='\033[1;34m'
RESET='\033[0m'

# --- CONFIGURAÇÃO ---
REPO_BASE="https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main"
MENU_PATH="/usr/local/bin/menuxray.sh"
SHORTCUT="/usr/bin/xray-menu"

# --- FUNÇÃO DE BARRA DE PROGRESSO ---
fun_bar() {
    local pid=$1
    local text=$2
    local delay=0.1
    local i=0
    local percent=0
    
    tput civis # Esconde cursor
    
    while kill -0 $pid 2>/dev/null; do
        if [ $percent -lt 95 ]; then percent=$((percent + 1)); fi
        local filled=$((percent / 5))
        local unfilled=$((20 - filled))
        printf "\r${AZUL}[${text}]${RESET} ["
        printf "%0.s#" $(seq 1 $filled)
        printf "%0.s." $(seq 1 $unfilled)
        printf "] ${AMARELO}%d%%${RESET} " "$percent"
        sleep $delay
    done

    printf "\r${AZUL}[${text}]${RESET} ["
    printf "%0.s#" {1..20}
    printf "] ${VERDE}100%%${RESET} - ${VERDE}OK!${RESET}    \n"
    tput cnorm # Volta cursor
}

# --- INÍCIO ---
clear
echo -e "${AZUL}==================================================${RESET}"
echo -e "${AMARELO}🚀 DRAGONCORE MODULAR - LAUNCHER V7.4${RESET}"
echo -e "${AZUL}==================================================${RESET}"

if [ "$EUID" -ne 0 ]; then 
    echo -e "${VERMELHO}❌ Execute como root!${RESET}"
    exit 1
fi

# 1. Atualizando repositórios
(export DEBIAN_FRONTEND=noninteractive; apt-get update -y) > /dev/null 2>&1 &
fun_bar $! "Atualizando Sistema"

# 2. Instalando Dependências Básicas (Apenas o essencial para o Menu rodar)
# Curl: Baixar módulos / JQ: Ler configs JSON / Cron: Agendamentos futuros
PACKAGES="curl jq cron tar"
(export DEBIAN_FRONTEND=noninteractive; apt-get install -y $PACKAGES) > /dev/null 2>&1 &
fun_bar $! "Instalando Base (Curl/JQ)"

# 3. Limpeza de Versões Antigas (Para evitar conflito com sistema modular)
(
    rm -f /bin/menuxray.sh /usr/local/bin/menuxray.sh
    rm -f /bin/limiterxray.sh /usr/local/bin/limiterxray.sh
    rm -f /bin/botxray.sh /usr/local/bin/botxray.sh
    rm -f /bin/xray-menu /usr/bin/xray-menu
    
    # Remove scripts antigos que agora são módulos (limpa a raiz do bin)
    rm -f /usr/local/bin/add_user.sh
    rm -f /usr/local/bin/rem_user.sh
) > /dev/null 2>&1 &
fun_bar $! "Limpando Instalações Antigas"

# 4. Baixando o Menu Maestro (O Cérebro)
(
    # Baixa o Menu Principal
    curl -s -L -o "$MENU_PATH" "$REPO_BASE/menuxray.sh"
    
    # Verificação de integridade básica
    if [ ! -s "$MENU_PATH" ]; then
        exit 1 # Falha silenciosa capturada pelo fun_bar? Não, vamos tratar abaixo.
    fi

    chmod +x "$MENU_PATH"

    # Atalho Global 'xray-menu'
    ln -s "$MENU_PATH" "$SHORTCUT"
    chmod +x "$SHORTCUT"
) > /dev/null 2>&1 &

PID_DOWNLOAD=$!
wait $PID_DOWNLOAD
STATUS_DOWNLOAD=$?

if [ $STATUS_DOWNLOAD -ne 0 ] || [ ! -s "$MENU_PATH" ]; then
    echo -e "\n${VERMELHO}❌ Erro Crítico: Não foi possível baixar o menuxray.sh${RESET}"
    echo "Verifique sua conexão ou se o arquivo está na raiz do GitHub."
    exit 1
fi

fun_bar $PID_DOWNLOAD "Instalando Menu Maestro"

# Nota: A instalação do Python, Bot e Configuração do Xray/Cron
# foram removidas daqui propositalmente. Elas agora são gerenciadas
# dinamicamente pelo menu e pelos módulos na pasta 'modulosxray'.

echo -e "${AZUL}==================================================${RESET}"
echo -e "${VERDE}🎉 SISTEMA MODULAR PRONTO!${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo -e "O 'Launcher' preparou o ambiente com sucesso."
echo -e "Os módulos (Install Core, Bot, Limiter) serão baixados"
echo -e "automaticamente quando você usar o menu."
echo -e ""
echo -e "Para acessar, digite: ${VERDE}xray-menu${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo ""
sleep 2

# Executa o menu automaticamente
xray-menu
