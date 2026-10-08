const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

const samplePath = path.join(__dirname, '..', 'config', 'consumers', 'example.json.sample');
const sample = JSON.parse(fs.readFileSync(samplePath, 'utf8'));
const {
  buildParameters,
  generateConsumers,
} = require('../tools/generate-consumers.js');

const metadata = {
  full_name: sample.repo,
  private: false,
  default_branch: 'main',
};

function withDirectory(callback) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ghr-generator-'));
  try {
    callback(directory);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

function writeConsumers(directory, consumers) {
  fs.mkdirSync(directory, { recursive: true });
  for (const [filename, consumer] of consumers) {
    fs.writeFileSync(path.join(directory, filename), JSON.stringify(consumer), 'utf8');
  }
}

function provider(repo) {
  assert.equal(repo.toLowerCase(), sample.repo.toLowerCase());
  return metadata;
}

test('emits an ARM parameters document with the exact normalized hook policy', () => {
  const document = buildParameters([{ filename: 'example.json', consumer: sample }]);
  assert.equal(
    document.$schema,
    'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#',
  );
  assert.equal(document.contentVersion, '1.0.0.0');
  assert.deepEqual(Object.keys(document.parameters), ['consumers']);

  const [consumer] = document.parameters.consumers.value;
  assert.deepEqual(Object.keys(consumer), [
    'name',
    'repo',
    'visibility',
    'labels',
    'cpu',
    'memory',
    'maxExecutions',
    'replicaTimeoutSeconds',
    'policyJson',
  ]);
  assert.equal(consumer.name, sample.name);
  assert.equal(consumer.cpu, sample.cpu);
  assert.equal(consumer.maxExecutions, sample.maxExecutions);
  assert.equal(typeof consumer.policyJson, 'string');
  assert.deepEqual(JSON.parse(consumer.policyJson), {
    repository: sample.repo,
    visibility: sample.visibility,
    allowedEvents: ['push', 'schedule', 'workflow_dispatch'],
    allowedRefs: ['refs/heads/main'],
    allowedWorkflows: sample.allowedWorkflows,
  });
  assert.equal(Object.hasOwn(JSON.parse(consumer.policyJson), 'default_branch'), false);
  assert.equal(Object.hasOwn(consumer, 'notes'), false);
});

test('explicit ACA generation is identical to legacy generation', () => {
  withDirectory((directory) => {
    const registry = path.join(directory, 'registry');
    const output = path.join(directory, 'generated', 'consumers.json');
    writeConsumers(registry, [['example.json', sample]]);
    generateConsumers({ directory: registry, destination: output, metadataProvider: provider });
    const legacy = fs.readFileSync(output, 'utf8');

    writeConsumers(registry, [['example.json', { ...sample, backend: 'aca' }]]);
    generateConsumers({ directory: registry, destination: output, metadataProvider: provider });
    assert.equal(fs.readFileSync(output, 'utf8'), legacy);
  });
});

test('normalizes consumers and set-valued fields independent of source ordering', () => {
  const reordered = {
    ...sample,
    allowedEvents: [...sample.allowedEvents].reverse(),
    allowedRefs: [...sample.allowedRefs].reverse(),
    allowedWorkflows: [...sample.allowedWorkflows].reverse(),
    labels: [...sample.labels].reverse(),
  };
  const first = buildParameters([{ filename: 'example.json', consumer: sample }]);
  const second = buildParameters([{ filename: 'example.json', consumer: reordered }]);
  assert.deepEqual(second, first);

  const another = {
    ...sample,
    name: 'another',
    repo: 'jonathan-vella/another',
    labels: ['ghr-another'],
    allowedWorkflows: ['jonathan-vella/another/.github/workflows/ci.yml@refs/heads/main'],
  };
  const sorted = buildParameters([
    { filename: 'example.json', consumer: sample },
    { filename: 'another.json', consumer: another },
  ]);
  assert.deepEqual(
    sorted.parameters.consumers.value.map(({ name }) => name),
    ['another', 'example'],
  );
});

test('generates a valid empty-registry parameters document without metadata lookups', () => {
  withDirectory((directory) => {
    const registry = path.join(directory, 'registry');
    fs.mkdirSync(registry, { recursive: true });
    const output = path.join(directory, 'generated', 'consumers.json');
    let metadataCalls = 0;
    generateConsumers({
      directory: registry,
      destination: output,
      metadataProvider: () => {
        metadataCalls += 1;
        throw new Error('unexpected metadata lookup');
      },
    });

    const document = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.deepEqual(document.parameters.consumers.value, []);
    assert.equal(metadataCalls, 0);
  });
});

test('drift check rejects missing and stale artifacts without creating or modifying them', () => {
  withDirectory((directory) => {
    const registry = path.join(directory, 'registry');
    const output = path.join(directory, 'generated', 'consumers.json');
    writeConsumers(registry, [['example.json', sample]]);

    assert.throws(
      () => generateConsumers({ check: true, directory: registry, destination: output, metadataProvider: provider }),
      /file is missing/,
    );
    assert.equal(fs.existsSync(output), false);

    fs.mkdirSync(path.dirname(output), { recursive: true });
    fs.writeFileSync(output, 'stale contents\n', 'utf8');
    assert.throws(
      () => generateConsumers({ check: true, directory: registry, destination: output, metadataProvider: provider }),
      /file is stale/,
    );
    assert.equal(fs.readFileSync(output, 'utf8'), 'stale contents\n');

    generateConsumers({ directory: registry, destination: output, metadataProvider: provider });
    assert.deepEqual(
      JSON.parse(fs.readFileSync(output, 'utf8')).parameters.consumers.value.map(({ name }) => name),
      ['example'],
    );

    const generated = fs.readFileSync(output, 'utf8');
    fs.writeFileSync(output, generated.replace(/\n/g, '\r\n'), 'utf8');
    generateConsumers({
      check: true,
      directory: registry,
      destination: output,
      metadataProvider: provider,
    });
    assert.equal(fs.readFileSync(output, 'utf8'), generated.replace(/\n/g, '\r\n'));
  });
});

test('refuses invalid JSON, schema violations, and policy violations without replacing output', () => {
  withDirectory((directory) => {
    const registry = path.join(directory, 'registry');
    const output = path.join(directory, 'generated', 'consumers.json');
    fs.mkdirSync(registry, { recursive: true });
    fs.mkdirSync(path.dirname(output), { recursive: true });
    fs.writeFileSync(output, 'preserve this\n', 'utf8');

    fs.writeFileSync(path.join(registry, 'example.json'), '{invalid', 'utf8');
    assert.throws(
      () => generateConsumers({ directory: registry, destination: output, metadataProvider: provider }),
      /invalid JSON/,
    );
    assert.equal(fs.readFileSync(output, 'utf8'), 'preserve this\n');

    fs.writeFileSync(
      path.join(registry, 'example.json'),
      JSON.stringify({ ...sample, unknown: true }),
      'utf8',
    );
    assert.throws(
      () => generateConsumers({ directory: registry, destination: output, metadataProvider: provider }),
      /schema/,
    );
    assert.equal(fs.readFileSync(output, 'utf8'), 'preserve this\n');

    fs.writeFileSync(
      path.join(registry, 'example.json'),
      JSON.stringify({ ...sample, allowedEvents: ['workflow_dispatch', 'pull_request'] }),
      'utf8',
    );
    assert.throws(
      () => generateConsumers({ directory: registry, destination: output, metadataProvider: provider }),
      /public repositories cannot allow event "pull_request"/,
    );
    assert.equal(fs.readFileSync(output, 'utf8'), 'preserve this\n');
  });
});

test('refuses VMSS consumers without writing deployment parameters', () => {
  withDirectory((directory) => {
    const registry = path.join(directory, 'registry');
    const output = path.join(directory, 'generated', 'consumers.json');
    writeConsumers(registry, [['example.json', { ...sample, backend: 'vmss' }]]);

    assert.throws(
      () => generateConsumers({ directory: registry, destination: output, metadataProvider: provider }),
      /backend "vmss" is not supported in v1/,
    );
    assert.equal(fs.existsSync(output), false);
  });
});

test('fails closed on registry path and GitHub metadata errors', () => {
  withDirectory((directory) => {
    const output = path.join(directory, 'generated', 'consumers.json');
    assert.throws(
      () => generateConsumers({
        directory: path.join(directory, 'missing-registry'),
        destination: output,
      }),
      /ENOENT/,
    );
    assert.equal(fs.existsSync(output), false);

    const registry = path.join(directory, 'registry');
    writeConsumers(registry, [['example.json', sample]]);
    assert.throws(
      () => generateConsumers({
        directory: registry,
        destination: output,
        metadataProvider: () => { throw new Error('repository lookup failed'); },
      }),
      /could not verify jonathan-vella\/example: repository lookup failed/,
    );
    assert.equal(fs.existsSync(output), false);
  });
});
