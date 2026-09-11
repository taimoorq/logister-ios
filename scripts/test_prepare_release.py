import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("prepare-release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseRecoveryTests(unittest.TestCase):
    def simulate(self, *, tag_status=2, release_status=404, diff=0, stale=False, dispatch_error=False, advance=False):
        self.calls = []
        fetches = 0

        def run(*args, check=True):
            nonlocal fetches
            self.calls.append(args)
            output, error, code = "", "", 0
            if args[:3] == ("git", "fetch", "--no-tags"):
                fetches += 1
            if args[:2] == ("git", "rev-parse"):
                output = "other" if args[-1] != "HEAD" and (stale or advance and fetches > 1) else "candidate"
            if args[:2] == ("git", "ls-remote"):
                code = tag_status
            if args[:2] == ("git", "diff"):
                code = diff
            if args[:2] == ("gh", "api"):
                if release_status == 200:
                    output = '{"tag_name":"v1.2.3","draft":false}'
                else:
                    code, error = 1, f"gh: lookup failed (HTTP {release_status})"
            if args[:3] == ("gh", "workflow", "run") and dispatch_error:
                raise RuntimeError("dispatch failed")
            return SimpleNamespace(returncode=code, stdout=output, stderr=error)

        return release.prepare("v1.2.3", "release.yml", ["src", "package.json", "package-lock.json"], "candidate", "owner/repo", run)

    def dispatched(self):
        return any(call[:3] == ("gh", "workflow", "run") for call in self.calls)

    def tagged(self):
        return any(call[:2] == ("git", "tag") for call in self.calls)

    def test_new_tag_dispatches_explicitly_from_main(self):
        self.assertIn("still required", self.simulate())
        self.assertTrue(self.tagged())
        self.assertIn(("gh", "workflow", "run", "release.yml", "--repo", "owner/repo", "--ref", "main", "-f", "tag=v1.2.3"), self.calls)

    def test_tag_without_release_recovers_without_retagging(self):
        self.simulate(tag_status=0)
        self.assertFalse(self.tagged())
        self.assertTrue(self.dispatched())

    def test_completed_release_is_not_republished(self):
        self.simulate(tag_status=0, release_status=200)
        self.assertFalse(self.dispatched())

    def test_changed_publishable_inputs_require_new_version(self):
        with self.assertRaisesRegex(RuntimeError, "bump the version"):
            self.simulate(tag_status=0, diff=1)
        self.assertFalse(self.dispatched())

    def test_provider_failures_do_not_mean_absent(self):
        for options in ({"tag_status": 128}, {"tag_status": 0, "release_status": 503}, {"tag_status": 0, "release_status": 401}):
            with self.subTest(options=options), self.assertRaisesRegex(RuntimeError, "state is unknown"):
                self.simulate(**options)
            self.assertFalse(self.tagged())
            self.assertFalse(self.dispatched())

    def test_stale_ci_and_main_advancement_never_tag(self):
        for options in ({"stale": True}, {"advance": True}):
            self.assertIn("Skipping stale", self.simulate(**options))
            self.assertFalse(self.tagged())

    def test_dispatch_failure_leaves_immutable_tag_for_recovery(self):
        with self.assertRaisesRegex(RuntimeError, "dispatch failed"):
            self.simulate(dispatch_error=True)
        self.assertTrue(self.tagged())
        self.assertFalse(any("--delete" in call or "--force" in call for call in self.calls))


if __name__ == "__main__":
    unittest.main()
