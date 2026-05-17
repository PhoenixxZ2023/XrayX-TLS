import os
import json
import uuid
import logging
import subprocess
import re
from datetime import datetime, timedelta

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application, CommandHandler, ContextTypes, ConversationHandler,
    MessageHandler, filters, CallbackQueryHandler
)
import io

# --- CONFIGURAÇÃO (SERÁ SUBSTITUÍDA PELO INSTALADOR) ---
BOT_TOKEN = "SEU_TOKEN_AQUI"
ADMIN_ID = 123456789

CONFIG_PATH = "/usr/local/etc/xray/config.json"
USER_DB = "/opt/XrayTools/users.db"
XRAY_SERVICE = "xray"

# Scripts chamados via sudo (NOPASSWD em /etc/sudoers.d/botxray)
SCRIPTS = {
    "create": "/usr/local/bin/add_user.sh",
    "delete": "/usr/local/bin/remover_user.sh",
    "block":  "/usr/local/bin/block_user.sh",
    "unblock":"/usr/local/bin/unblock_user.sh",
    "backup": "/usr/local/bin/backup_bot.sh",
    "restore": "/usr/local/bin/restore_bot.sh",
}

# Limites do RESTORE (segurança)
MAX_RESTORE_MB = 50  # ajuste se precisar (50MB)
ALLOWED_EXT = (".tar.gz",)

logging.basicConfig(format='%(asctime)s - %(name)s - %(levelname)s - %(message)s', level=logging.INFO)
logger = logging.getLogger(__name__)

(
    SELECTING_ACTION,
    GET_USERNAME_CREATE,
    GET_EXPIRY_DAYS_CREATE,
    GET_USER_TO_DELETE,
    GET_USER_TO_BLOCK,
    GET_USER_TO_UNBLOCK,
    WAIT_RESTORE_FILE
) = range(7)

# --- FUNÇÕES DE SISTEMA (leitura apenas) ---

def load_config():
    if not os.path.exists(CONFIG_PATH):
        return None
    with open(CONFIG_PATH, 'r', encoding='utf-8', errors='ignore') as f:
        return json.load(f)

def get_ip():
    try:
        return subprocess.check_output(["curl", "-s", "ifconfig.me"], timeout=5).decode().strip()
    except Exception:
        return "127.0.0.1"

# --- EXECUÇÃO DE SCRIPTS VIA SUDO ---

def run_script(path: str, input_text: str = "", timeout: int = 180) -> tuple[int, str]:
    """
    Executa script via sudo (sem senha) com stdin controlado.
    Retorna (exit_code, stdout+stderr).
    """
    try:
        p = subprocess.run(
            ["sudo", "-n", "bash", path],
            input=input_text.encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=timeout
        )
        out = p.stdout.decode("utf-8", errors="ignore")
        return p.returncode, out
    except subprocess.TimeoutExpired:
        return 124, "⏱️ Timeout executando o script."
    except Exception as e:
        return 1, f"Erro ao executar script: {e}"

def run_script_args(path: str, args: list[str], timeout: int = 300) -> tuple[int, str]:
    """
    Executa script via sudo com args (sem stdin).
    """
    try:
        p = subprocess.run(
            ["sudo", "-n", "bash", path] + args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=timeout
        )
        out = p.stdout.decode("utf-8", errors="ignore")
        return p.returncode, out
    except subprocess.TimeoutExpired:
        return 124, "⏱️ Timeout executando o script."
    except Exception as e:
        return 1, f"Erro ao executar script: {e}"

# --- GERADOR DE LINKS (baseado no config atual) ---

