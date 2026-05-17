#!/bin/bash
# botxray.sh - Instalador Completo (SAFE) com venv + sudoers + backup + restore

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; read -rp "Enter...";' ERR

REPO_BASE="https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main"

VERMELHO='\033[1;31m'
VERDE='\033[1;32m'
AMARELO='\033[1;33m'
AZUL='\033[1;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

ensure_pkg() {
  local bin="$1" pkg="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "$pkg" >/dev/null 2>&1
  fi
}

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo -e "${VERMELHO}❌ Execute como root!${RESET}"
  exit 1
fi

clear
echo -e "${AZUL}==================================================${RESET}"
echo -e "${AMARELO}      🤖 CONFIGURAÇÃO DO BOT TELEGRAM 🤖       ${RESET}"
echo -e "${AZUL}==================================================${RESET}"
echo ""

echo "Preparando ambiente..."
ensure_pkg python3 python3
ensure_pkg pip3 python3-pip
ensure_pkg curl curl
ensure_pkg python3-venv python3-venv
ensure_pkg jq jq
ensure_pkg sudo sudo
ensure_pkg tar tar

mkdir -p /opt/XrayTools

echo ""
echo -e "${AMARELO}1. Digite o Token do BotFather:${RESET}"
read -r -p "Token: " bot_token

echo ""
echo -e "${AMARELO}2. Digite o SEU ID Numérico (Admin):${RESET}"
read -r -p "ID Admin: " admin_id

if [ -z "${bot_token:-}" ] || [ -z "${admin_id:-}" ] || ! [[ "$admin_id" =~ ^[0-9]+$ ]]; then
  echo -e "${VERMELHO}❌ Dados inválidos/incompletos!${RESET}"
  exit 1
fi

# cria usuário do bot
if ! id -u botxray >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin botxray
fi

# baixa bot
echo ""
echo "Baixando bot..."
curl -fsSL -o /opt/XrayTools/botxray.py "$REPO_BASE/botxray.py"
if [ ! -s /opt/XrayTools/botxray.py ]; then
  echo -e "${VERMELHO}Erro ao baixar botxray.py.${RESET}"
  exit 1
fi

# substitui token/admin (seguro com caracteres especiais)
BOT_TOKEN_ENV="$bot_token" ADMIN_ID_ENV="$admin_id" python3 - <<'PY'
import os
from pathlib import Path

token = os.environ.get("BOT_TOKEN_ENV","")
admin = os.environ.get("ADMIN_ID_ENV","")

p = Path("/opt/XrayTools/botxray.py")
s = p.read_text(encoding="utf-8", errors="ignore")

s = s.replace('BOT_TOKEN = "SEU_TOKEN_AQUI"', f'BOT_TOKEN = "{token}"')
s = s.replace("ADMIN_ID = 123456789", f"ADMIN_ID = {admin}")

p.write_text(s, encoding="utf-8")
PY

# venv isolado
if [ ! -d /opt/XrayTools/venv ]; then
  python3 -m venv /opt/XrayTools/venv
fi
/opt/XrayTools/venv/bin/pip install -U pip >/dev/null 2>&1
/opt/XrayTools/venv/bin/pip install -U python-telegram-bot requests >/dev/null 2>&1

# scripts headless do bot
# backup: gera .tar.gz e imprime o path
cat > /usr/local/bin/backup_bot.sh <<'EOF'
#!/bin/bash
set -Eeuo pipefail
umask 077

OUT_DIR="/opt/XrayTools/backups"
mkdir -p "$OUT_DIR"

ts="$(date +%Y%m%d_%H%M%S)"
OUT_FILE="${OUT_DIR}/backup_dragoncore_${ts}.tar.gz"

# paths essenciais
[ -d /opt/XrayTools ] || { echo "ERR: /opt/XrayTools ausente"; exit 2; }
[ -d /usr/local/etc/xray ] || { echo "ERR: /usr/local/etc/xray ausente"; exit 2; }
mkdir -p /opt/DragonCoreSSL 2>/dev/null || true

# evita “backup dentro de backup”: inclui só DBs + config + SSL
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# copia somente o necessário de /opt/XrayTools
mkdir -p "$tmpdir/opt/XrayTools"
for f in users.db limits.db usage.db session.db active_domain; do
  [ -f "/opt/XrayTools/$f" ] && cp -f "/opt/XrayTools/$f" "$tmpdir/opt/XrayTools/$f"
done

# garante estrutura
mkdir -p "$tmpdir/usr/local/etc"
cp -a /usr/local/etc/xray "$tmpdir/usr/local/etc/" 2>/dev/null || true

