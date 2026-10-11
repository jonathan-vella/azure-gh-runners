import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import test from "node:test";
import {
  buildCustomData,
  computeExpiresUtc,
  createAzRunner,
  createWorkerOps,
  parseExpiry,
  selectExpired,
  workerNames,
  workerTags,
} from "../image/windows-orchestrator/azure.mjs";
import { createGithubClient } from "../image/windows-orchestrator/github.mjs";
import {
  createLogger,
  createRedactor,
  generateAdminPassword,
  parseConfig,
  run,
  runJanitor,
} from "../image/windows-orchestrator/orchestrator.mjs";

const sub = "/subscriptions/00000000-0000-0000-0000-000000000000";
const rg = "rg-test-win";
const now = Date.parse("2030-01-01T12:00:00Z");
const past = "2030-01-01T11:00:00Z";
const future = "2030-01-01T13:00:00Z";
const resource = (type, name, tags, group = rg) => ({ id: `${sub}/resourceGroups/${group}/providers/${type}/${name}`, type, tags });
const VM = "Microsoft.Compute/virtualMachines";
const NIC = "Microsoft.Network/networkInterfaces";
const DISK = "Microsoft.Compute/disks";
const managed = (expiresUtc) => ({ "ghr-managed": "true", consumer: "c", runId: "r", expiresUtc });

const env = {
  GH_APP_ID: "123",
  GH_APP_INSTALLATION_ID: "456",
  GH_APP_PRIVATE_KEY: "-----BEGIN PRIVATE KEY-----fake-key-material-----END PRIVATE KEY-----",
  GITHUB_OWNER: "octo",
  GITHUB_REPOSITORY: "repo",
  RUNNER_LABEL: "ghr-win-test",
  CONSUMER_NAME: "test",
  WORKER_VM_SIZE: "Standard_D4ds_v5",
  JOB_TIMEOUT_MINUTES: "60",
  WORKER_POLICY_JSON: '{"allowedEvents":["push"]}',
  AZURE_RESOURCE_GROUP: rg,
  VMSS_NAME: "vmss-test",
  IMAGE_DEFINITION_ID: `${sub}/resourceGroups/${rg}/providers/Microsoft.Compute/galleries/gal/images/ghr-windows-2025`,
  WORKER_SUBNET_ID: `${sub}/resourceGroups/${rg}/providers/Microsoft.Network/virtualNetworks/v/subnets/s`,
  AZURE_CLIENT_ID: "11111111-1111-1111-1111-111111111111",
  CONTAINER_APP_JOB_EXECUTION_NAME: "caj-ghr-win-test-abc123",
};

test("expiry is now plus job timeout plus 15 minutes, in UTC", () => {
  assert.equal(computeExpiresUtc(now, 60), "2030-01-01T13:15:00Z");
  assert.equal(computeExpiresUtc(now, 1), "2030-01-01T12:16:00Z");
  assert.equal(parseExpiry("2030-01-01T13:15:00Z"), Date.parse("2030-01-01T13:15:00Z"));
  for (const bad of [undefined, "", "tomorrow", "2030-01-01 13:15:00", "2030-01-01T13:15:00+02:00"]) {
    assert.ok(Number.isNaN(parseExpiry(bad)), String(bad));
  }
});

test("janitor selects only expired resources carrying the managed tag in the configured group", () => {
  const resources = [
    resource(VM, "expired-vm", managed(past)),
    resource(NIC, "expired-nic", managed(past)),
    resource(DISK, "expired-disk", managed(past)),
    resource(VM, "live-vm", managed(future)),
    resource(VM, "untagged-vm", {}),
    resource(VM, "no-tags-at-all", undefined),
    resource(VM, "tag-not-true", { ...managed(past), "ghr-managed": "false" }),
    resource(VM, "no-expiry", { "ghr-managed": "true" }),
    resource(VM, "bad-expiry", managed("not-a-date")),
    resource(VM, "other-rg", managed(past), "rg-someone-else"),
    resource(VM, "other-rg-prefix", managed(past), `${rg}-2`),
    resource("Microsoft.Storage/storageAccounts", "wrong-kind", managed(past)),
    resource("Microsoft.Network/virtualNetworks", "vnet", managed(past)),
  ];
  const selected = selectExpired(resources, { resourceGroup: rg, nowMs: now });
  assert.deepEqual(selected.map(({ id }) => id.split("/").pop()), ["expired-vm", "expired-nic", "expired-disk"]);
  assert.deepEqual(
    selectExpired([resource(VM, "x", managed(past), rg.toUpperCase())], { resourceGroup: rg, nowMs: now }).length,
    1,
  );
});

