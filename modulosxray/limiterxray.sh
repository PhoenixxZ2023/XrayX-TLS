#!/bin/bash
# limiterxray.sh - Controle de Consumo V7.3 (COM RELOAD SUAVE)
# CORREÇÃO: Usa 'systemctl reload' para não derrubar clientes online ao bloquear alguém.

# CONFIGURAÇÃO
XRAY_BIN="/usr/local/bin/xray"
CONFIG_PATH="/usr/local/etc/xray/config.json"
LIMITS_DB="/opt/XrayTools/limits.db"     # Limites definidos (User|Bytes)
USAGE_DB="/opt/XrayTools/usage.db"       # Histórico Cumulativo (User|Bytes)
SESSION_DB="/opt/XrayTools/session.db"   # Controle de Sessão (User|LastBytes)
USER_DB="/opt/XrayTools/users.db" 
XRAY_API_PORT="1080" 

# CORES
TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_BLUE='\033[1;34m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'

mkdir -p "/opt/XrayTools"
touch "$LIMITS_DB"
touch "$USAGE_DB"
touch "$SESSION_DB"

# --- FUNÇÕES ---

header_limit() {
    clear
    echo -e "${TITLE_BAR}   CONTROLE DE CONSUMO (PERSISTENTE)   ${RESET}"
    echo ""
}

func_get_api_port() {
    if [ -f "$CONFIG_PATH" ]; then
        local p=$(jq -r '.inbounds[] | select(.tag == "api").port // empty' "$CONFIG_PATH")
        if [ -n "$p" ]; then XRAY_API_PORT="$p"; fi
    fi
}

func_bytes_to_human() {
    local b=${1:-0}
    if [ $b -gt 1073741824 ]; then
        echo "$(echo "scale=2; $b/1073741824" | bc) GB"
    elif [ $b -gt 1048576 ]; then
        echo "$(echo "scale=2; $b/1048576" | bc) MB"
    else
        echo "$(echo "scale=2; $b/1024" | bc) KB"
    fi
}

# --- FUNÇÃO INTELIGENTE (Define Limite e Zera Contador se necessário) ---
func_set_limit() {
    header_limit
    echo "Definir Limite de Dados"
    echo "--------------------------------------"
    read -rp "Digite o Usuário (Nick): " nick
    if [ -z "$nick" ]; then return; fi
    
    # Verifica existência
    local is_locked=false
    if grep -q "\"email\": \"LOCKED_$nick\"" "$CONFIG_PATH"; then
        is_locked=true
    elif ! grep -q "\"email\": \"$nick\"" "$CONFIG_PATH"; then
        echo -e "${TXT_RED}Usuário não encontrado!${RESET}"; read -rp "Enter..."; return
    fi

    echo "Qual o limite de internet?"
    read -rp "Limite (GB): " gb_limit
    if ! [[ "$gb_limit" =~ ^[0-9]+$ ]]; then echo "Inválido."; sleep 1; return; fi

    local bytes_limit=$(echo "$gb_limit * 1073741824" | bc)
    
    # Salva Limite
    sed -i "/^$nick|/d" "$LIMITS_DB"
    echo "$nick|$bytes_limit" >> "$LIMITS_DB"

    echo ""
    read -rp "Deseja ZERAR o consumo atual deste usuário? [s/n]: " zerar
    if [[ "$zerar" =~ ^[Ss]$ ]]; then
        sed -i "/^$nick|/d" "$USAGE_DB"
        sed -i "/^$nick|/d" "$SESSION_DB"
        echo -e "${TXT_CYAN}Histórico zerado.${RESET}"
    fi

    # Se estiver bloqueado, desbloqueia
    if [ "$is_locked" = true ]; then
        local real_uuid=$(grep "^$nick|" "$USER_DB" | cut -d'|' -f2 | head -n 1)
        if [ -n "$real_uuid" ]; then
            jq --arg nick "$nick" --arg locked "LOCKED_$nick" --arg uuid "$real_uuid" \
               '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(if .email == $locked then .email = $nick | .id = $uuid else . end)' \
               "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            
            # Ao desbloquear, também usamos reload para não derrubar os outros
            systemctl reload xray > /dev/null 2>&1 || systemctl restart xray > /dev/null 2>&1
            echo -e "${TXT_GREEN}Usuário desbloqueado!${RESET}"
        fi
    fi

    echo -e "${TXT_GREEN}Limite salvo!${RESET}"
    read -rp "Enter para voltar..."
}

