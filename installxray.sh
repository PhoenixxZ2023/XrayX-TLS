#!/bin/bash
# installxray.sh - Instalador e Configuração (Corrigido para One-Liner)

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

# 1. Instalação de dependências essenciais (jq, psql, openssl, wget)
echo "1. Instalando Dependências essenciais (jq, psql, openssl, wget)..."
apt update
apt install -y uuid-runtime curl jq postgresql-client net-tools openssl wget

if [ $? -ne 0 ]; then echo "❌ Falha ao instalar dependências. Verifique sua conexão ou repositórios."; exit 1; fi
echo "✅ Dependências instaladas."


# 2. Checagem e Download do menuxray.sh (Correção para One-Liner)
echo "2. Verificando e baixando o menuxray.sh..."

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

# 3. Instalação do Binário Xray Core
if ! command -v xray &> /dev/null; then
    echo "3. Instalando Xray Core..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    if [ $? -ne 0 ]; then echo "❌ Falha na instalação do Xray."; exit 1; fi
    echo "✅ Xray Core instalado."
else
    echo "3. Xray Core já está instalado. Prosseguindo..."
fi

# --- 4. CÓPIA E CONFIGURAÇÃO DO ARQUIVO DE MENU ---
mkdir -p "$XRAY_DIR"
echo "4. Copiando '$MENU_SOURCE' para '$MENU_DESTINATION' e configurando DB..."

# Cópia do arquivo
cp "$MENU_SOURCE" "$MENU_DESTINATION"

# Injeção das Variáveis de Credencial no arquivo copiado
echo "-> Injetando credenciais do DB (DB: $DB_NAME, User: $DB_USER)..."
sed -i "s|{DB_HOST}|$DB_HOST|g" "$MENU_DESTINATION"
sed -i "s|{DB_NAME}|$DB_NAME|g" "$MENU_DESTINATION"
sed -i "s|{DB_USER}|$DB_USER|g" "$MENU_DESTINATION"
sed -i "s|{DB_PASS}|$DB_PASS|g" "$MENU_DESTINATION"
echo "✅ Variáveis de DB injetadas com sucesso."

# 5. CONFIGURAÇÃO FINAL
echo "5. Configurando atalhos, permissões e cronjob..."
chmod +x "$MENU_DESTINATION"

# Cria o atalho /bin/xray-menu
echo -n "$MENU_DESTINATION" > /bin/xray-menu
chmod +x /bin/xray-menu
echo "-> Atalho 'xray-menu' criado em /bin."

# Inicializa a tabela do DB (chamando a função do menuxray.sh)
"$MENU_DESTINATION" func_create_db_table >/dev/null

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
