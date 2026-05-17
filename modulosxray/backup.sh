#!/bin/bash
# backup.sh - Backup & Restore seguro (inclui SSL) - DragonCore FIX

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; read -rp "Enter...";' ERR

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
RESET='\033[0m'
TITLE_BAR='\033[1;47;34m'

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"
    exit 1
  fi
}

require_root

BACKUP_DIR="/root/backups"
mkdir -p "$BACKUP_DIR"

clear; echo -e "${TITLE_BAR}   BACKUP & RESTORE   ${RESET}"; echo ""
echo -e "${TXT_CYAN}[1] CRIAR BACKUP${RESET}"
echo -e "${TXT_CYAN}[2] RESTAURAR BACKUP${RESET}"
echo -e "${TXT_CYAN}[0] SAIR${RESET}"
read -rp "Opção: " opt

is_safe_tar() {
  local tarfile="$1"

  # lê lista do tar SEM pipe (evita subshell)
  local entry
  while IFS= read -r entry; do
    entry="${entry#./}"
    [ -n "$entry" ] || continue

    # bloqueia paths absolutos e traversal
    [[ "$entry" != /* ]] || return 1
    [[ "$entry" != *".."* ]] || return 1

    # permite SOMENTE estes prefixos
    case "$entry" in
      opt/XrayTools|opt/XrayTools/*) ;;
      usr/local/etc/xray|usr/local/etc/xray/*) ;;
      opt/DragonCoreSSL|opt/DragonCoreSSL/*) ;;
      *) return 1 ;;
    esac
  done < <(tar -tzf "$tarfile")
  return 0
}

case "${opt:-}" in
  1)
    echo "Criando backup..."
    umask 077
    FILE="${BACKUP_DIR}/backup_dragoncore_$(date +%Y%m%d_%H%M%S).tar.gz"

    if [ ! -f "/opt/XrayTools/users.db" ]; then
      echo -e "${TXT_RED}Erro: DB não encontrado em /opt/XrayTools/users.db${RESET}"
      exit 1
    fi
    if [ ! -d "/usr/local/etc/xray" ]; then
      echo -e "${TXT_RED}Erro: pasta /usr/local/etc/xray não encontrada.${RESET}"
      exit 1
    fi

    # monta lista de paths existentes
    paths=( "opt/XrayTools" "usr/local/etc/xray" )
    [ -d "/opt/DragonCoreSSL" ] && paths+=( "opt/DragonCoreSSL" )

    tar -czf "$FILE" -C / "${paths[@]}" >/dev/null 2>&1

    if [ -s "$FILE" ]; then
      chmod 600 "$FILE" || true
      echo -e "${TXT_GREEN}Backup criado: $(basename "$FILE")${RESET}"
      if [ ! -d "/opt/DragonCoreSSL" ]; then
        echo -e "${TXT_CYAN}Nota:${RESET} /opt/DragonCoreSSL não existia e não foi incluída."
      fi
    else
      echo -e "${TXT_RED}Erro ao criar backup.${RESET}"
      rm -f "$FILE"
    fi
    ;;

  2)
    echo "Restaurando..."
    shopt -s nullglob
    FILES=("$BACKUP_DIR"/*.tar.gz)

    if [ ${#FILES[@]} -eq 0 ]; then
      echo -e "${TXT_RED}Nenhum backup encontrado.${RESET}"
      exit 1
    fi

    echo ""
    echo "Selecione um backup (ou 0 para cancelar):"
    i=1
    for f in "${FILES[@]}"; do
      echo " [$i] $(basename "$f")"
      i=$((i+1))
    done
    read -rp "Número: " n
    if [ "${n:-0}" = "0" ]; then exit 0; fi
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "${#FILES[@]}" ]; then
      echo -e "${TXT_RED}Opção inválida.${RESET}"
      exit 1
    fi

    FILE="${FILES[$((n-1))]}"

    if ! is_safe_tar "$FILE"; then
      echo -e "${TXT_RED}Backup recusado: conteúdo fora de paths permitidos (ou possui '..' / paths absolutos).${RESET}"
      exit 1
    fi

    read -rp "Confirmar RESTORE deste backup? [s/n]: " ok
    [[ "${ok:-n}" =~ ^[sS]$ ]] || exit 0

    systemctl stop xray >/dev/null 2>&1 || true
    systemctl stop botxray >/dev/null 2>&1 || true

    # extrai tudo (já validado que só tem os 3 paths permitidos)
    tar -xzf "$FILE" -C /

    # permissões mínimas
    chmod 700 /opt/XrayTools 2>/dev/null || true
    chmod 600 /opt/XrayTools/users.db 2>/dev/null || true

    # SSL: xray roda como nobody -> precisa ler os .pem
    if [ -d /opt/DragonCoreSSL ]; then
      chown -R nobody:nogroup /opt/DragonCoreSSL 2>/dev/null || true
      chmod 750 /opt/DragonCoreSSL 2>/dev/null || true
      chmod 644 /opt/DragonCoreSSL/fullchain.pem 2>/dev/null || true
      chmod 640 /opt/DragonCoreSSL/privkey.pem 2>/dev/null || true
    fi

    systemctl restart xray >/dev/null 2>&1 || true
    systemctl restart botxray >/dev/null 2>&1 || true

    echo -e "${TXT_GREEN}Sistema restaurado!${RESET}"
    ;;

  0) exit 0 ;;
  *) echo -e "${TXT_RED}Opção inválida.${RESET}" ;;
esac

read -rp "Enter..."
