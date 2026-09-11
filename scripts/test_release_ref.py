from pathlib import Path
import os
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("verify-release-ref.sh").resolve()


class ReviewedRefTests(unittest.TestCase):
    def test_exact_reviewed_tag_and_unreviewed_branch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote, source = root / "remote.git", root / "source"

            def git(*args):
                return subprocess.run(["git", *args], cwd=source, text=True, capture_output=True, check=True)

            source.mkdir()
            git("init", "-b", "main")
            git("config", "user.email", "release-test@example.invalid")
            git("config", "user.name", "Release test")
            (source / "payload").write_text("reviewed")
            git("add", "payload")
            git("commit", "-m", "reviewed")
            subprocess.run(["git", "init", "--bare", str(remote)], capture_output=True, check=True)
            git("remote", "add", "origin", str(remote))
            git("push", "origin", "main")
            git("tag", "v1.0.0")

            def verify(tag):
                env = {**os.environ, "RELEASE_TAG": tag}
                env.pop("GITHUB_ENV", None)
                return subprocess.run(["bash", str(SCRIPT)], cwd=source, env=env, capture_output=True).returncode

            self.assertEqual(verify("v1.0.0"), 0)
            self.assertNotEqual(verify("main"), 0)
            git("checkout", "-b", "unreviewed")
            (source / "payload").write_text("unreviewed")
            git("commit", "-am", "not on main")
            self.assertNotEqual(verify("v1.0.0"), 0)
            git("tag", "v2.0.0")
            self.assertNotEqual(verify("v2.0.0"), 0)


if __name__ == "__main__":
    unittest.main()
