#!/bin/bash
# backup.sh - DragonCore V7.5.1
# Correções aplicadas:
#   - chmod 0600 root:root → 640 root:nogroup no config.json e preset.json pós-restore
#   - Permissões de /opt/XrayTools/users/*.txt restauradas explicitamente (600)
#   - tar com --no-overwrite-dir --no-same-permissions — reduz superfície de path traversal
#   - _cleanup() centralizado via trap EXIT desde o início
#   - rotate_backups() usa find + mapfile — sem parse de ls, seguro com nomes especiais
#   - _wait_xray_active() com retry de 5s — substitui sleep 2 + is-active simples
#   - SNAP_FILE registrado para cleanup em caso de abort

set -Eeuo pipefail

# --- CLEANUP CENTRALIZADO ---
_TMPDIR_BKP=""
_SNAP_FILE=""
_cleanup() {
    [ -n "$_TMPDIR_BKP" ] && rm -rf "$_TMPDIR_BKP" 2>/dev/null || true
    # SNAP_FILE é intencional para recuperação manual — só remove se restore foi bem-sucedido
    # (controlado pelo código principal). Aqui apenas garantimos limpeza em abort inesperado
    # se a flag _SNAP_REMOVE_OK estiver setada.
    [ "${_SNAP_REMOVE_OK:-0}" = "1" ] && [ -n "$_SNAP_FILE" ] && rm -f "$_SNAP_FILE" 2>/dev/null || true
}
trap '_cleanup' EXIT
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; read -rp "Enter...";' ERR

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'
TITLE_BAR='\033[1;47;34m'

BACKUP_DIR="/root/backups"
MAX_BACKUPS=5
_SNAP_REMOVE_OK=0

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo -e "${TXT_RED}❌ Execute como root!${RESET}"
        exit 1
    fi
}

require_root
mkdir -p "$BACKUP_DIR"

# --- VERIFICAÇÃO DE XRAY ATIVO COM RETRY ---
# Padrão adotado em todos os módulos corrigidos — substitui sleep fixo + is-active simples.
_wait_xray_active() {
    local tries=5
    while [ "$tries" -gt 0 ]; do
        systemctl is-active --quiet xray 2>/dev/null && return 0
        sleep 1
        tries=$(( tries - 1 ))
    done
    return 1
}

# --- PERMISSÕES DO CONFIG ---
# CORREÇÃO: centralizada — 640 root:nogroup em todo restore.
# 600 root:root anterior impedia que o Xray (nobody/nogroup) lesse o config.
_apply_config_perms() {
    local f="$1"
    chmod 0640 "$f"
    chown root:nogroup "$f"
}

