import hashlib
import unittest
import urllib.error

from main_probe import assert_canaries_absent, assert_environment_isolated, assert_metadata_token_denied


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


if __name__ == "__main__":
    unittest.main()
