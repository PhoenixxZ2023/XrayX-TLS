#!/bin/bash
# installxray.sh - Instalador Premium V7.4 (Modular Launcher)

set -Eeuo pipefail
trap 'tput cnorm 2>/dev/null || true' EXIT

# --- CORES ---
VERMELHO='\033[1;31m'
VERDE='\033[1;32m'
AMARELO='\033[1;33m'
AZUL='\033[1;34m'
RESET='\033[0m'

# --- CONFIGURAÇÃO ---
REPO_OWNER="PhoenixxZ2023"
REPO_NAME="XrayX-TLS"

# Permite pin por tag/commit:
# Ex.: REPO_REF="v7.4" ou REPO_REF="7b1f9b8..." (commit)
REPO_REF="${REPO_REF:-main}"

REPO_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}"
MENU_PATH="/usr/local/bin/menuxray.sh"
SHORTCUT="/usr/bin/xray-menu"

fun_bar() {
    local pid="$1"
    local text="$2"
    local delay=0.1
    local percent=0

    tput civis || true

    while kill -0 "$pid" 2>/dev/null; do
        if [ "$percent" -lt 95 ]; then percent=$((percent + 1)); fi
        local filled=$((percent / 5))
        local unfilled=$((20 - filled))

        printf "\r${AZUL}[${text}]${RESET} ["
        printf "%0.s#" $(seq 1 "$filled")
        printf "%0.s." $(seq 1 "$unfilled")
        printf "] ${AMARELO}%d%%${RESET} " "$percent"
        sleep "$delay"
    done

    printf "\r${AZUL}[${text}]${RESET} ["
    printf "%0.s#" $(seq 1 20)
    printf "] ${VERDE}100%%${RESET} - ${VERDE}OK!${RESET}    \n"
    tput cnorm || true
}

clear
echo -e "${AZUL}==================================================${RESET}"
echo -e "${AMARELO}🚀 DRAGONCORE MODULAR - LAUNCHER V7.4${RESET}"
echo -e "${AZUL}==================================================${RESET}"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${VERMELHO}❌ Execute como root!${RESET}"
    exit 1
fi

# 1) Atualizando
( export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
) >/dev/null 2>&1 &
fun_bar $! "Atualizando Sistema"

# 2) Dependências
PACKAGES=(curl jq cron tar)
( export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "${PACKAGES[@]}"
) >/dev/null 2>&1 &
fun_bar $! "Instalando Base (Curl/JQ)"

# 3) Limpeza antiga
(
  rm -f /bin/menuxray.sh /usr/local/bin/menuxray.sh
  rm -f /bin/limiterxray.sh /usr/local/bin/limiterxray.sh
  rm -f /bin/botxray.sh /usr/local/bin/botxray.sh
  rm -f /bin/xray-menu /usr/bin/xray-menu
  rm -f /usr/local/bin/add_user.sh /usr/local/bin/rem_user.sh
) >/dev/null 2>&1 &
fun_bar $! "Limpando Instalações Antigas"

# 4) Download do menu (sem wait antes do fun_bar)
(
  curl -fLsS --retry 3 --retry-delay 1 -o "$MENU_PATH" "$REPO_BASE/menuxray.sh"
  test -s "$MENU_PATH"
  chmod 0755 "$MENU_PATH"

  # cria/atualiza symlink
  ln -sf "$MENU_PATH" "$SHORTCUT"
) >/dev/null 2>&1 &
PID_DOWNLOAD=$!
fun_bar "$PID_DOWNLOAD" "Instalando Menu Maestro"

wait "$PID_DOWNLOAD" || {
  echo -e "\n${VERMELHO}❌ Erro Crítico: Não foi possível baixar o menuxray.sh${RESET}"
  echo "Verifique sua conexão ou se o arquivo existe no repositório/ref: ${REPO_REF}"
  exit 1
}

echo -e "${AZUL}==================================================${RESET}"
echo -e "${VERDE}🎉 SISTEMA MODULAR PRONTO!${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo -e "Para acessar, digite: ${VERDE}xray-menu${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo ""
sleep 1

exec xray-menu
