#!/usr/bin/env bash
set -euo pipefail
[[ $# == 1 && $(id -u) == 0 ]]
manifest=$1
mapfile -t minimal_packages < <(python3 - "$manifest" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    manifest = json.load(source)
for name in ("jq", "curl", "python"):
    package = manifest["inherited"][name]
    print(f'{package["package"]}={package["packageVersion"]}')
PY
)
[[ ${#minimal_packages[@]} == 3 ]]
sed -i 's|http://archive.ubuntu.com/|https://archive.ubuntu.com/|g; s|http://security.ubuntu.com/|https://security.ubuntu.com/|g' \
  /etc/apt/sources.list.d/ubuntu.sources
timeout --signal=TERM --kill-after=10s 180s apt-get -o APT::Update::Error-Mode=any \
  -o Acquire::Retries=0 -o Acquire::https::Timeout=20 update
DEBIAN_FRONTEND=noninteractive timeout --signal=TERM --kill-after=10s 180s \
  apt-get -o Acquire::Retries=0 -o Acquire::https::Timeout=20 --yes --no-install-recommends \
  install "${minimal_packages[@]}"
while IFS=$'\t' read -r package version; do
  [[ $(dpkg-query -W -f='${Version}' "$package") == "$version" ]]
done < <(jq -r '.inherited | [.jq, .curl, .python][] | [.package, .packageVersion] | @tsv' "$manifest")
