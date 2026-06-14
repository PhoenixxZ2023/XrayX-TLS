import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from datetime import datetime

# -------------------------------
# STUBS para não depender do telegram na hora do import
# -------------------------------
telegram_stub = types.ModuleType("telegram")
telegram_stub.Update = object
telegram_stub.InlineKeyboardButton = object
telegram_stub.InlineKeyboardMarkup = object
sys.modules["telegram"] = telegram_stub

telegram_ext_stub = types.ModuleType("telegram.ext")
telegram_ext_stub.Application = object
telegram_ext_stub.CommandHandler = object
telegram_ext_stub.ContextTypes = types.SimpleNamespace(DEFAULT_TYPE=object)
telegram_ext_stub.ConversationHandler = object
telegram_ext_stub.MessageHandler = object
telegram_ext_stub.filters = types.SimpleNamespace(TEXT=object, COMMAND=object)
telegram_ext_stub.CallbackQueryHandler = object
sys.modules["telegram.ext"] = telegram_ext_stub

import botxray


def _write_config(path: Path, clients, *, network="xhttp", security="tls", port=443, server_name="example.com"):
    """
    Gera um config mínimo suficiente para o core + generate_link.
    """
    inbound = {
        "tag": "inbound-dragoncore",
        "port": port,
        "protocol": "vless",
        "settings": {"clients": clients, "decryption": "none"},
        "streamSettings": {
            "network": network,
            "security": security,
        },
    }

    # tls settings se tls
    if security == "tls":
        inbound["streamSettings"]["tlsSettings"] = {"serverName": server_name}

    # settings por rede (para o generate_link não quebrar)
    if network == "ws":
        inbound["streamSettings"]["wsSettings"] = {"path": "/"}
    elif network == "grpc":
        inbound["streamSettings"]["grpcSettings"] = {"serviceName": "gRPC"}
    elif network == "xhttp":
        inbound["streamSettings"]["xhttpSettings"] = {"path": "/"}

    data = {"inbounds": [inbound]}
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")


def _read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def _clients_from_config(path: Path):
    data = _read_json(path)
    inbound = next(i for i in data["inbounds"] if i.get("tag") == "inbound-dragoncore")
    return inbound["settings"]["clients"]


def _read_db_lines(db_path: Path):
    txt = db_path.read_text(encoding="utf-8").strip()
    if not txt:
        return []
    return [line.strip() for line in txt.splitlines() if line.strip()]


def _db_find_user(db_path: Path, nick: str):
    """
    Retorna (nick, uuid, expiry) ou None.
    """
    for line in _read_db_lines(db_path):
        parts = line.split("|")
        if len(parts) >= 3 and parts[0] == nick:
            return parts[0], parts[1], parts[2]
    return None


class BotXrayCoreTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        base = Path(self.temp_dir.name)

        self.config_path = base / "config.json"
        self.user_db = base / "users.db"

        # config padrão: xhttp + tls em 443
        _write_config(self.config_path, [], network="xhttp", security="tls", port=443, server_name="turbonet.example")
        self.user_db.write_text("", encoding="utf-8")

        # aponta o bot para os caminhos temporários
        botxray.CONFIG_PATH = str(self.config_path)
        botxray.USER_DB = str(self.user_db)

        # evita mexer no systemctl em testes
        botxray.restart_xray = lambda: None

        # evita depender de IP público real
        botxray.get_ip = lambda: "203.0.113.10"  # IP de documentação (RFC 5737)

    def tearDown(self):
        self.temp_dir.cleanup()

    # -------------------------------
    # CREATE + LIST (com validação de JSON/DB)
    # -------------------------------
    def test_create_user_updates_json_and_db(self):
        ok, msg = botxray.core_create_user("tester", "10")
        self.assertTrue(ok)
        self.assertIn("Usuário Criado", msg)

        # JSON: 1 client com email=tester
        clients = _clients_from_config(self.config_path)
        self.assertEqual(len(clients), 1)
        self.assertEqual(clients[0].get("email"), "tester")
        self.assertTrue(clients[0].get("id"))

        # DB: linha criada com expiry YYYY-MM-DD
        rec = _db_find_user(self.user_db, "tester")
        self.assertIsNotNone(rec)
        _, uuid_real, expiry = rec
        self.assertEqual(uuid_real, clients[0].get("id"))

        # valida formato da data
        datetime.strptime(expiry, "%Y-%m-%d")

        # LIST: aparece “tester”
        report = botxray.core_list_users_text()
        self.assertIn("LISTA DE USUÁRIOS", report)
        self.assertIn("tester", report)

    def test_create_user_duplicate_is_blocked_strict(self):
        ok1, _ = botxray.core_create_user("tester", "10")
        self.assertTrue(ok1)
        ok2, msg2 = botxray.core_create_user("tester", "10")
        self.assertFalse(ok2)
        self.assertIn("já existe", msg2.lower())

        # JSON não duplica
        clients = _clients_from_config(self.config_path)
        self.assertEqual(len(clients), 1)

    # -------------------------------
    # BLOCK / UNBLOCK (LOCKED_ + UUID scramble + restore UUID)
    # -------------------------------
    def test_block_scrambles_uuid_and_prefixes_locked(self):
        ok, _ = botxray.core_create_user("blockme", "5")
        self.assertTrue(ok)

        before = _clients_from_config(self.config_path)
        self.assertEqual(len(before), 1)
        real_uuid = before[0]["id"]

        blocked_msg = botxray.core_block_user("blockme")
        self.assertIn("SUSPENSO", blocked_msg)

        after = _clients_from_config(self.config_path)
        self.assertEqual(len(after), 1)
        self.assertEqual(after[0]["email"], "LOCKED_blockme")

        scrambled_uuid = after[0]["id"]
        self.assertNotEqual(scrambled_uuid, real_uuid)  # UUID mudou (scramble)

        # DB continua com UUID real
        rec = _db_find_user(self.user_db, "blockme")
        self.assertIsNotNone(rec)
        _, db_uuid, _ = rec
        self.assertEqual(db_uuid, real_uuid)

    def test_unblock_restores_original_uuid(self):
        ok, _ = botxray.core_create_user("blockme", "5")
        self.assertTrue(ok)

        real_uuid = _clients_from_config(self.config_path)[0]["id"]
        botxray.core_block_user("blockme")

        unblocked_msg = botxray.core_unblock_user("blockme")
        self.assertIn("REATIVADO", unblocked_msg)

        clients = _clients_from_config(self.config_path)
        self.assertEqual(len(clients), 1)
        self.assertEqual(clients[0]["email"], "blockme")
        self.assertEqual(clients[0]["id"], real_uuid)

    # -------------------------------
    # DELETE (remove do JSON + DB)
    # -------------------------------
    def test_delete_user_removes_from_json_and_db(self):
        ok, _ = botxray.core_create_user("deleteme", "3")
        self.assertTrue(ok)

        # sanity
        self.assertEqual(len(_clients_from_config(self.config_path)), 1)
        self.assertIsNotNone(_db_find_user(self.user_db, "deleteme"))

        msg = botxray.core_delete_user("deleteme")
        self.assertIn("removido", msg.lower())

        self.assertEqual(len(_clients_from_config(self.config_path)), 0)
        self.assertIsNone(_db_find_user(self.user_db, "deleteme"))

    def test_delete_user_not_found(self):
        result = botxray.core_delete_user("missing")
        self.assertIn("não encontrado", result.lower())

    # -------------------------------
    # GENERATE LINK (xhttp/ws/grpc/tcp/vision)
    # -------------------------------
    def _prepare_one_client(self, nick="tester", days="7"):
        ok, _ = botxray.core_create_user(nick, days)
        self.assertTrue(ok)
        clients = _clients_from_config(self.config_path)
        self.assertEqual(len(clients), 1)
        return clients[0]["id"], clients[0]["email"]

    def test_generate_link_xhttp_tls(self):
        # config xhttp tls
        _write_config(self.config_path, [], network="xhttp", security="tls", port=443, server_name="sni.example")
        uid, email = self._prepare_one_client("xhttpu", "5")

        link = botxray.generate_link(uid, email)
        self.assertTrue(link.startswith("vless://"))
        self.assertIn("type=xhttp", link)
        self.assertIn("security=tls", link)
        self.assertIn("sni=sni.example", link)

    def test_generate_link_ws_tls(self):
        _write_config(self.config_path, [], network="ws", security="tls", port=443, server_name="sni.example")
        uid, email = self._prepare_one_client("wsuser", "5")

        link = botxray.generate_link(uid, email)
        self.assertIn("type=ws", link)
        self.assertIn("security=tls", link)
        self.assertIn("path=/", link)
        self.assertIn("sni=sni.example", link)

    def test_generate_link_grpc_tls(self):
        _write_config(self.config_path, [], network="grpc", security="tls", port=443, server_name="sni.example")
        uid, email = self._prepare_one_client("grpcuser", "5")

        link = botxray.generate_link(uid, email)
        self.assertIn("type=grpc", link)
        self.assertIn("serviceName=gRPC", link)
        self.assertIn("security=tls", link)

    def test_generate_link_tcp_none(self):
        _write_config(self.config_path, [], network="tcp", security="none", port=80, server_name="")
        uid, email = self._prepare_one_client("tcpuser", "5")

        link = botxray.generate_link(uid, email)
        self.assertIn("type=tcp", link)
        self.assertIn("security=none", link)

    def test_generate_link_vision_flow(self):
        # vision = tcp + tls + flow no inbound.settings
        data = {
            "inbounds": [
                {
                    "tag": "inbound-dragoncore",
                    "port": 443,
                    "protocol": "vless",
                    "settings": {"clients": [], "decryption": "none", "flow": "xtls-rprx-vision"},
                    "streamSettings": {
                        "network": "tcp",
                        "security": "tls",
                        "tlsSettings": {"serverName": "sni.example"},
                    },
                }
            ]
        }
        self.config_path.write_text(json.dumps(data, indent=2), encoding="utf-8")

        uid, email = self._prepare_one_client("visionu", "5")
        link = botxray.generate_link(uid, email)
        self.assertIn("flow=xtls-rprx-vision", link)
        self.assertIn("security=tls", link)
        self.assertIn("type=tcp", link)

    # -------------------------------
    # BACKUP (opcional)
    # Se você criar uma função core no bot tipo:
    #   core_make_backup(dest_path) -> retorna caminho ou bytes
    # o teste roda. Se não existir, skip.
    # -------------------------------
    def test_backup_core_optional(self):
        if not hasattr(botxray, "core_make_backup"):
            self.skipTest("botxray.core_make_backup não existe (ok). Se quiser, eu adiciono no bot e ativo este teste.")

        # cria arquivos “fake” representando dirs reais
        # (o core_make_backup idealmente deve aceitar paths customizados ou usar os padrões)
        ok, _ = botxray.core_create_user("bkuser", "2")
        self.assertTrue(ok)

        out = Path(self.temp_dir.name) / "backup.tar.gz"
        result_path = botxray.core_make_backup(str(out))
        self.assertTrue(Path(result_path).exists())
        self.assertGreater(Path(result_path).stat().st_size, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
