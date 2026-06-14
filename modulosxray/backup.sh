#!/bin/bash
# backup.sh
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
RESET='\033[0m'
TITLE_BAR='\033[1;47;34m'

clear; echo -e "${TITLE_BAR}   BACKUP & RESTORE   ${RESET}"; echo ""
echo -e "${TXT_CYAN}[1] CRIAR BACKUP${RESET}"
echo -e "${TXT_CYAN}[2] RESTAURAR BACKUP${RESET}"
echo -e "${TXT_CYAN}[0] SAIR${RESET}"
read -rp "Opção: " opt

BACKUP_DIR="/root/backups"
mkdir -p "$BACKUP_DIR"

case "$opt" in
    1)
        echo "Criando backup..."
        FILE="${BACKUP_DIR}/backup_dragoncore_$(date +%Y%m%d_%H%M%S).tar.gz"
        if [ ! -f "/opt/XrayTools/users.db" ]; then echo "Erro: DB não encontrado."; exit 1; fi
        tar -czf "$FILE" /opt/XrayTools /usr/local/etc/xray >/dev/null 2>&1
        if [ -f "$FILE" ]; then
            echo -e "${TXT_GREEN}Backup criado: $(basename "$FILE")${RESET}"
        else
            echo -e "${TXT_RED}Erro ao criar backup.${RESET}"
        fi
        ;;
    2)
        echo "Restaurando..."
        shopt -s nullglob
        FILES=("$BACKUP_DIR"/*.tar.gz)
        if [ ${#FILES[@]} -eq 0 ]; then echo "Nenhum backup encontrado."; exit 1; fi
        
        PS3="Escolha o número: "
        select FILE in "${FILES[@]}"; do
            [ -n "$FILE" ] && break
        done
        
        systemctl stop xray >/dev/null 2>&1
        systemctl stop botxray >/dev/null 2>&1
        tar -xzf "$FILE" -C /
        systemctl restart xray >/dev/null 2>&1
        systemctl restart botxray >/dev/null 2>&1
        echo -e "${TXT_GREEN}Sistema restaurado!${RESET}"
        ;;
esac
read -rp "Enter..."
