#!/bin/bash
# installxray.sh - Instalador e Configuração (Versão Corrigida)
# Autor: Adaptado para DragonCore Xray

# --- CONFIGURAÇÃO DO BANCO DE DADOS ---
# Nota: Usamos 127.0.0.1 para forçar autenticação via senha (TCP), 
# evitando erros de 'peer authentication' do localhost.
DB_HOST="127.0.0.1"
DB_NAME="dragoncore"
DB_USER="root"
DB_PASS="senha"  # <-- Altere sua senha aqui se desejar

# --- VARIÁVEIS DE SISTEMA ---
XRAY_DIR="/opt/XrayTools"
MENU_LOCAL="./menuxray.sh"
MENU_DESTINATION="$XRAY_DIR/menuxray.sh"
MENU_GITHUB_URL="https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/menuxray.sh"

# --- 1. CHECAGEM DE ROOT ---
if [ "$EUID" -ne 0 ]; then
  echo "❌ Execute como root (sudo -i)."
  exit 1
fi

echo "=================================================="
echo "🚀 Instalador DragonCore Xray (Bash Nativo)"
echo "=================================================="

# --- 2. INSTALAÇÃO DE DEPENDÊNCIAS ---
echo "1. Instalando Dependências..."
apt update -y
apt install -y uuid-runtime curl jq net-tools openssl wget postgresql postgresql-contrib socat

if [ $? -ne 0 ]; then 
    echo "❌ Falha no apt install. Verifique sua internet."
    exit 1
fi
echo "✅ Dependências instaladas."

# --- 3. CONFIGURAÇÃO DO POSTGRESQL ---
echo "2. Configurando Banco de Dados..."

# Inicia serviço se estiver parado
systemctl start postgresql 
systemctl enable postgresql

# Define senha do ambiente para comandos psql
export PGPASSWORD=$DB_PASS

# Cria usuário (se não existir)
sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null
# Cria banco (se não existir)
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>/dev/null

unset PGPASSWORD
echo "✅ PostgreSQL configurado (User: $DB_USER / DB: $DB_NAME)."

# --- 4. PREPARAÇÃO DO MENU ---
echo "3. Preparando arquivos do Menu..."

mkdir -p "$XRAY_DIR"

# Lógica: Usa o arquivo local se existir (prioridade dev), senão baixa
if [ -f "$MENU_LOCAL" ]; then
    echo "-> Usando arquivo local '$MENU_LOCAL'."
    cp "$MENU_LOCAL" "$MENU_DESTINATION"
else
    echo "-> Arquivo local não encontrado. Baixando do GitHub..."
    wget -qO "$MENU_DESTINATION" "$MENU_GITHUB_URL"
fi

if [ ! -f "$MENU_DESTINATION" ]; then
    echo "❌ Erro crítico: menuxray.sh não encontrado em $MENU_DESTINATION"
    exit 1
fi

# --- 5. INSTALAÇÃO DO XRAY CORE ---
if ! command -v xray &> /dev/null; then
    echo "4. Instalando Xray Core..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    echo "✅ Xray Core instalado."
else
    echo "4. Xray Core já está instalado."
fi

# --- 6. INJEÇÃO DE VARIÁVEIS NO MENU ---
echo "5. Configurando conexões..."

# Substitui os placeholders no arquivo final
sed -i "s|{DB_HOST}|$DB_HOST|g" "$MENU_DESTINATION"
sed -i "s|{DB_NAME}|$DB_NAME|g" "$MENU_DESTINATION"
sed -i "s|{DB_USER}|$DB_USER|g" "$MENU_DESTINATION"
sed -i "s|{DB_PASS}|$DB_PASS|g" "$MENU_DESTINATION"

chmod +x "$MENU_DESTINATION"
echo "✅ Credenciais injetadas no script."

# --- 7. CRIAÇÃO DE ATALHO E CRON ---
echo "6. Finalizando..."

# CORREÇÃO: Criação de Link Simbólico (Maneira correta)
rm -f /bin/xray-menu
ln -sf "$MENU_DESTINATION" /bin/xray-menu
chmod +x /bin/xray-menu

# Inicializa tabela do banco executando a função interna do menu
export PGPASSWORD=$DB_PASS
"$MENU_DESTINATION" func_create_db_table
if [ $? -eq 0 ]; then
    echo "✅ Tabela de dados inicializada."
else
    echo "⚠️  Aviso: Não foi possível inicializar a tabela agora. O menu tentará novamente ao abrir."
fi
unset PGPASSWORD

# Cronjob para limpeza automática (Diariamente 01:00 AM)
CRON_CMD="$MENU_DESTINATION func_purge_expired > /dev/null 2>&1"
(crontab -l 2>/dev/null | grep -v "func_purge_expired"; echo "0 1 * * * $CRON_CMD") | crontab -

echo ""
echo "=================================================="
echo "🎉 INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
echo "=================================================="
echo "Comando para acessar: xray-menu"
echo "=================================================="
