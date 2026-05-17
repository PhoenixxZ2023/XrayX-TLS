# ⚡ DragonCore Xray Manager | V7.7 (Modular)

![Version](https://img.shields.io/badge/Version-7.7-blue?style=for-the-badge&labelColor=black)
![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Python](https://img.shields.io/badge/Bot-Python3-yellow?style=for-the-badge&logo=python&logoColor=white)
![Xray](https://img.shields.io/badge/Core-Xray-purple?style=for-the-badge)
![Security](https://img.shields.io/badge/Security-UUID_Scramble-red?style=for-the-badge)

> **Gerenciador Xray híbrido (Bash + Python)** com arquitetura modular, cache local e foco em estabilidade/segurança.
> Ideal para quem administra múltiplos usuários VLESS e precisa de painel local + bot Telegram.

---

## ✅ O que este projeto entrega

### 🧩 Arquitetura Modular (Cache Local)
- O `installxray.sh` instala apenas o **launcher** e dependências essenciais.
- O `menuxray.sh` baixa os módulos **sob demanda** (e mantém no `/usr/local/bin`).
- Mesmo se o GitHub ficar fora do ar, o painel segue funcionando com os módulos já cacheados.

### 🛡️ Bloqueio Seguro (Scramble)
- Bloquear não deleta usuário.
- Troca UUID por falso e aplica `LOCKED_` no email (fácil de reverter).
- Mantém histórico do usuário no `users.db`.

### 🤖 Bot Telegram (Seguro)
- Bot roda em **venv** (não quebra o Python do sistema).
- Bot roda como usuário **não-root** (`botxray`).
- Ações administrativas (criar/remover/bloquear/desbloquear/backup) são feitas via **sudoers restrito** chamando scripts do painel.

### 📦 Backup Completo (inclui SSL)
- Backup inclui:
  - `/opt/XrayTools`
  - `/usr/local/etc/xray`
  - `/opt/DragonCoreSSL`

### 📡 Monitor Online (API-only)
- Monitor de online usa a **API do Xray** (sem mexer em loglevel e sem restart).

---

## 📋 Requisitos

- **SO:** Ubuntu 20.04+ ou Debian 11/12
- **Arquitetura:** amd64 (x86_64) ou arm64
- **Acesso:** root
- **TLS (Let's Encrypt):** Porta 80 deve estar livre durante emissão/renovação

---

## 🛠️ Instalação Rápida

Compatível com **Ubuntu 20.04+** (Recomendado) e Debian 11+.
Execute **um** dos comandos abaixo no terminal da sua VPS (como root):

### Opção 1 (Recomendada - via wget)

````
sudo apt update && sudo apt install -y wget && wget -qO installxray.sh https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/installxray.sh && sudo chmod +x installxray.sh && sudo ./installxray.sh
````


````
bash <(wget -qO- https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/installxray.sh) && xray-menu
````
