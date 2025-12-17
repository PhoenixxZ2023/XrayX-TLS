#!/bin/bash
# installxray.sh - Instalador Automático DragonCore Xray
# Repositório: https://github.com/PhoenixxZ2023/XrayX-TLS

# --- Variáveis ---
XRAY_DIR="/opt/XrayTools"
MENU_DESTINATION="$XRAY_DIR/menuxray.sh"
# Link do seu repositório (Certifique-se que o menuxray.sh lá já é o novo!)
MENU_GITHUB_URL="https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/menuxray.sh"

# --- CONFIGURAÇÃO DB (O script injeta isso no menu) ---
DB_HOST="127.0.0.1"
DB_NAME="dragoncore"
DB_USER="root"
DB_PASS="senha"

# Verificação de Root
if [ "$EUID" -ne 0 ]; then echo "❌ Execute como root!"; exit 1; fi

echo "=================================================="
echo "🚀 Instalando DragonCore Xray Manager"
echo "=================================================="

# 1. Dependências
echo "1. Instalando dependências do sistema..."
apt update -y >/dev/null 2>&1
apt install -y uuid-runtime curl jq net-tools openssl wget postgresql postgresql-contrib cron >/dev/null 2>&1
echo "✅ Dependências OK."

# 2. Banco de Dados
echo "2. Configurando PostgreSQL..."
# Define senha temporária para comandos
export PGPASSWORD=$DB_PASS
systemctl start postgresql
systemctl enable postgresql

# Cria usuário e banco (ignora erro se já existir)
sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null || true
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>/dev/null || true
unset PGPASSWORD
echo "✅ Banco de Dados OK."

# 3. Baixar Menu
echo "3. Baixando Menu atualizado do GitHub..."
mkdir -p "$XRAY_DIR"
wget -qO "$MENU_DESTINATION" "$MENU_GITHUB_URL"

if [ $? -ne 0 ] || [ ! -s "$MENU_DESTINATION" ]; then
    echo "❌ ERRO CRÍTICO: Não foi possível baixar o menuxray.sh."
    echo "Verifique se o arquivo existe no repositório GitHub."
    exit 1
fi
echo "✅ Menu baixado."

# 4. Instalar Xray Core (Binário Oficial)
echo "4. Instalando Xray Core Oficial..."
if ! command -v xray &> /dev/null; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    echo "✅ Xray Core instalado."
else
    echo "ℹ️  Xray Core já estava instalado."
fi

# 5. Configuração Final
echo "5. Configurando permissões e atalhos..."
chmod +x "$MENU_DESTINATION"

# Injeta as credenciais do DB dentro do arquivo do menu
sed -i "s|{DB_HOST}|$DB_HOST|g" "$MENU_DESTINATION"
sed -i "s|{DB_NAME}|$DB_NAME|g" "$MENU_DESTINATION"
sed -i "s|{DB_USER}|$DB_USER|g" "$MENU_DESTINATION"
sed -i "s|{DB_PASS}|$DB_PASS|g" "$MENU_DESTINATION"

# Cria o comando 'xray-menu' (Link Simbólico)
ln -sf "$MENU_DESTINATION" /bin/xray-menu
chmod +x /bin/xray-menu

# Inicializa a tabela do banco de dados chamando a função do menu
export PGPASSWORD=$DB_PASS
"$MENU_DESTINATION" func_create_db_table >/dev/null 2>&1
unset PGPASSWORD

# Configura o Cronjob (Limpeza automática de expirados às 01:00 AM)
(crontab -l 2>/dev/null | grep -v "func_purge_expired"; echo "0 1 * * * $MENU_DESTINATION func_purge_expired > /dev/null 2>&1") | crontab -

echo ""
echo "=================================================="
echo "🎉 INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
echo "=================================================="
echo "Comando para acessar: xray-menu"
echo "=================================================="
