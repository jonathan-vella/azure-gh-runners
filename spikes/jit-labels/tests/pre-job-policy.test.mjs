import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import test from "node:test";

const hookPath = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../pre-job-policy.sh",
);

function runHook(overrides) {
  return spawnSync("bash", [hookPath], {
    encoding: "utf8",
    env: {
      ...process.env,
      GITHUB_REPOSITORY: "jonathan-vella/ghr-smoke",
      GITHUB_EVENT_NAME: "workflow_dispatch",
      GITHUB_REF: "refs/heads/main",
      GITHUB_WORKFLOW_REF: "jonathan-vella/ghr-smoke/.github/workflows/jit-label-match.yml@refs/heads/main",
      ...overrides,
    },
  });
}

test("allows the exact approved dispatch workflow on main", () => {
  assert.equal(runHook({}).status, 0);
});

test("allows the isolated negative-control dispatch workflow on main", () => {
  assert.equal(runHook({
    GITHUB_WORKFLOW_REF: "jonathan-vella/ghr-smoke/.github/workflows/jit-self-hosted-only.yml@refs/heads/main",
  }).status, 0);
});

for (const [reason, overrides] of [
  ["repository", { GITHUB_REPOSITORY: "attacker/fork" }],
  ["event", { GITHUB_EVENT_NAME: "pull_request_target" }],
  ["branch", { GITHUB_REF: "refs/heads/feature" }],
  ["workflow", { GITHUB_WORKFLOW_REF: "jonathan-vella/ghr-smoke/.github/workflows/untrusted.yml@refs/heads/main" }],
  ["missing context", { GITHUB_WORKFLOW_REF: "" }],
]) {
  test(`denies ${reason} outside the allowlist`, () => {
    assert.notEqual(runHook(overrides).status, 0);
  });
}
