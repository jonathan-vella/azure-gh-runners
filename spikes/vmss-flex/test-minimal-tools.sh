#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) == 0 ]]
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export MINIMAL_FIXTURE=$fixture MINIMAL_MANIFEST="$root/image/versions.json"
cat > "$fixture/apt-get" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MINIMAL_FIXTURE/calls"
if [[ " $* " == *' install '* ]]; then
  [[ ${SIMULATE_FAILURE:-false} == false ]]
  touch "$MINIMAL_FIXTURE/installed"
fi
SH
cat > "$fixture/dpkg-query" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ! -f $MINIMAL_FIXTURE/installed ]]; then
  printf '%s' 'older-image-baseline'
  exit 0
fi
python3 - "$MINIMAL_MANIFEST" "${@: -1}" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    packages = json.load(source)["inherited"]
for item in packages.values():
    if item["package"] == sys.argv[2]:
        print(item["packageVersion"], end="")
        break
else:
    raise SystemExit(1)
PY
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/sed"
chmod 0755 "$fixture/apt-get" "$fixture/dpkg-query" "$fixture/sed"
export PATH="$fixture:$PATH"
[[ $(dpkg-query -W -f='${Version}' jq) == older-image-baseline ]]
/bin/bash "$root/spikes/vmss-flex/install-minimal-tools.sh" "$MINIMAL_MANIFEST"
grep -q 'Acquire::Retries=0' "$fixture/calls"
for name in jq curl python; do
  package=$(jq -r --arg name "$name" '.inherited[$name].package' "$MINIMAL_MANIFEST")
  grep -F -q "$package=" "$fixture/calls"
done
rm "$fixture/installed"
if SIMULATE_FAILURE=true /bin/bash "$root/spikes/vmss-flex/install-minimal-tools.sh" "$MINIMAL_MANIFEST"; then
  echo 'Failed minimum-package installation was accepted.' >&2
  exit 1
fi
