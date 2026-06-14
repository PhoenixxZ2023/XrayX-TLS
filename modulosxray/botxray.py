import os
import json
import uuid
import logging
import subprocess
import asyncio
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

logging.basicConfig(format='%(asctime)s - %(name)s - %(levelname)s - %(message)s', level=logging.INFO)
logger = logging.getLogger(__name__)

(SELECTING_ACTION, GET_USERNAME_CREATE, GET_EXPIRY_DAYS_CREATE, GET_USER_TO_DELETE, GET_USER_TO_BLOCK, GET_USER_TO_UNBLOCK) = range(6)

# --- FUNÇÕES DE SISTEMA ---

def restart_xray():
    subprocess.run(["systemctl", "restart", XRAY_SERVICE], check=False)

def load_config():
    if not os.path.exists(CONFIG_PATH): return None
    with open(CONFIG_PATH, 'r') as f:
        return json.load(f)

def save_config(data):
    with open(CONFIG_PATH, 'w') as f:
        json.dump(data, f, indent=2)

def get_ip():
    try:
        return subprocess.check_output("curl -s ifconfig.me", shell=True).decode().strip()
    except:
        return "127.0.0.1"

# --- GERADOR DE LINKS ---
def generate_link(client_uuid, client_email):
    try:
        data = load_config()
        if not data: return "Erro ao ler config."
        
        inbound = next((i for i in data['inbounds'] if i.get('tag') == 'inbound-dragoncore'), data['inbounds'][0])
        
        port = inbound['port']
        stream = inbound['streamSettings']
        network = stream['network']
        security = stream['security']
        
        host = ""
        sni = ""
        
        if security == 'tls':
            tls = stream.get('tlsSettings', {})
            sni = tls.get('serverName', "")
            host = sni
        
        if not host:
            host = get_ip()
            sni = "" 

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
            path = stream['wsSettings'].get('path', '/')
            sec_param = "security=tls" if security == "tls" else "security=none"
            ws_host = sni if sni else host
            link = f"vless://{client_uuid}@{host}:{port}?{sec_param}&encryption=none&type=ws&host={ws_host}&path={path}&sni={sni}#{client_email}"

        elif network == "grpc":
            service = stream['grpcSettings'].get('serviceName', 'gRPC')
            sec_param = "security=tls" if security == "tls" else "security=none"
            link = f"vless://{client_uuid}@{host}:{port}?{sec_param}&encryption=none&type=grpc&serviceName={service}&sni={sni}#{client_email}"

        elif network == "xhttp":
            path = stream['xhttpSettings'].get('path', '/')
            sec_param = "security=tls" if security == "tls" else "security=none"
            link = f"vless://{client_uuid}@{host}:{port}?mode=auto&{sec_param}&encryption=none&type=xhttp&host={host}&path={path}&sni={sni}#{client_email}"

        return link
    except Exception as e:
        return f"Erro Link: {str(e)}"

# --- FUNÇÕES CORE ---

def core_create_user(nick, days):
    if os.path.exists(USER_DB):
        with open(USER_DB, 'r') as f:
            if f"{nick}|" in f.read(): return False, "❌ Usuário já existe!"
    else:
        open(USER_DB, 'a').close()
    
    user_uuid = str(uuid.uuid4())
    expiry_date = (datetime.now() + timedelta(days=int(days))).strftime('%Y-%m-%d')
    data = load_config()
    
    if not data: return False, "❌ Erro ao ler config.json"

    inbounds = data.get('inbounds', [])
    target = next((i for i in inbounds if i.get('tag') == 'inbound-dragoncore'), None)
    
    if target:
        target['settings']['clients'].append({"id": user_uuid, "email": nick, "level": 0})
        save_config(data)
        
        with open(USER_DB, 'a') as f:
            f.write(f"{nick}|{user_uuid}|{expiry_date}\n")
        
        restart_xray()
        
        link = generate_link(user_uuid, nick)
        
        return True, f"✅ *Usuário Criado!*\n\n👤 `{nick}`\n📅 `{expiry_date}`\n\n🔗 *Link VLESS:*\n`{link}`"
    return False, "❌ Inbound não encontrado."

