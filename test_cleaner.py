import io
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

import cleaner


class CleanerTest(unittest.TestCase):
    def test_preview_defaults_and_explicit_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "xwechat"
            defaults = (
                "log/radium/old.xlog",
                "radium/web/profiles/profile/Cache/Cache_Data/entry",
                "radium/users/account/applet/codecache/entry",
            )
            optional = (
                "radium/users/account/applet/packages/app.wxapkg",
                "XPlugin/Plugins/Example/1/plugin.dll",
            )
            keep = (
                "log/mm.mmap3",
                "radium/cache/main.mmap",
                "radium/web/profiles/profile/Local Storage/entry",
                "radium/users/account/applet/local/entry",
                "XPlugin/info/metadata",
                "login/account",
            )
            for name in defaults + optional + keep:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"sample")

            external = Path(temp) / "other" / "outside.xlog"
            external.parent.mkdir()
            external.write_bytes(b"keep")
            try:
                os.link(external, root / "log/linked.xlog")
            except OSError:
                pass
            else:
                keep += ("log/linked.xlog",)

            if os.name == "nt":
                import _winapi

                junction = root / "log" / "junction"
                _winapi.CreateJunction(str(external.parent), str(junction))
                keep += ("log/junction/outside.xlog",)

            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()), patch.object(
                cleaner, "wechat_running", return_value=True
            ):
                self.assertEqual(cleaner.main([], root), 0)
                self.assertEqual(cleaner.main(["--apply"], root), 1)
            self.assertTrue(all((root / name).is_file() for name in defaults + optional + keep))

            with redirect_stdout(io.StringIO()), patch.object(
                cleaner, "wechat_running", return_value=False
            ):
                self.assertEqual(cleaner.main(["--apply"], root), 0)
                self.assertTrue(all((root / name).is_file() for name in optional + keep))
                self.assertFalse(any((root / name).exists() for name in defaults))
                self.assertEqual(cleaner.main(["--apply", "--packages", "--plugins"], root), 0)
                self.assertEqual(cleaner.main(["--apply", "--packages", "--plugins"], root), 0)
            self.assertFalse(any((root / name).exists() for name in optional))
            self.assertTrue(all((root / name).is_file() for name in keep))
            self.assertEqual(external.read_bytes(), b"keep")


if __name__ == "__main__":
    unittest.main()
