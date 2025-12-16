#!/bin/bash
# installxray.sh - Instalador Remoto via GitHub

# --- Variáveis ---
XRAY_DIR="/opt/XrayTools"
MENU_DESTINATION="$XRAY_DIR/menuxray.sh"
# Link direto para o arquivo RAW do seu repositório
MENU_GITHUB_URL="https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/menuxray.sh"

# --- CONFIGURAÇÃO DB ---
DB_HOST="127.0.0.1"
DB_NAME="dragoncore"
DB_USER="root"
DB_PASS="senha"

if [ "$EUID" -ne 0 ]; then echo "Execute como root!"; exit 1; fi

echo "=================================================="
echo "🚀 Instalando DragonCore Xray via GitHub"
echo "=================================================="

echo "1. Instalando dependências..."
apt update -y >/dev/null 2>&1
apt install -y uuid-runtime curl jq net-tools openssl wget postgresql postgresql-contrib >/dev/null 2>&1
echo "✅ Dependências OK."

echo "2. Configurando PostgreSQL..."
export PGPASSWORD=$DB_PASS
systemctl start postgresql
systemctl enable postgresql
sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null || true
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>/dev/null || true
unset PGPASSWORD
echo "✅ Banco de Dados OK."

echo "3. Baixando Menu Xray do GitHub..."
mkdir -p "$XRAY_DIR"

# Baixa sempre a versão mais nova do repositório
wget -qO "$MENU_DESTINATION" "$MENU_GITHUB_URL"

if [ $? -ne 0 ] || [ ! -s "$MENU_DESTINATION" ]; then
    echo "❌ ERRO: Falha ao baixar menuxray.sh do GitHub."
    echo "Verifique se o link $MENU_GITHUB_URL está acessível."
    exit 1
fi
echo "✅ Download concluído."

echo "4. Instalando Xray Core..."
if ! command -v xray &> /dev/null; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
fi

echo "5. Configurando sistema..."
chmod +x "$MENU_DESTINATION"
# Injeta credenciais do DB no arquivo baixado
sed -i "s|{DB_HOST}|$DB_HOST|g" "$MENU_DESTINATION"
sed -i "s|{DB_NAME}|$DB_NAME|g" "$MENU_DESTINATION"
sed -i "s|{DB_USER}|$DB_USER|g" "$MENU_DESTINATION"
sed -i "s|{DB_PASS}|$DB_PASS|g" "$MENU_DESTINATION"

# Link simbólico
ln -sf "$MENU_DESTINATION" /bin/xray-menu
chmod +x /bin/xray-menu

# Inicializa DB e CRON
export PGPASSWORD=$DB_PASS
"$MENU_DESTINATION" func_create_db_table >/dev/null 2>&1
unset PGPASSWORD

(crontab -l 2>/dev/null | grep -v "func_purge_expired"; echo "0 1 * * * $MENU_DESTINATION func_purge_expired > /dev/null 2>&1") | crontab -

echo ""
echo "🎉 INSTALAÇÃO CONCLUÍDA!"
echo "Digite: xray-menu"
