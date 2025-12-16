#!/bin/bash
# installxray.sh - Instalador e Configuração (Corrigido para Auto-Install DB)

# --- Variáveis de Sistema ---
XRAY_DIR="/opt/XrayTools"
MENU_SOURCE="./menuxray.sh"
MENU_DESTINATION="$XRAY_DIR/menuxray.sh"
MENU_GITHUB_URL="https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/menuxray.sh"

# --- CONFIGURAÇÃO (AJUSTE AQUI AS CREDENCIAIS DO SEU BANCO) ---
DB_HOST="localhost"
DB_NAME="dragoncore"
DB_USER="root"
DB_PASS="senha"
# -----------------------------------------------------------------

# Checagem de privilégio Root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Por favor, execute este script como root ou com sudo."
  exit 1
fi

echo "=================================================="
echo "🚀 Instalador DragonCore Xray (Bash Nativo)"
echo "=================================================="

# 1. Instalação de dependências essenciais, incluindo o PostgreSQL Server
echo "1. Instalando Dependências essenciais (Xray, DB e utilitários)..."
apt update
# Instala o Servidor PostgreSQL, o Cliente e as dependências do script
apt install -y uuid-runtime curl jq net-tools openssl wget postgresql postgresql-contrib

if [ $? -ne 0 ]; then echo "❌ Falha ao instalar dependências. Verifique sua conexão ou repositórios."; exit 1; fi
echo "✅ Dependências instaladas."


# 2. Configuração do PostgreSQL Server
echo "2. Configurando Servidor PostgreSQL (Usuário: $DB_USER, DB: $DB_NAME)..."

# Define a senha para o psql
export PGPASSWORD=$DB_PASS

# Cria o usuário do DB e define a senha
sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null
if [ $? -ne 0 ]; then echo "⚠️ Aviso: Usuário '$DB_USER' já existia ou falha na criação. Prosseguindo..."; fi

# Cria a base de dados e define o owner
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>/dev/null
if [ $? -ne 0 ]; then echo "⚠️ Aviso: Banco de dados '$DB_NAME' já existia ou falha na criação. Prosseguindo..."; fi

# Limpa a variável de ambiente de senha
unset PGPASSWORD

echo "✅ PostgreSQL Server configurado."


# 3. Checagem e Download do menuxray.sh
echo "3. Verificando e baixando o menuxray.sh..."

if [ ! -f "$MENU_SOURCE" ]; then
    echo "-> Arquivo '$MENU_SOURCE' não encontrado localmente. Baixando do GitHub..."
    wget -qO "$MENU_SOURCE" "$MENU_GITHUB_URL"
    
    if [ $? -ne 0 ] || [ ! -f "$MENU_SOURCE" ]; then
        echo "❌ ERRO CRÍTICO: Não foi possível baixar o menuxray.sh do GitHub."
        echo "Instalação abortada."
        exit 1
    fi
    echo "✅ menuxray.sh baixado com sucesso."
fi

# 4. Instalação do Binário Xray Core
if ! command -v xray &> /dev/null; then
    echo "4. Instalando Xray Core..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    if [ $? -ne 0 ]; then echo "❌ Falha na instalação do Xray."; exit 1; fi
    echo "✅ Xray Core instalado."
else
    echo "4. Xray Core já está instalado. Prosseguindo..."
fi

# --- 5. CÓPIA E CONFIGURAÇÃO DO ARQUIVO DE MENU ---
mkdir -p "$XRAY_DIR"
echo "5. Copiando '$MENU_SOURCE' para '$MENU_DESTINATION' e configurando DB..."

# Cópia do arquivo
cp "$MENU_SOURCE" "$MENU_DESTINATION"

# Injeção das Variáveis de Credencial no arquivo copiado
echo "-> Injetando credenciais do DB (DB: $DB_NAME, User: $DB_USER)..."
sed -i "s|{DB_HOST}|$DB_HOST|g" "$MENU_DESTINATION"
sed -i "s|{DB_NAME}|$DB_NAME|g" "$MENU_DESTINATION"
sed -i "s|{DB_USER}|$DB_USER|g" "$MENU_DESTINATION"
sed -i "s|{DB_PASS}|$DB_PASS|g" "$MENU_DESTINATION"
echo "✅ Variáveis de DB injetadas com sucesso."

# 6. CONFIGURAÇÃO FINAL
echo "6. Configurando atalhos, permissões e cronjob..."
chmod +x "$MENU_DESTINATION"

# Cria o atalho /bin/xray-menu
echo -n "$MENU_DESTINATION" > /bin/xray-menu
chmod +x /bin/xray-menu
echo "-> Atalho 'xray-menu' criado em /bin."

# Define a senha para que o 'menuxray.sh' possa se conectar imediatamente
export PGPASSWORD=$DB_PASS
# Inicializa a tabela do DB (chamando a função do menuxray.sh)
"$MENU_DESTINATION" func_create_db_table >/dev/null
unset PGPASSWORD

# Adiciona o Cronjob de limpeza (Limpeza diária à 1h da manhã)
EXISTING_PURGE_CRON=$(crontab -l 2>/dev/null | grep -F "menuxray.sh func_purge_expired")
if [ -z "$EXISTING_PURGE_CRON" ]; then
    (crontab -l 2>/dev/null; echo "0 1 * * * $MENU_DESTINATION func_purge_expired > /dev/null 2>&1") | crontab -
    echo "-> Tarefa Cron de limpeza diária adicionada."
fi

echo ""
echo "=================================================="
echo "🎉 Instalação Xray Concluída!"
echo "Para acessar o menu, digite o comando: **sudo xray-menu**"
echo "=================================================="
