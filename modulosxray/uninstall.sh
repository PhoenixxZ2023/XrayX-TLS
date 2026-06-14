#!/bin/bash
# uninstall.sh - DragonCore V7.5.1
# Correções aplicadas:
#   - ACTIVE_DOMAIN lido ANTES de qualquer rm -rf — era lido após /opt/XrayTools já deletado
#   - set -Eeuo pipefail — consistente com demais módulos
#   - kill $PPID com verificação do nome do processo — não mata shell pai errado
#   - Listagem de backups usa find em vez de ls — seguro com nomes especiais
#   - Verificação de backup_script com -f e comentário sobre bash explícito

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_YELLOW='\033[1;33m'
TXT_CYAN='\033[1;36m'
TITLE_BAR='\033[1;41;37m'
RESET='\033[0m'

# --- VERIFICAÇÃO DE ROOT ---
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"
    exit 1
fi

ask_sn() {
    local prompt="${1:-Confirmar?}"
    local ans=""
    while true; do
        read -rp "$prompt [s/n]: " ans
        ans="${ans,,}"
        case "$ans" in
            s) return 0 ;;
            n) return 1 ;;
            *) echo "Digite s (sim) ou n (não)." ;;
        esac
    done
}

# CORREÇÃO: lê ACTIVE_DOMAIN ANTES de qualquer remoção —
# o step 3 apaga /opt/XrayTools inteiro, então a leitura posterior retornava sempre vazio,
# fazendo com que os dados do certbot nunca fossem encontrados para remoção.
ACTIVE_DOMAIN=""
if [ -f "/opt/XrayTools/active_domain" ]; then
    ACTIVE_DOMAIN=$(cat "/opt/XrayTools/active_domain" 2>/dev/null || true)
fi

BACKUP_DIR="/root/backups"

clear
echo -e "${TITLE_BAR}   DESINSTALAÇÃO TOTAL DO DRAGONCORE   ${RESET}"
echo ""
echo -e "${TXT_YELLOW}Será removido permanentemente:${RESET}"
echo " • Xray Core (binário, configs, serviço)"
echo " • Bot Telegram (serviço e scripts)"
echo " • Usuários e banco de dados (/opt/XrayTools)"
echo " • Certificados SSL (/opt/DragonCoreSSL)"
echo " • Todos os scripts do DragonCore (/usr/local/bin)"
echo " • Entradas de cron do DragonCore"
echo ""
echo -e "${TXT_RED}⚠  Esta operação é IRREVERSÍVEL sem um backup prévio.${RESET}"
echo ""

# --- OFERTA DE BACKUP ANTES DE DESINSTALAR ---
BACKUP_SCRIPT="/usr/local/bin/backup.sh"
# -f verifica existência; bash é chamado explicitamente então -x não é obrigatório,
# mas garantimos que o arquivo existe antes de tentar executar.
if [ -f "$BACKUP_SCRIPT" ]; then
    if ask_sn "Deseja criar um backup antes de desinstalar"; then
        echo -e "${TXT_CYAN}Executando backup...${RESET}"
        bash "$BACKUP_SCRIPT" || echo -e "${TXT_YELLOW}⚠  Backup falhou — continuando mesmo assim.${RESET}"
        echo ""
    fi
fi

# --- CONFIRMAÇÃO ÚNICA ---
if ! ask_sn "Confirmar desinstalação TOTAL"; then
    echo "Cancelado."
    exit 0
fi

echo ""
echo -e "${TXT_YELLOW}>>> Desinstalando...${RESET}"

# --- 1) SERVIÇOS ---
echo -n " Parando serviços... "
systemctl stop    xray    >/dev/null 2>&1 || true
systemctl disable xray    >/dev/null 2>&1 || true
systemctl stop    botxray >/dev/null 2>&1 || true
systemctl disable botxray >/dev/null 2>&1 || true
echo -e "${TXT_GREEN}OK${RESET}"

# --- 2) UNITS SYSTEMD ---
echo -n " Removendo units systemd... "
rm -f  /etc/systemd/system/xray.service
rm -f  /etc/systemd/system/botxray.service
rm -rf /etc/systemd/system/xray.service.d
systemctl daemon-reload >/dev/null 2>&1 || true
echo -e "${TXT_GREEN}OK${RESET}"

# --- 3) DADOS E CONFIGS ---
# NOTA: ACTIVE_DOMAIN já foi lido antes deste bloco — seguro apagar agora.
echo -n " Removendo dados e configs... "
rm -rf /usr/local/etc/xray
rm -rf /opt/XrayTools
rm -rf /opt/DragonCoreSSL
rm -rf /var/log/xray
echo -e "${TXT_GREEN}OK${RESET}"

# --- 4) BINÁRIO XRAY ---
echo -n " Removendo binário xray... "
rm -f /usr/local/bin/xray
rm -f /usr/local/share/xray/geoip.dat   2>/dev/null || true
rm -f /usr/local/share/xray/geosite.dat 2>/dev/null || true
rmdir /usr/local/share/xray             2>/dev/null || true
echo -e "${TXT_GREEN}OK${RESET}"

