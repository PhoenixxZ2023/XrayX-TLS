#!/bin/bash
# bbr.sh - Ativador de BBR V1.0 — DragonCore
# BBR (Bottleneck Bandwidth and Round-trip propagation time) é um algoritmo
# de controle de congestionamento TCP desenvolvido pelo Google.
# Melhora velocidade e estabilidade da conexão VPN, especialmente em redes
# com perda de pacotes ou alta latência.

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

# --- VERIFICAÇÃO DE ROOT ---
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"
    exit 1
fi

clear
echo -e "${TITLE_BAR}   ATIVADOR DE BBR — DragonCore   ${RESET}"
echo ""

# --- STATUS ATUAL ---
_get_current_cc() {
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "desconhecido"
}

_get_current_qdisc() {
    sysctl -n net.core.default_qdisc 2>/dev/null || echo "desconhecido"
}

current_cc=$(_get_current_cc)
current_qdisc=$(_get_current_qdisc)

echo -e " ${TXT_CYAN}STATUS ATUAL:${RESET}"
echo -e " Algoritmo TCP:  ${TXT_YELLOW}${current_cc}${RESET}"
echo -e " Fila (qdisc):   ${TXT_YELLOW}${current_qdisc}${RESET}"
echo ""

# --- FUNÇÃO DE DESATIVAÇÃO ---
_disable_bbr() {
    echo ""
    echo -e "${TXT_YELLOW}Desativando BBR e restaurando padrão do sistema...${RESET}"

    # Remove arquivo de config dedicado do DragonCore
    rm -f /etc/sysctl.d/99-bbr-dragoncore.conf

    # Remove entradas do sysctl.conf se existirem
    if [ -f /etc/sysctl.conf ]; then
        sed -i '/net\.core\.default_qdisc.*fq/d'           /etc/sysctl.conf
        sed -i '/net\.ipv4\.tcp_congestion_control.*bbr/d' /etc/sysctl.conf
    fi

    # Remove autoload do módulo no boot
    rm -f /etc/modules-load.d/tcp_bbr.conf

    # Restaura para o padrão do sistema (cubic é o padrão Linux)
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    sysctl -w net.core.default_qdisc=pfifo_fast      >/dev/null 2>&1 || true

    local new_cc; new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    local new_qdisc; new_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")

    echo ""
    if [ "$new_cc" != "bbr" ]; then
        echo -e "${TXT_GREEN}✅ BBR desativado com sucesso!${RESET}"
        echo "-----------------------------------------"
        echo -e " Algoritmo TCP:  ${TXT_GREEN}${new_cc}${RESET} (padrão)"
        echo -e " Fila (qdisc):   ${TXT_GREEN}${new_qdisc}${RESET} (padrão)"
        echo "-----------------------------------------"
        echo ""
        echo -e "${TXT_YELLOW}Nota:${RESET} A mudança é imediata. Novas conexões usarão ${new_cc}."
        echo -e " O BBR não voltará após reiniciar o servidor."
    else
        echo -e "${TXT_RED}❌ Não foi possível desativar o BBR.${RESET}"
        echo -e " Pode estar configurado em outro arquivo de sysctl."
        echo -e " Verifique: ${TXT_CYAN}sysctl -a | grep congestion${RESET}"
    fi

    echo ""
    read -rp "Pressione Enter para voltar..."
}

