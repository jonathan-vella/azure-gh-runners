import { createSign, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { chmod, chown, mkdir, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const apiRoot = "https://api.github.com";
const apiVersion = "2022-11-28";
const runnerGroupId = 1;
const requestTimeoutMs = 10_000;
const retryDelaysMs = [250, 1_000];

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

export function createAppJwt(appId, privateKey, now = Math.floor(Date.now() / 1000)) {
  const unsigned = [
    base64url(JSON.stringify({ alg: "RS256", typ: "JWT" })),
    base64url(JSON.stringify({ iat: now - 60, exp: now + 540, iss: appId })),
  ].join(".");
  const signer = createSign("RSA-SHA256");
  signer.update(unsigned);
  signer.end();
  return `${unsigned}.${signer.sign(privateKey, "base64url")}`;
}

function retryable(response) {
  return response.status === 429 ||
    response.status >= 500 ||
    (response.status === 403 && response.headers.get("x-ratelimit-remaining") === "0");
}

async function githubRequest({ path, method, token, body, fetchImpl, retrySafe = false }) {
  const maxAttempts = retrySafe ? retryDelaysMs.length + 1 : 1;
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    let response;
    try {
      response = await fetchImpl(`${apiRoot}${path}`, {
        method,
        headers: {
          Accept: "application/vnd.github+json",
          Authorization: `Bearer ${token}`,
          "X-GitHub-Api-Version": apiVersion,
          ...(body ? { "Content-Type": "application/json" } : {}),
        },
        ...(body ? { body: JSON.stringify(body) } : {}),
        signal: AbortSignal.timeout(requestTimeoutMs),
      });
    } catch {
      if (attempt === maxAttempts - 1) throw new Error(`GitHub API ${method} failed or timed out.`);
      await new Promise((done) => setTimeout(done, retryDelaysMs[attempt]));
      continue;
    }
    if (response.ok) {
      if (response.status === 204) return null;
      try {
        return await response.json();
      } catch {
        throw new Error(`GitHub API ${method} returned an invalid response.`);
      }
    }
    if (!retrySafe || !retryable(response) || attempt === maxAttempts - 1) {
      throw new Error(`GitHub API ${method} returned HTTP ${response.status}.`);
    }
    await new Promise((done) => setTimeout(done, retryDelaysMs[attempt]));
  }
  throw new Error(`GitHub API ${method} exhausted its retry limit.`);
}

function runnerAccount() {
  const uid = Number(execFileSync("id", ["-u", "runner"], { encoding: "utf8" }).trim());
  const gid = Number(execFileSync("id", ["-g", "runner"], { encoding: "utf8" }).trim());
  if (!Number.isInteger(uid) || !Number.isInteger(gid)) {
    throw new Error("Unable to resolve the runner account.");
  }
  return { uid, gid };
}

async function removeRunner({ runnerId, runnerName, runnerPath, token, fetchImpl }) {
  if (!runnerId) {
    const found = await githubRequest({
      path: `${runnerPath}?name=${encodeURIComponent(runnerName)}&per_page=100`,
      method: "GET",
      token,
      fetchImpl,
      retrySafe: true,
    });
    const matches = (found?.runners ?? []).filter((runner) => runner.name === runnerName);
    if (matches.length > 1) throw new Error("Cleanup found multiple runners with the unique name.");
    runnerId = matches[0]?.id;
  }
  if (runnerId) {
    await githubRequest({ path: `${runnerPath}/${runnerId}`, method: "DELETE", token, fetchImpl, retrySafe: true });
  }
}

export async function initializeJitRunner({
  env = process.env,
  fetchImpl = fetch,
  sharedDirectory = "/jit",
  getAccountIds = runnerAccount,
  isRoot = () => process.getuid?.() === 0,
  fileOps = { chmod, chown, mkdir, rm, writeFile },
} = {}) {
  const owner = env.GITHUB_OWNER;
  const repo = env.GITHUB_REPOSITORY;
  const appId = env.GH_APP_ID;
  const installationId = env.GH_APP_INSTALLATION_ID;
  const privateKey = env.GH_APP_PRIVATE_KEY;
  const namePrefix = env.RUNNER_NAME_PREFIX;
  const labels = (env.RUNNER_LABELS ?? "").split(",").map((label) => label.trim()).filter(Boolean);
  if (![owner, repo, appId, installationId, privateKey, namePrefix].every(Boolean) || labels.length === 0) {
    throw new Error("Required JIT initialization settings are missing.");
  }
  if (!isRoot()) {
    throw new Error("The JIT init container must run as root to set shared-volume ownership.");
  }

  const runnerName = `${namePrefix}-${randomUUID()}`;
  const runnerPath = `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/actions/runners`;
  const configPath = `${sharedDirectory}/config`;
  let installationToken;
  let runnerId;

  try {
    const installation = await githubRequest({
      path: `/app/installations/${encodeURIComponent(installationId)}/access_tokens`,
      method: "POST",
      token: createAppJwt(appId, privateKey),
      body: { repositories: [repo], permissions: { administration: "write" } },
      fetchImpl,
      retrySafe: true,
    });
    if (typeof installation?.token !== "string" || !installation.token) {
      throw new Error("GitHub did not return an installation token.");
    }
    installationToken = installation.token;

    const jit = await githubRequest({
      path: `${runnerPath}/generate-jitconfig`,
      method: "POST",
      token: installationToken,
      body: { name: runnerName, runner_group_id: runnerGroupId, labels, work_folder: "_work" },
      fetchImpl,
    });
    runnerId = jit?.runner?.id;
    if (!Number.isInteger(runnerId) || typeof jit.encoded_jit_config !== "string" || !jit.encoded_jit_config ||
      !Array.isArray(jit.runner.labels)) {
      throw new Error("The JIT response is missing required runner metadata.");
    }
    const returned = new Set(jit.runner.labels.map(({ name }) => String(name).toLowerCase()));
    if (!labels.every((label) => returned.has(label.toLowerCase()))) {
      throw new Error("GitHub did not return the requested custom labels on the JIT runner.");
    }

    const { uid, gid } = getAccountIds();
    await fileOps.mkdir(sharedDirectory, { recursive: true, mode: 0o700 });
    await fileOps.chown(sharedDirectory, uid, gid);
    await fileOps.chmod(sharedDirectory, 0o700);
    await fileOps.writeFile(configPath, jit.encoded_jit_config, { mode: 0o400, flag: "wx" });
    await fileOps.chown(configPath, uid, gid);
    await fileOps.chmod(configPath, 0o400);

    console.log(JSON.stringify({ event: "jit-runner-created", name: runnerName, labels }));
  } catch (error) {
    const cleanupFailures = [];
    try {
      await fileOps.rm(configPath, { force: true });
    } catch {
      cleanupFailures.push("JIT config file");
    }
    if (installationToken) {
      try {
        await removeRunner({ runnerId, runnerName, runnerPath, token: installationToken, fetchImpl });
      } catch {
        cleanupFailures.push("GitHub runner registration");
      }
    }
    if (cleanupFailures.length > 0) {
      throw new Error(`JIT initialization failed; cleanup also failed for: ${cleanupFailures.join(", ")}.`);
    }
    throw error;
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  try {
    await initializeJitRunner();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
