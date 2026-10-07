const fs = require('node:fs');
const path = require('node:path');
const {
  getGitHubRepoMetadata,
  loadRegistry,
  validateRegistry,
} = require('./validate-consumers.js');

const root = path.resolve(__dirname, '..');
const consumersPath = path.join(root, 'config', 'consumers');
const outputPath = path.join(root, 'infra', 'generated', 'consumers.json');

function sortValues(values) {
  return [...values].sort((left, right) => (left < right ? -1 : left > right ? 1 : 0));
}

function normalizeConsumer(consumer) {
  const policy = {
    repository: consumer.repo,
    visibility: consumer.visibility,
    allowedEvents: sortValues(consumer.allowedEvents),
    allowedRefs: sortValues(consumer.allowedRefs),
    allowedWorkflows: sortValues(consumer.allowedWorkflows),
  };

  return {
    name: consumer.name,
    repo: consumer.repo,
    visibility: consumer.visibility,
    labels: sortValues(consumer.labels),
    cpu: consumer.cpu,
    memory: consumer.memory,
    maxExecutions: consumer.maxExecutions,
    replicaTimeoutSeconds: consumer.replicaTimeoutSeconds,
    policyJson: JSON.stringify(policy),
  };
}

function buildParameters(entries) {
  const consumers = entries
    .map(({ consumer }) => normalizeConsumer(consumer))
    .sort((left, right) => (left.name < right.name ? -1 : left.name > right.name ? 1 : 0));

  return {
    $schema: 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#',
    contentVersion: '1.0.0.0',
    parameters: {
      consumers: {
        value: consumers,
      },
    },
  };
}

function serializeParameters(entries) {
  return `${JSON.stringify(buildParameters(entries), null, 2)}\n`;
}

function writeAtomically(filePath, contents) {
  const directory = path.dirname(filePath);
  fs.mkdirSync(directory, { recursive: true });
  const temporaryDirectory = fs.mkdtempSync(path.join(directory, '.consumers-'));
  const temporaryPath = path.join(temporaryDirectory, path.basename(filePath));

  try {
    fs.writeFileSync(temporaryPath, contents, { encoding: 'utf8', mode: 0o644, flag: 'wx' });
    fs.renameSync(temporaryPath, filePath);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

function generateConsumers({
  check = false,
  directory = consumersPath,
  destination = outputPath,
  metadataProvider = getGitHubRepoMetadata,
} = {}) {
  const registry = loadRegistry(directory);
  const errors = [...registry.errors, ...validateRegistry(registry.entries, metadataProvider)];
  if (errors.length > 0) {
    throw new Error([
      `Consumer registry validation failed (${errors.length} error${errors.length === 1 ? '' : 's'}):`,
      ...errors.map((error) => `- ${error}`),
    ].join('\n'));
  }

  const expected = serializeParameters(registry.entries);
  if (check) {
    let actual;
    try {
      actual = fs.readFileSync(destination, 'utf8');
    } catch (error) {
      if (error.code === 'ENOENT') {
        throw new Error(`Generated consumers file is missing: ${path.relative(root, destination)}.`);
      }
      throw error;
    }
    if (actual.replace(/\r\n/g, '\n') !== expected) {
      throw new Error(`Generated consumers file is stale: ${path.relative(root, destination)}.`);
    }
    return;
  }

  writeAtomically(destination, expected);
}

function main(args) {
  if (args.some((arg) => arg !== '--check') || args.filter((arg) => arg === '--check').length > 1) {
    console.error('Usage: node tools/generate-consumers.js [--check]');
    process.exitCode = 2;
    return;
  }

  try {
    const check = args.includes('--check');
    generateConsumers({ check });
    console.log(check ? 'Generated consumer parameters are current.' : 'Generated consumer parameters.');
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

if (require.main === module) {
  main(process.argv.slice(2));
}

module.exports = { buildParameters, generateConsumers, normalizeConsumer, serializeParameters };