def generate_link(client_uuid: str | None, client_email: str) -> str:
    try:
        data = load_config()
        if not data:
            return "Erro ao ler config."

        inbound = next((i for i in data.get('inbounds', []) if i.get('tag') == 'inbound-dragoncore'), None)
        if not inbound:
            return "Erro: inbound-dragoncore não encontrado."

        port = inbound.get('port')
        stream = inbound.get('streamSettings', {})
        network = stream.get('network', 'tcp')
        security = stream.get('security', 'none')

        host = ""
        sni = ""

        if security == 'tls':
            tls = stream.get('tlsSettings', {})
            sni = tls.get('serverName', "") or ""
            host = sni

        if not host:
            host = get_ip()
            sni = ""

        # Se UUID não foi fornecido, tenta extrair do config por email
        if not client_uuid:
            clients = inbound.get('settings', {}).get('clients', [])
            for c in clients:
                if c.get('email') == client_email:
                    client_uuid = c.get('id')
                    break
        if not client_uuid:
            return "UUID não encontrado para gerar link."

        link = ""
        if network == "tcp":
            settings = inbound.get('settings', {})
            flow = settings.get('flow', "")
            if flow == "xtls-rprx-vision":
                link = f"vless://{client_uuid}@{host}:{port}?security=tls&encryption=none&type=tcp&headerType=none&flow={flow}&sni={sni}#{client_email}"
            else:
                sec_param = "security=tls" if security == "tls" else "security=none"
                link = f"vless://{client_uuid}@{host}:{port}?{sec_param}&encryption=none&type=tcp&headerType=none&sni={sni}#{client_email}"

        elif network == "ws":
            ws = stream.get('wsSettings', {})
            path = ws.get('path', '/')
            sec_param = "security=tls" if security == "tls" else "security=none"
            ws_host = sni if sni else host
            link = f"vless://{client_uuid}@{host}:{port}?{sec_param}&encryption=none&type=ws&host={ws_host}&path={path}&sni={sni}#{client_email}"

        elif network == "grpc":
            grpc = stream.get('grpcSettings', {})
            service = grpc.get('serviceName', 'gRPC')
            sec_param = "security=tls" if security == "tls" else "security=none"
            link = f"vless://{client_uuid}@{host}:{port}?{sec_param}&encryption=none&type=grpc&serviceName={service}&sni={sni}#{client_email}"

        elif network == "xhttp":
            xh = stream.get('xhttpSettings', {})
            path = xh.get('path', '/')
            sec_param = "security=tls" if security == "tls" else "security=none"
            link = f"vless://{client_uuid}@{host}:{port}?mode=auto&{sec_param}&encryption=none&type=xhttp&host={host}&path={path}&sni={sni}#{client_email}"

        else:
            sec_param = "security=tls" if security == "tls" else "security=none"
            link = f"vless://{client_uuid}@{host}:{port}?{sec_param}&encryption=none&type={network}&sni={sni}#{client_email}"

        return link

    except Exception as e:
        return f"Erro Link: {str(e)}"

# --- FUNÇÕES CORE (via scripts) ---