func_view_usage() {
    func_get_api_port
    header_limit
    # Mostra o consumo ACUMULADO (do banco de dados), não o do Xray (sessão)
    printf "%-18s | %-12s | %-12s | %s\n" "USUÁRIO" "USADO (DB)" "LIMITE" "STATUS"
    echo "------------------------------------------------------------"

    # Itera sobre quem tem limite definido
    while IFS='|' read -r nick limit_bytes; do
        if [ -z "$nick" ]; then continue; fi
        
        # Pega o acumulado histórico
        local usage_total=$(grep "^$nick|" "$USAGE_DB" | cut -d'|' -f2)
        [ -z "$usage_total" ] && usage_total=0

        local total_h=$(func_bytes_to_human "$usage_total")
        local limit_h=$(func_bytes_to_human "$limit_bytes")
        local status="${TXT_GREEN}OK${RESET}"
        
        # Verifica se está bloqueado visualmente
        if grep -q "\"email\": \"LOCKED_$nick\"" "$CONFIG_PATH"; then
             status="${TXT_RED}BLOQUEADO${RESET}"
        elif [ "$usage_total" -ge "$limit_bytes" ]; then
             status="${TXT_RED}EXCEDIDO${RESET}"
        else
             local pct=$(echo "scale=0; ($usage_total * 100) / $limit_bytes" | bc)
             status="${TXT_CYAN}${pct}%${RESET}"
        fi
        
        printf "%-18s | %-12s | %-12s | %b\n" "$nick" "$total_h" "$limit_h" "$status"
    done < "$LIMITS_DB"
    
    echo "------------------------------------------------------------"
    echo "Nota: Este consumo não zera se reiniciar a VPS."
    echo ""; read -rp "Enter para voltar..."
}

func_remove_limit() {
    header_limit
    read -rp "Usuário para remover limite: " nick
    if [ -z "$nick" ]; then return; fi
    
    sed -i "/^$nick|/d" "$LIMITS_DB"
    sed -i "/^$nick|/d" "$USAGE_DB"
    sed -i "/^$nick|/d" "$SESSION_DB"
    
    # Lógica de desbloqueio (igual anterior)
    if grep -q "\"email\": \"LOCKED_$nick\"" "$CONFIG_PATH"; then
        local real_uuid=$(grep "^$nick|" "$USER_DB" | cut -d'|' -f2 | head -n 1)
        if [ -n "$real_uuid" ]; then
            jq --arg nick "$nick" --arg locked "LOCKED_$nick" --arg uuid "$real_uuid" \
               '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(if .email == $locked then .email = $nick | .id = $uuid else . end)' \
               "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            # Reload suave
            systemctl reload xray > /dev/null 2>&1 || systemctl restart xray > /dev/null 2>&1
        fi
    fi
    echo -e "${TXT_GREEN}Limite removido e histórico limpo!${RESET}"
    sleep 2
}

