import { createHash, randomBytes, randomUUID } from "node:crypto";
import { rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  buildCustomData,
  computeExpiresUtc,
  createAzRunner,
  createWorkerOps,
  selectExpired,
  workerTags,
} from "./azure.mjs";
import { createGithubClient } from "./github.mjs";

const pollIntervalMs = 30_000;
const maxConsecutivePollErrors = 5;
const waitGraceMinutes = 12;
const stoppedStates = new Set(["PowerState/stopped", "PowerState/deallocated", "PowerState/deallocating"]);

export function createRedactor() {
  const secrets = new Set();
  return {
    add(secret) {
      if (typeof secret === "string" && secret.length >= 8) secrets.add(secret);
    },
    redact(text) {
      let result = String(text);
      for (const secret of secrets) result = result.split(secret).join("[redacted]");
      return result;
    },
  };
}

export function createLogger(redactor, sink = (line) => console.log(line)) {
  return (event, fields = {}) => sink(redactor.redact(JSON.stringify({ event, ...fields })));
}

const patterns = {
  GITHUB_OWNER: /^[A-Za-z0-9-]{1,39}$/,
  GITHUB_REPOSITORY: /^[A-Za-z0-9._-]{1,100}$/,
  RUNNER_LABEL: /^[A-Za-z0-9._-]{1,50}$/,
  CONSUMER_NAME: /^[a-z0-9][a-z0-9-]{0,30}$/,
  WORKER_VM_SIZE: /^Standard_[A-Za-z0-9_]{2,40}$/,
  AZURE_RESOURCE_GROUP: /^[A-Za-z0-9._()-]{1,90}$/,
  VMSS_NAME: /^[A-Za-z0-9._-]{1,64}$/,
};

export function parseConfig(env) {
  const required = [
    "GH_APP_ID", "GH_APP_INSTALLATION_ID", "GH_APP_PRIVATE_KEY", "GITHUB_OWNER", "GITHUB_REPOSITORY",
    "RUNNER_LABEL", "CONSUMER_NAME", "WORKER_VM_SIZE", "JOB_TIMEOUT_MINUTES", "WORKER_POLICY_JSON",
    "AZURE_RESOURCE_GROUP", "VMSS_NAME", "IMAGE_DEFINITION_ID", "WORKER_SUBNET_ID", "AZURE_CLIENT_ID",
  ];
  const missing = required.filter((name) => !env[name]);
  if (missing.length > 0) throw new Error(`Required settings are missing: ${missing.join(", ")}.`);
  for (const [name, pattern] of Object.entries(patterns)) {
    if (!pattern.test(env[name])) throw new Error(`Setting ${name} has an invalid format.`);
  }
  const jobTimeoutMinutes = Number(env.JOB_TIMEOUT_MINUTES);
  if (!Number.isInteger(jobTimeoutMinutes) || jobTimeoutMinutes < 1 || jobTimeoutMinutes > 1440) {
    throw new Error("Setting JOB_TIMEOUT_MINUTES must be an integer from 1 to 1440.");
  }
  let policy;
  try {
    policy = JSON.parse(env.WORKER_POLICY_JSON);
  } catch {
    throw new Error("Setting WORKER_POLICY_JSON is not valid JSON.");
  }
  if (policy === null || typeof policy !== "object" || Array.isArray(policy)) {
    throw new Error("Setting WORKER_POLICY_JSON must be a JSON object.");
  }
  const runId = env.CONTAINER_APP_JOB_EXECUTION_NAME || randomUUID();
  const suffix = createHash("sha256").update(runId).digest("hex").slice(0, 8);
  return {
    appId: env.GH_APP_ID,
    installationId: env.GH_APP_INSTALLATION_ID,
    privateKey: env.GH_APP_PRIVATE_KEY,
    owner: env.GITHUB_OWNER,
    repo: env.GITHUB_REPOSITORY,
    label: env.RUNNER_LABEL,
    consumer: env.CONSUMER_NAME,
    vmSize: env.WORKER_VM_SIZE,
    jobTimeoutMinutes,
    policy,
    resourceGroup: env.AZURE_RESOURCE_GROUP,
    vmssName: env.VMSS_NAME,
    imageId: env.IMAGE_DEFINITION_ID,
    subnetId: env.WORKER_SUBNET_ID,
    clientId: env.AZURE_CLIENT_ID,
    runId,
    // Windows computer names are limited to 15 characters.
    vmName: `ghrw-${suffix}`,
    runnerName: `ghr-win-${env.CONSUMER_NAME}-${suffix}`,
  };
}

export function generateAdminPassword() {
  return `${randomBytes(24).toString("base64url")}aA1!`;
}

async function waitForWorker({ config, github, ops, runnerId, log, now, sleep, signal, startMs }) {
  const deadline = startMs + (config.jobTimeoutMinutes + waitGraceMinutes) * 60_000;
  let consecutiveErrors = 0;
  for (;;) {
    if (signal.aborted) return "aborted";
    if (now() >= deadline) return "timeout";
    try {
      const state = await ops.powerState(config.vmName);
      if (state === "deleted") return "worker-disappeared";
      if (stoppedStates.has(state)) {
        return (await github.runnerExists(runnerId)) ? "stopped-runner-registered" : "completed";
      }
      if (!(await github.runnerExists(runnerId))) return "completed";
      consecutiveErrors = 0;
    } catch (error) {
      consecutiveErrors += 1;
      log("poll-error", { message: error.message, consecutiveErrors });
      if (consecutiveErrors >= maxConsecutivePollErrors) throw error;
    }
    await sleep(pollIntervalMs, signal);
  }
}

