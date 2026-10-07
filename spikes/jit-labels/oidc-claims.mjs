import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const allowedClaims = [
  "iss",
  "sub",
  "aud",
  "repository",
  "repository_id",
  "repository_owner",
  "repository_owner_id",
  "ref",
  "ref_type",
  "event_name",
  "environment",
  "workflow_ref",
  "job_workflow_ref",
];

export function readAllowlistedClaims(token) {
  const payload = token.split(".")[1];
  if (!payload) throw new Error("GitHub OIDC response did not contain a JWT payload.");

  let claims;
  try {
    claims = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
  } catch {
    throw new Error("GitHub OIDC JWT payload was not valid JSON.");
  }

  const safeClaims = Object.fromEntries(
    allowedClaims
      .filter((name) => typeof claims[name] === "string" || typeof claims[name] === "number")
      .map((name) => [name, claims[name]]),
  );
  if (typeof claims.aud === "string" || Array.isArray(claims.aud)) safeClaims.aud = claims.aud;
  const audiences = Array.isArray(safeClaims.aud) ? safeClaims.aud : [safeClaims.aud];

  if (
    safeClaims.iss !== "https://token.actions.githubusercontent.com" ||
    !audiences.includes("api://AzureADTokenExchange") ||
    safeClaims.repository !== "jonathan-vella/azure-gh-runners" ||
    String(safeClaims.repository_id) !== "1408821667" ||
    String(safeClaims.repository_owner_id) !== "25802147" ||
    safeClaims.ref !== "refs/heads/main" ||
    safeClaims.environment !== "platform-prod" ||
    safeClaims.sub !==
      "repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:platform-prod"
  ) {
    throw new Error("OIDC claims did not match the allowlisted issue 10 diagnostic context.");
  }
  return safeClaims;
}

export async function reportOidcClaims({
  env = process.env,
  fetchImpl = fetch,
  write = console.log,
}) {
  if (!env.ACTIONS_ID_TOKEN_REQUEST_URL || !env.ACTIONS_ID_TOKEN_REQUEST_TOKEN) {
    throw new Error("GitHub Actions OIDC request context is unavailable.");
  }
  const url = new URL(env.ACTIONS_ID_TOKEN_REQUEST_URL);
  url.searchParams.set("audience", "api://AzureADTokenExchange");
  let response;
  try {
    response = await fetchImpl(url, {
      headers: { Authorization: `Bearer ${env.ACTIONS_ID_TOKEN_REQUEST_TOKEN}` },
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    throw new Error("GitHub OIDC token request failed or timed out.");
  }
  if (!response.ok) throw new Error(`GitHub OIDC token request returned HTTP ${response.status}.`);

  let body;
  try {
    body = await response.json();
  } catch {
    throw new Error("GitHub OIDC token endpoint returned an invalid response.");
  }
  if (typeof body.value !== "string") throw new Error("GitHub OIDC response did not contain a token.");
  const claims = readAllowlistedClaims(body.value);
  write(JSON.stringify(claims));
  return claims;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  try {
    await reportOidcClaims();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
