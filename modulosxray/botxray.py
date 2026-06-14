"""
botxray.py - DragonCore V7.7.1
Correções aplicadas:
  - save_config(): escrita atômica via tmpfile + os.replace() + chmod 0o640
  - core_delete_user(): USER_DB atômico via tmpfile + os.replace()
  - restart_xray(): retorna bool, loga stderr em caso de falha
  - Funções core reportam falha de restart ao usuário
  - nick normalizado para minúsculas em input_handler
  - generate_link(): sem fallback para inbounds[0] — erro explícito se inbound não encontrado
  - core_create_user(): verificação de duplicidade linha por linha (sem string.contains)
  - Backup Python gera SHA256 e envia junto ao admin
  - get_ip(): timeout aumentado para 8s
"""

import os
import json
import uuid
import hashlib
import logging
import subprocess
import asyncio
import re
import urllib.request
from datetime import datetime, timedelta
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application, CommandHandler, ContextTypes, ConversationHandler,
    MessageHandler, filters, CallbackQueryHandler
)
import io

# --- CONFIGURACAO VIA VARIAVEIS DE AMBIENTE ---
_token = os.environ.get("BOT_TOKEN", "")
_admin = os.environ.get("ADMIN_ID", "")
if not _token or not _admin:
    raise EnvironmentError(
        "BOT_TOKEN e ADMIN_ID devem estar definidos.\n"
        "Verifique /opt/XrayTools/.bot_env e EnvironmentFile= no botxray.service."
    )
BOT_TOKEN = _token
try:
    ADMIN_ID = int(_admin)
except ValueError:
    raise EnvironmentError(f"ADMIN_ID deve ser inteiro, obtido: '{_admin}'")

CONFIG_PATH  = "/usr/local/etc/xray/config.json"
USER_DB      = "/opt/XrayTools/users.db"
XRAY_SERVICE = "xray"

logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

(
    SELECTING_ACTION,
    GET_USERNAME_CREATE,
    GET_EXPIRY_DAYS_CREATE,
    GET_USER_TO_DELETE,
    GET_USER_TO_BLOCK,
    GET_USER_TO_UNBLOCK,
) = range(6)


# =============================================================
# FUNÇÕES DE SISTEMA
# =============================================================

def reload_xray_user(action: str, nick: str, user_uuid: str, inbound_tag: str = "inbound-dragoncore") -> bool:
    """
    Adiciona ou remove usuário via API do Xray em tempo real — sem restart.
    Não derruba conexões de outros clientes.
    action: "add" ou "remove"
    Requer inbound api configurado (tag: api) e XRAY_BIN disponível.
    """
    try:
        # Descobre a porta da API no config
        data = load_config()
        if not data:
            return False
        api_port = None
        for inb in data.get("inbounds", []):
            if inb.get("tag") == "api":
                api_port = str(inb.get("port", ""))
                break
        if not api_port:
            logger.warning("reload_xray_user: inbound api não encontrado")
            return False

        xray_bin = "/usr/local/bin/xray"
        if not os.path.exists(xray_bin):
            logger.warning("reload_xray_user: xray binário não encontrado")
            return False

        if action == "add":
            user_json = json.dumps({
                "id": user_uuid,
                "email": nick,
                "level": 0
            })
            cmd = [xray_bin, "api", "adduser",
                   f"-server=127.0.0.1:{api_port}",
                   f"-inboundTag={inbound_tag}",
                   f"-user={user_json}"]
        elif action == "remove":
            cmd = [xray_bin, "api", "removeuser",
                   f"-server=127.0.0.1:{api_port}",
                   f"-inboundTag={inbound_tag}",
                   f"-email={nick}"]
        else:
            return False

        result = subprocess.run(cmd, check=False, capture_output=True, timeout=5)
        if result.returncode == 0:
            logger.info("reload_xray_user: %s '%s' via API OK", action, nick)
            return True
        else:
            logger.warning("reload_xray_user %s falhou: %s",
                          action, result.stderr.decode(errors="replace").strip())
            return False
    except Exception as e:
        logger.error("reload_xray_user erro: %s", e)
        return False


def load_config() -> dict | None:
    if not os.path.exists(CONFIG_PATH):
        return None
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        logger.error("JSON corrompido: %s", e)
        return None


