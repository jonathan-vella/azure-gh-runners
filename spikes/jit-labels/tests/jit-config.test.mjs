import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { initializeJitRunner } from "../jit-config.mjs";
import { reportOidcClaims, readAllowlistedClaims } from "../oidc-claims.mjs";

const { privateKey } = generateKeyPairSync("rsa", {
  modulusLength: 2048,
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});
const env = {
  GITHUB_OWNER: "jonathan-vella",
  GITHUB_REPOSITORY: "ghr-smoke",
  GH_APP_ID: "123",
  GH_APP_INSTALLATION_ID: "456",
  GH_APP_PRIVATE_KEY: privateKey,
  RUNNER_LABEL: "ghr-smoke-jit-label-spike",
};

function response(status, data, headers = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: new Headers(headers),
    async json() {
      return data;
    },
  };
}

function successfulApi({ jitLabels = [env.RUNNER_LABEL] } = {}) {
  const requests = [];
  const fetchImpl = async (url, options) => {
    requests.push({ url, options });
    if (url.includes("/access_tokens")) return response(201, { token: "mock-installation-token" });
    if (url.includes("/generate-jitconfig")) {
      return response(201, {
        encoded_jit_config: "mock-jit-config",
        runner: {
          id: 777,
          name: "spike10-mock",
          labels: jitLabels.map((name) => ({ name, type: "custom" })),
        },
      });
    }
    return response(204);
  };
  return { fetchImpl, requests };
}

async function tempDirectory() {
  return mkdtemp(path.join(os.tmpdir(), "jit-label-test-"));
}

test("requires runner_group_id 1 and writes owner-readable handoff files with restricted modes", async () => {
  const directory = await tempDirectory();
  const { fetchImpl, requests } = successfulApi();
  const ownership = [];
  const modes = [];
  const originalLog = console.log;
  console.log = () => {};
  try {
    await initializeJitRunner({
      env,
      fetchImpl,
      sharedDirectory: directory,
      isRoot: () => true,
      getAccountIds: () => ({ uid: 1001, gid: 2345 }),
      fileOps: {
        chmod: async (filePath, mode) => {
          modes.push([path.basename(filePath), mode]);
          await (await import("node:fs/promises")).chmod(filePath, mode);
        },
        chown: async (...args) => ownership.push(args),
        mkdir: async (...args) => (await import("node:fs/promises")).mkdir(...args),
        rm: async (...args) => (await import("node:fs/promises")).rm(...args),
        writeFile: async (...args) => (await import("node:fs/promises")).writeFile(...args),
      },
    });

    const jitBody = JSON.parse(requests.find(({ url }) => url.includes("/generate-jitconfig")).options.body);
    assert.equal(jitBody.runner_group_id, 1);
    assert.equal(jitBody.labels[0], env.RUNNER_LABEL);
    assert.equal(await readFile(path.join(directory, "encoded-jit-config"), "utf8"), "mock-jit-config");
    assert.deepEqual(modes, [
      [path.basename(directory), 0o700],
      ["encoded-jit-config", 0o400],
      ["runner-metadata.json", 0o400],
    ]);
    assert.ok(ownership.every(([, uid, gid]) => uid === 1001 && gid === 2345));
  } finally {
    console.log = originalLog;
    await rm(directory, { recursive: true, force: true });
  }
});

test("deletes the exact runner registration and removes partial handoff when label validation fails", async () => {
  const directory = await tempDirectory();
  const { fetchImpl, requests } = successfulApi({ jitLabels: ["other-label"] });
  const originalLog = console.log;
  console.log = () => {};
  try {
    await assert.rejects(
      initializeJitRunner({ env, fetchImpl, sharedDirectory: directory, isRoot: () => true }),
      /requested custom label/,
    );
    const deleteRequest = requests.find(({ options }) => options.method === "DELETE");
    assert.match(deleteRequest.url, /\/runners\/777$/);
    await assert.rejects(readFile(path.join(directory, "encoded-jit-config")));
  } finally {
    console.log = originalLog;
    await rm(directory, { recursive: true, force: true });
  }
});

