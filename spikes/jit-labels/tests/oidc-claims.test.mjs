import test from "node:test";
import assert from "node:assert/strict";
import { readAllowlistedClaims } from "../oidc-claims.mjs";

const expectedClaims = {
  iss: "https://token.actions.githubusercontent.com",
  sub: "repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:platform-prod",
  aud: "api://AzureADTokenExchange",
  repository: "jonathan-vella/azure-gh-runners",
  repository_id: 1408821667,
  repository_owner: "jonathan-vella",
  repository_owner_id: 25802147,
  ref: "refs/heads/main",
  ref_type: "branch",
  event_name: "workflow_dispatch",
  environment: "platform-prod",
  workflow_ref: "jonathan-vella/azure-gh-runners/.github/workflows/spike-jit-oidc-claims.yml@refs/heads/main",
  job_workflow_ref: "jonathan-vella/azure-gh-runners/.github/workflows/spike-jit-oidc-claims.yml@refs/heads/main",
};

function tokenFor(claims) {
  return `header.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.signature`;
}

test("accepts the exact immutable repository and environment subject", () => {
  assert.deepEqual(readAllowlistedClaims(tokenFor(expectedClaims)), expectedClaims);
});

test("rejects a name-only or otherwise unexpected subject", () => {
  assert.throws(
    () => readAllowlistedClaims(tokenFor({ ...expectedClaims, sub: "repo:jonathan-vella/azure-gh-runners:environment:platform-prod" })),
    /did not match the allowlisted/,
  );
});

test("rejects a missing environment claim", () => {
  const claims = { ...expectedClaims };
  delete claims.environment;
  assert.throws(
    () => readAllowlistedClaims(tokenFor(claims)),
    /did not match the allowlisted/,
  );
});
