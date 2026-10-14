"""通过临时本地远端验证发布 hook，不联网、不运行原生 UI 测试。"""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


class ReleaseHookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="PastePal-release-hook-")
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.repo = base / "repo"
        self.repo.mkdir()
        self.env = dict(os.environ, RELEASE_HOOK_CALLS=str(base / "calls"))
        self.git("init", "-q", "--initial-branch=main")
        self.git("config", "user.name", "Release Hook Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        self.git("config", "core.hooksPath", str(Path(__file__).resolve().parents[2] / ".githooks"))
        self.git("init", "-q", "--bare", str(base / "remote.git"))
        self.git("remote", "add", "origin", str(base / "remote.git"))
        (self.repo / "resources").mkdir()
        (self.repo / "resources/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.1.1"}))
        (self.repo / "scripts").mkdir()
        (self.repo / "scripts/verify-docs.py").write_text("import os, sys\nsys.exit(int(os.environ.get('DOCS_EXIT', '0')))\n")
        runner = self.repo / "scripts/swift-env.sh"
        runner.write_text('''#!/bin/bash
set -eu
[[ "$*" == 'test -c release' ]]
echo "$*" >> "$RELEASE_HOOK_CALLS"
if [[ "${CHANGE_SOURCE:-0}" == 1 ]]; then echo changed >> scripts/verify-docs.py; fi
exit "${TEST_EXIT:-0}"
''')
        runner.chmod(0o755)
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def git(self, *args, check=True):
        return subprocess.run(["git", *args], cwd=self.repo, env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)

    def push_tag(self, tag="v0.1.1", *, success):
        result = self.git("push", "origin", f"refs/tags/{tag}", check=False)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        remote = self.git("ls-remote", "origin", f"refs/tags/{tag}").stdout
        self.assertEqual(bool(remote.strip()), success)

    def test_annotated_and_lightweight_tags_run_release_gate(self):
        self.git("tag", "-a", "v0.1.1", "-m", "release")
        self.push_tag(success=True)
        self.git("push", "origin", ":refs/tags/v0.1.1")
        self.git("tag", "-d", "v0.1.1")
        self.git("tag", "v0.1.1")
        self.push_tag(success=True)
        self.assertEqual(Path(self.env["RELEASE_HOOK_CALLS"]).read_text().splitlines(),
                         ["test -c release", "test -c release"])

    def test_test_or_document_failure_blocks_remote_tag(self):
        self.git("tag", "v0.1.1")
        for key in ("TEST_EXIT", "DOCS_EXIT"):
            with self.subTest(key=key):
                self.env[key] = "1"
                self.push_tag(success=False)
                del self.env[key]

    def test_wrong_version_and_malformed_tag_are_blocked(self):
        for tag in ("v0.1.2", "v0.1"):
            with self.subTest(tag=tag):
                self.git("tag", tag)
                self.push_tag(tag, success=False)

    def test_wrong_checkout_and_dirty_source_are_blocked(self):
        self.git("tag", "v0.1.1")
        (self.repo / "new-source").write_text("source")
        self.push_tag(success=False)
        self.git("add", ".")
        self.push_tag(success=False)
        self.git("commit", "-qm", "next commit")
        self.push_tag(success=False)

    def test_source_changes_during_tests_are_blocked(self):
        self.git("tag", "v0.1.1")
        self.env["CHANGE_SOURCE"] = "1"
        self.push_tag(success=False)

    def test_branch_and_non_release_tag_pushes_skip_tests(self):
        self.env["TEST_EXIT"] = "1"
        self.git("push", "origin", "main")
        self.git("tag", "checkpoint")
        self.push_tag("checkpoint", success=True)
        self.assertFalse(Path(self.env["RELEASE_HOOK_CALLS"]).exists())

    def test_test_entrypoints_keep_desktop_tests_opt_in(self):
        source = Path(__file__).resolve().parents[2] / "scripts/swift-env.sh"
        runner = self.repo / "scripts/swift-env.sh"
        runner.write_text(source.read_text())
        (self.repo / "scripts/prepare-dependencies.py").write_text("")
        binary = Path(self.temp.name) / "bin"
        binary.mkdir()
        swift = binary / "swift"
        swift.write_text('#!/bin/bash\n[[ "$SDKROOT" != "/wrong-inherited-sdk" ]] || exit 1\nprintf "%s\\n" "$*" >> "$RELEASE_HOOK_CALLS"\n')
        swift.chmod(0o755)
        self.env["PATH"] = str(binary) + os.pathsep + self.env["PATH"]
        self.env["SDKROOT"] = "/wrong-inherited-sdk"
        for mode, excluded in (("test", "/testDesktop"), ("test-desktop", "/test(?!Desktop)")):
            with self.subTest(mode=mode):
                subprocess.run([str(runner), mode, "-c", "release", "--filter", "ImagePreviewTests"],
                               cwd=self.repo, env=self.env, check=True)
                calls = Path(self.env["RELEASE_HOOK_CALLS"]).read_text().splitlines()
                self.assertEqual(calls[-2:], ["package resolve", f"test --skip {excluded} -c release --filter ImagePreviewTests"])


if __name__ == "__main__":
    unittest.main()