def core_delete_user(nick):
    data = load_config()
    found = False
    
    if data:
        inbounds = data.get('inbounds', [])
        for inbound in inbounds:
            if inbound.get('tag') == 'inbound-dragoncore':
                clients = inbound['settings']['clients']
                new_clients = [c for c in clients if c.get('email') != nick and c.get('email') != f"LOCKED_{nick}"]
                if len(clients) != len(new_clients): found = True
                inbound['settings']['clients'] = new_clients
        save_config(data)
    
    if os.path.exists(USER_DB):
        with open(USER_DB, 'r') as f: lines = f.readlines()
        with open(USER_DB, 'w') as f:
            for line in lines:
                if not line.startswith(f"{nick}|"):
                    f.write(line)
                else:
                    found = True

    if not found:
        return "❌ Usuário não encontrado no sistema."

    restart_xray()
    return "✅ Usuário removido do sistema."

def core_block_user(nick):
    data = load_config()
    if not data: return "❌ Erro config."

    found = False
    inbounds = data.get('inbounds', [])
    for inbound in inbounds:
        if inbound.get('tag') == 'inbound-dragoncore':
            for client in inbound['settings']['clients']:
                if client.get('email') == f"LOCKED_{nick}":
                    return "⚠️ Usuário já está bloqueado."
                if client.get('email') == nick:
                    client['email'] = f"LOCKED_{nick}"
                    client['id'] = str(uuid.uuid4())
                    found = True
                    break
    
    if found:
        save_config(data)
        restart_xray()
        return f"⛔ Usuário `{nick}` foi SUSPENSO."
    else:
        return "❌ Usuário não encontrado no Config."

def core_unblock_user(nick):
    real_uuid = None
    if os.path.exists(USER_DB):
        with open(USER_DB, 'r') as f:
            for line in f:
                if line.startswith(f"{nick}|"):
                    parts = line.strip().split('|')
                    real_uuid = parts[1]
                    break
    
    if not real_uuid: return "❌ Erro: UUID original não encontrado no Backup (DB)."

    data = load_config()
    found = False
    inbounds = data.get('inbounds', [])
    for inbound in inbounds:
        if inbound.get('tag') == 'inbound-dragoncore':
            for client in inbound['settings']['clients']:
                if client.get('email') == f"LOCKED_{nick}":
                    client['email'] = nick
                    client['id'] = real_uuid
                    found = True
                    break
    
    if found:
        save_config(data)
        restart_xray()
        return f"✅ Usuário `{nick}` REATIVADO com sucesso."
    else:
        return "❌ Usuário não estava bloqueado no sistema."

def core_list_users_text():
    if not os.path.exists(USER_DB): return "Nenhum usuário cadastrado."
    
    data = load_config()
    locked_users = []
    if data:
        inbounds = data.get('inbounds', [])
        target = next((i for i in inbounds if i.get('tag') == 'inbound-dragoncore'), None)
        if target:
            for c in target['settings']['clients']:
                email = c.get('email', '')
                if email.startswith("LOCKED_"):
                    locked_users.append(email.replace("LOCKED_", ""))

    msg = "LISTA DE USUÁRIOS - DRAGONCORE\n"
    msg += "=================================================================================\n"
    msg += "NOME            | VENCIMENTO  | UUID                                     | STATUS\n"
    msg += "=================================================================================\n"

    with open(USER_DB, 'r') as f:
        for line in f:
            parts = line.strip().split('|')
            if len(parts) >= 3:
                nick = parts[0]
                uuid_real = parts[1]
                expiry = parts[2]
                status = "✅"
                if nick in locked_users:
                    status = "⛔️"
                msg += f"{nick:<15} | {expiry:<11} | {uuid_real:<36} | {status}\n"
    return msg

# --- FUNÇÕES DO TELEGRAM ---

def is_admin(update: Update) -> bool:
    if update.effective_user.id != ADMIN_ID: return False
    return True

