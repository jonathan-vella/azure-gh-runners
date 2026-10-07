const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const Ajv2020 = require("ajv/dist/2020");

const root = path.resolve(__dirname, "..");
const schema = JSON.parse(fs.readFileSync(path.join(root, "config", "schema", "consumer.v1.json"), "utf8"));
const sample = JSON.parse(fs.readFileSync(path.join(root, "config", "consumers", "example.json.sample"), "utf8"));
const validate = new Ajv2020({ allErrors: true }).compile(schema);

function consumer(overrides) {
  return { ...sample, ...overrides };
}

const validFixtures = [
  ["documented sample", sample],
  ["minimum resource pair", consumer({ cpu: 0.25, memory: "0.5Gi" })],
  ["maximum resource pair", consumer({ cpu: 4, memory: "8Gi" })],
  ["minimum integer values", consumer({ maxExecutions: 1, replicaTimeoutSeconds: 1 })],
  [
    "private pull request opt-in",
    consumer({ visibility: "private", allowedEvents: ["workflow_dispatch", "pull_request"] })
  ],
  ["private multiple branch refs", consumer({ visibility: "private", allowedRefs: ["refs/heads/main", "refs/heads/release"] })]
];

const invalidFixtures = [
  ["mismatched CPU and memory", consumer({ cpu: 0.75, memory: "1Gi" })],
  ["resources above the platform cap", consumer({ cpu: 4.25, memory: "8.5Gi" })],
  ["zero concurrent executions", consumer({ maxExecutions: 0 })],
  ["zero replica timeout", consumer({ replicaTimeoutSeconds: 0 })],
  ["public pull request", consumer({ allowedEvents: ["workflow_dispatch", "pull_request"] })],
  ["forbidden pull_request_target", consumer({ allowedEvents: ["pull_request_target"] })],
  ["forbidden workflow_run", consumer({ allowedEvents: ["workflow_run"] })],
  ["public multiple refs", consumer({ allowedRefs: ["refs/heads/main", "refs/heads/release"] })],
  ["unknown property", consumer({ unexpected: true })],
  ["missing required property", consumer({ labels: undefined })],
  ["repository without owner/name", consumer({ repo: "example" })]
];

for (const [name, fixture] of validFixtures) {
  test(`accepts ${name}`, () => {
    assert.equal(validate(fixture), true, JSON.stringify(validate.errors, null, 2));
  });
}

for (const [name, fixture] of invalidFixtures) {
  test(`rejects ${name}`, () => {
    assert.equal(validate(fixture), false);
  });
}
