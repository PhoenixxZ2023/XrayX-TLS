#!/bin/bash
# installxray.sh - Instalador Leve (Dependências + DB + Menu)
# O Xray Core será instalado apenas via Menu (Opção 6)
# Repositório: https://github.com/PhoenixxZ2023/XrayX-TLS

# --- Variáveis ---
XRAY_DIR="/opt/XrayTools"
MENU_DESTINATION="$XRAY_DIR/menuxray.sh"
# Link do seu repositório
MENU_GITHUB_URL="https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/menuxray.sh"

# --- CONFIGURAÇÃO DB (O script injeta isso no menu) ---
DB_HOST="127.0.0.1"
DB_NAME="dragoncore"
DB_USER="root"
DB_PASS="senha"

# Verificação de Root
if [ "$EUID" -ne 0 ]; then echo "❌ Execute como root!"; exit 1; fi

echo "=================================================="
echo "🚀 Preparando Ambiente DragonCore Xray"
echo "=================================================="

# 1. Dependências do Sistema (Essenciais para o Menu funcionar)
echo "1. Instalando dependências do sistema..."
apt update -y >/dev/null 2>&1
apt install -y uuid-runtime curl jq net-tools openssl wget postgresql postgresql-contrib cron >/dev/null 2>&1
echo "✅ Dependências OK."

# 2. Banco de Dados
echo "2. Configurando PostgreSQL..."
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
    exit 1
fi
echo "✅ Menu baixado."

# --- REMOVIDO: A instalação do Xray Core foi retirada daqui. ---
# Ela será feita exclusivamente pela Opção 6 do Menu.

# 4. Configuração Final
echo "4. Configurando permissões e atalhos..."
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
echo "🎉 AMBIENTE PREPARADO COM SUCESSO!"
echo "=================================================="
echo "⚠️  IMPORTANTE: O Xray Core AINDA NÃO ESTÁ INSTALADO."
echo "👉 Digite 'xray-menu' e vá na OPÇÃO 6 para instalar e configurar."
echo "=================================================="