# --- VERIFICA SE JÁ ESTÁ ATIVO ---
if [ "$current_cc" = "bbr" ]; then
    echo -e "${TXT_GREEN}✅ BBR está ativo neste sistema.${RESET}"
    echo ""

    if lsmod 2>/dev/null | grep -q tcp_bbr; then
        echo -e " Módulo kernel: ${TXT_GREEN}tcp_bbr carregado${RESET}"
    else
        echo -e " Módulo kernel: ${TXT_YELLOW}built-in no kernel (normal em kernels 5.x+)${RESET}"
    fi

    echo ""
    echo -e "${TXT_CYAN}[1] Manter BBR ativo${RESET}"
    echo -e "${TXT_RED}[2] Desativar BBR (restaurar padrão do sistema)${RESET}"
    echo -e "${TXT_CYAN}[0] Voltar${RESET}"
    echo ""
    read -rp "Opção: " bbr_opt
    case "${bbr_opt:-0}" in
        1) echo -e "${TXT_GREEN}BBR mantido.${RESET}"; sleep 1; exit 0 ;;
        2)
            read -rp "Confirmar desativação do BBR? [s/N]: " conf
            [[ "${conf:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; exit 0; }
            _disable_bbr
            exit 0
            ;;
        *) exit 0 ;;
    esac
fi

# --- VERIFICA SUPORTE DO KERNEL ---
echo -e "${TXT_CYAN}Verificando compatibilidade do kernel...${RESET}"

kernel_version=$(uname -r)
kernel_major=$(echo "$kernel_version" | cut -d. -f1)
kernel_minor=$(echo "$kernel_version" | cut -d. -f2)

echo -e " Kernel: ${TXT_YELLOW}${kernel_version}${RESET}"

# BBR requer kernel 4.9+
if [ "$kernel_major" -lt 4 ] || { [ "$kernel_major" -eq 4 ] && [ "$kernel_minor" -lt 9 ]; }; then
    echo ""
    echo -e "${TXT_RED}❌ Kernel muito antigo para BBR.${RESET}"
    echo -e " BBR requer kernel 4.9 ou superior."
    echo -e " Seu kernel: ${kernel_version}"
    echo -e " Atualize o kernel ou use outro servidor."
    echo ""
    read -rp "Pressione Enter para voltar..."
    exit 1
fi

echo -e " Kernel compatível: ${TXT_GREEN}✓${RESET}"
echo ""

# Verifica se o módulo tcp_bbr está disponível
bbr_available=false
if modprobe --dry-run tcp_bbr >/dev/null 2>&1; then
    bbr_available=true
    echo -e " Módulo tcp_bbr: ${TXT_GREEN}disponível${RESET}"
elif grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    bbr_available=true
    echo -e " Módulo tcp_bbr: ${TXT_GREEN}built-in no kernel${RESET}"
else
    echo -e " Módulo tcp_bbr: ${TXT_YELLOW}não encontrado — tentaremos mesmo assim${RESET}"
fi

echo ""

# --- INFORMAÇÕES SOBRE O BBR ---
echo -e "${TXT_CYAN}O que o BBR faz:${RESET}"
echo " • Melhora throughput em conexões com perda de pacotes"
echo " • Reduz latência em redes congestionadas"
echo " • Aumenta velocidade de download/upload no túnel VPN"
echo " • Não requer reinicialização do sistema"
echo ""

# --- CONFIRMAÇÃO ---
read -rp "Ativar BBR agora? [s/N]: " confirm
[[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; exit 0; }

echo ""
echo -e "${TXT_YELLOW}Ativando BBR...${RESET}"

# --- CARREGA O MÓDULO ---
modprobe tcp_bbr 2>/dev/null || true

# --- VERIFICA ALGORITMOS DISPONÍVEIS ---
available_cc=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
if ! echo "$available_cc" | grep -q "\bbbr\b"; then
    echo -e "${TXT_RED}❌ BBR não está disponível neste kernel após carregar o módulo.${RESET}"
    echo -e " Algoritmos disponíveis: ${available_cc}"
    echo -e " Considere atualizar o kernel: ${TXT_YELLOW}apt install --install-recommends linux-generic${RESET}"
    echo ""
    read -rp "Pressione Enter para voltar..."
    exit 1
fi

# --- APLICA CONFIGURAÇÃO VIA SYSCTL ---
# Remove entradas antigas para evitar duplicatas
if [ -f /etc/sysctl.conf ]; then
    sed -i '/net\.core\.default_qdisc/d'              /etc/sysctl.conf
    sed -i '/net\.ipv4\.tcp_congestion_control/d'     /etc/sysctl.conf
fi

# Cria ou atualiza arquivo de configuração dedicado
SYSCTL_FILE="/etc/sysctl.d/99-bbr-dragoncore.conf"
cat > "$SYSCTL_FILE" << 'EOF'
# DragonCore — BBR TCP Congestion Control
# Ativado pelo módulo bbr.sh
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

chmod 644 "$SYSCTL_FILE"

# Aplica imediatamente sem reiniciar
sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true

# Garante que módulo carrega no boot
if [ -d /etc/modules-load.d ]; then
    echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf
    chmod 644 /etc/modules-load.d/tcp_bbr.conf
fi

# --- VERIFICA RESULTADO ---
sleep 1
new_cc=$(_get_current_cc)
new_qdisc=$(_get_current_qdisc)

echo ""
if [ "$new_cc" = "bbr" ]; then
    echo -e "${TXT_GREEN}✅ BBR ativado com sucesso!${RESET}"
    echo "-----------------------------------------"
    echo -e " Algoritmo TCP:  ${TXT_GREEN}${new_cc}${RESET}"
    echo -e " Fila (qdisc):   ${TXT_GREEN}${new_qdisc}${RESET}"
    echo -e " Config salva:   ${TXT_CYAN}${SYSCTL_FILE}${RESET}"
    echo -e " Boot automático:${TXT_GREEN} ✓ (modules-load.d)${RESET}"
    echo "-----------------------------------------"
    echo ""
    echo -e "${TXT_YELLOW}Dica:${RESET} O BBR já está ativo. Não é necessário reiniciar."
    echo -e " A melhoria de velocidade será perceptível imediatamente nas"
    echo -e " novas conexões VPN — conexões existentes não são afetadas."
else
    echo -e "${TXT_RED}❌ Falha ao ativar BBR.${RESET}"
    echo -e " Algoritmo atual: ${new_cc}"
    echo -e " Esperado: bbr"
    echo ""
    echo -e "${TXT_YELLOW}Tente reiniciar o sistema e executar novamente.${RESET}"
fi

echo ""
read -rp "Pressione Enter para voltar..."
