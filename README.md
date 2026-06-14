# ⚡ DragonCore Xray Manager | V7.3

![Version](https://img.shields.io/badge/Version-7.3-blue?style=for-the-badge&labelColor=black)
![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Python](https://img.shields.io/badge/Bot-Python3-yellow?style=for-the-badge&logo=python&logoColor=white)
![Xray](https://img.shields.io/badge/Core-Xray-purple?style=for-the-badge)
![Security](https://img.shields.io/badge/Security-UUID_Scramble-red?style=for-the-badge)

> **A evolução do gerenciamento Xray.** Uma solução híbrida (Bash + Python) robusta, offline-ready e focada em segurança para provedores de VPN profissional.

---

## 🚀 O Que Há de Novo na V7.3?

O **DragonCore Xray Manager** foi reescrito para eliminar dependências externas críticas e maximizar a estabilidade.

### 🛡️ Segurança e Estabilidade
* **Offline-Ready (Cache Inteligente):** Os módulos essenciais são baixados e armazenados localmente. O painel segue funcionando mesmo se o GitHub cair.
* **Bloqueio "Scramble":** O sistema **não deleta** o usuário ao bloquear. Ele altera o UUID para um hash inválido e renomeia para `LOCKED_`, preservando o histórico e facilitando o desbloqueio.
* **Validação Rigorosa:** Impede erros humanos e nomes quebrados (Regra: 5-9 caracteres alfanuméricos).

### 🤖 Automação e Bot Telegram
* **Bot Python Nativo (Async):** Painel de controle completo via Telegram, rápido e sem delay.
* **Gerador de Links Inteligente:** Detecta automaticamente o protocolo (Vision, XHTTP, gRPC, WS) e gera o link VLESS correto.
* **Relatórios Limpos:** Gera listas de usuários em arquivo `.txt` para evitar poluição visual no chat.
* **Anti-Freeze:** Sistema de conversação que não trava se o usuário clicar em botões antigos.

### ⚡ Funcionalidades do Core
* **Protocolos Modernos:** Suporte total a VLESS + XTLS-Vision, gRPC, WebSocket e o novo XHTTP.
* **Gerenciador de Certificados:** Suporte a Let's Encrypt (Oficial) e Auto-Assinado com renovação automática.
* **Backup Inteligente:** Verifica a integridade dos dados antes de substituir o backup anterior.
* **Auto-Instalação:** Configura Xray, Certificados, Python, Cron e Bot com um único comando.

---

## 📋 Requisitos do Sistema

* **SO:** Ubuntu 20.04+ (Recomendado) ou Debian 11+
* **Arquitetura:** x86_64 (amd64) ou ARM64
* **Portas:**
    * **Com TLS:** Porta 80 livre (para validação do Certificado)
    * **Sem TLS:** Qualquer porta livre

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