# --- CORE LÓGICO: CALCULA DELTA E ACUMULA ---
# Argumento $1:
#   --cron: Silencioso + Bloqueia
#   --enforce: Visual + Bloqueia (Opção 4)
#   --sync-only: Visual + NÃO BLOQUEIA (Opção 5)
func_check_and_block() {
    local MODE="$1"
    func_get_api_port
    
    if [ "$MODE" != "--cron" ]; then 
        header_limit
        if [ "$MODE" == "--sync-only" ]; then
            echo "Sincronizando dados (Sem bloquear)..."
        else
            echo "Sincronizando e aplicando regras..."
        fi
    fi
    
    local blocked_count=0
    
    # Arquivos temporários para transação segura
    cp "$USAGE_DB" "${USAGE_DB}.tmp"
    cp "$SESSION_DB" "${SESSION_DB}.tmp"

    # Itera sobre usuários com limite
    while IFS='|' read -r nick limit_bytes; do
        # Se já está bloqueado, ignora
        if grep -q "\"email\": \"LOCKED_$nick\"" "$CONFIG_PATH"; then continue; fi
        
        # Pega dados atuais da API (Sessão Atual)
        local down=$($XRAY_BIN api stats -server="127.0.0.1:$XRAY_API_PORT" -name "user>>>${nick}>>>traffic>>>downlink" 2>/dev/null | grep "value" | awk '{print $2}')
        local up=$($XRAY_BIN api stats -server="127.0.0.1:$XRAY_API_PORT" -name "user>>>${nick}>>>traffic>>>uplink" 2>/dev/null | grep "value" | awk '{print $2}')
        [ -z "$down" ] && down=0; [ -z "$up" ] && up=0
        local current_session=$(echo "$down + $up" | bc)

        # Se API retornar vazio (erro), pula
        if [ -z "$current_session" ]; then continue; fi

        # Pega última leitura da sessão (SESSION_DB)
        local last_session=$(grep "^$nick|" "${SESSION_DB}.tmp" | cut -d'|' -f2)
        [ -z "$last_session" ] && last_session=0

        # Pega acumulado histórico (USAGE_DB)
        local historical_usage=$(grep "^$nick|" "${USAGE_DB}.tmp" | cut -d'|' -f2)
        [ -z "$historical_usage" ] && historical_usage=0

        # CÁLCULO DO DELTA
        local delta=0
        if [ "$current_session" -lt "$last_session" ]; then
            delta=$current_session # Restart detectado
        else
            delta=$(echo "$current_session - $last_session" | bc)
        fi

        local new_historical=$(echo "$historical_usage + $delta" | bc)

        # Atualiza os bancos temporários
        sed -i "/^$nick|/d" "${USAGE_DB}.tmp"
        echo "$nick|$new_historical" >> "${USAGE_DB}.tmp"
        
        sed -i "/^$nick|/d" "${SESSION_DB}.tmp"
        echo "$nick|$current_session" >> "${SESSION_DB}.tmp"

        # --- LÓGICA DE BLOQUEIO ---
        if [ "$new_historical" -ge "$limit_bytes" ]; then
            # Se for apenas SYNC, apenas avisa na tela
            if [ "$MODE" == "--sync-only" ]; then
                echo -e "${TXT_YELLOW}⚠️  $nick excedeu o limite! (Bloqueio pendente)${RESET}"
            
            # Se for CRON ou ENFORCE, aplica o bloqueio real
            else
                if [ "$MODE" != "--cron" ]; then echo -e "${TXT_RED}❌ $nick estourou. Bloqueando...${RESET}"; fi
                
                local fake_uuid=$(uuidgen)
                jq --arg nick "$nick" --arg locked "LOCKED_$nick" --arg fake "$fake_uuid" \
                   '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(if .email == $nick then .email = $locked | .id = $fake else . end)' \
                   "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
                ((blocked_count++))
            fi
        fi

    done < "$LIMITS_DB"
    
    # Commit
    mv "${USAGE_DB}.tmp" "$USAGE_DB"
    mv "${SESSION_DB}.tmp" "$SESSION_DB"
    
    # --- CORREÇÃO PRINCIPAL: RELOAD vs RESTART ---
    if [ $blocked_count -gt 0 ]; then
        # Tenta RELOAD primeiro (Não derruba conexões ativas dos outros clientes)
        # Se falhar, faz RESTART (Fallback de segurança)
        if ! systemctl reload xray > /dev/null 2>&1; then
            systemctl restart xray > /dev/null 2>&1
        fi
        
        if [ "$MODE" != "--cron" ]; then echo -e "${TXT_RED}🚫 $blocked_count bloqueados (Reload aplicado).${RESET}"; fi
    elif [ "$MODE" != "--cron" ]; then
        echo -e "${TXT_GREEN}Dados atualizados com sucesso.${RESET}"
    fi
    
    if [ "$MODE" != "--cron" ]; then read -rp "Enter..."; fi
}

# --- INIT (Cron chama sem argumentos ou com flag) ---
if [ "$1" == "--cron" ]; then func_check_and_block "--cron"; exit 0; fi

# --- MENU ---
while true; do
    header_limit
    echo -e "${TXT_CYAN}[1]. DEFINIR/ALTERAR LIMITE${RESET}"
    echo -e "${TXT_CYAN}[2]. VER CONSUMO ACUMULADO${RESET}"
    echo -e "${TXT_CYAN}[3]. REMOVER LIMITE${RESET}"
    echo -e "${TXT_RED}[4]. VERIFICAR E BLOQUEAR EXCEDENTES${RESET}"
    echo -e "${TXT_YELLOW}[5]. APENAS SINCRONIZAR (SEM BLOQUEIO)${RESET}"
    echo -e "${TXT_CYAN}[0]. VOLTAR AO MENU PRINCIPAL${RESET}"
    echo "--------------------------------------"
    
    read -rp "Opção: " choice
    case "$choice" in
        1) func_set_limit ;; 
        2) func_view_usage ;; 
        3) func_remove_limit ;; 
        4) func_check_and_block "--enforce" ;;    # Bloqueia de verdade
        5) func_check_and_block "--sync-only" ;;  # Só atualiza números
        0) exit 0 ;; *) echo "Inválido";;
    esac
done
