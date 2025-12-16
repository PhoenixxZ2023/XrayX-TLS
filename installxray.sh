#!/bin/bash
# installxray.sh - Instalador e Configuração (Livre de código do menu)

# --- CONFIGURAÇÃO (AJUSTE AQUI AS CREDENCIAIS DO SEU BANCO) ---
XRAY_DIR="/opt/XrayTools"
DB_HOST="localhost"
DB_NAME="dragoncore"
DB_USER="root"
DB_PASS="senha"
# -----------------------------------------------------------------

MENU_SOURCE="./menuxray.sh"
MENU_DESTINATION="$XRAY_DIR/menuxray.sh"

echo "=================================================="
echo "🚀 Instalador DragonCore Xray (Bash Nativo)"
echo "=================================================="

# 1. Checagem do arquivo de menu
if [ ! -f "$MENU_SOURCE" ]; then
    echo "❌ ERRO: Arquivo $MENU_SOURCE não encontrado neste diretório."
    echo "Certifique-se de que o 'menuxray.sh' está salvo antes de rodar o instalador."
    exit 1
fi

# 2. Instalação de dependências e binário Xray
echo "1. Instalando Dependências essenciais (jq, psql, openssl)..."
sudo apt update
sudo apt install -y uuid-runtime curl jq postgresql-client net-tools openssl

if ! command -v xray &> /dev/null; then
    echo "-> Instalando Xray Core..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    if [ $? -ne 0 ]; then echo "❌ Falha na instalação do Xray."; exit 1; fi
    echo "✅ Xray Core instalado."
fi

# --- 3. CÓPIA E CONFIGURAÇÃO DO ARQUIVO DE MENU ---
mkdir -p "$XRAY_DIR"
echo "2. Copiando $MENU_SOURCE para $MENU_DESTINATION e configurando..."

# Cópia do arquivo
sudo cp "$MENU_SOURCE" "$MENU_DESTINATION"

# Injeção das Variáveis de Credencial no arquivo copiado
sudo sed -i "s|{DB_HOST}|$DB_HOST|g" "$MENU_DESTINATION"
sudo sed -i "s|{DB_NAME}|$DB_NAME|g" "$MENU_DESTINATION"
sudo sed -i "s|{DB_USER}|$DB_USER|g" "$MENU_DESTINATION"
sudo sed -i "s|{DB_PASS}|$DB_PASS|g" "$MENU_DESTINATION"

# 4. CONFIGURAÇÃO FINAL
echo "3. Configurando atalhos, permissões e cronjob..."
sudo chmod +x "$MENU_DESTINATION"

# Cria o atalho /bin/xray-menu
echo -n "$MENU_DESTINATION" | sudo tee /bin/xray-menu > /dev/null
sudo chmod +x /bin/xray-menu

# Inicializa a tabela do DB (chamando a função do menuxray.sh)
"$MENU_DESTINATION" func_create_db_table >/dev/null

# Adiciona o Cronjob de limpeza
EXISTING_PURGE_CRON=$(crontab -l 2>/dev/null | grep -F "menuxray.sh func_purge_expired")
if [ -z "$EXISTING_PURGE_CRON" ]; then
    (crontab -l 2>/dev/null; echo "0 1 * * * $MENU_DESTINATION func_purge_expired > /dev/null 2>&1") | crontab -
    echo "-> Tarefa Cron de limpeza diária adicionada."
fi

echo ""
echo "=================================================="
echo "✅ Instalação Xray Concluída!"
echo "Para acessar o menu, digite o comando: sudo xray-menu"
echo "=================================================="
