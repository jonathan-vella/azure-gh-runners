import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import test from "node:test";

const require = createRequire(import.meta.url);
const yaml = require("js-yaml");

const workflowPath = new URL("../../../.github/workflows/spike-jit-labels-deploy.yml", import.meta.url);
const source = await readFile(workflowPath, "utf8");
const workflow = yaml.load(source);
const deployJob = workflow.jobs.deploy;

test("deployment has reserved setup, observation, cleanup, and final job timeouts", () => {
  const deployStep = deployJob.steps.find((step) => step.name === "Validate scope, region, network and private dependencies; deploy job");
  const observeStep = deployJob.steps.find((step) => step.name === "Keep scaler available for the bounded observation window");
  const cleanupStep = deployJob.steps.find((step) => step.name === "Remove only the job created by this workflow run");

  assert.equal(deployStep["timeout-minutes"], 30);
  assert.equal(observeStep["timeout-minutes"], 50);
  assert.equal(cleanupStep["timeout-minutes"], 10);
  assert.equal(deployJob["timeout-minutes"], 105);
  assert.match(observeStep.run, /OBSERVATION_WINDOW_MINUTES \* 60/);
  assert.match(deployStep.run, /AZ_COMMAND_TIMEOUT_SECONDS=900/);
});

test("every deployment and cleanup Azure CLI invocation is behind coreutils timeout", () => {
  const scripts = deployJob.steps.filter((step) => step.run).map((step) => step.run);
  const azLines = scripts.flatMap((script) => script.split(/\r?\n/))
    .filter((line) => /(?:^|[;&|()]|\$\()\s*az\s/.test(line) || /\btimeout\b.*\baz\s/.test(line));

  assert.ok(azLines.length > 0, "workflow should contain Azure CLI calls");
  for (const line of azLines) {
    assert.match(line, /\btimeout\b.*\baz\s/, `unbounded Azure CLI invocation: ${line.trim()}`);
  }
});