test("retries bounded runner lookup on a transient server failure before cleaning registration", async () => {
  const directory = await tempDirectory();
  let lookupCount = 0;
  const requests = [];
  const fetchImpl = async (url, options) => {
    requests.push({ url, options });
    if (url.includes("/access_tokens")) return response(201, { token: "mock-installation-token" });
    if (url.includes("/generate-jitconfig")) {
      return response(201, { encoded_jit_config: "ignored", runner: { labels: [] } });
    }
    if (url.includes("?name=")) {
      lookupCount += 1;
      if (lookupCount === 1) return response(503, {});
      return response(200, { runners: [{ id: 778, name: decodeURIComponent(new URL(url).searchParams.get("name")) }] });
    }
    return response(204);
  };
  const originalLog = console.log;
  console.log = () => {};
  try {
    await assert.rejects(
      initializeJitRunner({ env, fetchImpl, sharedDirectory: directory, isRoot: () => true }),
      /missing required runner metadata/,
    );
    assert.equal(lookupCount, 2);
    assert.ok(requests.some(({ options, url }) => options.method === "DELETE" && url.endsWith("/778")));
  } finally {
    console.log = originalLog;
    await rm(directory, { recursive: true, force: true });
  }
});

test("rejects missing settings before contacting GitHub", async () => {
  let calls = 0;
  await assert.rejects(
    initializeJitRunner({
      env: { ...env, RUNNER_LABEL: "" },
      fetchImpl: async () => { calls += 1; },
      isRoot: () => true,
    }),
    /settings are missing/,
  );
  assert.equal(calls, 0);
});

test("prints only allowlisted claims and never the OIDC JWT", async () => {
  const jwt = `header.${Buffer.from(JSON.stringify({
    iss: "https://token.actions.githubusercontent.com",
    sub: "repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:platform-prod",
    aud: "api://AzureADTokenExchange",
    repository: "jonathan-vella/azure-gh-runners",
    repository_id: 1408821667,
    repository_owner: "jonathan-vella",
    repository_owner_id: 25802147,
    ref: "refs/heads/main",
    event_name: "workflow_dispatch",
    environment: "platform-prod",
    unapproved_claim: "must-not-print",
  })).toString("base64url")}.signature`;
  let printed = "";
  let requestedUrl;
  const claims = await reportOidcClaims({
    env: {
      ACTIONS_ID_TOKEN_REQUEST_URL: "https://token.actions.githubusercontent.com/request",
      ACTIONS_ID_TOKEN_REQUEST_TOKEN: "mock-request-token",
    },
    fetchImpl: async (url, options) => {
      requestedUrl = new URL(url);
      assert.equal(options.headers.Authorization, "Bearer mock-request-token");
      return response(200, { value: jwt });
    },
    write: (value) => { printed = value; },
  });
  assert.equal(requestedUrl.searchParams.get("audience"), "api://AzureADTokenExchange");
  assert.ok(claims.sub.includes(":environment:platform-prod"));
  assert.ok(!printed.includes(jwt));
  assert.ok(!printed.includes("must-not-print"));
  assert.ok(!printed.includes("mock-request-token"));
});

test("rejects OIDC claims outside the allowlisted repository context", () => {
  const payload = Buffer.from(JSON.stringify({
    iss: "https://token.actions.githubusercontent.com",
    sub: "repo:attacker/fork:environment:platform-prod",
    repository: "attacker/fork",
    repository_id: 1,
    repository_owner_id: 2,
    ref: "refs/heads/main",
  })).toString("base64url");
  assert.throws(
    () => readAllowlistedClaims(`header.${payload}.signature`),
    /allowlisted issue 10 diagnostic context/,
  );
});