test("janitor orders VMs before NICs before disks and deletes through the guarded operation", async () => {
  const deleted = [];
  const ops = {
    listManaged: async () => [
      resource(DISK, "d", managed(past)),
      resource(NIC, "n", managed(past)),
      resource(VM, "v", managed(past)),
      resource(VM, "other", managed(past), "rg-other"),
    ],
    deleteResource: async (r) => deleted.push(r.id.split("/").pop()),
  };
  const result = await runJanitor({ ops, resourceGroup: rg, now: () => now, log: () => {} });
  assert.deepEqual(deleted, ["v", "n", "d"]);
  assert.equal(result.selected, 3);
});

test("guarded delete refuses resources outside the group or unknown kinds", async () => {
  const calls = [];
  const ops = createWorkerOps({ az: async (args) => calls.push(args), resourceGroup: rg, vmssName: "v", imageId: "i", subnetId: "s", clientId: "c" });
  await assert.rejects(ops.deleteResource(resource(VM, "x", managed(past), "rg-other")), /Refusing/);
  await assert.rejects(ops.deleteResource(resource("Microsoft.KeyVault/vaults", "kv", managed(past))), /Refusing/);
  assert.equal(calls.length, 0);
  await ops.deleteResource(resource(VM, "ok", managed(past)));
  assert.deepEqual(calls[0].slice(0, 3), ["vm", "delete", "--yes"]);
});

test("customData has the version 1 contract and nothing else", () => {
  const data = JSON.parse(buildCustomData({ jitConfig: "BASE64", policy: { a: 1 }, expiresUtc: "2030-01-01T13:15:00Z" }));
  assert.deepEqual(Object.keys(data).sort(), ["expiresUtc", "jitConfig", "policy", "version"]);
  assert.equal(data.version, 1);
  assert.equal(data.jitConfig, "BASE64");
  assert.deepEqual(data.policy, { a: 1 });
  assert.deepEqual(workerTags({ consumer: "c", runId: "r", expiresUtc: "e" }), {
    "ghr-managed": "true", consumer: "c", runId: "r", expiresUtc: "e",
  });
});

test("worker creation has no public IP, no identity, Premium SSD and delete-with-VM options", async () => {
  const calls = [];
  const ops = createWorkerOps({
    az: async (args) => { calls.push(args); return null; },
    resourceGroup: rg, vmssName: "vmss-test", imageId: "IMG", subnetId: "SUBNET", clientId: "c",
  });
  await ops.createWorker({
    vmName: "ghrw-1234abcd", vmSize: "Standard_D4ds_v5", tags: workerTags({ consumer: "c", runId: "r", expiresUtc: "e" }),
    customDataFile: "/tmp/cd.json", adminPassword: "pw",
  });
  const create = calls.find((args) => args[0] === "vm" && args[1] === "create");
  const flat = create.join(" ");
  assert.ok(create.includes("--vmss") && create.includes("Premium_LRS"));
  assert.match(flat, /--nic-delete-option Delete/);
  assert.match(flat, /--os-disk-delete-option Delete/);
  assert.doesNotMatch(flat, /assign-identity|public-ip|--nsg/);
  const nic = calls.find((args) => args[1] === "nic" && args[2] === "create");
  assert.doesNotMatch(nic.join(" "), /public-ip/);
  assert.ok(workerNames("ghrw-1234abcd").vm.length <= 15);
});

