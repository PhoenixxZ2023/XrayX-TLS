# ⚡ DragonCore Xray Manager | V7.7 (Modular)

![Version](https://img.shields.io/badge/Version-7.7-blue?style=for-the-badge&labelColor=black)
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
- `config.json` com permissão `0644 nobody:nogroup` — Xray lê, outros não escrevem.
- Backup do config antes de qualquer modificação, com rollback automático em falha.
- `REPO_BASE` e `PINNED_REF` validados com regex antes de uso em URLs.
- UUID gerado com fallback (`uuidgen` → `/proc/sys/kernel/random/uuid` → `/dev/urandom`).

### 🤖 Bot Telegram (Seguro)
- Bot roda em **venv** isolado (não afeta o Python do sistema).
- Bot roda como usuário **não-root** (`botxray`).
- Token e Admin ID armazenados em `EnvironmentFile` (`/opt/XrayTools/.bot_env`) — nunca hardcoded no código.
- Manipulação direta do `config.json` via Python (sem dependência de sudo).
- Backup pelo bot exclui venv e arquivos desnecessários — arquivo compacto (~8KB).

### 📦 Backup Compacto (inclui SSL)
- Backup inclui apenas o essencial:
  - Bancos de dados: `users.db`, `limits.db`, `usage.db`, `session.db`
  - Configuração: `/usr/local/etc/xray/`
  - Certificados: `/opt/DragonCoreSSL/`
- Arquivo SHA256 gerado ao lado do backup para verificação de integridade.
- Rotação automática — mantém apenas os 5 backups mais recentes.
- **Não inclui:** venv Python, scripts, backups anteriores (~8KB em vez de ~8MB).

### 📡 Monitor Online (API-only)
- Monitor usa a **API do Xray** — sem mexer em loglevel, sem restart.
- Janela deslizante de atividade (padrão 15s).
- Timeout por chamada à API para evitar travamentos.

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
│   ├── add_user.sh         # Criar usuário
│   ├── remover_user.sh     # Remover usuário
│   ├── lista_users.sh      # Listar usuários com status
│   ├── block_user.sh       # Bloquear usuário (scramble)
│   ├── unblock_user.sh     # Desbloquear usuário
│   ├── remover_expirados.sh# Limpar usuários vencidos
│   ├── limiterxray.sh      # Controle de consumo por GB
│   ├── onlinexray.sh       # Monitor de usuários online (API)
│   ├── backup.sh           # Backup e restore
│   ├── certxray.sh         # Emissão de certificados TLS
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
| `/opt/XrayTools/.bot_env` | Token e Admin ID do bot (chmod 640) |
| `/usr/local/etc/xray/config.json` | Configuração principal do Xray |
| `/usr/local/etc/xray/preset.json` | Metadados da instalação (protocolo, porta, domínio) |
| `/opt/DragonCoreSSL/` | Certificados TLS (fullchain.pem, privkey.pem) |
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
| BACKUP | Gera e envia backup compacto via Telegram |
| SAIR | Fecha o painel |

---

## 🔄 Atualizar Módulos

No menu principal, selecione a opção `[99] ATUALIZAR MÓDULOS` para forçar o re-download de todos os módulos do repositório.

---

## 📄 Licença

Projeto de uso livre para administração pessoal de servidores VPS.
