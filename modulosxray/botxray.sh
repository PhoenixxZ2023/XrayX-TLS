#!/bin/bash
# botxray.sh - Gerenciador do Bot Telegram V7.7
# - Menu interativo (Instalar, Ligar, Desligar, Logs)
# - Wrappers setuid C compilados (sem sudo, resolve nosuid)
# - Token via EnvironmentFile
# - ReadWritePaths corrigido
# - Permissoes corretas e patch automatico no Python

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (codigo: $?)"; read -rp "Enter...";' ERR

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main}"
LOG_FILE="/tmp/botxray_install.log"

VERMELHO='\033[1;31m'
VERDE='\033[1;32m'
AMARELO='\033[1;33m'
AZUL='\033[1;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

_PKG_MANAGER=""
_APT_UPDATED=0
_detect_pkg_manager() {
    [ -n "$_PKG_MANAGER" ] && return
    if   command -v apt-get &>/dev/null; then _PKG_MANAGER="apt"
    elif command -v dnf     &>/dev/null; then _PKG_MANAGER="dnf"
    elif command -v yum     &>/dev/null; then _PKG_MANAGER="yum"
    elif command -v pacman  &>/dev/null; then _PKG_MANAGER="pacman"
    else echo -e "${VERMELHO}Gerenciador de pacotes nao detectado.${RESET}"; exit 1; fi
}

ensure_pkg() {
    local bin="$1" pkg="$2"
    command -v "$bin" &>/dev/null && return 0
    _detect_pkg_manager
    case "$_PKG_MANAGER" in
        apt)
            [ "$_APT_UPDATED" -eq 0 ] && { apt-get update -y >>"$LOG_FILE" 2>&1 || true; _APT_UPDATED=1; }
            apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        pacman)  pacman -Sy --noconfirm "$pkg"      >>"$LOG_FILE" 2>&1 ;;
    esac
}

[ "${EUID:-$(id -u)}" -ne 0 ] && { echo -e "${VERMELHO}Execute como root!${RESET}"; exit 1; }