test("deleteWorker removes VM, NIC and disk by unique name and ignores already-deleted resources", async () => {
  const calls = [];
  const az = async (args) => {
    calls.push(args.join(" "));
    if (args[0] === "vm" && args[1] === "show") return { id: `${sub}/vm`, tags: { ...managed(future), runId: "run1" } };
    if (args[0] === "disk") {
      const error = new Error("gone");
      error.notFound = true;
      throw error;
    }
    return null;
  };
  const ops = createWorkerOps({ az, resourceGroup: rg, vmssName: "v", imageId: "i", subnetId: "s", clientId: "c" });
  await ops.deleteWorker({ vmName: "ghrw-aaaaaaaa", runId: "run1" });
  assert.ok(calls.some((c) => c.startsWith("vm delete --ids")));
  assert.ok(calls.some((c) => c.includes("network nic delete") && c.includes("nic-ghrw-aaaaaaaa")));
  assert.ok(calls.some((c) => c.includes("disk delete") && c.includes("osdisk-ghrw-aaaaaaaa")));
});

test("deleteWorker refuses a VM that does not belong to this run but still tries NIC and disk", async () => {
  const calls = [];
  const az = async (args) => {
    calls.push(args.join(" "));
    if (args[0] === "vm" && args[1] === "show") return { id: `${sub}/vm`, tags: { "ghr-managed": "true", runId: "other" } };
    return null;
  };
  const ops = createWorkerOps({ az, resourceGroup: rg, vmssName: "v", imageId: "i", subnetId: "s", clientId: "c" });
  await assert.rejects(ops.deleteWorker({ vmName: "ghrw-aaaaaaaa", runId: "run1" }), /Refusing/);
  assert.ok(!calls.some((c) => c.startsWith("vm delete")));
});

test("config parsing validates inputs and keeps VM names within the Windows limit", () => {
  const config = parseConfig(env);
  assert.equal(config.jobTimeoutMinutes, 60);
  assert.ok(config.vmName.length <= 15);
  assert.match(config.runnerName, /^ghr-win-test-[0-9a-f]{8}$/);
  assert.throws(() => parseConfig({ ...env, GH_APP_PRIVATE_KEY: "" }), /GH_APP_PRIVATE_KEY/);
  assert.throws(() => parseConfig({ ...env, JOB_TIMEOUT_MINUTES: "0" }), /JOB_TIMEOUT_MINUTES/);
  assert.throws(() => parseConfig({ ...env, WORKER_POLICY_JSON: "[]" }), /JSON object/);
  assert.throws(() => parseConfig({ ...env, WORKER_VM_SIZE: "D4; rm -rf" }), /WORKER_VM_SIZE/);
  assert.throws(() => parseConfig({ ...env, RUNNER_LABEL: "a b" }), /RUNNER_LABEL/);
  assert.notEqual(generateAdminPassword(), generateAdminPassword());
});

function harness(overrides = {}) {
  const events = [];
  const logs = [];
  const redactor = createRedactor();
  const config = parseConfig(env);
  redactor.add(config.privateKey);
  const github = {
    mintJitRunner: async () => { events.push("mint"); return { runnerId: 77, encodedJitConfig: "JIT-CONFIG-SECRET-VALUE" }; },
    runnerExists: async () => false,
    deleteRunnerById: async (id) => { events.push(`deregister:${id}`); return true; },
    deleteRunnerByName: async (name) => { events.push(`deregister-name:${name}`); return true; },
    ...overrides.github,
  };
  const ops = {
    login: async () => { events.push("login"); },
    listManaged: async () => [],
    deleteResource: async () => {},
    createWorker: async (args) => { events.push("create"); ops.created = args; },
    powerState: async () => "PowerState/stopped",
    deleteWorker: async () => { events.push("delete-worker"); },
    ...overrides.ops,
  };
  const written = {};
  const fileOps = {
    writeFile: async (path, content) => { written.path = path; written.content = content; events.push("write-customdata"); },
    rm: async (path) => { events.push(`rm:${path === written.path}`); },
  };
  let clock = now;
  const options = {
    config, github, ops, fileOps, tempDir: "/tmp",
    log: createLogger(redactor, (line) => logs.push(line)),
    now: () => clock,
    sleep: async (ms) => { clock += ms; },
    password: () => "Pa55-word-SECRET-xyz",
    onSecret: redactor.add,
    ...overrides.options,
  };
  return { events, logs, ops, written, options, advance: (ms) => { clock += ms; } };
}

