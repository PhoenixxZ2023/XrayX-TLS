#!/bin/bash
# backup.sh - Backup & Restore Seguro V7.5
# Correções: snapshot antes do restore, verificação de integridade do tar,
#            SHA256 gerado no backup e verificado no restore, rotação de
#            backups antigos, permissões no config após restore, verificação
#            de restart, listagem com tamanho e data.

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; read -rp "Enter...";' ERR

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'
TITLE_BAR='\033[1;47;34m'

BACKUP_DIR="/root/backups"
MAX_BACKUPS=5   # quantos backups manter (rotação automática)

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo -e "${TXT_RED}❌ Execute como root!${RESET}"
        exit 1
    fi
}

require_root
mkdir -p "$BACKUP_DIR"

# --- VALIDAÇÃO DE PATHS NO TAR (whitelist rigorosa) ---
is_safe_tar() {
    local tarfile="$1"
    local entry
    while IFS= read -r entry; do
        entry="${entry#./}"
        [ -n "$entry" ] || continue
        [[ "$entry" != /* ]]    || return 1   # path absoluto
        [[ "$entry" != *".."* ]] || return 1  # traversal
        case "$entry" in
            opt/XrayTools|opt/XrayTools/*)       ;;
            usr/local/etc/xray|usr/local/etc/xray/*) ;;
            opt/DragonCoreSSL|opt/DragonCoreSSL/*) ;;
            *) return 1 ;;
        esac
    done < <(tar -tzf "$tarfile" 2>/dev/null)
    return 0
}

# --- VERIFICAÇÃO DE INTEGRIDADE DO TAR ---
verify_tar_integrity() {
    local tarfile="$1"
    # Testa leitura completa do arquivo sem extrair
    if ! tar -tzf "$tarfile" >/dev/null 2>&1; then
        echo -e "${TXT_RED}❌ Arquivo tar corrompido ou ilegível.${RESET}"
        return 1
    fi

    # Verifica SHA256 se arquivo .sha256 existir ao lado
    local sha_file="${tarfile}.sha256"
    if [ -f "$sha_file" ]; then
        echo -n "Verificando integridade SHA256... "
        local expected actual
        expected=$(awk '{print $1}' "$sha_file")
        actual=$(sha256sum "$tarfile" | awk '{print $1}')
        if [ "$expected" != "$actual" ]; then
            echo -e "${TXT_RED}FALHOU${RESET}"
            echo -e "${TXT_RED}❌ SHA256 não confere — backup pode estar corrompido.${RESET}"
            echo "   Esperado: $expected"
            echo "   Obtido:   $actual"
            return 1
        fi
        echo -e "${TXT_GREEN}OK${RESET}"
    else
        echo -e "${TXT_YELLOW}⚠  Arquivo .sha256 não encontrado — verificação de integridade ignorada.${RESET}"
    fi
    return 0
}

# --- ROTAÇÃO DE BACKUPS ANTIGOS ---
rotate_backups() {
    local dir="$1" max="$2"
    local count
    count=$(ls -1 "$dir"/*.tar.gz 2>/dev/null | wc -l)
    if [ "$count" -gt "$max" ]; then
        local to_remove=$(( count - max ))
        echo -e "${TXT_CYAN}Removendo ${to_remove} backup(s) antigo(s)...${RESET}"
        ls -1t "$dir"/*.tar.gz | tail -n "$to_remove" | while read -r old; do
            rm -f "$old" "${old}.sha256"
            echo " removido: $(basename "$old")"
        done
    fi
}

# --- MENU ---
clear
echo -e "${TITLE_BAR}   BACKUP & RESTORE   ${RESET}"
echo ""
echo -e "${TXT_CYAN}[1] CRIAR BACKUP${RESET}"
echo -e "${TXT_CYAN}[2] RESTAURAR BACKUP${RESET}"
echo -e "${TXT_CYAN}[0] SAIR${RESET}"
read -rp "Opção: " opt

case "${opt:-0}" in

  # ============================================================
  1)  # CRIAR BACKUP
  # ============================================================
    echo "Verificando arquivos necessários..."

    if [ ! -f "/opt/XrayTools/users.db" ]; then
        echo -e "${TXT_RED}❌ users.db não encontrado em /opt/XrayTools/${RESET}"
        exit 1
    fi
    if [ ! -d "/usr/local/etc/xray" ]; then
        echo -e "${TXT_RED}❌ Pasta /usr/local/etc/xray não encontrada.${RESET}"
        exit 1
    fi

    umask 077
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    FILE="${BACKUP_DIR}/backup_dragoncore_${TIMESTAMP}.tar.gz"
    SHA_FILE="${FILE}.sha256"

    # Copia apenas arquivos essenciais para tmpdir
    # Exclui venv, backups anteriores, botxray.py e arquivos desnecessarios
    TMPDIR_BKP=$(mktemp -d)
    trap 'rm -rf "$TMPDIR_BKP"' EXIT

    mkdir -p "$TMPDIR_BKP/opt/XrayTools"
    for f in users.db limits.db usage.db session.db active_domain; do
        [ -f "/opt/XrayTools/$f" ] && cp -f "/opt/XrayTools/$f" "$TMPDIR_BKP/opt/XrayTools/$f"
    done
    [ -d "/opt/XrayTools/users" ] && cp -r "/opt/XrayTools/users" "$TMPDIR_BKP/opt/XrayTools/" 2>/dev/null || true

    mkdir -p "$TMPDIR_BKP/usr/local/etc"
    cp -a /usr/local/etc/xray "$TMPDIR_BKP/usr/local/etc/" 2>/dev/null || true

    if [ -d "/opt/DragonCoreSSL" ]; then
        mkdir -p "$TMPDIR_BKP/opt"
        cp -a /opt/DragonCoreSSL "$TMPDIR_BKP/opt/" 2>/dev/null || true
    fi

    echo "Criando backup..."
    if ! tar -czf "$FILE" -C "$TMPDIR_BKP" . >/dev/null 2>&1; then
        echo -e "${TXT_RED}❌ Falha ao criar arquivo tar.${RESET}"
        rm -f "$FILE"
        exit 1
    fi

    if [ ! -s "$FILE" ]; then
        echo -e "${TXT_RED}❌ Backup criado está vazio.${RESET}"
        rm -f "$FILE"
        exit 1
    fi

    chmod 600 "$FILE"

    # Gera SHA256 ao lado do backup para verificação futura
    echo -n "Gerando SHA256... "
    sha256sum "$FILE" > "$SHA_FILE"
    chmod 600 "$SHA_FILE"
    echo -e "${TXT_GREEN}OK${RESET}"

    SIZE=$(du -sh "$FILE" | cut -f1)
    echo ""
    echo -e "${TXT_GREEN}✅ Backup criado com sucesso!${RESET}"
    echo "-----------------------------------------"
    echo -e " Arquivo: ${TXT_CYAN}$(basename "$FILE")${RESET}"
    echo -e " Tamanho: ${SIZE}"
    echo -e " SHA256:  $(basename "$SHA_FILE")"
    if [ ! -d "/opt/DragonCoreSSL" ]; then
        echo -e "${TXT_CYAN}Nota:${RESET} /opt/DragonCoreSSL não existia e não foi incluída."
    fi
    echo "-----------------------------------------"

    # Rotação automática
    rotate_backups "$BACKUP_DIR" "$MAX_BACKUPS"
    ;;

  # ============================================================
  2)  # RESTAURAR BACKUP
  # ============================================================
    echo "Procurando backups disponíveis..."
    shopt -s nullglob
    FILES=("$BACKUP_DIR"/*.tar.gz)

    if [ ${#FILES[@]} -eq 0 ]; then
        echo -e "${TXT_RED}❌ Nenhum backup encontrado em ${BACKUP_DIR}.${RESET}"
        exit 1
    fi

    echo ""
    echo "Selecione um backup (0 para cancelar):"
    echo "-----------------------------------------"
    i=1
    for f in "${FILES[@]}"; do
        local_size=$(du -sh "$f" 2>/dev/null | cut -f1)
        local_date=$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || stat -c '%y' "$f" | cut -c1-16)
        local_sha=""
        [ -f "${f}.sha256" ] && local_sha=" [SHA256 ✓]"
        printf " [%d] %-45s %6s  %s%s\n" "$i" "$(basename "$f")" "$local_size" "$local_date" "$local_sha"
        i=$(( i + 1 ))
    done
    echo "-----------------------------------------"

    read -rp "Número: " n
    [ "${n:-0}" = "0" ] && exit 0

    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "${#FILES[@]}" ]; then
        echo -e "${TXT_RED}❌ Opção inválida.${RESET}"
        exit 1
    fi

    FILE="${FILES[$((n-1))]}"

    # Verifica integridade antes de qualquer operação
    echo ""
    echo "Verificando arquivo selecionado..."
    if ! verify_tar_integrity "$FILE"; then
        exit 1
    fi

    # Valida paths dentro do tar (whitelist)
    echo -n "Validando conteúdo do backup... "
    if ! is_safe_tar "$FILE"; then
        echo -e "${TXT_RED}RECUSADO${RESET}"
        echo -e "${TXT_RED}❌ Backup contém paths não permitidos (possível archive malicioso).${RESET}"
        exit 1
    fi
    echo -e "${TXT_GREEN}OK${RESET}"

    echo ""
    echo -e "${TXT_YELLOW}⚠  ATENÇÃO: O sistema atual será substituído pelo backup.${RESET}"
    echo -e " Backup selecionado: ${TXT_CYAN}$(basename "$FILE")${RESET}"
    read -rp "Confirmar RESTORE? [s/N]: " ok
    [[ "${ok:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

    # SNAPSHOT DO ESTADO ATUAL antes de restaurar
    echo ""
    echo "Criando snapshot do estado atual (segurança)..."
    SNAP_PATHS=( "opt/XrayTools" "usr/local/etc/xray" )
    [ -d "/opt/DragonCoreSSL" ] && SNAP_PATHS+=( "opt/DragonCoreSSL" )
    SNAP_FILE=$(mktemp /tmp/xray_restore_snap_XXXXXX.tar.gz)
    if tar -czf "$SNAP_FILE" -C / "${SNAP_PATHS[@]}" >/dev/null 2>&1 && [ -s "$SNAP_FILE" ]; then
        chmod 600 "$SNAP_FILE"
        echo -e "${TXT_GREEN}Snapshot salvo em: ${SNAP_FILE}${RESET}"
    else
        echo -e "${TXT_YELLOW}⚠  Não foi possível criar snapshot — continuando mesmo assim.${RESET}"
        SNAP_FILE=""
    fi

    # Para serviços antes de substituir arquivos
    echo "Parando serviços..."
    systemctl stop xray    >/dev/null 2>&1 || true
    systemctl stop botxray >/dev/null 2>&1 || true

    # Extrai backup (já validado)
    echo "Restaurando arquivos..."
    if ! tar -xzf "$FILE" -C / 2>/dev/null; then
        echo -e "${TXT_RED}❌ Falha ao extrair backup.${RESET}"
        if [ -n "${SNAP_FILE:-}" ] && [ -f "$SNAP_FILE" ]; then
            echo "Restaurando snapshot anterior..."
            tar -xzf "$SNAP_FILE" -C / >/dev/null 2>&1 || true
            echo -e "${TXT_YELLOW}Estado anterior restaurado do snapshot.${RESET}"
        fi
        exit 1
    fi

    # Reforça permissões após restore (tar pode restaurar permissões erradas)
    echo "Aplicando permissões..."
    chmod 700  /opt/XrayTools                           2>/dev/null || true
    chmod 600  /opt/XrayTools/users.db                  2>/dev/null || true
    chmod 0600 /usr/local/etc/xray/config.json          2>/dev/null || true
    chown root:root /usr/local/etc/xray/config.json     2>/dev/null || true
    chmod 0600 /usr/local/etc/xray/preset.json          2>/dev/null || true
    chown root:root /usr/local/etc/xray/preset.json     2>/dev/null || true

    if [ -d /opt/DragonCoreSSL ]; then
        chown -R nobody:nogroup /opt/DragonCoreSSL      2>/dev/null || true
        chmod 750  /opt/DragonCoreSSL                   2>/dev/null || true
        chmod 644  /opt/DragonCoreSSL/fullchain.pem     2>/dev/null || true
        chmod 640  /opt/DragonCoreSSL/privkey.pem       2>/dev/null || true
    fi

    # Reinicia e verifica
    echo "Reiniciando serviços..."
    systemctl restart xray    >/dev/null 2>&1 || true
    systemctl restart botxray >/dev/null 2>&1 || true
    sleep 2

    echo ""
    local_xray_status="${TXT_RED}FALHA${RESET}"
    systemctl is-active --quiet xray 2>/dev/null && local_xray_status="${TXT_GREEN}ATIVO${RESET}"

    echo -e "${TXT_GREEN}✅ Sistema restaurado!${RESET}"
    echo "-----------------------------------------"
    echo -e " Xray:    ${local_xray_status}"
    if ! systemctl is-active --quiet xray 2>/dev/null; then
        echo ""
        echo -e "${TXT_YELLOW}Últimas linhas do journal:${RESET}"
        journalctl -u xray -n 10 --no-pager 2>/dev/null || true
        if [ -n "${SNAP_FILE:-}" ] && [ -f "$SNAP_FILE" ]; then
            echo ""
            echo -e "${TXT_YELLOW}Snapshot disponível para recuperação manual: ${SNAP_FILE}${RESET}"
        fi
    else
        # Remove snapshot se restore foi bem-sucedido
        [ -n "${SNAP_FILE:-}" ] && rm -f "$SNAP_FILE"
    fi
    echo "-----------------------------------------"
    ;;

  0) exit 0 ;;
  *) echo -e "${TXT_RED}❌ Opção inválida.${RESET}" ;;
esac

read -rp "Enter..."
