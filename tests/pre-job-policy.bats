#!/usr/bin/env bats

setup() {
  export HOOK_PATH="${HOOK_PATH:-$BATS_TEST_DIRNAME/../image/pre-job-policy.sh}"
  export GITHUB_REPOSITORY='example/service'
  export GITHUB_EVENT_NAME='workflow_dispatch'
  export GITHUB_REF='refs/heads/release'
  export GITHUB_WORKFLOW_REF='example/service/.github/workflows/deploy.yml@refs/heads/release'
  export CONSUMER_POLICY_JSON='{"repository":"example/service","visibility":"public","allowedEvents":["push","schedule","workflow_dispatch"],"allowedRefs":["refs/heads/release"],"allowedWorkflows":["example/service/.github/workflows/deploy.yml@refs/heads/release"]}'
  unset GITHUB_EVENT_PATH GITHUB_BASE_REF GITHUB_HEAD_REF
}

deny() {
  run bash -e "$HOOK_PATH"
  [ "$status" -ne 0 ]
  [[ "$output" == *'::error::Consumer policy rejected job:'* ]]
  [[ "$output" != *'SECRET_CANARY'* ]]
  [[ "$output" != *'Traceback'* ]]
}

private_pr() {
  export CONSUMER_POLICY_JSON
  CONSUMER_POLICY_JSON="$(jq -c '.visibility="private" | .allowedEvents += ["pull_request"]' <<< "$CONSUMER_POLICY_JSON")"
  export GITHUB_EVENT_NAME='pull_request'
  export GITHUB_REF='refs/pull/17/merge'
  export GITHUB_WORKFLOW_REF='example/service/.github/workflows/deploy.yml@refs/pull/17/merge'
  export GITHUB_BASE_REF='release' GITHUB_HEAD_REF='feature'
  export GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/event.json"
  printf '%s\n' '{"number":17,"repository":{"full_name":"example/service","private":true,"fork":false},"pull_request":{"number":17,"state":"open","base":{"ref":"release","repo":{"full_name":"example/service","private":true,"fork":false}},"head":{"ref":"feature","repo":{"full_name":"example/service","private":true,"fork":false}}}}' > "$GITHUB_EVENT_PATH"
}

mutate_payload() {
  local updated
  updated="$(jq -c "$1" "$GITHUB_EVENT_PATH")"
  printf '%s\n' "$updated" > "$GITHUB_EVENT_PATH"
}

@test "public dispatch, schedule and push allow the validated non-main default branch" {
  for event in workflow_dispatch schedule push; do
    export GITHUB_EVENT_NAME="$event"
    run bash -e "$HOOK_PATH"
    [ "$status" -eq 0 ]
    [ "$output" = 'Consumer policy accepted job.' ]
  done
}

@test "exact generator policy is accepted without runtime contract additions" {
  export CONSUMER_POLICY_JSON
  CONSUMER_POLICY_JSON="$(cat "$GENERATED_POLICY_PATH")"
  export GITHUB_REPOSITORY='jonathan-vella/example'
  export GITHUB_REF='refs/heads/main'
  export GITHUB_WORKFLOW_REF='jonathan-vella/example/.github/workflows/private-ci.yml@refs/heads/main'
  run bash -e "$HOOK_PATH"
  [ "$status" -eq 0 ]
}

@test "repository matching is case-insensitive while workflow paths remain exact" {
  export GITHUB_REPOSITORY='Example/Service'
  export GITHUB_WORKFLOW_REF='Example/Service/.github/workflows/deploy.yml@refs/heads/release'
  run bash -e "$HOOK_PATH"
  [ "$status" -eq 0 ]
  export GITHUB_WORKFLOW_REF='Example/Service/.github/workflows/Deploy.yml@refs/heads/release'
  deny
}

@test "repository, event, ref and workflow are independently enforced" {
  for key in GITHUB_REPOSITORY GITHUB_EVENT_NAME GITHUB_REF GITHUB_WORKFLOW_REF; do
    local old="${!key}"
    export "$key=SECRET_CANARY"
    deny
    export "$key=$old"
  done
}