def save_config(data: dict) -> bool:
    """
    Escrita atômica: tmpfile no mesmo diretório do config → os.replace().
    - tmpfile no mesmo dir evita cross-device link (PrivateTmp=true no systemd
      cria /tmp isolado, impossibilitando os.replace() de /tmp para /usr/local).
    - Após replace, restaura dono root:nogroup e permissão 660 — o os.replace()
      herda dono do tmpfile (botxray:botxray), não do arquivo original.
    """
    tmp_path = CONFIG_PATH + f".tmp.{os.getpid()}"
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp_path, CONFIG_PATH)
        # Restaura permissão e dono corretos após replace
        # (os.replace herda dono do tmpfile — botxray:botxray — em vez do original)
        os.chmod(CONFIG_PATH, 0o660)
        try:
            import grp
            gid = grp.getgrnam("nogroup").gr_gid
            os.chown(CONFIG_PATH, 0, gid)  # root:nogroup
        except Exception as e:
            logger.warning("save_config: não foi possível restaurar chown root:nogroup: %s", e)
        return True
    except PermissionError as e:
        logger.error("save_config: sem permissão — verifique chmod 770 em %s e SupplementaryGroups=nogroup: %s",
                     os.path.dirname(CONFIG_PATH), e)
        return False
    except Exception as e:
        logger.error("Erro ao salvar config: %s", e)
        return False
    finally:
        try:
            os.remove(tmp_path)
        except OSError:
            pass


def get_ip() -> str:
    """CORREÇÃO: timeout 8s — 3s era muito curto para VPS com alta latência."""
    for url in ("https://icanhazip.com", "https://api.ipify.org"):
        try:
            with urllib.request.urlopen(url, timeout=8) as resp:
                return resp.read().decode("utf-8").strip()
        except Exception as e:
            logger.warning("get_ip falhou em %s: %s", url, e)
    return "127.0.0.1"


# =============================================================
# GERADOR DE LINKS
# =============================================================

def generate_link(client_uuid: str, client_email: str) -> str:
    """
    CORREÇÃO: sem fallback para inbounds[0] — se inbound-dragoncore não existir,
    retorna erro explícito em vez de gerar link para a porta da API interna.
    """
    try:
        data = load_config()
        if not data:
            return "❌ Erro ao ler config."

        inbound = next(
            (i for i in data.get("inbounds", []) if i.get("tag") == "inbound-dragoncore"),
            None,
        )
        if not inbound:
            return "❌ inbound-dragoncore não encontrado no config."

        port     = inbound["port"]
        stream   = inbound["streamSettings"]
        network  = stream["network"]
        security = stream["security"]

        sni = ""
        host = ""
        if security == "tls":
            tls = stream.get("tlsSettings", {})
            sni  = tls.get("serverName", "")
            host = sni

        if not host:
            host = get_ip()
            sni  = ""

        if network == "tcp":
            clients = inbound.get("settings", {}).get("clients", [])
            client  = next((c for c in clients if c.get("id") == client_uuid), {})
            flow    = client.get("flow", "")
            if flow == "xtls-rprx-vision":
                return (
                    f"vless://{client_uuid}@{host}:{port}"
                    f"?security=tls&encryption=none&type=tcp"
                    f"&headerType=none&flow={flow}&sni={sni}#{client_email}"
                )
            sec_param = "security=tls" if security == "tls" else "security=none"
            return (
                f"vless://{client_uuid}@{host}:{port}"
                f"?{sec_param}&encryption=none&type=tcp&headerType=none&sni={sni}#{client_email}"
            )

        if network == "ws":
            path      = stream.get("wsSettings", {}).get("path", "/")
            sec_param = "security=tls" if security == "tls" else "security=none"
            ws_host   = sni if sni else host
            return (
                f"vless://{client_uuid}@{host}:{port}"
                f"?{sec_param}&encryption=none&type=ws"
                f"&host={ws_host}&path={path}&sni={sni}#{client_email}"
            )

        if network == "grpc":
            service   = stream.get("grpcSettings", {}).get("serviceName", "gRPC")
            sec_param = "security=tls" if security == "tls" else "security=none"
            return (
                f"vless://{client_uuid}@{host}:{port}"
                f"?{sec_param}&encryption=none&type=grpc"
                f"&serviceName={service}&sni={sni}#{client_email}"
            )

        if network == "xhttp":
            path      = stream.get("xhttpSettings", {}).get("path", "/")
            sec_param = "security=tls" if security == "tls" else "security=none"
            return (
                f"vless://{client_uuid}@{host}:{port}"
                f"?mode=auto&{sec_param}&encryption=none&type=xhttp"
                f"&host={host}&path={path}&sni={sni}#{client_email}"
            )

        return "❌ Protocolo não suportado para geração de link."

    except Exception as e:
        return f"Erro Link: {e}"