def build_menu():
    keyboard = [
        [InlineKeyboardButton("👤 CRIAR", callback_data='create_start'),
         InlineKeyboardButton("🗑️ REMOVER", callback_data='delete_start')],
        [InlineKeyboardButton("⛔ SUSPENDER", callback_data='block_start'),
         InlineKeyboardButton("✅ REATIVAR", callback_data='unblock_start')],
        [InlineKeyboardButton("📋 LISTAR (TXT)", callback_data='list_users'),
         InlineKeyboardButton("📥 BACKUP", callback_data='backup_start')],
        [InlineKeyboardButton("❌ SAIR", callback_data='cancel')]
    ]
    return InlineKeyboardMarkup(keyboard)

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update): return
    context.user_data.clear()
    await update.message.reply_text("🐉 *PAINEL DRAGONCORE V7.7*", reply_markup=build_menu(), parse_mode='Markdown')
    return SELECTING_ACTION

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update): return

    query = update.callback_query
    await query.answer()
    
    if query.data == 'close_file':
        await query.message.delete()
        return SELECTING_ACTION

    if query.data == 'cancel':
        await query.edit_message_text("Painel Fechado.", reply_markup=None); return ConversationHandler.END
    
    if query.data == 'create_start':
        await query.edit_message_text("Nome do usuário (5-9 letras/num):", parse_mode='Markdown'); return GET_USERNAME_CREATE
    elif query.data == 'delete_start':
        await query.edit_message_text("Nome para remover:", parse_mode='Markdown'); return GET_USER_TO_DELETE
    elif query.data == 'block_start':
        await query.edit_message_text("Nome para ⛔ SUSPENDER:", parse_mode='Markdown'); return GET_USER_TO_BLOCK
    elif query.data == 'unblock_start':
        await query.edit_message_text("Nome para ✅ REATIVAR:", parse_mode='Markdown'); return GET_USER_TO_UNBLOCK
    
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
        
        date_str = datetime.now().strftime('%Y%m%d_%H%M')
        bkp_file = f"/tmp/backup_{date_str}.tar.gz"
        subprocess.run(f"tar -czPf {bkp_file} /opt/XrayTools /usr/local/etc/xray", shell=True)
        
        if os.path.exists(bkp_file):
            with open(bkp_file, 'rb') as f:
                close_btn = InlineKeyboardMarkup([[InlineKeyboardButton("🗑 Fechar Backup", callback_data='close_file')]])
                await context.bot.send_document(
                    chat_id=update.effective_chat.id, 
                    document=f, 
                    filename=os.path.basename(bkp_file),
                    caption="🔐 *Backup do Sistema*",
                    parse_mode='Markdown',
                    reply_markup=close_btn
                )
            os.remove(bkp_file)
            await query.edit_message_text("✅ *Backup enviado abaixo!*", parse_mode='Markdown', reply_markup=build_menu())
        else:
            await query.edit_message_text("❌ Falha ao criar backup.", reply_markup=build_menu())
        return SELECTING_ACTION
    
    await query.edit_message_text("Reiniciando...", reply_markup=build_menu())
    return SELECTING_ACTION

async def unexpected_button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    return await button_handler(update, context)

async def input_handler(update: Update, context: ContextTypes.DEFAULT_TYPE, mode):
    if not is_admin(update): return
    if not update.message or not update.message.text: return
    text = update.message.text.strip().split()[0]

    if mode == 'create_nick':
        if not re.match(r'^[a-zA-Z0-9]{5,9}$', text):
            await update.message.reply_text(
                "❌ *Nome Inválido!*\n\nRegras:\n• Entre 5 e 9 caracteres\n• Apenas letras e números\n\nTente outro:",
                parse_mode='Markdown'
            )
            return GET_USERNAME_CREATE

        context.user_data['nick'] = text
        await update.message.reply_text(f"Validade (dias) para `{text}`:", parse_mode='Markdown'); return GET_EXPIRY_DAYS_CREATE

    elif mode == 'create_days':
        if not text.isdigit(): await update.message.reply_text("Só números."); return GET_EXPIRY_DAYS_CREATE
        res, msg = core_create_user(context.user_data['nick'], text)
        await update.message.reply_text(msg, parse_mode='Markdown', reply_markup=build_menu()); return SELECTING_ACTION
    elif mode == 'delete':
        msg = core_delete_user(text)
        await update.message.reply_text(msg, reply_markup=build_menu()); return SELECTING_ACTION
    elif mode == 'block':
        msg = core_block_user(text)
        await update.message.reply_text(msg, parse_mode='Markdown', reply_markup=build_menu()); return SELECTING_ACTION
    elif mode == 'unblock':
        msg = core_unblock_user(text)
        await update.message.reply_text(msg, parse_mode='Markdown', reply_markup=build_menu()); return SELECTING_ACTION

# Wrappers
async def h_create_nick(u, c): return await input_handler(u, c, 'create_nick')
async def h_create_days(u, c): return await input_handler(u, c, 'create_days')
async def h_delete(u, c): return await input_handler(u, c, 'delete')
async def h_block(u, c): return await input_handler(u, c, 'block')
async def h_unblock(u, c): return await input_handler(u, c, 'unblock')
async def cancel_op(u, c): await u.message.reply_text("Cancelado.", reply_markup=build_menu()); return SELECTING_ACTION

def main():
    app = Application.builder().token(BOT_TOKEN).build()
    
    txt_handler = MessageHandler(filters.TEXT & ~filters.COMMAND, None)

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
        },
        fallbacks=[CommandHandler('cancel', cancel_op)]
    )
    app.add_handler(conv)
    print("Bot Iniciado...")
    app.run_polling()

if __name__ == '__main__':
    main()
