import json
import sys
import tempfile
import types
import unittest
from pathlib import Path

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


def _write_config(path: Path, clients):
    data = {
        "inbounds": [
            {
                "tag": "inbound-dragoncore",
                "settings": {"clients": clients},
            }
        ]
    }
    path.write_text(json.dumps(data), encoding="utf-8")


class BotXrayCoreTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        base = Path(self.temp_dir.name)
        self.config_path = base / "config.json"
        self.user_db = base / "users.db"
        _write_config(self.config_path, [])
        self.user_db.write_text("", encoding="utf-8")

        botxray.CONFIG_PATH = str(self.config_path)
        botxray.USER_DB = str(self.user_db)
        botxray.restart_xray = lambda: None

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_create_and_list_user(self):
        ok, msg = botxray.core_create_user("tester", "10")
        self.assertTrue(ok)
        self.assertIn("Usuário Criado", msg)

        report = botxray.core_list_users_text()
        self.assertIn("LISTA DE USUÁRIOS", report)
        self.assertIn("tester", report)

    def test_block_and_unblock_user(self):
        ok, _ = botxray.core_create_user("blockme", "5")
        self.assertTrue(ok)

        blocked_msg = botxray.core_block_user("blockme")
        self.assertIn("SUSPENSO", blocked_msg)

        unblocked_msg = botxray.core_unblock_user("blockme")
        self.assertIn("REATIVADO", unblocked_msg)

    def test_delete_user_not_found(self):
        result = botxray.core_delete_user("missing")
        self.assertIn("não encontrado", result)


if __name__ == "__main__":
    unittest.main()
