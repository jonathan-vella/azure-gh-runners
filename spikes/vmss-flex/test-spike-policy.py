import unittest

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

spec = spec_from_file_location("spike_policy", Path(__file__).with_name("pre-job-spike.py"))
policy = module_from_spec(spec)
spec.loader.exec_module(policy)


class SpikePolicyTest(unittest.TestCase):
    def test_reviewed_commit_only(self):
        sha = "a" * 40
        context = {"GHR_SPIKE_WORKFLOW_SHA": sha, "GITHUB_WORKFLOW_SHA": sha, "GITHUB_SHA": sha}
        self.assertTrue(policy.validate(context))
        for field in context:
            for value in ("", "b" * 40, "latest", sha + "\n"):
                with self.subTest(field=field, value=value):
                    altered = dict(context)
                    altered[field] = value
                    self.assertFalse(policy.validate(altered))


if __name__ == "__main__":
    unittest.main()