@test "each missing or empty GitHub context field fails closed" {
  for key in GITHUB_REPOSITORY GITHUB_EVENT_NAME GITHUB_REF GITHUB_WORKFLOW_REF; do
    local old="${!key}"
    unset "$key"
    deny
    export "$key="
    deny
    export "$key=$old"
  done
}

@test "missing, malformed, non-object, duplicate-key and oversized policies reject without echoing input" {
  local valid="$CONSUMER_POLICY_JSON"
  unset CONSUMER_POLICY_JSON
  deny
  for value in '' 'SECRET_CANARY' 'null' '[]' '{}' \
    '{"repository":"SECRET_CANARY","repository":"example/service"}'; do
    export CONSUMER_POLICY_JSON="$value"
    deny
  done
  export CONSUMER_POLICY_JSON="$valid"
  CONSUMER_POLICY_JSON="$(printf '%65537s' ' ')"
  deny
}

@test "invalid policy types, unknown fields and malformed allowlists reject" {
  local valid="$CONSUMER_POLICY_JSON"
  for change in '.visibility="internal"' '.visibility=[]' '.repository=null' \
    '.unknown="SECRET_CANARY"' 'del(.allowedRefs)' '.allowedRefs=[]' \
    '.allowedEvents="push"' '.allowedWorkflows=[null]' \
    '.allowedEvents += ["push"]' '.allowedRefs=["refs/heads/bad..branch"]' \
    '.allowedWorkflows=["example/service/.github/workflows/../deploy.yml@refs/heads/release"]' \
    '.allowedWorkflows=["example/foreign/.github/workflows/deploy.yml@refs/heads/release"]' \
    '.allowedWorkflows=["example/service/.github/workflows/deploy.yml@refs/heads/feature"]'; do
    export CONSUMER_POLICY_JSON
    CONSUMER_POLICY_JSON="$(jq -c "$change" <<< "$valid")"
    deny
  done
}

@test "policy and payload size limits count UTF-8 bytes rather than characters" {
  export CONSUMER_POLICY_JSON
  CONSUMER_POLICY_JSON="$(/usr/bin/python3 -I -c 'import sys; sys.stdout.buffer.write(b"\xc3\xa9" * 32769)')"
  deny
  [[ "$output" == *'oversized consumer policy'* ]]
  setup
  private_pr
  /usr/bin/python3 -I -c 'import sys; sys.stdout.buffer.write(b"\xc3\xa9" * 524289)' > "$GITHUB_EVENT_PATH"
  deny
  [[ "$output" == *'oversized pull request payload'* ]]
}

@test "public policy cannot widen event or branch floor" {
  local valid="$CONSUMER_POLICY_JSON"
  for event in pull_request pull_request_target workflow_run issue_comment; do
    export CONSUMER_POLICY_JSON
    CONSUMER_POLICY_JSON="$(jq -c --arg event "$event" '.allowedEvents += [$event]' <<< "$valid")"
    deny
  done
  CONSUMER_POLICY_JSON="$(jq -c '.allowedRefs += ["refs/heads/feature"]' <<< "$valid")"
  deny
}

@test "private policy never permits pull_request_target or workflow_run" {
  local valid="$CONSUMER_POLICY_JSON"
  for event in pull_request_target workflow_run; do
    export CONSUMER_POLICY_JSON
    CONSUMER_POLICY_JSON="$(jq -c --arg event "$event" '.visibility="private" | .allowedEvents += [$event]' <<< "$valid")"
    deny
  done
}

@test "tag, nondefault branch and mismatched workflow branch reject" {
  export GITHUB_REF='refs/tags/release'
  deny
  export GITHUB_REF='refs/heads/feature'
  deny
  export GITHUB_REF='refs/heads/release'
  export GITHUB_WORKFLOW_REF='example/service/.github/workflows/deploy.yml@refs/heads/feature'
  deny
}

@test "private branch jobs use explicit refs, not a guessed default" {
  export CONSUMER_POLICY_JSON
  CONSUMER_POLICY_JSON="$(jq -c '.visibility="private" | .allowedRefs += ["refs/heads/feature"] | .allowedWorkflows += ["example/service/.github/workflows/deploy.yml@refs/heads/feature"]' <<< "$CONSUMER_POLICY_JSON")"
  export GITHUB_REF='refs/heads/feature'
  export GITHUB_WORKFLOW_REF='example/service/.github/workflows/deploy.yml@refs/heads/feature'
  run bash -e "$HOOK_PATH"
  [ "$status" -eq 0 ]
  export GITHUB_WORKFLOW_REF='example/service/.github/workflows/deploy.yml@refs/heads/release'
  deny
}