mkdir -p "$tmpdir/opt"
cp -a /opt/DragonCoreSSL "$tmpdir/opt/" 2>/dev/null || true

tar -czf "$OUT_FILE" -C "$tmpdir" opt usr >/dev/null 2>&1 || { echo "ERR: falha tar"; exit 3; }

chmod 600 "$OUT_FILE" 2>/dev/null || true
echo "$OUT_FILE"
EOF
chmod +x /usr/local/bin/backup_bot.sh

# restore: recebe caminho do tar e restaura somente paths permitidos
cat > /usr/local/bin/restore_bot.sh <<'EOF'
#!/bin/bash
set -Eeuo pipefail

FILE="${1:-}"
[ -n "$FILE" ] || { echo "ERR: informe o caminho do .tar.gz"; exit 2; }
[ -f "$FILE" ] || { echo "ERR: arquivo não existe"; exit 2; }

# valida conteúdo
tar -tzf "$FILE" | while IFS= read -r entry; do
  entry="${entry#./}"
  [ -n "$entry" ] || continue
  [[ "$entry" != /* ]] || { echo "ERR: path absoluto"; exit 9; }
  [[ "$entry" != *".."* ]] || { echo "ERR: contém .."; exit 9; }
  case "$entry" in
    opt/XrayTools/*) ;;
    usr/local/etc/xray/*) ;;
    opt/DragonCoreSSL/*) ;;
    *) echo "ERR: path não permitido: $entry"; exit 9 ;;
  esac
done

systemctl stop xray >/dev/null 2>&1 || true
systemctl stop botxray >/dev/null 2>&1 || true

tar -xzf "$FILE" -C / opt/XrayTools usr/local/etc/xray opt/DragonCoreSSL >/dev/null 2>&1

chmod 700 /opt/XrayTools 2>/dev/null || true
chmod 600 /opt/XrayTools/users.db 2>/dev/null || true

# xray roda como nobody => precisa ler pem
chown -R nobody:nogroup /opt/DragonCoreSSL 2>/dev/null || true
chmod 750 /opt/DragonCoreSSL 2>/dev/null || true
chmod 644 /opt/DragonCoreSSL/fullchain.pem 2>/dev/null || true
chmod 640 /opt/DragonCoreSSL/privkey.pem 2>/dev/null || true

systemctl restart xray >/dev/null 2>&1 || true
systemctl restart botxray >/dev/null 2>&1 || true
echo "OK"
EOF
chmod +x /usr/local/bin/restore_bot.sh

# sudoers restrito: permite somente scripts necessários
cat > /etc/sudoers.d/botxray <<'EOF'
Defaults:botxray !requiretty
Defaults:botxray !authenticate
Defaults:botxray secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

botxray ALL=(root) NOPASSWD: /bin/bash /usr/local/bin/add_user.sh
botxray ALL=(root) NOPASSWD: /bin/bash /usr/local/bin/remover_user.sh
botxray ALL=(root) NOPASSWD: /bin/bash /usr/local/bin/block_user.sh
botxray ALL=(root) NOPASSWD: /bin/bash /usr/local/bin/unblock_user.sh
botxray ALL=(root) NOPASSWD: /bin/bash /usr/local/bin/backup_bot.sh
botxray ALL=(root) NOPASSWD: /bin/bash /usr/local/bin/restore_bot.sh
EOF
chmod 440 /etc/sudoers.d/botxray
visudo -cf /etc/sudoers.d/botxray >/dev/null

# permissões do diretório do bot
mkdir -p /opt/XrayTools/backups
chown -R botxray:botxray /opt/XrayTools
chmod 750 /opt/XrayTools
chmod 750 /opt/XrayTools/backups
chmod 640 /opt/XrayTools/botxray.py 2>/dev/null || true

# service systemd hardened (sem quebrar leitura)
cat > /etc/systemd/system/botxray.service <<'EOF'
[Unit]
Description=DragonCore Telegram Bot
After=network.target

[Service]
Type=simple
User=botxray
Group=botxray
WorkingDirectory=/opt/XrayTools
ExecStart=/opt/XrayTools/venv/bin/python /opt/XrayTools/botxray.py
Restart=always
RestartSec=10

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/opt/XrayTools /tmp

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable botxray >/dev/null 2>&1 || true
systemctl restart botxray >/dev/null 2>&1 || true

echo ""
echo -e "${VERDE}🤖 BOT ATIVADO COM SUCESSO!${RESET}"
echo "Teste no Telegram: /start ou /menu"
echo ""
systemctl status botxray --no-pager | sed -n '1,20p'
echo ""
read -rp "Pressione ENTER para voltar..."
