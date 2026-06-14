# ⚡ DragonCore Xray Manager | V7.7.1 (Modular)

![Version](https://img.shields.io/badge/Version-7.7.1-blue?style=for-the-badge&labelColor=black)
![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Python](https://img.shields.io/badge/Bot-Python3-yellow?style=for-the-badge&logo=python&logoColor=white)
![Xray](https://img.shields.io/badge/Core-Xray-purple?style=for-the-badge)
![Security](https://img.shields.io/badge/Security-UUID_Scramble-red?style=for-the-badge)

> **Gerenciador Xray híbrido (Bash + Python)** com arquitetura modular, cache local e foco em estabilidade e segurança.
> Ideal para quem administra múltiplos usuários VLESS e precisa de painel local + bot Telegram.

---

## ✅ O que este projeto entrega

### 🧩 Arquitetura Modular (Cache Local)
- O `installxray.sh` instala apenas o **launcher** e dependências essenciais.
- O `menuxray.sh` baixa os módulos **sob demanda** e mantém cache em `/usr/local/bin`.
- Mesmo se o GitHub ficar fora do ar, o painel segue funcionando com os módulos já cacheados.
- Suporte a `REPO_REF` para fixar versão por branch, tag ou commit hash.

### 🛡️ Bloqueio Seguro (Scramble)
- Bloquear **não deleta** o usuário — mantém histórico no `users.db`.
- Troca UUID por falso e aplica prefixo `LOCKED_` no email (fácil de reverter).
- Desbloqueio restaura o UUID original do banco de dados.

### 🔒 Segurança
- Validação de integridade SHA256 nos downloads de módulos.
- Validação de domínio RFC 1123 antes de emitir certificados.
- `config.json` com permissão **`0640 root:nogroup`** — Xray (`nobody`) lê, outros não têm acesso.
- `privkey.pem` com permissão **`0640 root:nogroup`** — chave privada TLS nunca legível por outros processos.
- `renew_cert.sh` com permissão **`0700 root:root`** — script de renovação não modificável por processos não-root.
- Wrappers setuid do bot com permissão **`4750 root:botxray`** — apenas o grupo `botxray` executa como root.
- Backup do config antes de qualquer modificação, com rollback automático em falha.
- `REPO_BASE` e `PINNED_REF` validados com regex antes de uso em URLs.
- UUID gerado com fallback (`uuidgen` → `/proc/sys/kernel/random/uuid` → `/dev/urandom`).
- Validação de shebang BOM-safe (suporte a UTF-8 BOM de editores Windows/macOS) em todos os downloads.
- Validação de IPs reservados/privados em `validate_domain_or_ip()` — loopback, RFC1918 e multicast rejeitados.

### 🤖 Bot Telegram (Seguro)
- Bot roda em **venv** isolado (não afeta o Python do sistema).
- Bot roda como usuário **não-root** (`botxray`).
- Token e Admin ID armazenados em `EnvironmentFile` (`/opt/XrayTools/.bot_env`) — nunca hardcoded no código.
- Escrita atômica no `config.json` e `users.db` via `tmpfile + os.replace()` — sem corrupção em falha parcial.
- `save_config()` aplica `chmod 0640` — config não fica legível por outros usuários após operações do bot.
- `restart_xray()` retorna status e informa falha ao operador via Telegram.
- Backup pelo bot gera arquivo **SHA256** e envia junto ao admin.
- Nicks normalizados para minúsculas em todas as operações — consistente com os scripts Shell.

### 📦 Backup Compacto (inclui SSL)
- Backup inclui apenas o essencial:
  - Bancos de dados: `users.db`, `limits.db`, `usage.db`, `session.db`
  - Configuração: `/usr/local/etc/xray/`
  - Certificados: `/opt/DragonCoreSSL/`
- Arquivo SHA256 gerado ao lado do backup para verificação de integridade.
- Extração com `--no-overwrite-dir --no-same-permissions` — tar não sobrescreve permissões existentes.
- Permissões explícitas aplicadas após restore (640/600/750 nos arquivos corretos).
- Rotação automática — mantém apenas os 5 backups mais recentes.
- **Não inclui:** venv Python, scripts, backups anteriores.

### 📡 Monitor Online (API-only)
- Monitor usa a **API do Xray** — sem mexer em loglevel, sem restart.
- Delta real por ciclo (down+up separados desde a inicialização) — coluna "DELTA CICLO" exibe tráfego do intervalo, não total acumulado.
- Flag de saúde do Xray persistida entre ciclos — aviso não desaparece entre verificações.
- Janela deslizante de atividade (padrão 15s).
- Timeout por chamada à API para evitar travamentos.

---

## 🔐 Tabela de Permissões

| Arquivo / Diretório | Permissão | Dono |
|---|---|---|
| `config.json` | `0640` | `root:nogroup` |
| `preset.json` | `0640` | `root:nogroup` |
| `connection_info.txt` | `0600` | `root:root` |
| `users/*.txt` | `0600` | `root:root` |
| `users.db` | `0600` | `root:root` ou `botxray:botxray` |
| `limits.db / usage.db / session.db` | `0600` | `botxray:botxray` |
| `.bot_env` | `0640` | `root:botxray` |
| `botxray.py` | `0640` | `root:botxray` |
| `DragonCoreSSL/` | `0750` | `root:nogroup` |
| `fullchain.pem` | `0644` | `root:root` |
| `privkey.pem` | `0640` | `root:nogroup` |
| `renew_cert.sh` | `0700` | `root:root` |
| `wrap_*` (setuid) | `4750` | `root:botxray` |

---

## 📋 Requisitos

| Item | Requisito |
|------|-----------|
| Sistema Operacional | Ubuntu 20.04+ ou Debian 11/12 |
| Arquitetura | amd64 (x86_64) ou arm64 |
| Acesso | root |
| Python | 3.8+ (para o bot Telegram) |
| TLS (Let's Encrypt) | Porta 80 livre durante emissão/renovação |
| DNS (Let's Encrypt) | Domínio deve apontar para o IP da VPS |

---

## 🛠️ Instalação Rápida

Execute como **root** na sua VPS:

```bash
wget -qO installxray.sh https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/installxray.sh
chmod +x installxray.sh
./installxray.sh
```

Ou em uma linha:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/installxray.sh)
```

Após instalar, acesse o painel a qualquer momento com:

```bash
xray-menu
```

---

## 📁 Estrutura do Projeto

```
XrayX-TLS/
├── installxray.sh          # Instalador do launcher
├── menuxray.sh             # Menu principal (baixa módulos sob demanda)
├── modulosxray/
│   ├── core_manager.sh     # Wizard de instalação/configuração do Xray
│   ├── certxray.sh         # Emissão de certificados TLS
│   ├── add_user.sh         # Criar usuário
│   ├── remover_user.sh     # Remover usuário
│   ├── lista_users.sh      # Listar usuários com status
│   ├── block_user.sh       # Bloquear usuário (scramble)
│   ├── unblock_user.sh     # Desbloquear usuário
│   ├── remover_expirados.sh# Limpar usuários vencidos
│   ├── limiterxray.sh      # Controle de consumo por GB
│   ├── onlinexray.sh       # Monitor de usuários online (API)
│   ├── backup.sh           # Backup e restore
│   ├── botxray.sh          # Instalador do bot Telegram
│   ├── botxray.py          # Bot Telegram (Python)
│   └── uninstall.sh        # Desinstalação completa
```

---

## 🗂️ Arquivos de Dados

| Arquivo | Descrição |
|---------|-----------|
| `/opt/XrayTools/users.db` | Banco de usuários (`nick\|uuid\|expiry`) |
| `/opt/XrayTools/limits.db` | Limites de consumo por usuário |
| `/opt/XrayTools/usage.db` | Consumo acumulado por usuário |
| `/opt/XrayTools/.bot_env` | Token e Admin ID do bot (`0640 root:botxray`) |
| `/opt/XrayTools/users/` | Arquivos individuais de usuário com link VLESS (`0600`) |
| `/usr/local/etc/xray/config.json` | Configuração principal do Xray (`0640 root:nogroup`) |
| `/usr/local/etc/xray/preset.json` | Metadados da instalação (protocolo, porta, domínio) |
| `/opt/DragonCoreSSL/fullchain.pem` | Certificado TLS público (`0644`) |
| `/opt/DragonCoreSSL/privkey.pem` | Chave privada TLS (`0640 root:nogroup`) |
| `/opt/DragonCoreSSL/renew_cert.sh` | Script de renovação automática (`0700 root:root`) |
| `/root/backups/` | Backups gerados pelo sistema |

---

## 🌐 Protocolos Suportados

| Protocolo | TLS | Sem TLS |
|-----------|-----|---------|
| XHTTP | ✅ | ✅ |
| WebSocket (WS) | ✅ | ✅ |
| gRPC | ✅ | ✅ |
| TCP | ✅ | ✅ |
| VISION (XTLS) | ✅ | ❌ (exige TLS) |

---

## 🤖 Bot Telegram — Funcionalidades

| Função | Descrição |
|--------|-----------|
| `/start` ou `/menu` | Abre o painel |
| CRIAR | Cria usuário e gera link VLESS |
| REMOVER | Remove usuário do sistema |
| SUSPENDER | Bloqueia sem deletar (scramble UUID) |
| REATIVAR | Restaura UUID original e reativa |
| LISTAR | Envia arquivo `.txt` com todos os usuários |
| BACKUP | Gera backup compacto + SHA256 e envia via Telegram |
| SAIR | Fecha o painel |

---

## 🔄 Atualizar Módulos

No menu principal, selecione a opção `[99] ATUALIZAR MÓDULOS` para forçar o re-download de todos os módulos do repositório.

---

## 📝 Notas de Versão — V7.7.1

### Segurança
- **`chmod 777` eliminado em todos os módulos** — substituído por permissões mínimas necessárias (`640/600/700/750`).
- **Chave privada TLS** (`privkey.pem`) agora com `0640 root:nogroup` — antes era `777`, legível por qualquer processo.
- **`renew_cert.sh`** agora com `0700 root:root` — antes era `777`, qualquer processo podia substituí-lo por código malicioso executado como root via cron.
- **Wrappers setuid** do bot com `4750 root:botxray` — antes era `4755`, qualquer usuário do sistema executava como root.
- **Cron de renovação** com jitter aleatório — evita rate limiting no Let's Encrypt com múltiplos servidores.

### Atomicidade e integridade
- **`save_config()` Python** agora usa `tmpfile + os.replace()` — config nunca corrompido em falha parcial.
- **`users.db`** reescrito atomicamente em todos os módulos Shell e Python.
- **DBs do limiter** (`usage.db`, `session.db`) promovidos atomicamente após o loop de verificação.
- **`_TMP_FILES`** corretamente limpos após `mv -f` em `remover_expirados.sh`.

### Consistência
- **Nicks normalizados para minúsculas** em todos os módulos (`add_user`, `remover_user`, `block_user`, `unblock_user`, `lista_users`, `limiterxray`, `botxray.py`) — elimina dessincronização entre DB e config.json.
- **`_wait_xray_active()`** com retry de 5s substituiu `sleep N + is-active` simples em todos os módulos.
- **`bytes_human()` sem `bc`** em `limiterxray.sh` e `onlinexray.sh` — usa `awk`, disponível em qualquer Unix.
- **`func_get_api_port()`** lê a porta da API dinamicamente do `config.json` em todos os módulos que consultam a API.

### Bugs corrigidos
- `remover_expirados.sh`: `_cleanup()` exibia `[ERRO]` em toda saída incluindo `exit 0`.
- `uninstall.sh`: `ACTIVE_DOMAIN` lido após `rm -rf /opt/XrayTools` — sempre ficava vazio.
- `lista_users.sh`: status `"unknown"` exibido como `ATIVO` (enganoso) — agora exibe `FORA DE SYNC`.
- `onlinexray.sh`: coluna "DELTA CICLO" exibia total acumulado desde o início do Xray, não o delta do ciclo.
- `limiterxray.sh`: `chmod 0600 root:root` no `config.json` impedia que o Xray (`nobody/nogroup`) lesse o arquivo após qualquer operação do limiter.
- `botxray.py`: `restart_xray()` ignorava falha silenciosamente — bot reportava sucesso mesmo com Xray parado.
- `core_manager.sh`: porta API hardcoded como `1080` com fallback quebrado que tentava `1080` duas vezes.
- `certxray.sh`: domínio gravado em `$ACTIVE_DOMAIN_FILE` antes da validação — valor inválido podia ser persistido.

---

## 📄 Licença

Projeto de uso livre para administração pessoal de servidores VPS.
