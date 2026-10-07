#!/usr/bin/env bash
set -euo pipefail
/usr/bin/python3 /opt/ghr-vmss/pre-job-spike.py
exec /opt/runner-image/pre-job-policy.sh