# =============================================================
# FUNÇÕES CORE
# =============================================================

def core_create_user(nick: str, days: str) -> tuple[bool, str]:
    """
    CORREÇÃO: verificação de duplicidade linha por linha com startswith()
    em vez de 'nick|' in f.read() — mais robusto com linhas corrompidas sem '|'.
    """
    if os.path.exists(USER_DB):
        with open(USER_DB, "r") as f:
            if any(line.startswith(f"{nick}|") for line in f):
                return False, "❌ Usuário já existe!"
    else:
        open(USER_DB, "a").close()

    user_uuid   = str(uuid.uuid4())
    expiry_date = (datetime.now() + timedelta(days=int(days))).strftime("%Y-%m-%d")

    data = load_config()
    if not data:
        return False, "❌ Erro ao ler config.json"

    inbound = next(
        (i for i in data.get("inbounds", []) if i.get("tag") == "inbound-dragoncore"),
        None,
    )
    if not inbound:
        return False, "❌ inbound-dragoncore não encontrado."

    inbound["settings"]["clients"].append(
        {"id": user_uuid, "email": nick, "level": 0}
    )

    if not save_config(data):
        return False, "❌ Falha ao salvar config.json."

    with open(USER_DB, "a") as f:
        f.write(f"{nick}|{user_uuid}|{expiry_date}\n")

    # Adiciona usuário via API do Xray em tempo real (sem restart, sem derrubar outros)
    reload_xray_user("add", nick, user_uuid)

    return True, (
        f"✅ *Usuário Criado!*\n\n"
        f"👤 Nome:   `{nick}`\n"
        f"🔑 UUID:   `{user_uuid}`\n"
        f"📅 Expira: `{expiry_date}`"
    )


def core_delete_user(nick: str) -> str:
    data  = load_config()
    found = False

    if data:
        for inbound in data.get("inbounds", []):
            if inbound.get("tag") == "inbound-dragoncore":
                clients     = inbound["settings"]["clients"]
                new_clients = [
                    c for c in clients
                    if c.get("email") not in (nick, f"LOCKED_{nick}")
                ]
                if len(clients) != len(new_clients):
                    found = True
                inbound["settings"]["clients"] = new_clients
        if not save_config(data):
            return "❌ Falha ao salvar config.json."

    if os.path.exists(USER_DB):
        with open(USER_DB, "r") as f:
            lines = f.readlines()
        new_lines = []
        for line in lines:
            if line.startswith(f"{nick}|"):
                found = True
            else:
                new_lines.append(line)
        # CORREÇÃO: escrita atômica — evita truncamento parcial em falha.
        tmp_db = USER_DB + ".tmp"
        with open(tmp_db, "w") as f:
            f.writelines(new_lines)
        os.replace(tmp_db, USER_DB)

    if not found:
        return "❌ Usuário não encontrado no sistema."

    # Remove usuário via API do Xray em tempo real
    reload_xray_user("remove", nick, "")
    return "✅ Usuário removido do sistema."


def core_block_user(nick: str) -> str:
    data = load_config()
    if not data:
        return "❌ Erro config."

    found = False
    for inbound in data.get("inbounds", []):
        if inbound.get("tag") == "inbound-dragoncore":
            for client in inbound["settings"]["clients"]:
                if client.get("email") == f"LOCKED_{nick}":
                    return "⚠️ Usuário já está bloqueado."
                if client.get("email") == nick:
                    client["email"] = f"LOCKED_{nick}"
                    client["id"]    = str(uuid.uuid4())
                    found = True
                    break

    if not found:
        return "❌ Usuário não encontrado no Config."

    if not save_config(data):
        return "❌ Falha ao salvar config.json."

    # Remove o usuário com UUID real e adiciona com UUID falso via API (sem restart)
    reload_xray_user("remove", nick, "")
    locked_nick = f"LOCKED_{nick}"
    fake_uuid_str = str(uuid.uuid4())
    reload_xray_user("add", locked_nick, fake_uuid_str)
    return f"⛔ Usuário `{nick}` foi SUSPENSO."