export async function runJanitor({ ops, resourceGroup, now, log }) {
  const resources = await ops.listManaged();
  const expired = selectExpired(resources, { resourceGroup, nowMs: now() });
  const failures = [];
  for (const resource of expired) {
    try {
      await ops.deleteResource(resource);
      log("janitor-deleted", { id: resource.id, type: resource.type });
    } catch (error) {
      failures.push(error.message);
      log("janitor-delete-failed", { id: resource.id, message: error.message });
    }
  }
  return { selected: expired.length, failures };
}

export async function run({
  config,
  github,
  ops,
  log,
  now = () => Date.now(),
  sleep,
  signal = new AbortController().signal,
  password = generateAdminPassword,
  fileOps = { writeFile, rm },
  tempDir = tmpdir(),
  onSecret = () => {},
}) {
  const failures = [];
  const startMs = now();
  const expiresUtc = computeExpiresUtc(startMs, config.jobTimeoutMinutes);
  const customDataFile = join(tempDir, `ghr-customdata-${config.runId}.json`);
  let runnerId;
  let outcome = "not-started";
  let workerRequested = false;
  let mintAttempted = false;

  try {
    await ops.login();
    try {
      const janitor = await runJanitor({ ops, resourceGroup: config.resourceGroup, now, log });
      log("janitor-complete", janitor);
    } catch (error) {
      // A janitor problem must not block this job; the next execution retries it.
      log("janitor-failed", { message: error.message });
    }

    let jit;
    mintAttempted = true;
    try {
      jit = await github.mintJitRunner({ name: config.runnerName, label: config.label });
    } catch (error) {
      runnerId = error.runnerId;
      throw error;
    }
    runnerId = jit.runnerId;
    onSecret(jit.encodedJitConfig);
    log("jit-runner-created", { name: config.runnerName, label: config.label, runnerId });

    const adminPassword = password();
    onSecret(adminPassword);
    const customData = buildCustomData({ jitConfig: jit.encodedJitConfig, policy: config.policy, expiresUtc });
    await fileOps.writeFile(customDataFile, customData, { mode: 0o600, flag: "wx" });
    workerRequested = true;
    await ops.createWorker({
      vmName: config.vmName,
      vmSize: config.vmSize,
      tags: workerTags({ consumer: config.consumer, runId: config.runId, expiresUtc }),
      customDataFile,
      adminPassword,
    });
    log("worker-created", { vmName: config.vmName, vmSize: config.vmSize, expiresUtc });

    outcome = await waitForWorker({ config, github, ops, runnerId, log, now, sleep, signal, startMs });
    log("worker-finished", { outcome });
    if (outcome !== "completed") failures.push(new Error(`Worker did not complete cleanly: ${outcome}.`));
  } catch (error) {
    outcome = "error";
    failures.push(error);
    log("run-failed", { message: error.message });
  } finally {
    try {
      await fileOps.rm(customDataFile, { force: true });
    } catch (error) {
      failures.push(error);
    }
    if (workerRequested) {
      try {
        await ops.deleteWorker({ vmName: config.vmName, runId: config.runId });
        log("worker-deleted", { vmName: config.vmName });
      } catch (error) {
        failures.push(error);
        log("worker-delete-failed", { message: error.message });
      }
    }
    if (mintAttempted) {
      try {
        const removed = runnerId === undefined
          ? await github.deleteRunnerByName(config.runnerName)
          : await github.deleteRunnerById(runnerId);
        log("runner-deregistered", { removed });
      } catch (error) {
        failures.push(error);
        log("runner-deregister-failed", { message: error.message });
      }
    }
  }
  return { ok: failures.length === 0, outcome, failures: failures.map((failure) => failure.message) };
}

function abortableSleep(ms, signal) {
  return new Promise((done) => {
    if (signal?.aborted) return done();
    const timer = setTimeout(done, ms);
    signal?.addEventListener("abort", () => {
      clearTimeout(timer);
      done();
    }, { once: true });
  });
}

export async function main(env = process.env) {
  const redactor = createRedactor();
  const log = createLogger(redactor);
  let config;
  try {
    config = parseConfig(env);
  } catch (error) {
    console.error(error.message);
    return 1;
  }
  redactor.add(config.privateKey);
  const controller = new AbortController();
  process.once("SIGTERM", () => controller.abort());
  process.once("SIGINT", () => controller.abort());

  const az = createAzRunner({ redact: redactor.redact });
  const ops = createWorkerOps({
    az,
    resourceGroup: config.resourceGroup,
    vmssName: config.vmssName,
    imageId: config.imageId,
    subnetId: config.subnetId,
    clientId: config.clientId,
  });
  const github = createGithubClient({
    appId: config.appId,
    installationId: config.installationId,
    privateKey: config.privateKey,
    owner: config.owner,
    repo: config.repo,
    onSecret: redactor.add,
  });
  const result = await run({
    config,
    github,
    ops,
    log,
    sleep: abortableSleep,
    signal: controller.signal,
    onSecret: redactor.add,
  });
  log("orchestrator-finished", { ok: result.ok, outcome: result.outcome, failures: result.failures });
  return result.ok ? 0 : 1;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  process.exitCode = await main();
}
