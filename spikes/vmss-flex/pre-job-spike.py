import os
import re
import sys


def validate(context):
    reviewed = context.get("GHR_SPIKE_WORKFLOW_SHA", "")
    return bool(re.fullmatch(r"[a-f0-9]{40}", reviewed)) and (
        context.get("GITHUB_WORKFLOW_SHA") == reviewed
        and context.get("GITHUB_SHA") == reviewed
    )


if __name__ == "__main__":
    if not validate(os.environ):
        print("::error::Spike rejected job: workflow/job commit differs from reviewed commit.",
              file=sys.stderr)
        sys.exit(1)
