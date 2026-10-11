import { createSign } from "node:crypto";

const apiRoot = "https://api.github.com";
const apiVersion = "2022-11-28";
const runnerGroupId = 1;
const requestTimeoutMs = 10_000;
const retryDelaysMs = [250, 1_000];
const tokenRefreshMarginMs = 5 * 60_000;

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

export class GithubHttpError extends Error {
  constructor(method, status) {
    super(`GitHub API ${method} returned HTTP ${status}.`);
    this.status = status;
  }
}

function retryable(response) {
  return response.status === 429 ||
    response.status >= 500 ||
    (response.status === 403 && response.headers.get("x-ratelimit-remaining") === "0");
}

// Error messages never include URLs, headers or bodies so credentials cannot leak through them.
async function githubRequest({ path, method, token, body, fetchImpl, retrySafe = false, sleep }) {
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
      await sleep(retryDelaysMs[attempt]);
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
      throw new GithubHttpError(method, response.status);
    }
    await sleep(retryDelaysMs[attempt]);
  }
  throw new Error(`GitHub API ${method} exhausted its retry limit.`);
}

export function createGithubClient({
  appId,
  installationId,
  privateKey,
  owner,
  repo,
  fetchImpl = fetch,
  now = () => Date.now(),
  sleep = (ms) => new Promise((done) => setTimeout(done, ms)),
  onSecret = () => {},
}) {
  const runnerPath = `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/actions/runners`;
  let cached;

  async function installationToken() {
    if (cached && cached.expiresAt - now() > tokenRefreshMarginMs) return cached.token;
    const jwt = createAppJwt(appId, privateKey, Math.floor(now() / 1000));
    onSecret(jwt);
    const response = await githubRequest({
      path: `/app/installations/${encodeURIComponent(installationId)}/access_tokens`,
      method: "POST",
      token: jwt,
      body: { repositories: [repo], permissions: { administration: "write" } },
      fetchImpl,
      retrySafe: true,
      sleep,
    });
    if (typeof response?.token !== "string" || !response.token) {
      throw new Error("GitHub did not return an installation token.");
    }
    onSecret(response.token);
    const expiresAt = Date.parse(response.expires_at ?? "");
    cached = { token: response.token, expiresAt: Number.isFinite(expiresAt) ? expiresAt : now() + 30 * 60_000 };
    return cached.token;
  }

  return {
    async mintJitRunner({ name, label }) {
      const jit = await githubRequest({
        path: `${runnerPath}/generate-jitconfig`,
        method: "POST",
        token: await installationToken(),
        body: { name, runner_group_id: runnerGroupId, labels: [label], work_folder: "_work" },
        fetchImpl,
        sleep,
      });
      const runnerId = jit?.runner?.id;
      if (typeof jit?.encoded_jit_config === "string" && jit.encoded_jit_config) onSecret(jit.encoded_jit_config);
      if (!Number.isInteger(runnerId) || typeof jit.encoded_jit_config !== "string" || !jit.encoded_jit_config ||
        !Array.isArray(jit.runner.labels)) {
        const error = new Error("The JIT response is missing required runner metadata.");
        error.runnerId = Number.isInteger(runnerId) ? runnerId : undefined;
        throw error;
      }
      const returned = new Set(jit.runner.labels.map(({ name: labelName }) => String(labelName).toLowerCase()));
      if (!returned.has(label.toLowerCase())) {
        const error = new Error("GitHub did not return the requested custom label on the JIT runner.");
        error.runnerId = runnerId;
        throw error;
      }
      return { runnerId, encodedJitConfig: jit.encoded_jit_config };
    },

    async runnerExists(runnerId) {
      try {
        await githubRequest({
          path: `${runnerPath}/${runnerId}`,
          method: "GET",
          token: await installationToken(),
          fetchImpl,
          retrySafe: true,
          sleep,
        });
        return true;
      } catch (error) {
        if (error instanceof GithubHttpError && error.status === 404) return false;
        throw error;
      }
    },

    async deleteRunnerById(runnerId) {
      try {
        await githubRequest({
          path: `${runnerPath}/${runnerId}`,
          method: "DELETE",
          token: await installationToken(),
          fetchImpl,
          retrySafe: true,
          sleep,
        });
        return true;
      } catch (error) {
        if (error instanceof GithubHttpError && error.status === 404) return false;
        throw error;
      }
    },

    // Used when the mint failed before the runner ID was known.
    async deleteRunnerByName(name) {
      const found = await githubRequest({
        path: `${runnerPath}?name=${encodeURIComponent(name)}&per_page=100`,
        method: "GET",
        token: await installationToken(),
        fetchImpl,
        retrySafe: true,
        sleep,
      });
      const matches = (found?.runners ?? []).filter((runner) => runner.name === name);
      if (matches.length > 1) throw new Error("Cleanup found multiple runners with the unique name.");
      if (matches.length === 0) return false;
      return this.deleteRunnerById(matches[0].id);
    },
  };
}
