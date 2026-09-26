import unittest

from check_native_artifacts import ARTIFACTS, verify


class NativeArtifactTests(unittest.TestCase):
    def setUp(self):
        self.manifest = "\n".join(f"{key}={'a' * 64}" for key in ARTIFACTS)
        self.checksums = "\n".join(f"{'a' * 64}  {name}" for name in ARTIFACTS.values())

    def test_release_matches_manifest(self):
        verify("# Manifest\nERIKA_NATIVE_VERSION=0.2.1\n" + self.manifest, self.checksums)

    def test_wrong_release_digest_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            verify(self.manifest, self.checksums.replace("a" * 64, "b" * 64, 1))

    def test_missing_platform_archive_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            verify(self.manifest, "\n".join(self.checksums.splitlines()[1:]))

    def test_missing_or_invalid_manifest_digest_is_rejected(self):
        for manifest in ("\n".join(self.manifest.splitlines()[1:]), self.manifest.replace("a" * 64, "invalid", 1)):
            with self.subTest(manifest=manifest), self.assertRaisesRegex(ValueError, "invalid manifest"):
                verify(manifest, self.checksums)

    def test_duplicate_release_entry_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            verify(self.manifest, self.checksums + "\n" + self.checksums.splitlines()[0])


if __name__ == "__main__":
    unittest.main()