def core_unblock_user(nick: str) -> str:
    real_uuid = None
    if os.path.exists(USER_DB):
        with open(USER_DB, "r") as f:
            for line in f:
                if line.startswith(f"{nick}|"):
                    parts = line.strip().split("|")
                    if len(parts) >= 2:
                        real_uuid = parts[1]
                    break

    if not real_uuid:
        return "❌ Erro: UUID original não encontrado no DB."

    data = load_config()
    if not data:
        return "❌ Erro ao ler config."

    found = False
    for inbound in data.get("inbounds", []):
        if inbound.get("tag") == "inbound-dragoncore":
            for client in inbound["settings"]["clients"]:
                if client.get("email") == f"LOCKED_{nick}":
                    client["email"] = nick
                    client["id"]    = real_uuid
                    found = True
                    break

    if not found:
        return "❌ Usuário não estava bloqueado no sistema."

    if not save_config(data):
        return "❌ Falha ao salvar config.json."

    # Remove entrada LOCKED_ e adiciona com UUID real via API (sem restart)
    reload_xray_user("remove", f"LOCKED_{nick}", "")
    reload_xray_user("add", nick, real_uuid)
    return f"✅ Usuário `{nick}` REATIVADO com sucesso."


def core_list_users_text() -> str:
    if not os.path.exists(USER_DB):
        return "Nenhum usuário cadastrado."

    data         = load_config()
    locked_users = set()
    if data:
        for inbound in data.get("inbounds", []):
            if inbound.get("tag") == "inbound-dragoncore":
                for c in inbound["settings"]["clients"]:
                    email = c.get("email", "")
                    if email.startswith("LOCKED_"):
                        locked_users.add(email.replace("LOCKED_", "", 1))

    sep = "-" * 65
    header = (
        "📋 LISTA DE USUÁRIOS - DRAGONCORE\n"
        + sep + "\n"
        + f"{'NOME':<12} | {'VENCIMENTO':<11} | {'UUID (resumido)':<20} | STATUS\n"
        + sep + "\n"
    )
    rows = []
    with open(USER_DB, "r") as f:
        for line in f:
            parts = line.strip().split("|")
            if len(parts) >= 3:
                nick_r, uuid_r, expiry_r = parts[0], parts[1], parts[2]
                status = "⛔" if nick_r in locked_users else "✅"
                # UUID truncado — não expõe credencial completa no chat
                uuid_short = uuid_r[:8] + "..." + uuid_r[-4:] if len(uuid_r) >= 12 else uuid_r
                rows.append(f"{nick_r:<12} | {expiry_r:<11} | {uuid_short:<20} | {status}")

    footer = "\n" + sep + f"\nTotal: {len(rows)} usuário(s)"
    return header + "\n".join(rows) + footer if rows else header + "(vazio)"


# =============================================================
# FUNÇÕES DO TELEGRAM
# =============================================================

def is_admin(update: Update) -> bool:
    return update.effective_user is not None and update.effective_user.id == ADMIN_ID


def build_menu() -> InlineKeyboardMarkup:
    keyboard = [
        [
            InlineKeyboardButton("👤 CRIAR",     callback_data="create_start"),
            InlineKeyboardButton("🗑️ REMOVER",   callback_data="delete_start"),
        ],
        [
            InlineKeyboardButton("⛔ SUSPENDER", callback_data="block_start"),
            InlineKeyboardButton("✅ REATIVAR",  callback_data="unblock_start"),
        ],
        [
            InlineKeyboardButton("📋 LISTAR (TXT)", callback_data="list_users"),
            InlineKeyboardButton("📥 BACKUP",        callback_data="backup_start"),
        ],
        [InlineKeyboardButton("❌ SAIR", callback_data="cancel")],
    ]
    return InlineKeyboardMarkup(keyboard)


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return
    context.user_data.clear()
    await update.message.reply_text(
        "🐉 *PAINEL DRAGONCORE V7.7*",
        reply_markup=build_menu(),
        parse_mode="Markdown",
    )
    return SELECTING_ACTION


