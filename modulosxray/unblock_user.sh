#!/bin/bash
# unblock_user.sh - Módulo de Desbloqueio Seguro V7.4 (Otimizado)
# CORREÇÃO: head -n 1 na recuperação e Reload Suave

# CONFIGURAÇÃO
USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"

# CORES
TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_CYAN='\033[1;36m'
RESET='\033[0m'

clear
echo -e "${TXT_GREEN}🔓 DESBLOQUEAR USUÁRIO (REATIVAR)${RESET}"
echo ""

# Verifica dependências
if ! command -v jq &> /dev/null; then echo "Erro: jq não instalado."; exit 1; fi

# --- LISTAR APENAS USUÁRIOS BLOQUEADOS ---
echo "--- Usuários Suspensos ---"
FOUND_LOCKED=0
if [ -f "$CONFIG_PATH" ]; then
    while read -r line; do
        if [ -n "$line" ]; then
            echo " • ${line#LOCKED_}"
            FOUND_LOCKED=1
        fi
    done < <(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients[].email' "$CONFIG_PATH" | grep "^LOCKED_")
else
    echo "Erro: config.json não encontrado."
    exit 1
fi

if [ "$FOUND_LOCKED" -eq 0 ]; then
    echo "Nenhum usuário bloqueado no momento."
    echo "--------------------------"
    echo ""
    read -rp "Pressione ENTER para voltar..."
    exit
fi
echo "--------------------------"
echo ""

read -rp "Digite o usuário para desbloquear: " user_input

if [ -z "$user_input" ]; then exit; fi

LOCKED_NAME="LOCKED_$user_input"

# Verifica se ele realmente está bloqueado
if ! grep -q "\"email\": \"$LOCKED_NAME\"" "$CONFIG_PATH"; then
    echo -e "${TXT_RED}❌ Usuário não encontrado na lista de bloqueios!${RESET}"
    sleep 2
    exit
fi

echo "Recuperando dados originais..."

# 1. Recupera o UUID Original (Com proteção head -n 1)
REAL_UUID=$(grep "^$user_input|" "$USER_DB" | cut -d'|' -f2 | head -n 1)

if [ -z "$REAL_UUID" ]; then
    echo -e "${TXT_RED}ERRO CRÍTICO:${RESET} UUID original não encontrado em $USER_DB."
    exit 1
fi

# 2. Restaura no config.json
jq --arg nick "$user_input" --arg locked "$LOCKED_NAME" --arg uuid "$REAL_UUID" \
   '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(if .email == $locked then .email = $nick | .id = $uuid else . end)' \
   "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

# --- MELHORIA AQUI: RELOAD SUAVE ---
# Tenta recarregar sem derrubar conexões. Se falhar, força o restart.
if systemctl reload xray > /dev/null 2>&1; then
    echo -e "${TXT_GREEN}✅ Configuração recarregada (Reload Suave).${RESET}"
else
    systemctl restart xray > /dev/null 2>&1
    echo -e "${TXT_YELLOW}⚠️  Reload falhou, restart aplicado.${RESET}"
fi

echo -e "${TXT_GREEN}✅ Usuário $user_input reativado com sucesso!${RESET}"
echo "UUID original restaurado: $REAL_UUID"
sleep 3
