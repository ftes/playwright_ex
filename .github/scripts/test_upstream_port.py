from contextlib import chdir, nullcontext
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location("port", Path(__file__).with_name("upstream-port.py"))
port = importlib.util.module_from_spec(spec)
spec.loader.exec_module(port)


class PortTest(unittest.TestCase):
    def test_generated_final_patch_is_applied_to_a_clean_index(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, fresh, checked = (root / name for name in ("source", "fresh", "checked"))
            source.mkdir()
            checked.mkdir()
            with chdir(source):
                port.git("init", "--quiet")
                Path("DRIVER_VERSION").write_text("1.65.1\n")
                Path("NODE_VERSION").write_text("26.13.1\n")
                facade = Path("lib/playwright/api/context.ex")
                facade.parent.mkdir(parents=True)
                facade.write_text("# original generated facade\n")
                port.git("add", "-A")
                port.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                         "-c", "commit.gpgsign=false", "commit", "-m", "Draft checkpoint")
                facade.write_text("# regenerated from the edited example\n")
                port.git("add", str(facade))
                with self.assertRaisesRegex(ValueError, "Unexpected model"):
                    port.files("model")
                port.save_patch(checked, "final")
                tree = port.git("write-tree").decode().strip()
            port.git("clone", "--quiet", source, fresh)
            (checked / "body").write_text("Port details.")
            with chdir(fresh), patch.dict(os.environ, SEALED_TREE=tree):
                port.artifact(checked, {"body"}, {"patch"})
                self.assertEqual(port.apply(checked, "final"), {str(facade)})
                self.assertEqual(port.sealed_tree(), tree)
                self.assertEqual(facade.read_text(), "# original generated facade\n")
                with patch.dict(os.environ, SEALED_TREE="0" * 40):
                    with self.assertRaisesRegex(ValueError, "does not match"):
                        port.sealed_tree()

    def test_artifact_rejects_git_metadata_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory)
            (artifact / "body").write_text("Port details.")
            (artifact / ".git").write_text("gitdir: /somewhere")
            with self.assertRaisesRegex(ValueError, "Unexpected artifact"):
                port.artifact(artifact, {"body"}, {"patch"})
            (artifact / ".git").unlink()
            (artifact / "patch").symlink_to(artifact / "body")
            with self.assertRaisesRegex(ValueError, "Invalid artifact file"):
                port.artifact(artifact, {"body"}, {"patch"})

    def test_checkpoint_publishes_under_empty_lease_and_stays_draft(self):
        base, sha = "a" * 40, "b" * 40
        branch, title = "upstream/1.65.1", "Update to Playwright 1.65.1"
        pr = {"title": title, "draft": True, "state": "open", "body": port.PLACEHOLDER,
              "number": 7, "html_url": "https://example.invalid/7"}
        shared = Mock(BASE="main")
        shared.remote_head.side_effect = [None, base, sha, base, sha]
        shared.branch_prs.return_value = []
        shared.commit.return_value = sha
        shared.app_token.return_value = nullcontext("app")
        shared.api.return_value = pr
        with (patch.object(port, "artifact"), patch.object(port, "apply"), patch.object(port, "check_pins"),
              patch.object(port, "sealed_tree"), patch.dict(os.environ, GITHUB_OUTPUT=os.devnull)):
            port.checkpoint(shared, Path("prep"), base, branch, title, "marker", "1.65.1", "26.13.1")
        shared.push.assert_called_once_with(branch, "app", "")
        self.assertTrue(shared.api.call_args.kwargs["payload"]["draft"])

    def test_finish_does_not_publish_after_a_maintainer_changes_the_draft(self):
        base, sha = "a" * 40, "b" * 40
        shared = Mock(BASE="main")
        shared.remote_head.side_effect = [sha, base]
        shared.current.return_value = {"draft": True, "title": "Maintainer's title"}
        with tempfile.TemporaryDirectory() as directory:
            checked = Path(directory)
            (checked / "body").write_text("Port details.")
            shared.text.return_value = "Port details."
            with (patch.object(port, "apply", return_value={"lib/port.ex"}),
                  patch.object(port, "check_pins"), patch.object(port, "sealed_tree")):
                with self.assertRaisesRegex(ValueError, "no longer under automation"):
                    port.finish(shared, checked, base, "upstream/1.65.1", "Update to Playwright 1.65.1",
                                "marker", sha, 7, "1.65.1", "26.13.1")
        shared.app_token.assert_not_called()
        shared.push.assert_not_called()


if __name__ == "__main__":
    unittest.main()
