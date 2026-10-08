import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import * as fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { initializeJitRunner } from "../image/jit-init.mjs";

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
  RUNNER_LABELS: "ghr-smoke",
  RUNNER_NAME_PREFIX: "ghr-smoke",
};

function response(status, data, headers = {}) {
  return { ok: status >= 200 && status < 300, status, headers: new Headers(headers), json: async () => data };
}

function api({ labels = ["ghr-smoke"], runnerId = 777 } = {}) {
  const requests = [];
  const fetchImpl = async (url, options) => {
    requests.push({ url, options });
    if (url.includes("/access_tokens")) return response(201, { token: "installation-token" });
    if (url.includes("/generate-jitconfig")) {
      return response(201, {
        encoded_jit_config: "encoded-config",
        runner: { id: runnerId, labels: labels.map((name) => ({ name, type: "custom" })) },
      });
    }
    if (url.includes("?name=")) return response(200, { runners: [] });
    return response(204);
  };
  return { fetchImpl, requests };
}

async function withDirectory(run) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "jit-init-"));
  const log = console.log;
  console.log = () => {};
  try {
    await run(directory);
  } finally {
    console.log = log;
    await fs.rm(directory, { recursive: true, force: true });
  }
}

const fileOps = (overrides = {}) => ({
  chmod: fs.chmod,
  chown: async () => {},
  mkdir: fs.mkdir,
  rm: fs.rm,
  writeFile: fs.writeFile,
  ...overrides,
});

test("mints a JIT config with the consumer label and hands it to the runner account", async () => {
  await withDirectory(async (directory) => {
    const { fetchImpl, requests } = api();
    const owners = [];
    const modes = [];
    await initializeJitRunner({
      env,
      fetchImpl,
      sharedDirectory: directory,
      isRoot: () => true,
      getAccountIds: () => ({ uid: 1001, gid: 1001 }),
      fileOps: fileOps({
        chown: async (...args) => owners.push(args),
        chmod: async (filePath, mode) => {
          modes.push([path.basename(filePath), mode]);
          await fs.chmod(filePath, mode);
        },
      }),
    });

    const tokenRequest = requests[0];
    assert.match(tokenRequest.url, /\/app\/installations\/456\/access_tokens$/);
    assert.deepEqual(JSON.parse(tokenRequest.options.body), {
      repositories: ["ghr-smoke"],
      permissions: { administration: "write" },
    });
    const jitRequest = requests[1];
    assert.match(jitRequest.url, /\/repos\/jonathan-vella\/ghr-smoke\/actions\/runners\/generate-jitconfig$/);
    assert.equal(jitRequest.options.headers.Authorization, "Bearer installation-token");
    const body = JSON.parse(jitRequest.options.body);
    assert.equal(body.runner_group_id, 1);
    assert.deepEqual(body.labels, ["ghr-smoke"]);
    assert.equal(body.work_folder, "_work");
    assert.match(body.name, /^ghr-smoke-[0-9a-f-]{36}$/);
    assert.equal(await fs.readFile(path.join(directory, "config"), "utf8"), "encoded-config");
    assert.deepEqual(modes, [[path.basename(directory), 0o700], ["config", 0o400]]);
    assert.ok(owners.every(([, uid, gid]) => uid === 1001 && gid === 1001));
    assert.equal(owners.length, 2);
  });
});

test("fails closed and deregisters the runner when GitHub drops the requested label", async () => {
  await withDirectory(async (directory) => {
    const { fetchImpl, requests } = api({ labels: ["other"] });
    await assert.rejects(
      initializeJitRunner({ env, fetchImpl, sharedDirectory: directory, isRoot: () => true, fileOps: fileOps() }),
      /requested custom labels/,
    );
    assert.ok(requests.some(({ url, options }) => options.method === "DELETE" && url.endsWith("/runners/777")));
    await assert.rejects(fs.readFile(path.join(directory, "config")));
  });
});

test("removes a partial handoff file and reports cleanup failures without leaking content", async () => {
  await withDirectory(async (directory) => {
    const { fetchImpl, requests } = api();
    let chownCalls = 0;
    await assert.rejects(
      initializeJitRunner({
        env,
        fetchImpl,
        sharedDirectory: directory,
        isRoot: () => true,
        getAccountIds: () => ({ uid: 1001, gid: 1001 }),
        fileOps: fileOps({
          chown: async () => {
            chownCalls += 1;
            if (chownCalls === 2) throw new Error("chown failed");
          },
        }),
      }),
      /chown failed/,
    );
    await assert.rejects(fs.readFile(path.join(directory, "config")));
    assert.ok(requests.some(({ options }) => options.method === "DELETE"));
  });
});

test("refuses to run without root or required settings before contacting GitHub", async () => {
  let calls = 0;
  const fetchImpl = async () => {
    calls += 1;
  };
  await assert.rejects(initializeJitRunner({ env, fetchImpl, isRoot: () => false }), /must run as root/);
  await assert.rejects(
    initializeJitRunner({ env: { ...env, RUNNER_LABELS: " , " }, fetchImpl, isRoot: () => true }),
    /settings are missing/,
  );
  await assert.rejects(
    initializeJitRunner({ env: { ...env, GH_APP_PRIVATE_KEY: "" }, fetchImpl, isRoot: () => true }),
    /settings are missing/,
  );
  assert.equal(calls, 0);
});

test("does not retry the non-idempotent JIT request and surfaces the HTTP status only", async () => {
  await withDirectory(async (directory) => {
    let jitCalls = 0;
    const fetchImpl = async (url) => {
      if (url.includes("/access_tokens")) return response(201, { token: "installation-token" });
      if (url.includes("/generate-jitconfig")) {
        jitCalls += 1;
        return response(500, { message: "boom" });
      }
      if (url.includes("?name=")) return response(200, { runners: [] });
      return response(204);
    };
    await assert.rejects(
      initializeJitRunner({ env, fetchImpl, sharedDirectory: directory, isRoot: () => true, fileOps: fileOps() }),
      (error) => error.message === "GitHub API POST returned HTTP 500.",
    );
    assert.equal(jitCalls, 1);
  });
});
