import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from ci_changes import FLAGS, PLATFORMS, changed_paths, classify, outputs


class SelectionTests(unittest.TestCase):
    def selected(self, *paths):
        return {key for key, enabled in classify(paths).items() if enabled}

    def test_metadata_and_dart_do_not_build_native_consumers(self):
        for path in ("lib/src/erika_file_image.dart", "test/player_test.dart", "README.md", "pubspec.lock"):
            with self.subTest(path=path):
                self.assertEqual(self.selected("packages/erika_flutter/" + path), {"package"})
        self.assertEqual(self.selected("packages/erika_flutter/native_artifacts.properties"), {"package", "artifacts"})

    def test_each_bridge_selects_only_its_platform(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                self.assertEqual(self.selected(f"packages/erika_flutter/{platform}/bridge.cc"), {"package", platform})

    def test_native_sources_do_not_add_flutter_package_runs(self):
        for path in ("crates/erika/src/lib.rs", "Cargo.lock", "Cargo.toml", ".cargo/config.toml", "rust-toolchain.toml", "xtask/src/main.rs", "third_party/patches/ffmpeg.patch", "third_party/wgpu-hal/src/lib.rs"):
            with self.subTest(path=path):
                self.assertEqual(self.selected(path), {"native", *PLATFORMS})
        self.assertEqual(self.selected("crates/erika/src/lib.rs", "packages/erika_flutter/lib/player.dart"), {"native", "package", *PLATFORMS})

    def test_shared_build_inputs_and_apple_helper(self):
        for path in ("native/include/erika.h", "tool/build.sh", "pubspec.yaml"):
            self.assertEqual(self.selected("packages/erika_flutter/" + path), {"package", *PLATFORMS})
        self.assertEqual(self.selected("packages/erika_flutter/native/prepare_apple_prebuilt.sh"), {"package", "ios", "macos", "tvos"})

    def test_workflows_and_selection_infrastructure(self):
        self.assertEqual(self.selected(".github/workflows/ci.yml"), {"native", *PLATFORMS})
        self.assertEqual(self.selected(".github/workflows/android.yml"), {"android"})
        self.assertEqual(self.selected(".github/workflows/ohos.yml"), {"ohos"})
        self.assertEqual(self.selected(".github/workflows/flutter-package.yml"), {"package", "artifacts", *PLATFORMS})
        for path in (".github/workflows/ci-changes.yml", ".github/scripts/ci_changes.py", ".github/scripts/test_ci_changes.py", ".github/actions/cache-native/action.yml"):
            self.assertEqual(self.selected(path), set(FLAGS))
        self.assertEqual(self.selected(".github/scripts/check_native_artifacts.py"), {"package", "artifacts"})
        self.assertEqual(self.selected("README.md"), set())

    def test_output_contract_and_manual(self):
        self.assertEqual(json.loads(outputs(classify([]))["apple"]), [])
        selected = classify(["packages/erika_flutter/ios/plugin.swift"])
        self.assertEqual(outputs(selected)["apple"], '["ios"]')
        self.assertEqual(outputs(selected)["package"], "true")
        self.assertEqual(outputs(selected)["native"], "false")
        self.assertIsNone(changed_paths("workflow_dispatch", {}))
        self.assertEqual(set(key for key, value in classify([], all_checks=True).items() if value), set(FLAGS))


class GitRangeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "ci@example.invalid")
        self.git("config", "user.name", "CI test")
        self.write("initial.txt", "initial")
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, stderr=subprocess.DEVNULL).decode().strip()

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def commit(self):
        self.git("add", "--all")
        self.git("commit", "-qm", "test change")
        return self.git("rev-parse", "HEAD")

    def test_push_includes_all_commits_and_deleted_or_renamed_paths(self):
        self.write("packages/erika_flutter/android/old.kt", "bridge")
        start = self.commit()
        self.git("mv", "packages/erika_flutter/android/old.kt", "packages/erika_flutter/android/new.kt")
        self.commit()
        self.write("packages/erika_flutter/lib/player.dart", "dart")
        (self.root / "initial.txt").unlink()
        head = self.commit()
        paths = changed_paths("push", {"before": start, "after": head}, cwd=self.root)
        self.assertEqual(set(paths), {"packages/erika_flutter/android/old.kt", "packages/erika_flutter/android/new.kt", "packages/erika_flutter/lib/player.dart", "initial.txt"})

    def test_pull_request_uses_merge_base_not_changed_base_tip(self):
        self.git("checkout", "-qb", "feature")
        self.write("packages/erika_flutter/lib/player.dart", "dart")
        head = self.commit()
        self.git("checkout", "-q", "main")
        self.write("crates/erika/src/lib.rs", "base-only change")
        base_tip = self.commit()
        event = {"pull_request": {"base": {"sha": base_tip}, "head": {"sha": head}}}
        self.assertEqual(changed_paths("pull_request", event, cwd=self.root), ["packages/erika_flutter/lib/player.dart"])

    def test_first_push_missing_history_and_no_changes(self):
        self.assertIsNone(changed_paths("push", {"before": "0" * 40, "after": self.base}, cwd=self.root))
        self.assertIsNone(changed_paths("push", {"before": "1" * 40, "after": self.base}, cwd=self.root))
        self.assertEqual(changed_paths("push", {"before": self.base, "after": self.base}, cwd=self.root), [])


if __name__ == "__main__":
    unittest.main()