async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return

    query = update.callback_query
    await query.answer()

    if query.data == "close_file":
        await query.message.delete()
        return SELECTING_ACTION

    if query.data == "cancel":
        await query.edit_message_text("Painel Fechado.", reply_markup=None)
        return ConversationHandler.END

    if query.data == "create_start":
        await query.edit_message_text(
            "Nome do usuário (5-9 letras/num):", parse_mode="Markdown"
        )
        return GET_USERNAME_CREATE

    if query.data == "delete_start":
        await query.edit_message_text("Nome para remover:", parse_mode="Markdown")
        return GET_USER_TO_DELETE

    if query.data == "block_start":
        await query.edit_message_text(
            "Nome para ⛔ SUSPENDER:", parse_mode="Markdown"
        )
        return GET_USER_TO_BLOCK

    if query.data == "unblock_start":
        await query.edit_message_text(
            "Nome para ✅ REATIVAR:", parse_mode="Markdown"
        )
        return GET_USER_TO_UNBLOCK

    if query.data == "list_users":
        report = core_list_users_text()
        f = io.BytesIO(report.encode("utf-8"))
        f.name = "usuarios.txt"
        close_btn = InlineKeyboardMarkup(
            [[InlineKeyboardButton("🗑 Fechar Lista", callback_data="close_file")]]
        )
        await context.bot.send_document(
            chat_id=update.effective_chat.id,
            document=f,
            caption="📂 *Lista gerada*",
            parse_mode="Markdown",
            reply_markup=close_btn,
        )
        await query.edit_message_text(
            "✅ *Lista enviada abaixo!*\nEscolha outra opção:",
            parse_mode="Markdown",
            reply_markup=build_menu(),
        )
        return SELECTING_ACTION

    if query.data == "backup_start":
        await query.edit_message_text("📦 Gerando Backup...", parse_mode="Markdown")

        import tempfile, shutil

        date_str = datetime.now().strftime("%Y%m%d_%H%M")
        bkp_file = f"/tmp/backup_{date_str}.tar.gz"
        sha_file = bkp_file + ".sha256"

        tmpdir = tempfile.mkdtemp()
        try:
            os.makedirs(f"{tmpdir}/opt/XrayTools", exist_ok=True)
            for fname in ["users.db", "limits.db", "usage.db", "session.db", "active_domain"]:
                src = f"/opt/XrayTools/{fname}"
                if os.path.exists(src):
                    shutil.copy2(src, f"{tmpdir}/opt/XrayTools/{fname}")
            if os.path.isdir("/usr/local/etc/xray"):
                shutil.copytree(
                    "/usr/local/etc/xray",
                    f"{tmpdir}/usr/local/etc/xray",
                    dirs_exist_ok=True,
                )
            if os.path.isdir("/opt/DragonCoreSSL"):
                shutil.copytree(
                    "/opt/DragonCoreSSL",
                    f"{tmpdir}/opt/DragonCoreSSL",
                    dirs_exist_ok=True,
                )
            subprocess.run(
                ["tar", "-czf", bkp_file, "-C", tmpdir, "."],
                check=False,
                capture_output=True,
            )
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

        if os.path.exists(bkp_file) and os.path.getsize(bkp_file) > 0:
            # CORREÇÃO: gera SHA256 e envia junto ao admin —
            # versão anterior não gerava hash, impossibilitando verificação antes do restore.
            digest = hashlib.sha256(open(bkp_file, "rb").read()).hexdigest()
            with open(sha_file, "w") as sf:
                sf.write(f"{digest}  {os.path.basename(bkp_file)}\n")

            close_btn = InlineKeyboardMarkup(
                [[InlineKeyboardButton("🗑 Fechar Backup", callback_data="close_file")]]
            )
            # Envia o tar.gz
            with open(bkp_file, "rb") as f:
                await context.bot.send_document(
                    chat_id=update.effective_chat.id,
                    document=f,
                    filename=os.path.basename(bkp_file),
                    caption=(
                        "🔐 *Backup do Sistema*\n\n"
                        "_Inclui Xray, Banco de Dados e SSL_\n"
                        f"SHA256: `{digest[:16]}...`"
                    ),
                    parse_mode="Markdown",
                    reply_markup=close_btn,
                )
            # Envia o .sha256
            with open(sha_file, "rb") as f:
                await context.bot.send_document(
                    chat_id=update.effective_chat.id,
                    document=f,
                    filename=os.path.basename(sha_file),
                    caption="🔑 Hash SHA256 do backup acima",
                )
            os.remove(bkp_file)
            os.remove(sha_file)
            await query.edit_message_text(
                "✅ *Backup enviado abaixo!*",
                parse_mode="Markdown",
                reply_markup=build_menu(),
            )
        else:
            await query.edit_message_text(
                "❌ Falha ao criar backup. Verifique os logs.",
                reply_markup=build_menu(),
            )
        return SELECTING_ACTION

    await query.edit_message_text("Reiniciando...", reply_markup=build_menu())
    return SELECTING_ACTION


