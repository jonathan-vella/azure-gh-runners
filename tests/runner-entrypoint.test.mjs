import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const root = path.resolve(import.meta.dirname, "..");
const script = fs.readFileSync(path.join(root, "image", "runner-entrypoint.sh"), "utf8");
const bash = spawnSync("bash", ["-c", "true"]).status === 0 && process.platform !== "win32";

test("entrypoint reads the fixed JIT path and execs run.sh", () => {
  assert.match(script, /^config_path=\/jit\/config$/m);
  assert.match(script, /^rm -f -- "\$config_path"$/m);
  assert.match(script, /^unset GH_APP_PRIVATE_KEY GH_APP_ID GH_APP_INSTALLATION_ID$/m);
  assert.match(script, /^exec \/home\/runner\/run\.sh --jitconfig "\$jit_config"$/m);
});

function runEntrypoint({ config }) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "runner-entrypoint-"));
  try {
    const configPath = path.join(directory, "config");
    const runPath = path.join(directory, "run.sh");
    const outputPath = path.join(directory, "output");
    if (config !== undefined) fs.writeFileSync(configPath, config, { mode: 0o400 });
    fs.writeFileSync(
      runPath,
      `#!/usr/bin/env bash\nprintf '%s|%s|%s|%s' "$*" "\${GH_APP_PRIVATE_KEY-unset}" "\${CONSUMER_POLICY_JSON-unset}" "$(test -e '${configPath}' && echo present || echo deleted)" > '${outputPath}'\n`,
      { mode: 0o755 },
    );
    const testScript = script.replace("/jit/config", configPath).replace("/home/runner/run.sh", runPath);
    const scriptPath = path.join(directory, "entrypoint.sh");
    fs.writeFileSync(scriptPath, testScript, { mode: 0o755 });
    const result = spawnSync("bash", [scriptPath], {
      encoding: "utf8",
      env: { PATH: process.env.PATH, GH_APP_PRIVATE_KEY: "secret", CONSUMER_POLICY_JSON: "{}" },
    });
    const output = fs.existsSync(outputPath) ? fs.readFileSync(outputPath, "utf8") : undefined;
    return { result, output };
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

test("entrypoint consumes and deletes the handoff before starting the runner", { skip: !bash }, () => {
  const { result, output } = runEntrypoint({ config: "encoded-config" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(output, "--jitconfig encoded-config|unset|{}|deleted");
});

test("entrypoint fails closed without a JIT config", { skip: !bash }, () => {
  const { result, output } = runEntrypoint({});
  assert.equal(result.status, 1);
  assert.match(result.stderr, /JIT runner configuration is missing/);
  assert.equal(output, undefined);
});
