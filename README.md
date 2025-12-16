# ⚡ XrayX-TLS | Gerenciador Xray Core Avançado

![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Xray](https://img.shields.io/badge/Core-Xray-blue?style=for-the-badge)
![PostgreSQL](https://img.shields.io/badge/Database-PostgreSQL-336791?style=for-the-badge&logo=postgresql&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge)

> Uma solução robusta, leve e automatizada escrita 100% em **Bash Puro** para gerenciamento profissional do Xray Core. Integração nativa com banco de dados PostgreSQL e manipulação direta de JSON.

---

## 🚀 Sobre o Projeto

O **XrayX-TLS** foi desenvolvido para substituir sistemas legados baseados em PHP, oferecendo maior performance e segurança ao remover dependências de interpretadores web. O sistema gerencia usuários, configurações de rede, certificados SSL e limpeza automática de contas expiradas.

### ✨ Principais Funcionalidades

* ✅ **Instalação Automática:** Configura dependências (`jq`, `psql`, `uuidgen`), binário Xray e ambiente.
* ✅ **Gestão de Usuários VLESS:** Criação, remoção e listagem com UUIDs gerados dinamicamente.
* ✅ **Integração PostgreSQL:** Armazenamento persistente e seguro de credenciais e validade.
* ✅ **Manipulação JSON Nativa:** Edição segura do `config.json` do Xray utilizando `jq`.
* ✅ **Certificados TLS:** Geração automática de certificados autoassinados para protocolos seguros (XHTTP/TLS).
* ✅ **Auto-Purge:** Tarefa automática (Cron) para remover usuários expirados diariamente.
* ✅ **Interface CLI:** Menu interativo intuitivo e colorido.

---

## 🛠️ Instalação

Siga os passos abaixo para instalar em seu servidor VPS (Ubuntu 20.04+ recomendado).

### 1. Preparar e Clonar o Repositório

````
sudo apt update && sudo apt install -y wget && wget -qO installxray.sh https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/installxray.sh && sudo chmod +x installxray.sh && sudo ./installxray.sh
````


````
bash <(wget -qO- https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/installxray.sh)
````
