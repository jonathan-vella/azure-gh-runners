#!/usr/bin/env bash
set -euo pipefail

exec /usr/bin/python3 -I "$(dirname -- "${BASH_SOURCE[0]}")/pre-job-policy.py"
