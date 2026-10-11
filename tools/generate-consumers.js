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
const windowsFilename = 'windows-consumers.json';

function sortValues(values) {
  return [...values].sort((left, right) => (left < right ? -1 : left > right ? 1 : 0));
}

function isWindows(consumer) {
  return consumer.backend === 'vmss';
}

function normalizePolicy(consumer) {
  return {
    repository: consumer.repo,
    visibility: consumer.visibility,
    allowedEvents: sortValues(consumer.allowedEvents),
    allowedRefs: sortValues(consumer.allowedRefs),
    allowedWorkflows: sortValues(consumer.allowedWorkflows),
  };
}

function normalizeConsumer(consumer) {
  const policy = normalizePolicy(consumer);

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

function normalizeWindowsConsumer(consumer) {
  const [owner, repo] = consumer.repo.split('/');
  return {
    name: consumer.name,
    owner,
    repo,
    label: `ghr-${consumer.name}`,
    vmSize: consumer.vmSize || 'Standard_D4ds_v5',
    maxRunners: consumer.maxRunners,
    jobTimeoutMinutes: consumer.jobTimeoutMinutes,
    policy: normalizePolicy(consumer),
  };
}

function byName(left, right) {
  return left.name < right.name ? -1 : left.name > right.name ? 1 : 0;
}

function buildParameters(entries) {
  const consumers = entries
    .filter(({ consumer }) => !isWindows(consumer))
    .map(({ consumer }) => normalizeConsumer(consumer))
    .sort(byName);

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

function buildWindowsConsumers(entries) {
  return entries
    .filter(({ consumer }) => isWindows(consumer))
    .map(({ consumer }) => normalizeWindowsConsumer(consumer))
    .sort(byName);
}

function serializeParameters(entries) {
  return `${JSON.stringify(buildParameters(entries), null, 2)}\n`;
}

function serializeWindowsConsumers(entries) {
  return `${JSON.stringify(buildWindowsConsumers(entries), null, 2)}\n`;
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

function readExpected(filePath, expected, description) {
  let actual;
  try {
    actual = fs.readFileSync(filePath, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') {
      throw new Error(`Generated ${description} file is missing: ${path.relative(root, filePath)}.`);
    }
    throw error;
  }
  if (actual.replace(/\r\n/g, '\n') !== expected) {
    throw new Error(`Generated ${description} file is stale: ${path.relative(root, filePath)}.`);
  }
}

function generateConsumers({
  check = false,
  directory = consumersPath,
  destination = outputPath,
  windowsDestination = path.join(path.dirname(destination), windowsFilename),
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
  const expectedWindows = serializeWindowsConsumers(registry.entries);
  if (check) {
    readExpected(destination, expected, 'consumers');
    readExpected(windowsDestination, expectedWindows, 'Windows consumers');
    return;
  }

  writeAtomically(destination, expected);
  writeAtomically(windowsDestination, expectedWindows);
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

module.exports = {
  buildParameters,
  buildWindowsConsumers,
  generateConsumers,
  normalizeConsumer,
  serializeParameters,
  serializeWindowsConsumers,
};