# --- VALIDAÇÃO DE PATHS NO TAR (whitelist rigorosa) ---
is_safe_tar() {
    local tarfile="$1"
    local entry
    while IFS= read -r entry; do
        entry="${entry#./}"
        [ -n "$entry" ] || continue
        [[ "$entry" != /* ]]     || return 1   # path absoluto
        [[ "$entry" != *".."* ]] || return 1   # traversal
        case "$entry" in
            opt/XrayTools|opt/XrayTools/*)            ;;
            usr/local/etc/xray|usr/local/etc/xray/*)  ;;
            opt/DragonCoreSSL|opt/DragonCoreSSL/*)    ;;
            *) return 1 ;;
        esac
    done < <(tar -tzf "$tarfile" 2>/dev/null)
    return 0
}

# --- VERIFICAÇÃO DE INTEGRIDADE DO TAR ---
verify_tar_integrity() {
    local tarfile="$1"
    if ! tar -tzf "$tarfile" >/dev/null 2>&1; then
        echo -e "${TXT_RED}❌ Arquivo tar corrompido ou ilegível.${RESET}"
        return 1
    fi

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
# CORREÇÃO: usa find + mapfile em vez de ls — seguro com nomes de arquivo
# que contenham espaços ou caracteres especiais.
rotate_backups() {
    local dir="$1" max="$2"
    local -a all_backups
    # sort -z ordena por nome (cronológico dado o timestamp no nome)
    mapfile -d '' all_backups < <(find "$dir" -maxdepth 1 -name "*.tar.gz" -print0 | sort -z)
    local count="${#all_backups[@]}"
    if [ "$count" -gt "$max" ]; then
        local to_remove=$(( count - max ))
        echo -e "${TXT_CYAN}Removendo ${to_remove} backup(s) antigo(s)...${RESET}"
        for (( i=0; i<to_remove; i++ )); do
            rm -f "${all_backups[$i]}" "${all_backups[$i]}.sha256"
            echo " removido: $(basename "${all_backups[$i]}")"
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

    _TMPDIR_BKP=$(mktemp -d)

    mkdir -p "$_TMPDIR_BKP/opt/XrayTools"
    for f in users.db limits.db usage.db session.db active_domain; do
        [ -f "/opt/XrayTools/$f" ] && cp -f "/opt/XrayTools/$f" "$_TMPDIR_BKP/opt/XrayTools/$f"
    done
    [ -d "/opt/XrayTools/users" ] && \
        cp -r "/opt/XrayTools/users" "$_TMPDIR_BKP/opt/XrayTools/" 2>/dev/null || true

    mkdir -p "$_TMPDIR_BKP/usr/local/etc"
    cp -a /usr/local/etc/xray "$_TMPDIR_BKP/usr/local/etc/" 2>/dev/null || true

    if [ -d "/opt/DragonCoreSSL" ]; then
        mkdir -p "$_TMPDIR_BKP/opt"
        cp -a /opt/DragonCoreSSL "$_TMPDIR_BKP/opt/" 2>/dev/null || true
    fi

    echo "Criando backup..."
    if ! tar -czf "$FILE" -C "$_TMPDIR_BKP" . >/dev/null 2>&1; then
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

    echo ""
    echo "Verificando arquivo selecionado..."
    if ! verify_tar_integrity "$FILE"; then
        exit 1
    fi

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

    # Snapshot do estado atual — intencional para recuperação manual se restore falhar
    echo ""
    echo "Criando snapshot do estado atual (segurança)..."
    SNAP_PATHS=( "opt/XrayTools" "usr/local/etc/xray" )
    [ -d "/opt/DragonCoreSSL" ] && SNAP_PATHS+=( "opt/DragonCoreSSL" )
    _SNAP_FILE=$(mktemp /tmp/xray_restore_snap_XXXXXX.tar.gz)
    if tar -czf "$_SNAP_FILE" -C / "${SNAP_PATHS[@]}" >/dev/null 2>&1 && [ -s "$_SNAP_FILE" ]; then
        chmod 600 "$_SNAP_FILE"
        echo -e "${TXT_GREEN}Snapshot salvo em: ${_SNAP_FILE}${RESET}"
    else
        echo -e "${TXT_YELLOW}⚠  Não foi possível criar snapshot — continuando mesmo assim.${RESET}"
        _SNAP_FILE=""
    fi

    echo "Parando serviços..."
    systemctl stop xray    >/dev/null 2>&1 || true
    systemctl stop botxray >/dev/null 2>&1 || true

    # CORREÇÃO: flags de segurança adicionais no tar.
    # --no-overwrite-dir: não sobrescreve permissões de diretórios existentes.
    # --no-same-permissions: usa umask em vez das permissões do arquivo original —
    # permissões são aplicadas explicitamente abaixo com valores conhecidos.
    echo "Restaurando arquivos..."
    if ! tar -xzf "$FILE" -C / \
            --no-overwrite-dir \
            --no-same-permissions \
            2>/dev/null; then
        echo -e "${TXT_RED}❌ Falha ao extrair backup.${RESET}"
        if [ -n "${_SNAP_FILE:-}" ] && [ -f "$_SNAP_FILE" ]; then
            echo "Restaurando snapshot anterior..."
            tar -xzf "$_SNAP_FILE" -C / \
                --no-overwrite-dir \
                --no-same-permissions \
                >/dev/null 2>&1 || true
            echo -e "${TXT_YELLOW}Estado anterior restaurado do snapshot.${RESET}"
        fi
        exit 1
    fi

    # CORREÇÃO: permissões explícitas após restore — tar pode restaurar
    # permissões do backup, que podem diferir do padrão atual do projeto.
    echo "Aplicando permissões..."
    chmod 700  /opt/XrayTools                                   2>/dev/null || true
    chmod 600  /opt/XrayTools/users.db                          2>/dev/null || true
    chown root:root /opt/XrayTools/users.db                     2>/dev/null || true

    # CORREÇÃO: 640 root:nogroup — Xray (nobody/nogroup) precisa ler o config.
    # Versão anterior usava 600 root:root — Xray não conseguia ler após restore.
    if [ -f /usr/local/etc/xray/config.json ]; then
        _apply_config_perms /usr/local/etc/xray/config.json
    fi
    if [ -f /usr/local/etc/xray/preset.json ]; then
        _apply_config_perms /usr/local/etc/xray/preset.json
    fi

    # CORREÇÃO: arquivos individuais de usuário — UUID e links VLESS.
    # Não estavam incluídos no bloco de permissões original.
    if [ -d /opt/XrayTools/users ]; then
        chmod 700 /opt/XrayTools/users
        find /opt/XrayTools/users -maxdepth 1 -name "*.txt" \
            -exec chmod 600 {} \; \
            -exec chown root:root {} \; 2>/dev/null || true
    fi

    if [ -d /opt/DragonCoreSSL ]; then
        chmod 750 /opt/DragonCoreSSL
        chown root:nogroup /opt/DragonCoreSSL                  2>/dev/null || true
        chmod 644 /opt/DragonCoreSSL/fullchain.pem              2>/dev/null || true
        chown root:root /opt/DragonCoreSSL/fullchain.pem        2>/dev/null || true
        chmod 640 /opt/DragonCoreSSL/privkey.pem                2>/dev/null || true
        chown root:nogroup /opt/DragonCoreSSL/privkey.pem       2>/dev/null || true
    fi

    echo "Reiniciando serviços..."
    systemctl restart xray    >/dev/null 2>&1 || true
    systemctl restart botxray >/dev/null 2>&1 || true

    # CORREÇÃO: _wait_xray_active() com retry de 5s — substitui sleep 2 fixo.
    echo ""
    local_xray_status="${TXT_RED}FALHA${RESET}"
    if _wait_xray_active; then
        local_xray_status="${TXT_GREEN}ATIVO${RESET}"
    fi

    echo -e "${TXT_GREEN}✅ Sistema restaurado!${RESET}"
    echo "-----------------------------------------"
    echo -e " Xray:    ${local_xray_status}"
    if ! systemctl is-active --quiet xray 2>/dev/null; then
        echo ""
        echo -e "${TXT_YELLOW}Últimas linhas do journal:${RESET}"
        journalctl -u xray -n 10 --no-pager 2>/dev/null || true
        if [ -n "${_SNAP_FILE:-}" ] && [ -f "$_SNAP_FILE" ]; then
            echo ""
            echo -e "${TXT_YELLOW}Snapshot disponível para recuperação manual: ${_SNAP_FILE}${RESET}"
        fi
    else
        # Remove snapshot apenas se restore e restart foram bem-sucedidos
        _SNAP_REMOVE_OK=1
    fi
    echo "-----------------------------------------"
    ;;

  0) exit 0 ;;
  *) echo -e "${TXT_RED}❌ Opção inválida.${RESET}" ;;
esac

read -rp "Enter..."
