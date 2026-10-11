const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const Ajv2020 = require("ajv/dist/2020");

const root = path.resolve(__dirname, "..");
const schema = JSON.parse(fs.readFileSync(path.join(root, "config", "schema", "consumer.v1.json"), "utf8"));
const sample = JSON.parse(fs.readFileSync(path.join(root, "config", "consumers", "example.json.sample"), "utf8"));
const acaSample = JSON.parse(fs.readFileSync(path.join(root, "config", "consumers", "example-aca.json.sample"), "utf8"));
const validate = new Ajv2020({ allErrors: true }).compile(schema);

function consumer(overrides) {
  return { ...sample, ...overrides };
}

const resourcePairs = Array.from({ length: 16 }, (_, index) => {
  const cpu = 0.25 * (index + 1);
  const memory = `${0.5 * (index + 1)}Gi`;
  return [`${cpu} vCPU / ${memory}`, consumer({ cpu, memory })];
});

const windowsSample = JSON.parse(fs.readFileSync(path.join(root, "config", "consumers", "smoke-windows.json"), "utf8"));

function windows(overrides) {
  return { ...windowsSample, ...overrides };
}

const validFixtures = [
  ["documented sample", sample],
  ["legacy sample without a backend", sample],
  ["explicit ACA backend", acaSample],
  ["Windows VMSS consumer", windowsSample],
  ["Windows VMSS consumer with default VM size", windows({ vmSize: undefined })],
  ["Windows VMSS limits at their bounds", windows({ maxRunners: 5, jobTimeoutMinutes: 360 })],
  ["Windows VMSS minimum limits", windows({ maxRunners: 1, jobTimeoutMinutes: 1 })],
  [
    "Windows VMSS acknowledged public pull request",
    windows({
      allowedEvents: ["workflow_dispatch", "pull_request"],
      acknowledgePublicPullRequestRisk: true
    })
  ],
  [
    "Windows VMSS private pull request without acknowledgement",
    windows({ visibility: "private", allowedEvents: ["workflow_dispatch", "pull_request"] })
  ],
  ...resourcePairs,
  ["minimum integer values", consumer({ maxExecutions: 1, replicaTimeoutSeconds: 1 })],
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
  ["VMSS backend without os", consumer({ backend: "vmss", cpu: undefined, memory: undefined, maxExecutions: undefined, replicaTimeoutSeconds: undefined, maxRunners: 1, jobTimeoutMinutes: 30 })],
  ["VMSS backend with ACA sizing fields", windows({ cpu: 1, memory: "2Gi" })],
  ["VMSS backend with ACA execution fields", windows({ maxExecutions: 1, replicaTimeoutSeconds: 60 })],
  ["VMSS backend with linux os", windows({ os: "linux" })],
  ["VMSS backend without maxRunners", windows({ maxRunners: undefined })],
  ["VMSS backend without jobTimeoutMinutes", windows({ jobTimeoutMinutes: undefined })],
  ["VMSS maxRunners of zero", windows({ maxRunners: 0 })],
  ["VMSS maxRunners above the cap", windows({ maxRunners: 6 })],
  ["VMSS timeout of zero", windows({ jobTimeoutMinutes: 0 })],
  ["VMSS timeout above the cap", windows({ jobTimeoutMinutes: 361 })],
  ["VMSS VM size outside the allowlist", windows({ vmSize: "Standard_E64s_v5" })],
  ["os windows without the VMSS backend", consumer({ os: "windows" })],
  ["os windows with explicit ACA backend", { ...acaSample, os: "windows" }],
  ["VMSS VM size on ACA", consumer({ vmSize: "Standard_D4ds_v5" })],
  ["VMSS acknowledgement on ACA", consumer({ allowedEvents: ["workflow_dispatch", "pull_request"], acknowledgePublicPullRequestRisk: true })],
  ["Windows VMSS public pull request without acknowledgement", windows({ allowedEvents: ["workflow_dispatch", "pull_request"] })],
  ["acknowledgement set to false", windows({ allowedEvents: ["pull_request"], acknowledgePublicPullRequestRisk: false })],
  ["acknowledgement without pull_request", windows({ acknowledgePublicPullRequestRisk: true })],
  ["acknowledgement on a private consumer", windows({ visibility: "private", allowedEvents: ["pull_request"], acknowledgePublicPullRequestRisk: true })],
  ["Windows VMSS pull_request_target", windows({ allowedEvents: ["pull_request_target"], acknowledgePublicPullRequestRisk: true })],
  ["Windows VMSS workflow_run", windows({ allowedEvents: ["workflow_run"], acknowledgePublicPullRequestRisk: true })],
  ["Windows VMSS public multiple refs", windows({ allowedRefs: ["refs/heads/main", "refs/heads/release"] })],
  ["VMSS SKU field", consumer({ vmSku: "Standard_D2ls_v5" })],
  ["VMSS runner limit field", consumer({ maxRunners: 1 })],
  ["VMSS job timeout field", consumer({ jobTimeoutMinutes: 60 })],
  ["missing ACA sizing", consumer({ cpu: undefined, memory: undefined })],
  ["missing max executions", consumer({ maxExecutions: undefined })],
  ["missing replica timeout", consumer({ replicaTimeoutSeconds: undefined })],
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