test("happy path: janitor, mint, create with customData, wait, then always cleanup", async () => {
  const h = harness();
  const result = await run(h.options);
  assert.equal(result.ok, true);
  assert.equal(result.outcome, "completed");
  assert.deepEqual(h.events, ["login", "mint", "write-customdata", "create", "rm:true", "delete-worker", "deregister:77"]);
  const data = JSON.parse(h.written.content);
  assert.equal(data.jitConfig, "JIT-CONFIG-SECRET-VALUE");
  assert.deepEqual(data.policy, { allowedEvents: ["push"] });
  assert.equal(data.expiresUtc, "2030-01-01T13:15:00Z");
  assert.equal(h.ops.created.tags.expiresUtc, data.expiresUtc);
  assert.equal(h.ops.created.vmSize, "Standard_D4ds_v5");
  assert.equal(h.ops.created.customDataFile, h.written.path);
});

test("waits while the runner is registered and the VM runs, then completes", async () => {
  let polls = 0;
  const h = harness({
    ops: { powerState: async () => (++polls < 3 ? "PowerState/running" : "PowerState/stopped") },
    github: { runnerExists: async () => polls < 3 },
  });
  const result = await run(h.options);
  assert.equal(result.ok, true);
  assert.equal(polls, 3);
});

test("a stopped VM whose runner is still registered is reported as a failure and still cleaned up", async () => {
  const h = harness({ github: { runnerExists: async () => true } });
  const result = await run(h.options);
  assert.equal(result.ok, false);
  assert.equal(result.outcome, "stopped-runner-registered");
  assert.ok(h.events.includes("delete-worker") && h.events.includes("deregister:77"));
});

test("timeout fails the run but still deletes the worker and deregisters the runner", async () => {
  const h = harness({
    ops: { powerState: async () => "PowerState/running" },
    github: { runnerExists: async () => true },
  });
  const result = await run(h.options);
  assert.equal(result.ok, false);
  assert.match(result.failures.join(), /timeout/);
  assert.deepEqual(h.events.slice(-2), ["delete-worker", "deregister:77"]);
});

test("abort signal (replica termination) stops waiting and runs cleanup", async () => {
  const controller = new AbortController();
  const h = harness({
    ops: { powerState: async () => { controller.abort(); return "PowerState/running"; } },
    github: { runnerExists: async () => true },
    options: { signal: controller.signal },
  });
  const result = await run(h.options);
  assert.equal(result.ok, false);
  assert.match(result.failures.join(), /aborted/);
  assert.deepEqual(h.events.slice(-2), ["delete-worker", "deregister:77"]);
});

test("VM creation failure still deletes partial resources and the runner registration", async () => {
  const h = harness({ ops: { createWorker: async () => { throw new Error("quota exceeded"); } } });
  const result = await run(h.options);
  assert.equal(result.ok, false);
  assert.deepEqual(h.events.slice(-3), ["rm:true", "delete-worker", "deregister:77"]);
});

test("JIT mint failure with a known runner ID deregisters it; without one it looks it up by name", async () => {
  const withId = harness({ github: { mintJitRunner: async () => { const e = new Error("bad labels"); e.runnerId = 9; throw e; } } });
  assert.equal((await run(withId.options)).ok, false);
  assert.ok(withId.events.includes("deregister:9"));
  assert.ok(!withId.events.includes("create") && !withId.events.includes("delete-worker"));

  const noId = harness({ github: { mintJitRunner: async () => { throw new Error("network"); } } });
  assert.equal((await run(noId.options)).ok, false);
  assert.ok(noId.events.some((e) => e.startsWith("deregister-name:ghr-win-test-")));
});

