const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const Ajv2020 = require("ajv/dist/2020");

const root = path.resolve(__dirname, "..");
const schema = JSON.parse(fs.readFileSync(path.join(root, "config", "schema", "consumer.v1.json"), "utf8"));
const sample = JSON.parse(fs.readFileSync(path.join(root, "config", "consumers", "example.json.sample"), "utf8"));
const acaSample = JSON.parse(fs.readFileSync(path.join(root, "config", "consumers", "example-aca.json.sample"), "utf8"));
const vmssSample = JSON.parse(fs.readFileSync(path.join(root, "config", "consumers", "example-vmss.json.sample"), "utf8"));
const validate = new Ajv2020({ allErrors: true }).compile(schema);

function consumer(overrides) {
  return { ...sample, ...overrides };
}

const resourcePairs = Array.from({ length: 16 }, (_, index) => {
  const cpu = 0.25 * (index + 1);
  const memory = `${0.5 * (index + 1)}Gi`;
  return [`${cpu} vCPU / ${memory}`, consumer({ cpu, memory })];
});

const validFixtures = [
  ["documented sample", sample],
  ["legacy sample without a backend", sample],
  ["explicit ACA backend", acaSample],
  ["explicit VMSS backend", vmssSample],
  ...resourcePairs,
  ["minimum integer values", consumer({ maxExecutions: 1, replicaTimeoutSeconds: 1 })],
  ["minimum VMSS sizing values", consumer({
    backend: "vmss",
    vmSku: "Standard_D2ls_v5",
    maxRunners: 1,
    jobTimeoutMinutes: 1
  })],
  [
    "private pull request opt-in",
    consumer({ visibility: "private", allowedEvents: ["workflow_dispatch", "pull_request"] })
  ],
  [
    "private multiple branch refs",
    consumer({ visibility: "private", allowedRefs: ["refs/heads/main", "refs/heads/release"] })
  ]
];

const invalidFixtures = [
  ["mismatched CPU and memory", consumer({ cpu: 0.75, memory: "1Gi" })],
  ["resources above the platform cap", consumer({ cpu: 4.25, memory: "8.5Gi" })],
  ["zero concurrent executions", consumer({ maxExecutions: 0 })],
  ["zero replica timeout", consumer({ replicaTimeoutSeconds: 0 })],
  ["unknown backend", consumer({ backend: "container-apps" })],
  ["VMSS fields without an explicit backend", consumer({ vmSku: "Standard_D2ls_v5" })],
  ["ACA backend with VMSS fields", consumer({ backend: "aca", vmSku: "Standard_D2ls_v5" })],
  ["ACA backend with VMSS runner limit", consumer({ backend: "aca", maxRunners: 1 })],
  ["ACA backend with VMSS job timeout", consumer({ backend: "aca", jobTimeoutMinutes: 60 })],
  ["VMSS missing SKU", consumer({ backend: "vmss", maxRunners: 1, jobTimeoutMinutes: 60 })],
  ["VMSS missing runner limit", consumer({ backend: "vmss", vmSku: "Standard_D2ls_v5", jobTimeoutMinutes: 60 })],
  ["VMSS missing job timeout", consumer({ backend: "vmss", vmSku: "Standard_D2ls_v5", maxRunners: 1 })],
  ["unapproved VMSS SKU", consumer({
    backend: "vmss",
    vmSku: "Standard_D2s_v5",
    maxRunners: 1,
    jobTimeoutMinutes: 60
  })],
  ["zero VMSS runners", consumer({
    backend: "vmss",
    vmSku: "Standard_D2ls_v5",
    maxRunners: 0,
    jobTimeoutMinutes: 60
  })],
  ["VMSS runner limit above platform cap", consumer({
    backend: "vmss",
    vmSku: "Standard_D2ls_v5",
    maxRunners: 3,
    jobTimeoutMinutes: 60
  })],
  ["zero VMSS job timeout", consumer({
    backend: "vmss",
    vmSku: "Standard_D2ls_v5",
    maxRunners: 1,
    jobTimeoutMinutes: 0
  })],
  ["VMSS job timeout above platform cap", consumer({
    backend: "vmss",
    vmSku: "Standard_D2ls_v5",
    maxRunners: 1,
    jobTimeoutMinutes: 361
  })],
  ["public pull request", consumer({ allowedEvents: ["workflow_dispatch", "pull_request"] })],
  ["forbidden pull_request_target", consumer({ allowedEvents: ["pull_request_target"] })],
  ["forbidden workflow_run", consumer({ allowedEvents: ["workflow_run"] })],
  ["public multiple refs", consumer({ allowedRefs: ["refs/heads/main", "refs/heads/release"] })],
  ["duplicate labels", consumer({ labels: ["ghr-example", "ghr-example"] })],
  ["duplicate events", consumer({ allowedEvents: ["push", "push"] })],
  ["duplicate refs", consumer({ allowedRefs: ["refs/heads/main", "refs/heads/main"] })],
  [
    "duplicate workflows",
    consumer({
      allowedWorkflows: [
        "jonathan-vella/example/.github/workflows/private-ci.yml@refs/heads/main",
        "jonathan-vella/example/.github/workflows/private-ci.yml@refs/heads/main"
      ]
    })
  ],
  ["malformed branch ref", consumer({ allowedRefs: ["refs/tags/v1"] })],
  [
    "malformed workflow path",
    consumer({ allowedWorkflows: ["jonathan-vella/example/workflows/private-ci.yml@refs/heads/main"] })
  ],
  [
    "malformed workflow ref",
    consumer({ allowedWorkflows: ["jonathan-vella/example/.github/workflows/private-ci.yml@refs/tags/v1"] })
  ],
  ["unknown property", consumer({ unexpected: true })],
  ["missing required property", consumer({ labels: undefined })],
  ["repository without owner/name", consumer({ repo: "example" })]
];

for (const [name, fixture] of validFixtures) {
  test(`accepts ${name}`, () => {
    assert.equal(validate(fixture), true, JSON.stringify(validate.errors, null, 2));
  });
}

test("backend remains optional and has no schema default", () => {
  assert.equal(Object.hasOwn(sample, "backend"), false);
  assert.equal(Object.hasOwn(schema.properties.backend, "default"), false);
});

for (const [name, fixture] of invalidFixtures) {
  test(`rejects ${name}`, () => {
    assert.equal(validate(fixture), false);
  });
}