# --- 5) SCRIPTS E ATALHOS ---
# NOTA: renew_cert.sh fica em /opt/DragonCoreSSL (removido no step 3).
# A entrada de cron que aponta para ele é removida no step 6.
echo -n " Removendo scripts DragonCore... "
# Remove lock files que possam ter ficado de instalações anteriores
rm -f /tmp/xray-install.lock /tmp/limiterxray.lock /tmp/menuxray.lock
rm -f /usr/bin/xray-menu
rm -f /usr/local/bin/xray-menu
rm -f /usr/local/bin/menuxray.sh
rm -f /usr/local/bin/installxray.sh
rm -f /usr/local/bin/core_manager.sh
rm -f /usr/local/bin/limiterxray.sh
rm -f /usr/local/bin/botxray.sh
rm -f /usr/local/bin/onlinexray.sh
rm -f /usr/local/bin/certxray.sh
rm -f /usr/local/bin/backup.sh
rm -f /usr/local/bin/add_user.sh
rm -f /usr/local/bin/block_user.sh
rm -f /usr/local/bin/unblock_user.sh
rm -f /usr/local/bin/uninstall.sh
rm -f /usr/local/bin/remover_user.sh
rm -f /usr/local/bin/rem_user.sh
rm -f /usr/local/bin/lista_users.sh
rm -f /usr/local/bin/list_users.sh
rm -f /usr/local/bin/remover_expirados.sh
rm -f /usr/local/bin/purge_users.sh
echo -e "${TXT_GREEN}OK${RESET}"

# --- 6) CRON (apenas entradas DragonCore) ---
echo -n " Limpando cron... "
(crontab -l 2>/dev/null \
    | grep -v "limiterxray" \
    | grep -v "renew_cert" \
) | crontab - 2>/dev/null || true
echo -e "${TXT_GREEN}OK${RESET}"

# --- 7) DADOS CERTBOT / LET'S ENCRYPT (opcional) ---
# CORREÇÃO: ACTIVE_DOMAIN foi lido antes do step 3 — agora está disponível corretamente.
LE_LIVE="/etc/letsencrypt/live"
if [ -d "$LE_LIVE" ] && [ -n "${ACTIVE_DOMAIN:-}" ]; then
    echo ""
    echo -e "${TXT_YELLOW}Dados do Let's Encrypt encontrados para:${RESET} ${TXT_CYAN}${ACTIVE_DOMAIN}${RESET}"
    if ask_sn "Remover dados do certbot para este domínio"; then
        certbot delete --cert-name "$ACTIVE_DOMAIN" --non-interactive >/dev/null 2>&1 || \
            rm -rf "${LE_LIVE}/${ACTIVE_DOMAIN}" 2>/dev/null || true
        echo -e " ${TXT_GREEN}Dados certbot removidos.${RESET}"
    fi
elif [ -d "$LE_LIVE" ]; then
    echo ""
    echo -e "${TXT_YELLOW}⚠  Dados do Let's Encrypt encontrados em ${LE_LIVE}.${RESET}"
    echo -e "${TXT_YELLOW}   Remova manualmente com: certbot delete --cert-name <dominio>${RESET}"
fi

# --- 8) BACKUPS RESIDUAIS ---
# CORREÇÃO: usa find em vez de ls — seguro com nomes de arquivo com espaços ou chars especiais.
if [ -d "$BACKUP_DIR" ] && \
   find "$BACKUP_DIR" -maxdepth 1 -name "*.tar.gz" -quit 2>/dev/null | grep -q .; then
    echo ""
    echo -e "${TXT_YELLOW}Backups encontrados em ${BACKUP_DIR}:${RESET}"
    while IFS= read -r -d '' bfile; do
        local_size=$(du -sh "$bfile" 2>/dev/null | cut -f1)
        printf "  %6s  %s\n" "$local_size" "$(basename "$bfile")"
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name "*.tar.gz" -print0 | sort -z)
    echo ""
    if ask_sn "Remover backups também"; then
        rm -rf "$BACKUP_DIR"
        echo -e " ${TXT_GREEN}Backups removidos.${RESET}"
    else
        echo -e " ${TXT_CYAN}Backups mantidos em ${BACKUP_DIR}.${RESET}"
    fi
fi

echo ""
echo -e "${TXT_GREEN}✅ Desinstalação concluída.${RESET}"
echo -e "${TXT_YELLOW}   O sistema está limpo. Reinicie a VPS se necessário.${RESET}"
sleep 2

# Encerra o processo pai (menuxray.sh) se ainda estiver rodando.
# CORREÇÃO: verifica o nome do processo antes de matar — evita encerrar
# o shell do operador se o script for chamado fora do contexto do menu.
PPID_MENU="${PPID:-0}"
if [ "$PPID_MENU" -gt 1 ]; then
    parent_cmd=$(ps -o comm= -p "$PPID_MENU" 2>/dev/null || true)
    if [[ "${parent_cmd:-}" == *"menuxray"* ]] || [[ "${parent_cmd:-}" == *"bash"* ]]; then
        kill "$PPID_MENU" 2>/dev/null || true
    fi
fi

exit 0