def read_uuid_from_db(nick: str) -> str | None:
    try:
        if not os.path.exists(USER_DB):
            return None
        with open(USER_DB, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.startswith(f"{nick}|"):
                    parts = line.strip().split("|")
                    if len(parts) >= 2:
                        return parts[1]
        return None
    except Exception:
        return None

def core_create_user(nick, days):
    # add_user.sh: Nome -> Dias -> Enter
    code, out = run_script(SCRIPTS["create"], f"{nick}\n{days}\n\n", timeout=120)
    if code == 0:
        user_uuid = read_uuid_from_db(nick)
        link = generate_link(user_uuid, nick)
        expiry = (datetime.now() + timedelta(days=int(days))).strftime('%Y-%m-%d')
        return True, f"✅ *Usuário Criado!*\n\n👤 `{nick}`\n📅 `{expiry}`\n\n🔗 *Link VLESS:*\n`{link}`"
    return False, f"❌ Falha ao criar usuário.\n\n```\n{out[-1500:]}\n```"

def core_delete_user(nick):
    code, out = run_script(SCRIPTS["delete"], f"{nick}\n", timeout=60)
    if code == 0:
        return f"✅ Usuário removido.\n\n```\n{out[-1200:]}\n```"
    return f"❌ Falha ao remover.\n\n```\n{out[-1200:]}\n```"

def core_block_user(nick):
    code, out = run_script(SCRIPTS["block"], f"{nick}\n", timeout=60)
    if code == 0:
        return f"⛔ Usuário `{nick}` SUSPENSO.\n\n```\n{out[-1200:]}\n```"
    return f"❌ Falha ao suspender.\n\n```\n{out[-1200:]}\n```"

def core_unblock_user(nick):
    code, out = run_script(SCRIPTS["unblock"], f"{nick}\n", timeout=60)
    if code == 0:
        return f"✅ Usuário `{nick}` REATIVADO.\n\n```\n{out[-1200:]}\n```"
    return f"❌ Falha ao reativar.\n\n```\n{out[-1200:]}\n```"

def core_list_users_text():
    if not os.path.exists(USER_DB):
        return "Nenhum usuário cadastrado."

    locked_users = set()
    data = load_config()
    if data:
        inbounds = data.get('inbounds', [])
        target = next((i for i in inbounds if i.get('tag') == 'inbound-dragoncore'), None)
        if target:
            for c in target.get('settings', {}).get('clients', []):
                email = c.get('email', '')
                if isinstance(email, str) and email.startswith("LOCKED_"):
                    locked_users.add(email.replace("LOCKED_", ""))

    msg = "LISTA DE USUÁRIOS - DRAGONCORE\n"
    msg += "=================================================================================\n"
    msg += "NOME            | VENCIMENTO  | UUID                                     | STATUS\n"
    msg += "=================================================================================\n"

    with open(USER_DB, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            parts = line.strip().split('|')
            if len(parts) >= 3:
                nick = parts[0]
                uuid_real = parts[1]
                expiry = parts[2]
                status = "⛔️" if nick in locked_users else "✅"
                msg += f"{nick:<15} | {expiry:<11} | {uuid_real:<36} | {status}\n"
    return msg

# --- FUNÇÕES DO TELEGRAM ---

def is_admin(update: Update) -> bool:
    return update.effective_user and update.effective_user.id == ADMIN_ID

def build_menu():
    keyboard = [
        [InlineKeyboardButton("👤 CRIAR", callback_data='create_start'),
         InlineKeyboardButton("🗑️ REMOVER", callback_data='delete_start')],
        [InlineKeyboardButton("⛔ SUSPENDER", callback_data='block_start'),
         InlineKeyboardButton("✅ REATIVAR", callback_data='unblock_start')],
        [InlineKeyboardButton("📋 LISTAR (TXT)", callback_data='list_users'),
         InlineKeyboardButton("📥 BACKUP", callback_data='backup_start')],
        [InlineKeyboardButton("♻️ RESTORE", callback_data='restore_start'),
         InlineKeyboardButton("❌ SAIR", callback_data='cancel')]
    ]
    return InlineKeyboardMarkup(keyboard)

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return
    context.user_data.clear()
    await update.message.reply_text("🐉 *PAINEL DRAGONCORE V7.8*", reply_markup=build_menu(), parse_mode='Markdown')
    return SELECTING_ACTION

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return

    query = update.callback_query
    await query.answer()

    if query.data == 'close_file':
        try:
            await query.message.delete()
        except Exception:
            pass
        return SELECTING_ACTION

    if query.data == 'cancel':
        await query.edit_message_text("Painel Fechado.", reply_markup=None)
        return ConversationHandler.END

    if query.data == 'create_start':
        await query.edit_message_text("Nome do usuário (5-9 letras/num):", parse_mode='Markdown')
        return GET_USERNAME_CREATE
    elif query.data == 'delete_start':
        await query.edit_message_text("Nome para remover:", parse_mode='Markdown')
        return GET_USER_TO_DELETE
    elif query.data == 'block_start':
        await query.edit_message_text("Nome para ⛔ SUSPENDER:", parse_mode='Markdown')
        return GET_USER_TO_BLOCK
    elif query.data == 'unblock_start':
        await query.edit_message_text("Nome para ✅ REATIVAR:", parse_mode='Markdown')
        return GET_USER_TO_UNBLOCK

    elif query.data == 'list_users':
        report = core_list_users_text()
        f = io.BytesIO(report.encode('utf-8'))
        f.name = "usuarios.txt"

        close_btn = InlineKeyboardMarkup([[InlineKeyboardButton("🗑 Fechar Lista", callback_data='close_file')]])
        await context.bot.send_document(
            chat_id=update.effective_chat.id,
            document=f,
            caption="📂 *Lista gerada*",
            parse_mode='Markdown',
            reply_markup=close_btn
        )

        await query.edit_message_text(
            "✅ *Lista enviada abaixo!*\nVerifique o arquivo ou escolha outra opção:",
            parse_mode='Markdown',
            reply_markup=build_menu()
        )
        return SELECTING_ACTION

    elif query.data == 'backup_start':
        await query.edit_message_text("📦 Gerando Backup...", parse_mode='Markdown')

        code, out = run_script(SCRIPTS["backup"], "", timeout=180)
        if code != 0:
            await query.edit_message_text(
                f"❌ Falha ao criar backup.\n\n```\n{out[-1200:]}\n```",
                reply_markup=build_menu(),
                parse_mode='Markdown'
            )
            return SELECTING_ACTION

        bkp_file = out.strip().splitlines()[-1].strip()
        if not os.path.exists(bkp_file):
            await query.edit_message_text("❌ Backup não encontrado após criação.", reply_markup=build_menu())
            return SELECTING_ACTION

        close_btn = InlineKeyboardMarkup([[InlineKeyboardButton("🗑 Fechar Backup", callback_data='close_file')]])
        with open(bkp_file, 'rb') as fobj:
            await context.bot.send_document(
                chat_id=update.effective_chat.id,
                document=fobj,
                filename=os.path.basename(bkp_file),
                caption="🔐 *Backup do Sistema* (inclui SSL)",
                parse_mode='Markdown',
                reply_markup=close_btn
            )

        try:
            os.remove(bkp_file)
        except Exception:
            pass

        await query.edit_message_text("✅ *Backup enviado abaixo!*", parse_mode='Markdown', reply_markup=build_menu())
        return SELECTING_ACTION

    elif query.data == 'restore_start':
        warn = (
            "♻️ *RESTORE*\n\n"
            "Envie agora o arquivo `backup_dragoncore_XXXX.tar.gz`.\n"
            f"• Somente `.tar.gz`\n"
            f"• Máx: {MAX_RESTORE_MB} MB\n\n"
            "_Atenção: isso vai restaurar config/usuários/SSL e reiniciar serviços._"
        )
        await query.edit_message_text(warn, parse_mode='Markdown')
        return WAIT_RESTORE_FILE

    await query.edit_message_text("OK.", reply_markup=build_menu())
    return SELECTING_ACTION

async def unexpected_button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    return await button_handler(update, context)

async def restore_file_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """
    Recebe o arquivo .tar.gz enviado no Telegram e executa restore_bot.sh.
    """
    if not is_admin(update):
        return SELECTING_ACTION

    if not update.message:
        return WAIT_RESTORE_FILE

    doc = update.message.document
    if not doc:
        await update.message.reply_text("Envie um arquivo `.tar.gz` (backup).", reply_markup=build_menu())
        return SELECTING_ACTION

    filename = (doc.file_name or "").strip()
    if not filename.endswith(ALLOWED_EXT):
        await update.message.reply_text("❌ Arquivo inválido. Envie um `.tar.gz`.", reply_markup=build_menu())
        return SELECTING_ACTION

    if doc.file_size and doc.file_size > (MAX_RESTORE_MB * 1024 * 1024):
        await update.message.reply_text(f"❌ Arquivo muito grande (máx {MAX_RESTORE_MB}MB).", reply_markup=build_menu())
        return SELECTING_ACTION

    await update.message.reply_text("⬇️ Baixando backup...")

    tmp_path = f"/tmp/restore_{uuid.uuid4().hex}.tar.gz"
    try:
        tg_file = await doc.get_file()
        await tg_file.download_to_drive(custom_path=tmp_path)

        await update.message.reply_text("⚙️ Restaurando... (pode reiniciar o Xray e o bot)")

        code, out = run_script_args(SCRIPTS["restore"], [tmp_path], timeout=300)

        if code == 0 and "OK" in out:
            await update.message.reply_text("✅ RESTORE concluído com sucesso.", reply_markup=build_menu())
        else:
            await update.message.reply_text(
                f"❌ Falha no RESTORE.\n\n```\n{out[-1500:]}\n```",
                parse_mode='Markdown',
                reply_markup=build_menu()
            )

    except Exception as e:
        await update.message.reply_text(f"❌ Erro no RESTORE: {e}", reply_markup=build_menu())
    finally:
        try:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)
        except Exception:
            pass

    return SELECTING_ACTION

async def input_handler(update: Update, context: ContextTypes.DEFAULT_TYPE, mode):
    if not is_admin(update):
        return
    if not update.message or not update.message.text:
        return

    text = update.message.text.strip().split()[0]

    if mode == 'create_nick':
        if not re.match(r'^[a-zA-Z0-9]{5,9}$', text):
            await update.message.reply_text(
                "❌ *Nome Inválido!*\n\nRegras:\n• Entre 5 e 9 caracteres\n• Apenas letras e números\n\nTente outro:",
                parse_mode='Markdown'
            )
            return GET_USERNAME_CREATE

        context.user_data['nick'] = text
        await update.message.reply_text(f"Validade (dias) para `{text}`:", parse_mode='Markdown')
        return GET_EXPIRY_DAYS_CREATE

    elif mode == 'create_days':
        if not text.isdigit():
            await update.message.reply_text("Só números.")
            return GET_EXPIRY_DAYS_CREATE
        res, msg = core_create_user(context.user_data['nick'], text)
        await update.message.reply_text(msg, parse_mode='Markdown', reply_markup=build_menu())
        return SELECTING_ACTION

    elif mode == 'delete':
        msg = core_delete_user(text)
        await update.message.reply_text(msg, reply_markup=build_menu())
        return SELECTING_ACTION

    elif mode == 'block':
        msg = core_block_user(text)
        await update.message.reply_text(msg, parse_mode='Markdown', reply_markup=build_menu())
        return SELECTING_ACTION

    elif mode == 'unblock':
        msg = core_unblock_user(text)
        await update.message.reply_text(msg, parse_mode='Markdown', reply_markup=build_menu())
        return SELECTING_ACTION

# Wrappers
async def h_create_nick(u, c): return await input_handler(u, c, 'create_nick')
async def h_create_days(u, c): return await input_handler(u, c, 'create_days')
async def h_delete(u, c): return await input_handler(u, c, 'delete')
async def h_block(u, c): return await input_handler(u, c, 'block')
async def h_unblock(u, c): return await input_handler(u, c, 'unblock')

async def cancel_op(u, c):
    if u.message:
        await u.message.reply_text("Cancelado.", reply_markup=build_menu())
    return SELECTING_ACTION

def main():
    app = Application.builder().token(BOT_TOKEN).build()

    conv = ConversationHandler(
        entry_points=[CommandHandler('start', start), CommandHandler('menu', start)],
        states={
            SELECTING_ACTION: [CallbackQueryHandler(button_handler)],

            GET_USERNAME_CREATE: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_create_nick),
                CallbackQueryHandler(unexpected_button)
            ],
            GET_EXPIRY_DAYS_CREATE: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_create_days),
                CallbackQueryHandler(unexpected_button)
            ],
            GET_USER_TO_DELETE: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_delete),
                CallbackQueryHandler(unexpected_button)
            ],
            GET_USER_TO_BLOCK: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_block),
                CallbackQueryHandler(unexpected_button)
            ],
            GET_USER_TO_UNBLOCK: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_unblock),
                CallbackQueryHandler(unexpected_button)
            ],

            # RESTORE: aguarda documento
            WAIT_RESTORE_FILE: [
                MessageHandler(filters.Document.ALL, restore_file_handler),
                CallbackQueryHandler(unexpected_button),
                MessageHandler(filters.TEXT & ~filters.COMMAND, lambda u, c: u.message.reply_text("Envie um arquivo `.tar.gz`.", reply_markup=build_menu()))
            ],
        },
        fallbacks=[CommandHandler('cancel', cancel_op)],
        allow_reentry=True
    )

    app.add_handler(conv)
    print("Bot Iniciado...")
    app.run_polling()

if __name__ == '__main__':
    main()
