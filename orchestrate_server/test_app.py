import base64
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import app


class DashboardTests(unittest.TestCase):
    def setUp(self) -> None:
        app.app.config["TESTING"] = True
        self.client = app.app.test_client()
        self.explorer_root = tempfile.TemporaryDirectory()
        self.original_explorer_root = app.app.config["FILE_EXPLORER_ROOT"]
        app.app.config["FILE_EXPLORER_ROOT"] = self.explorer_root.name

    def tearDown(self) -> None:
        app.app.config["FILE_EXPLORER_ROOT"] = self.original_explorer_root
        self.explorer_root.cleanup()

    def test_home_page_uses_vue_with_read_only_terminal_and_file_explorer(self) -> None:
        response = self.client.get("/")

        self.assertEqual(response.status_code, 200)
        self.assertIn(b"disableStdin: true", response.data)
        self.assertIn(b"/api/terminal", response.data)
        self.assertIn(b"vue@3.5.13", response.data)
        self.assertIn(b"File explorer", response.data)
        self.assertIn(
            b"grid-template-rows: repeat(2, minmax(350px, 1fr));",
            response.data,
        )

    def test_file_api_lists_directory_entries_without_opening_contents(self) -> None:
        root = Path(self.explorer_root.name)
        (root / "folder").mkdir()
        (root / "example.txt").write_text("contents are not returned")

        response = self.client.get(f"/api/files?path={root}")

        self.assertEqual(response.status_code, 200)
        result = response.get_json()
        self.assertEqual([entry["name"] for entry in result["entries"]], ["folder", "example.txt"])
        self.assertEqual([entry["type"] for entry in result["entries"]], ["directory", "file"])
        self.assertNotIn("contents", response.get_data(as_text=True))

    def test_file_api_rejects_paths_outside_configured_root(self) -> None:
        response = self.client.get("/api/files?path=/etc")

        self.assertEqual(response.status_code, 403)
        self.assertIn(b"outside the explorer root", response.data)

    def test_file_api_reports_unreadable_directory(self) -> None:
        with patch("app.os.scandir", side_effect=PermissionError):
            response = self.client.get(f"/api/files?path={self.explorer_root.name}")

        self.assertEqual(response.status_code, 403)
        self.assertIn(b"Permission denied", response.data)

    def test_terminal_stream_contains_btop_ansi_output(self) -> None:
        response = self.client.get("/api/terminal?cols=120&rows=36", buffered=False)
        try:
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.mimetype, "text/event-stream")

            for chunk in response.response:
                if chunk.startswith(b"data: "):
                    output = base64.b64decode(chunk[6:].splitlines()[0])
                    self.assertIn(b"\x1b[", output)
                    break
            else:
                self.fail("btop stream closed before sending terminal output.")
        finally:
            response.close()

    def test_invalid_terminal_dimensions_are_rejected(self) -> None:
        response = self.client.get("/api/terminal?cols=999&rows=36")

        self.assertEqual(response.status_code, 400)
        self.assertIn(b"cols must be between", response.data)

    @patch("app.shutil.which", return_value=None)
    def test_missing_btop_returns_a_service_error(self, _which: object) -> None:
        response = self.client.get("/api/terminal")

        self.assertEqual(response.status_code, 503)
        self.assertIn(b"btop is not installed", response.data)


if __name__ == "__main__":
    unittest.main()