# ==========================================
# FUNÇÃO DE INSTALAÇÃO
# ==========================================
func_install_bot() {
    : > "$LOG_FILE"
    clear
    echo -e "${AZUL}==================================================${RESET}"
    echo -e "${AMARELO}      INSTALADOR BOT TELEGRAM - V7.7           ${RESET}"
    echo -e "${AZUL}==================================================${RESET}"
    echo ""

    echo "Preparando ambiente..."
    ensure_pkg python3    python3
    ensure_pkg pip3       python3-pip
    ensure_pkg curl       curl
    ensure_pkg jq         jq
    ensure_pkg gcc        gcc
    ensure_pkg tar        tar

    # python3-venv: nome varia por distro
    python3 -m venv --help >/dev/null 2>&1 || ensure_pkg python3 python3-venv || true

    mkdir -p /opt/XrayTools

    echo ""
    echo -e "${AMARELO}1. Token do BotFather (formato: 123456789:ABCdef...):${RESET}"
    read -r -p "Token: " bot_token

    echo ""
    echo -e "${AMARELO}2. Seu ID numerico do Telegram (Admin):${RESET}"
    read -r -p "ID Admin: " admin_id

    if [ -z "${bot_token:-}" ] || ! [[ "$bot_token" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{35,}$ ]]; then
        echo -e "${VERMELHO}Token invalido.${RESET}"; sleep 2; return 1
    fi
    if [ -z "${admin_id:-}" ] || ! [[ "$admin_id" =~ ^[0-9]+$ ]]; then
        echo -e "${VERMELHO}ID Admin invalido.${RESET}"; sleep 2; return 1
    fi

    # --- USUARIO DEDICADO ---
    if ! id -u botxray >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin botxray
    fi

    # --- WRAPPERS SETUID EM C ---
    echo ""
    echo "Compilando wrappers setuid..."
    for s in add_user remover_user block_user unblock_user backup_bot restore_bot; do
        cat > /tmp/wrap_${s}.c << EOF
#include <unistd.h>
#include <stdlib.h>
int main(int argc, char *argv[]) {
    setuid(0); setgid(0);
    putenv("TERM=xterm");
    putenv("HOME=/root");
    putenv("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    char *args[] = {"/bin/bash", "/usr/local/bin/${s}.sh", (char*)0};
    execv("/bin/bash", args);
    return 1;
}
EOF
        gcc -o /usr/local/bin/wrap_${s} /tmp/wrap_${s}.c
        chown root:root /usr/local/bin/wrap_${s}
        chmod 4755 /usr/local/bin/wrap_${s}
        rm -f /tmp/wrap_${s}.c
    done
    echo -e "${VERDE}Wrappers criados com sucesso.${RESET}"

    # --- DOWNLOAD DO botxray.py ---
    echo ""
    echo "Baixando bot..."
    BOT_PY="/opt/XrayTools/botxray.py"
    tmp_bot=$(mktemp /tmp/botxray_XXXXXX.py)

    if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 60 --connect-timeout 10 \
            -o "$tmp_bot" "${REPO_BASE}/modulosxray/botxray.py" 2>>"$LOG_FILE"; then
        echo -e "${VERMELHO}Erro ao baixar botxray.py${RESET}"
        rm -f "$tmp_bot"; sleep 2; return 1
    fi
    [ -s "$tmp_bot" ] || { echo -e "${VERMELHO}botxray.py vazio.${RESET}"; rm -f "$tmp_bot"; sleep 2; return 1; }

    expected_sha=$(curl -fsSL --max-time 10 "${REPO_BASE}/modulosxray/botxray.py.sha256" 2>/dev/null | awk '{print $1}' || true)
    if [ -n "${expected_sha:-}" ]; then
        actual_sha=$(sha256sum "$tmp_bot" | awk '{print $1}')
        [ "$expected_sha" = "$actual_sha" ] || {
            echo -e "${VERMELHO}Falha de integridade.${RESET}"; rm -f "$tmp_bot"; sleep 2; return 1; }
        echo -e "${VERDE}SHA256 verificado.${RESET}"
    else
        echo -e "${AMARELO}Hash nao disponivel - verificacao ignorada.${RESET}"
    fi

    # --- PATCH AUTOMATICO NO botxray.py ---
    python3 - "$tmp_bot" << 'PYEOF'
import sys, re

path = sys.argv[1]
src = open(path, encoding="utf-8", errors="ignore").read()

# 1) Token e admin via os.environ
src = re.sub(r'BOT_TOKEN\s*=\s*["\'].*?["\']', 'BOT_TOKEN = os.environ.get("BOT_TOKEN", "")', src)
src = re.sub(r'ADMIN_ID\s*=\s*\d+', 'ADMIN_ID = int(os.environ.get("ADMIN_ID", "0"))', src)

# 2) Caminhos dos scripts -> wrappers setuid
for old, new in [
    ('"/usr/local/bin/add_user.sh"',     '"/usr/local/bin/wrap_add_user"'),
    ('"/usr/local/bin/remover_user.sh"', '"/usr/local/bin/wrap_remover_user"'),
    ('"/usr/local/bin/block_user.sh"',   '"/usr/local/bin/wrap_block_user"'),
    ('"/usr/local/bin/unblock_user.sh"', '"/usr/local/bin/wrap_unblock_user"'),
    ('"/usr/local/bin/backup_bot.sh"',   '"/usr/local/bin/wrap_backup_bot"'),
    ('"/usr/local/bin/restore_bot.sh"',  '"/usr/local/bin/wrap_restore_bot"'),
]:
    src = src.replace(old, new)

# 3) Remove sudo das chamadas subprocess
src = src.replace('["sudo", "-n", path]', '[path]')
src = src.replace('["sudo", "-n", path] + args', '[path] + args')

# 4) Corrige type hints incompativeis com Python 3.8
src = src.replace('dict | None', 'Optional[dict]')
src = src.replace('str | None', 'Optional[str]')
src = re.sub(r'\btuple\[([^\]]+)\]', lambda m: 'Tuple[' + m.group(1) + ']', src)
src = re.sub(r'\blist\[([^\]]+)\]', lambda m: 'List[' + m.group(1) + ']', src)

# 5) Garante imports necessarios
if 'from typing import' not in src:
    src = src.replace('import os\n', 'import os\nfrom typing import Optional, Tuple, List\n', 1)
if 'from __future__ import annotations' not in src:
    src = 'from __future__ import annotations\n' + src

open(path, 'w', encoding='utf-8').write(src)
print("Patch aplicado com sucesso no Python.")
PYEOF

    mv -f "$tmp_bot" "$BOT_PY"
    chmod 0640 "$BOT_PY"
    chown root:botxray "$BOT_PY"

    # --- ENVIRONMENTFILE ---
    ENV_FILE="/opt/XrayTools/.bot_env"
    printf 'BOT_TOKEN=%s\nADMIN_ID=%s\n' "$bot_token" "$admin_id" > "$ENV_FILE"
    chmod 0640 "$ENV_FILE"
    chown root:botxray "$ENV_FILE"
    echo -e "${VERDE}Credenciais salvas em ${ENV_FILE}${RESET}"

    # --- VENV COM VERSOES FIXADAS ---
    if [ ! -d /opt/XrayTools/venv ]; then
        python3 -m venv /opt/XrayTools/venv
    fi
    echo "Instalando dependencias Python..."
    /opt/XrayTools/venv/bin/pip install --quiet --upgrade pip >>"$LOG_FILE" 2>&1
    /opt/XrayTools/venv/bin/pip install --quiet \
        "python-telegram-bot==20.7" \
        "requests==2.31.0" >>"$LOG_FILE" 2>&1

    # --- backup_bot.sh ---
    cat > /usr/local/bin/backup_bot.sh << 'BKPEOF'
#!/bin/bash
set -Eeuo pipefail
umask 077
OUT_DIR="/root/backups"
mkdir -p "$OUT_DIR"
ts="$(date +%Y%m%d_%H%M%S)"
OUT_FILE="${OUT_DIR}/backup_dragoncore_bot_${ts}.tar.gz"
[ -d /opt/XrayTools      ] || { echo "ERR: /opt/XrayTools ausente"; exit 2; }
[ -d /usr/local/etc/xray ] || { echo "ERR: /usr/local/etc/xray ausente"; exit 2; }
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/opt/XrayTools"
for f in users.db limits.db usage.db session.db active_domain; do
    [ -f "/opt/XrayTools/$f" ] && cp -f "/opt/XrayTools/$f" "$tmpdir/opt/XrayTools/$f"
done
mkdir -p "$tmpdir/usr/local/etc"
cp -a /usr/local/etc/xray "$tmpdir/usr/local/etc/" 2>/dev/null || true
mkdir -p "$tmpdir/opt"
[ -d /opt/DragonCoreSSL ] && cp -a /opt/DragonCoreSSL "$tmpdir/opt/" 2>/dev/null || true
tar -czf "$OUT_FILE" -C "$tmpdir" opt usr >/dev/null 2>&1 || { echo "ERR: falha tar"; exit 3; }
chmod 0600 "$OUT_FILE"
sha256sum "$OUT_FILE" > "${OUT_FILE}.sha256"
chmod 0600 "${OUT_FILE}.sha256"
echo "$OUT_FILE"
BKPEOF
    chmod 0755 /usr/local/bin/backup_bot.sh
    chown root:root /usr/local/bin/backup_bot.sh

    # --- restore_bot.sh ---
    cat > /usr/local/bin/restore_bot.sh << 'RSTEOF'
#!/bin/bash
set -Eeuo pipefail
FILE="${1:-}"
[ -n "$FILE" ] || { echo "ERR: informe o .tar.gz"; exit 2; }
[ -f "$FILE" ] || { echo "ERR: arquivo nao existe"; exit 2; }
tar -tzf "$FILE" >/dev/null 2>&1 || { echo "ERR: tar corrompido"; exit 4; }
SHA_FILE="${FILE}.sha256"
if [ -f "$SHA_FILE" ]; then
    expected=$(awk '{print $1}' "$SHA_FILE")
    actual=$(sha256sum "$FILE" | awk '{print $1}')
    [ "$expected" = "$actual" ] || { echo "ERR: SHA256 nao confere"; exit 5; }
fi
while IFS= read -r entry; do
    entry="${entry#./}"; [ -n "$entry" ] || continue
    [[ "$entry" != /* ]]     || { echo "ERR: path absoluto"; exit 9; }
    [[ "$entry" != *".."* ]] || { echo "ERR: traversal"; exit 9; }
    case "$entry" in
        opt/XrayTools/*|usr/local/etc/xray/*|opt/DragonCoreSSL/*) ;;
        *) echo "ERR: path nao permitido: $entry"; exit 9 ;;
    esac
done < <(tar -tzf "$FILE" 2>/dev/null)
SNAP=$(mktemp /tmp/restore_snap_XXXXXX.tar.gz)
SNAP_PATHS=("opt/XrayTools" "usr/local/etc/xray")
[ -d /opt/DragonCoreSSL ] && SNAP_PATHS+=("opt/DragonCoreSSL")
tar -czf "$SNAP" -C / "${SNAP_PATHS[@]}" >/dev/null 2>&1 && chmod 0600 "$SNAP" || SNAP=""
systemctl stop xray    >/dev/null 2>&1 || true
systemctl stop botxray >/dev/null 2>&1 || true
if ! tar -xzf "$FILE" -C / 2>/dev/null; then
    echo "ERR: falha ao extrair"
    [ -n "${SNAP:-}" ] && tar -xzf "$SNAP" -C / >/dev/null 2>&1 || true
    systemctl start xray >/dev/null 2>&1 || true
    exit 3
fi
chown nobody:nogroup /usr/local/etc/xray/config.json 2>/dev/null || true
chmod 0644 /usr/local/etc/xray/config.json 2>/dev/null || true
[ -d /opt/DragonCoreSSL ] && {
    chown -R nobody:nogroup /opt/DragonCoreSSL 2>/dev/null || true
    chmod 750 /opt/DragonCoreSSL 2>/dev/null || true
    chmod 644 /opt/DragonCoreSSL/fullchain.pem 2>/dev/null || true
    chmod 640 /opt/DragonCoreSSL/privkey.pem 2>/dev/null || true
}
systemctl restart xray    >/dev/null 2>&1 || true
systemctl restart botxray >/dev/null 2>&1 || true
sleep 2
systemctl is-active --quiet xray 2>/dev/null && {
    [ -n "${SNAP:-}" ] && rm -f "$SNAP"
    echo "OK"
} || { echo "AVISO: Xray nao ficou ativo. Snapshot: ${SNAP:-N/A}"; exit 6; }
RSTEOF
    chmod 0755 /usr/local/bin/restore_bot.sh
    chown root:root /usr/local/bin/restore_bot.sh

    # --- PERMISSOES DO DIRETORIO ---
    mkdir -p /opt/XrayTools/backups
    chown -R botxray:botxray /opt/XrayTools
    chmod 0750 /opt/XrayTools
    chmod 0750 /opt/XrayTools/backups
    chown root:botxray "$ENV_FILE"
    chmod 0640 "$ENV_FILE"
    chown root:botxray "$BOT_PY"
    chmod 0640 "$BOT_PY"

    # --- SYSTEMD SERVICE ---
    cat > /etc/systemd/system/botxray.service << 'SVCEOF'
[Unit]
Description=DragonCore Telegram Bot
After=network.target

[Service]
Type=simple
User=botxray
Group=botxray
WorkingDirectory=/opt/XrayTools
EnvironmentFile=/opt/XrayTools/.bot_env
ExecStart=/opt/XrayTools/venv/bin/python /opt/XrayTools/botxray.py
Restart=always
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/opt/XrayTools /tmp /root/backups /usr/local/etc/xray /usr/local/bin

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable  botxray >/dev/null 2>&1 || true
    systemctl restart botxray >/dev/null 2>&1 || true
    sleep 2

    echo ""
    if systemctl is-active --quiet botxray 2>/dev/null; then
        echo -e "${VERDE}BOT ATIVADO COM SUCESSO!${RESET}"
    else
        echo -e "${AMARELO}Bot pode nao estar ativo. Verifique os logs.${RESET}"
    fi

    echo ""
    read -rp "Pressione ENTER para voltar ao Gerenciador..."
}

# ==========================================
# FUNÇÕES DE GERENCIAMENTO
# ==========================================
func_start_bot() {
    echo -e "\nIniciando o Bot..."
    systemctl enable botxray >/dev/null 2>&1 || true
    systemctl start botxray >/dev/null 2>&1 || true
    sleep 1
    if systemctl is-active --quiet botxray; then
        echo -e "${VERDE}✅ Bot iniciado e rodando perfeitamente!${RESET}"
    else
        echo -e "${VERMELHO}❌ Falha ao iniciar o Bot. Verifique os logs.${RESET}"
    fi
    sleep 2
}

func_stop_bot() {
    echo -e "\nParando o Bot..."
    systemctl stop botxray >/dev/null 2>&1 || true
    systemctl disable botxray >/dev/null 2>&1 || true
    sleep 1
    echo -e "${AMARELO}⛔ Bot desligado e desativado da inicialização.${RESET}"
    sleep 2
}

func_view_logs() {
    clear
    echo -e "${AZUL}==================================================${RESET}"
    echo -e "${AMARELO}   LOGS DO BOT (AO VIVO) - Pressione CTRL+C para sair   ${RESET}"
    echo -e "${AZUL}==================================================${RESET}"
    journalctl -u botxray -f || true
}

# ==========================================
# MENU PRINCIPAL DO GERENCIADOR
# ==========================================
while true; do
    clear
    echo -e "${AZUL}==================================================${RESET}"
    echo -e "${AMARELO}      GERENCIADOR DO BOT TELEGRAM V7.7           ${RESET}"
    echo -e "${AZUL}==================================================${RESET}"
    
    status_msg="${VERMELHO}NÃO INSTALADO${RESET}"
    if [ -f /etc/systemd/system/botxray.service ]; then
        if systemctl is-active --quiet botxray 2>/dev/null; then
            status_msg="${VERDE}ATIVO E RODANDO${RESET}"
        else
            status_msg="${VERMELHO}PARADO / DESATIVADO${RESET}"
        fi
    fi

    echo -e " STATUS DO BOT: ${status_msg}"
    echo -e "${AZUL}==================================================${RESET}"
    echo -e " ${VERDE}[1]${RESET} INSTALAR OU ATUALIZAR BOT"
    echo -e " ${VERDE}[2]${RESET} LIGAR BOT"
    echo -e " ${VERDE}[3]${RESET} DESLIGAR BOT"
    echo -e " ${VERDE}[4]${RESET} VER LOGS EM TEMPO REAL"
    echo -e " ${VERMELHO}[0]${RESET} VOLTAR AO MENU PRINCIPAL"
    echo -e "${AZUL}==================================================${RESET}"
    
    read -r -p "Escolha uma opção: " opt
    case "$opt" in
        1) func_install_bot ;;
        2) func_start_bot ;;
        3) func_stop_bot ;;
        4) func_view_logs ;;
        0) exit 0 ;;
        *) echo -e "${VERMELHO}Opção inválida!${RESET}"; sleep 1 ;;
    esac
done
