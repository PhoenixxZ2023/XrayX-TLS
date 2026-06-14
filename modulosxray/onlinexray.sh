#!/bin/bash
# onlinexray.sh - Monitor Otimizado com AWK (Anti-Spam)
# CORREÇÃO: Restart Inteligente (Não derruba conexões se o log já estiver ativo)

# Cores
GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'
CONF="/usr/local/etc/xray/config.json"

# Função para restaurar o log ao sair
restaurar_log() {
    echo ""
    echo -e "${YELLOW}>>> Restaurando configurações...${RESET}"
    # Só restaura se realmente precisar (evita restart desnecessário na saída também)
    if grep -q '"loglevel": "info"' "$CONF"; then
        sed -i 's/"loglevel": "info"/"loglevel": "warning"/' "$CONF"
        systemctl restart xray
    fi
    echo -e "${GREEN}>>> Encerrado.${RESET}"
    exit 0
}

trap restaurar_log SIGINT

clear
echo -e "${CYAN}================================================${RESET}"
echo -e "${CYAN}         MONITOR DE USUÁRIOS ONLINE (XRAY)      ${RESET}"
echo -e "${CYAN}================================================${RESET}"

# --- CORREÇÃO: VERIFICAÇÃO INTELIGENTE DE LOG ---
echo -e "${YELLOW}Verificando configurações de log...${RESET}"

if grep -q '"loglevel": "info"' "$CONF"; then
    echo -e "${GREEN}>>> Log detalhado já estava ativo. Iniciando sem reiniciar!${RESET}"
    # Pula o restart, mantendo as conexões vivas
else
    echo -e "${YELLOW}>>> Ativando modo espião (Filtro Anti-Spam: 15s)...${RESET}"
    sed -i 's/"loglevel": "warning"/"loglevel": "info"/' "$CONF"
    systemctl restart xray
    echo -e "${GREEN}>>> Xray reiniciado para aplicar logs.${RESET}"
fi
# -----------------------------------------------

echo -e "${GREEN}>>> AGUARDANDO CONEXÕES... (CTRL+C para Sair)${RESET}"
echo ""

# Monitora usando AWK (Muito mais rápido e estável)
journalctl -u xray -f --no-pager | grep --line-buffered "accepted" | \
awk '
BEGIN { 
    # Define o tempo de espera (Cooldown) em segundos
    cooldown = 15;
}
{
    # Tenta encontrar o padrão "email: usuario" na linha
    match($0, /email: [^ ]+/);
    
    if (RSTART > 0) {
        # Extrai o nome do usuário da linha
        user_str = substr($0, RSTART, RLENGTH);
        split(user_str, a, ": ");
        user = a[2];
        
        # Pega o tempo atual do sistema
        now = systime();
        
        # Se for a primeira vez que vemos o usuário OU se já passou o tempo de cooldown
        if ((user in last_seen) == 0 || (now - last_seen[user] >= cooldown)) {
            
            # Formata a hora (Campo 3 do log geralmente é a hora HH:MM:SS)
            hora = $3;
            
            # Imprime Colorido
            print "\033[1;36m[" hora "]\033[0m Usuário: \033[1;32m" user "\033[0m \033[1;33m(Online)\033[0m";
            
            # Atualiza a última vez que ele foi visto
            last_seen[user] = now;
            
            # Força o Linux a mostrar na tela agora (sem esperar encher buffer)
            fflush();
        }
    }
}'
