import { createSign, randomUUID } from "node:crypto";
import { chown, chmod, mkdir, writeFile } from "node:fs/promises";

const apiRoot = "https://api.github.com";
const apiVersion = "2026-03-10";
const owner = process.env.GITHUB_OWNER;
const repo = process.env.GITHUB_REPOSITORY;
const appId = process.env.GH_APP_ID;
const installationId = process.env.GH_APP_INSTALLATION_ID;
const privateKey = process.env.GH_APP_PRIVATE_KEY;
const label = process.env.RUNNER_LABEL;
const runnerName = `spike10-${randomUUID()}`;
const runnerPath = `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/actions/runners`;
const sharedDirectory = "/jit";

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

function createAppJwt() {
  const now = Math.floor(Date.now() / 1000);
  const unsigned = [
    base64url(JSON.stringify({ alg: "RS256", typ: "JWT" })),
    base64url(JSON.stringify({ iat: now - 60, exp: now + 540, iss: appId })),
  ].join(".");
  const signer = createSign("RSA-SHA256");
  signer.update(unsigned);
  signer.end();
  return `${unsigned}.${signer.sign(privateKey, "base64url")}`;
}

async function githubRequest(path, method, token, body) {
  const response = await fetch(`${apiRoot}${path}`, {
    method,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "X-GitHub-Api-Version": apiVersion,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });

  if (!response.ok) {
    throw new Error(`GitHub API ${method} returned HTTP ${response.status}.`);
  }
  return response.json();
}

if (![owner, repo, appId, installationId, privateKey, label].every(Boolean)) {
  throw new Error("Required JIT initialization settings are missing.");
}

if (process.getuid?.() !== 0) {
  throw new Error("The JIT init container must run as root to set shared-volume ownership.");
}

const appJwt = createAppJwt();
const installation = await githubRequest(
  `/app/installations/${encodeURIComponent(installationId)}/access_tokens`,
  "POST",
  appJwt,
  {
    repositories: [repo],
    permissions: { administration: "write" },
  },
);

const jit = await githubRequest(
  `${runnerPath}/generate-jitconfig`,
  "POST",
  installation.token,
  {
    name: runnerName,
    labels: [label],
    work_folder: "_work",
  },
);

if (!jit.encoded_jit_config || !Array.isArray(jit.runner?.labels)) {
  throw new Error("The JIT response is missing its config or runner label metadata.");
}

const labels = jit.runner.labels.map(({ name, type }) => ({ name, type }));
if (!labels.some(({ name }) => name.toLowerCase() === label.toLowerCase())) {
  throw new Error("GitHub did not return the requested custom label on the JIT runner.");
}

await mkdir(sharedDirectory, { recursive: true, mode: 0o700 });
await chown(sharedDirectory, 1001, 123);
await chmod(sharedDirectory, 0o700);
const configPath = `${sharedDirectory}/encoded-jit-config`;
const metadataPath = `${sharedDirectory}/runner-metadata.json`;
await writeFile(configPath, jit.encoded_jit_config, { mode: 0o400 });
await chown(configPath, 1001, 123);
await chmod(configPath, 0o440);
await writeFile(metadataPath, JSON.stringify({ name: jit.runner.name ?? runnerName, labels }), { mode: 0o444 });
await chown(metadataPath, 1001, 123);

console.log(JSON.stringify({ event: "jit-runner-created", name: runnerName, labels }));