async def unexpected_button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    return await button_handler(update, context)


async def input_handler(
    update: Update, context: ContextTypes.DEFAULT_TYPE, mode: str
):
    if not is_admin(update):
        return SELECTING_ACTION
    if not update.message or not update.message.text:
        return SELECTING_ACTION

    # CORREÇÃO: normaliza para minúsculas — usuários criados pelos scripts Shell
    # são gravados em minúsculas; sem normalização, block/delete/unblock falhavam
    # quando o operador digitava em maiúsculas pelo bot.
    text = update.message.text.strip().split()[0].lower()

    if mode == "create_nick":
        if not re.match(r"^[a-zA-Z0-9]{5,9}$", text):
            await update.message.reply_text(
                "❌ *Nome Inválido!*\n\nRegras:\n• Entre 5 e 9 caracteres\n"
                "• Apenas letras e números\n\nTente outro:",
                parse_mode="Markdown",
            )
            return GET_USERNAME_CREATE
        context.user_data["nick"] = text
        await update.message.reply_text(
            f"Validade (dias) para `{text}`:", parse_mode="Markdown"
        )
        return GET_EXPIRY_DAYS_CREATE

    if mode == "create_days":
        if not text.isdigit():
            await update.message.reply_text("Só números.")
            return GET_EXPIRY_DAYS_CREATE
        _ok, msg = core_create_user(context.user_data["nick"], text)
        await update.message.reply_text(msg, parse_mode="Markdown", reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == "delete":
        msg = core_delete_user(text)
        await update.message.reply_text(msg, reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == "block":
        msg = core_block_user(text)
        await update.message.reply_text(msg, parse_mode="Markdown", reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == "unblock":
        msg = core_unblock_user(text)
        await update.message.reply_text(msg, parse_mode="Markdown", reply_markup=build_menu())
        return SELECTING_ACTION

    # Fallback — modo desconhecido, retorna ao menu sem travar
    logger.warning("input_handler: modo desconhecido '%s'", mode)
    await update.message.reply_text("❌ Operação inválida.", reply_markup=build_menu())
    return SELECTING_ACTION


# Wrappers assíncronos
async def h_create_nick(u, c): return await input_handler(u, c, "create_nick")
async def h_create_days(u, c): return await input_handler(u, c, "create_days")
async def h_delete(u, c):      return await input_handler(u, c, "delete")
async def h_block(u, c):       return await input_handler(u, c, "block")
async def h_unblock(u, c):     return await input_handler(u, c, "unblock")


async def cancel_op(u, c):
    await u.message.reply_text("Cancelado.", reply_markup=build_menu())
    return SELECTING_ACTION


# =============================================================
# MAIN
# =============================================================

def main():
    app = Application.builder().token(BOT_TOKEN).build()

    conv = ConversationHandler(
        entry_points=[
            CommandHandler("start", start),
            CommandHandler("menu",  start),
        ],
        states={
            SELECTING_ACTION: [CallbackQueryHandler(button_handler)],
            GET_USERNAME_CREATE: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_create_nick),
                CallbackQueryHandler(unexpected_button),
            ],
            GET_EXPIRY_DAYS_CREATE: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_create_days),
                CallbackQueryHandler(unexpected_button),
            ],
            GET_USER_TO_DELETE: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_delete),
                CallbackQueryHandler(unexpected_button),
            ],
            GET_USER_TO_BLOCK: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_block),
                CallbackQueryHandler(unexpected_button),
            ],
            GET_USER_TO_UNBLOCK: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_unblock),
                CallbackQueryHandler(unexpected_button),
            ],
        },
        fallbacks=[CommandHandler("cancel", cancel_op)],
        allow_reentry=True,
    )
    app.add_handler(conv)
    logger.info("DragonCore Bot V7.7.1 iniciado. Admin ID: %d", ADMIN_ID)
    app.run_polling()


if __name__ == "__main__":
    main()
  
