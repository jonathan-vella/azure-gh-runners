import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.error

from main_probe import assert_canaries_absent, assert_environment_isolated, assert_metadata_token_denied, run


class MainProbeTests(unittest.TestCase):
    def setUp(self):
        self.app_key = "synthetic-app-key"
        self.scale_auth = "synthetic-scale-auth"
        self.expected_hashes = {
            hashlib.sha256(self.app_key.encode()).hexdigest(),
            hashlib.sha256(self.scale_auth.encode()).hexdigest(),
        }

    def test_canary_values_detected_under_arbitrary_environment_names(self):
        for name, value in (("UNEXPECTED_ONE", self.app_key), ("ANY_NAME", self.scale_auth)):
            with self.subTest(name=name):
                with self.assertRaisesRegex(RuntimeError, "canary value"):
                    assert_canaries_absent({name: value}, self.expected_hashes)

    def test_unrelated_environment_values_are_allowed(self):
        assert_canaries_absent({"PATH": "/usr/bin", "APP_MODE": "probe"}, self.expected_hashes)

    def test_secret_and_identity_environment_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "identity endpoint"):
            assert_environment_isolated(
                {
                    "IDENTITY_ENDPOINT": "synthetic",
                    "EXPECTED_APP_KEY_SHA256": hashlib.sha256(self.app_key.encode()).hexdigest(),
                    "EXPECTED_SCALE_AUTH_SHA256": hashlib.sha256(self.scale_auth.encode()).hexdigest(),
                }
            )
        with self.assertRaisesRegex(RuntimeError, "app key"):
            assert_environment_isolated(
                {
                    "APP_KEY": self.app_key,
                    "EXPECTED_APP_KEY_SHA256": hashlib.sha256(self.app_key.encode()).hexdigest(),
                    "EXPECTED_SCALE_AUTH_SHA256": hashlib.sha256(self.scale_auth.encode()).hexdigest(),
                }
            )

    def test_successful_token_response_is_rejected(self):
        def successful_response(_url, timeout):
            self.assertEqual(timeout, 2)
            return type("Response", (), {"close": lambda _self: None})()

        with self.assertRaisesRegex(RuntimeError, "token request unexpectedly succeeded"):
            assert_metadata_token_denied(successful_response)

    def test_http_error_is_a_denied_token_request(self):
        def denied_response(_url, timeout):
            self.assertEqual(timeout, 2)
            raise urllib.error.HTTPError(_url, 403, "denied", {}, None)

        assert_metadata_token_denied(denied_response)

    @unittest.skipUnless(os.name == "posix", "real UID/GID handoff requires POSIX")
    def test_non_root_process_reads_and_deletes_owned_handoff(self):
        if os.geteuid() != 0 and os.getuid() != 65532:
            self.skipTest("test requires root to drop privileges or an existing UID 65532")

        jit_config = b"synthetic-jit-config"
        jit_hash = hashlib.sha256(jit_config).hexdigest()
        with tempfile.TemporaryDirectory() as temporary_directory:
            os.chmod(temporary_directory, 0o700)
            path = os.path.join(temporary_directory, "config")
            with open(path, "wb") as handoff:
                handoff.write(jit_config)
            os.chown(temporary_directory, 65532, 65532)
            os.chown(path, 65532, 65532)
            os.chmod(path, 0o400)
            environment = {
                "EXPECTED_JIT_SHA256": jit_hash,
                "EXPECTED_APP_KEY_SHA256": self.expected_hashes.pop(),
                "EXPECTED_SCALE_AUTH_SHA256": self.expected_hashes.pop(),
            }
            probe = (
                "import urllib.error; from main_probe import run; "
                "deny=lambda *a,**k: (_ for _ in ()).throw(urllib.error.HTTPError('url', 403, 'denied', {}, None)); "
                f"run({path!r}, {environment!r}, deny)"
            )

            if os.geteuid() == 0:
                child_code = f"import os; os.setgroups([]); os.setgid(65532); os.setuid(65532); {probe}"
            else:
                child_code = probe
            result = subprocess.run(
                [sys.executable, "-B", "-c", child_code],
                cwd=os.path.dirname(__file__),
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("ASSERT_main_uid_65532=true", result.stdout)
            self.assertFalse(os.path.exists(path))


if __name__ == "__main__":
    unittest.main()