@test "private same-repository open PR explicitly opted in uses base allowlist and merge workflow ref" {
  private_pr
  run bash -e "$HOOK_PATH"
  [ "$status" -eq 0 ]
}

@test "PR without explicit opt-in and public PR payload reject" {
  private_pr
  export CONSUMER_POLICY_JSON
  CONSUMER_POLICY_JSON="$(jq -c '.allowedEvents=["workflow_dispatch"]' <<< "$CONSUMER_POLICY_JSON")"
  deny
  CONSUMER_POLICY_JSON="$(jq -c '.visibility="public"' <<< "$CONSUMER_POLICY_JSON")"
  deny
}

@test "fork PR payload rejects even when private policy opts in" {
  private_pr
  mutate_payload '.pull_request.head.repo.full_name="external/fork" | .pull_request.head.repo.fork=true'
  deny
  private_pr
  mutate_payload '.pull_request.head.repo.fork=true'
  deny
}

@test "unreadable, missing, invalid, duplicate-key or oversized PR payload rejects" {
  private_pr
  unset GITHUB_EVENT_PATH
  deny
  export GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/missing"
  deny
  export GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR"
  deny
  export GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/fifo"
  mkfifo "$GITHUB_EVENT_PATH"
  deny
  export GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/event.json"
  for value in 'SECRET_CANARY' 'null' '[]' '{}' '{"number":17,"number":18}' \
    '{"pull_request":{"base":null}}'; do
    printf '%s\n' "$value" > "$GITHUB_EVENT_PATH"
    deny
  done
  printf '%1048577s' ' ' > "$GITHUB_EVENT_PATH"
  deny
}

@test "PR payload repositories and visibility must unambiguously match" {
  for change in '.repository=null' '.repository.full_name="external/other"' \
    '.repository.private=false' '.repository.fork=true' \
    'del(.pull_request.head.repo)' '.pull_request.base.repo.private="true"' \
    '.pull_request.head.repo.full_name=null' '.pull_request.head.repo.private=false' \
    'del(.pull_request.head.repo.fork)' '.pull_request.base=[]'; do
    private_pr
    mutate_payload "$change"
    deny
  done
}

@test "PR number, state, base, head and runtime branch metadata must match" {
  for change in '.number="17"' '.number=true' '.pull_request.number=18' \
    '.number=1 | .pull_request.number=true' \
    '.pull_request.state="closed"' '.pull_request.base.ref="other"' \
    '.pull_request.head.ref=null' '.pull_request.base.ref="../bad"'; do
    private_pr
    mutate_payload "$change"
    deny
  done
  for key in GITHUB_BASE_REF GITHUB_HEAD_REF; do
    private_pr
    unset "$key"
    deny
    export "$key=other"
    deny
  done
}

@test "PR head, closed base and wrong-number refs cannot masquerade as merge refs" {
  for ref in refs/pull/17/head refs/pull/18/merge refs/heads/release; do
    private_pr
    export GITHUB_REF="$ref"
    deny
    private_pr
    export GITHUB_WORKFLOW_REF="example/service/.github/workflows/deploy.yml@$ref"
    deny
  done
}

@test "PR workflow path and base branch are independently allowlisted" {
  private_pr
  export GITHUB_WORKFLOW_REF='example/service/.github/workflows/other.yml@refs/pull/17/merge'
  deny
  private_pr
  mutate_payload '.pull_request.base.ref="other"'
  export GITHUB_BASE_REF='other'
  deny
}

@test "untrusted values cannot inject workflow commands into rejection logs" {
  export GITHUB_WORKFLOW_REF=$'SECRET_CANARY\n::warning::injected'
  deny
  [[ "$output" != *'::warning::'* ]]
}

@test "runner failure status prevents following user step in execution fixture" {
  export GITHUB_EVENT_NAME='pull_request_target'
  run bash -e -c 'bash -e "$HOOK_PATH"; touch "$1"' -- "$BATS_TEST_TMPDIR/user-step"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/user-step" ]
}