test("Azure login failure creates and deletes nothing", async () => {
  const h = harness({ ops: { login: async () => { throw new Error("no identity"); } } });
  const result = await run(h.options);
  assert.equal(result.ok, false);
  assert.deepEqual(h.events, ["rm:false"]);
});

test("a failing worker delete does not skip runner deregistration and fails the run", async () => {
  const h = harness({ ops: { deleteWorker: async () => { throw new Error("delete locked"); } } });
  const result = await run(h.options);
  assert.equal(result.ok, false);
  assert.ok(h.events.includes("deregister:77"));
});

test("a janitor failure is logged but does not block the job", async () => {
  const h = harness({ ops: { listManaged: async () => { throw new Error("list failed"); } } });
  const result = await run(h.options);
  assert.equal(result.ok, true);
  assert.ok(h.logs.some((line) => line.includes("janitor-failed")));
});

test("secrets never appear in logs, even inside error messages", async () => {
  const h = harness({
    ops: {
      createWorker: async (args) => { throw new Error(`az failed with ${args.adminPassword} and ${env.GH_APP_PRIVATE_KEY}`); },
    },
    github: {
      deleteRunnerById: async () => { throw new Error("cleanup JIT-CONFIG-SECRET-VALUE"); },
    },
  });
  await run(h.options);
  const output = h.logs.join("\n");
  assert.ok(output.length > 0);
  for (const secret of ["Pa55-word-SECRET-xyz", "JIT-CONFIG-SECRET-VALUE", env.GH_APP_PRIVATE_KEY]) {
    assert.ok(!output.includes(secret), `leaked ${secret.slice(0, 6)}`);
  }
  assert.ok(output.includes("[redacted]"));
});

test("az errors echo only command words and redact secrets from stderr", async () => {
  const redactor = createRedactor();
  redactor.add("Pa55-word-SECRET-xyz");
  const az = createAzRunner({
    redact: redactor.redact,
    execFileImpl: (_cmd, _args, _options, callback) => callback(new Error("exit 1"), "", "bad request Pa55-word-SECRET-xyz ResourceNotFound"),
  });
  await assert.rejects(
    az(["vm", "create", "--admin-password", "Pa55-word-SECRET-xyz"]),
    (error) => error.notFound === true && !error.message.includes("Pa55-word-SECRET-xyz") && error.message.startsWith("az vm create"),
  );
});

test("GitHub client mints a repo-scoped JIT runner with only the custom label and never leaks tokens", async () => {
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const pem = privateKey.export({ type: "pkcs8", format: "pem" });
  const requests = [];
  const secrets = [];
  const fetchImpl = async (url, init) => {
    requests.push({ url, method: init.method, body: init.body ? JSON.parse(init.body) : undefined });
    if (url.endsWith("/access_tokens")) {
      return new Response(JSON.stringify({ token: "ghs_installation_token_value", expires_at: "2030-01-01T13:00:00Z" }), { status: 201 });
    }
    if (url.endsWith("/generate-jitconfig")) {
      return new Response(JSON.stringify({ runner: { id: 5, labels: [{ name: "ghr-win-test" }] }, encoded_jit_config: "ENCODED" }), { status: 201 });
    }
    return new Response("{}", { status: 404 });
  };
  const client = createGithubClient({
    appId: "1", installationId: "2", privateKey: pem, owner: "octo", repo: "repo",
    fetchImpl, now: () => now, sleep: async () => {}, onSecret: (s) => secrets.push(s),
  });
  const jit = await client.mintJitRunner({ name: "ghr-win-test-1", label: "ghr-win-test" });
  assert.deepEqual(jit, { runnerId: 5, encodedJitConfig: "ENCODED" });
  assert.deepEqual(requests[0].body, { repositories: ["repo"], permissions: { administration: "write" } });
  assert.deepEqual(requests[1].body.labels, ["ghr-win-test"]);
  assert.equal(requests[1].body.runner_group_id, 1);
  assert.ok(secrets.includes("ghs_installation_token_value") && secrets.includes("ENCODED"));
  assert.equal(await client.runnerExists(5), false);
  assert.equal(await client.deleteRunnerById(5), false);
});
