const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

const sample = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'config', 'consumers', 'example.json.sample'), 'utf8'),
);
const {
  getGitHubRepoMetadata,
  loadRegistry,
  validateRegistry,
} = require('../tools/validate-consumers.js');

const publicMetadata = {
  full_name: 'jonathan-vella/example',
  private: false,
  default_branch: 'main',
};

function entry(consumer = {}, filename = `${sample.name}.json`) {
  return { filename, consumer: { ...sample, ...consumer } };
}

function validate(entries, metadata = publicMetadata) {
  return validateRegistry(entries, () => metadata);
}

test('accepts a valid public consumer with additional custom labels', () => {
  const errors = validate([
    entry({ labels: ['ghr-example', 'private-network'] })
  ]);
  assert.deepEqual(errors, []);
});

test('accepts private pull requests and multiple valid branch refs', () => {
  const consumer = {
    ...sample,
    name: 'private-example',
    visibility: 'private',
    repo: 'jonathan-vella/private-example',
    labels: ['ghr-private-example'],
    allowedEvents: ['workflow_dispatch', 'pull_request'],
    allowedRefs: ['refs/heads/main', 'refs/heads/release/1.x'],
    allowedWorkflows: [
      'jonathan-vella/private-example/.github/workflows/ci.yml@refs/heads/main',
      'jonathan-vella/private-example/.github/workflows/release.yml@refs/heads/release/1.x',
    ],
  };
  assert.deepEqual(
    validateRegistry([{ filename: 'private-example.json', consumer }], () => ({
      ...publicMetadata,
      full_name: 'jonathan-vella/private-example',
      private: true,
    })),
    [],
  );
});

test('checks filename against the declared consumer name', () => {
  assert.match(validate([entry({}, 'another-name.json')]).join('\n'), /filename must be exactly "example\.json"/);
});

test('rejects declared visibility that differs from GitHub metadata', () => {
  const consumer = {
    ...sample,
    visibility: 'private',
    allowedEvents: ['workflow_dispatch', 'pull_request'],
  };
  const errors = validateRegistry(
    [{ filename: 'example.json', consumer }],
    () => publicMetadata,
  );
  assert.match(errors.join('\n'), /does not match GitHub visibility "public"/);
});

test('rejects a public pull request trigger in the registry policy', () => {
  const errors = validate([
    entry({ allowedEvents: ['workflow_dispatch', 'pull_request'] })
  ]);
  assert.match(errors.join('\n'), /public repositories cannot allow event "pull_request"/);
});

test('checks public refs against the actual GitHub default branch', () => {
  const errors = validate([entry()], { ...publicMetadata, default_branch: 'trunk' });
  assert.match(errors.join('\n'), /actual default branch "refs\/heads\/trunk"/);
});

test('rejects forbidden events for private consumers', () => {
  const consumer = {
    ...sample,
    visibility: 'private',
    allowedEvents: ['workflow_run'],
  };
  const errors = validateRegistry(
    [{ filename: 'example.json', consumer }],
    () => ({ ...publicMetadata, private: true }),
  );
  assert.match(errors.join('\n'), /event "workflow_run" is never allowed/);
});

test('rejects duplicate repository names and labels ignoring case', () => {
  const first = entry({
    labels: ['ghr-example', 'cache'],
    allowedWorkflows: ['jonathan-vella/example/.github/workflows/private-ci.yml@refs/heads/main'],
  });
  const second = entry({
    name: 'other',
    repo: 'JONATHAN-VELLA/EXAMPLE',
    labels: ['ghr-other', 'CACHE'],
    allowedWorkflows: ['JONATHAN-VELLA/EXAMPLE/.github/workflows/private-ci.yml@refs/heads/main'],
  }, 'other.json');
  const errors = validate([first, second]);
  assert.match(errors.join('\n'), /repository "JONATHAN-VELLA\/EXAMPLE" duplicates/);
  assert.match(errors.join('\n'), /runner label "CACHE" duplicates/);
});

test('rejects duplicate names and labels within a consumer ignoring case', () => {
  const consumer = {
    ...sample,
    labels: ['ghr-example', 'GHR-EXAMPLE'],
  };
  const errors = validateRegistry(
    [
      { filename: 'example.json', consumer },
      entry({}, 'example-copy.json'),
    ],
    () => publicMetadata,
  );
  assert.match(errors.join('\n'), /label "GHR-EXAMPLE" duplicates another label/);
  assert.match(errors.join('\n'), /consumer name "example" duplicates/);
});

test('requires the named ghr label and rejects GitHub default labels', () => {
  const errors = validate([
    entry({ labels: ['linux', 'ghr-other'] })
  ]);
  assert.match(errors.join('\n'), /GitHub default runner label/);
  assert.match(errors.join('\n'), /required custom label "ghr-example"/);
});

test('requires workflow references to match the declared repository and allowlist', () => {
  const errors = validate([
    entry({
      allowedWorkflows: [
        'other-owner/example/.github/workflows/ci.yml@refs/heads/main',
        'jonathan-vella/example/.github/workflows/ci.yml@refs/heads/release',
      ],
    })
  ]);
  assert.match(errors.join('\n'), /must belong to jonathan-vella\/example/);
  assert.match(errors.join('\n'), /uses a ref not listed in allowedRefs/);
});

test('rejects repository metadata that resolves to a different repository', () => {
  const errors = validate([entry()], { ...publicMetadata, full_name: 'another-owner/example' });
  assert.match(errors.join('\n'), /resolved jonathan-vella\/example to a different repository/);
});

test('rejects malformed Git branch refs and workflow paths', () => {
  const errors = validate([
    entry({
      allowedRefs: ['refs/heads/bad..branch'],
      allowedWorkflows: [
        'jonathan-vella/example/.github/workflows/../ci.yml@refs/heads/bad..branch',
        'jonathan-vella/example/.github/workflows/nested/ci.yml@refs/heads/main',
        'jonathan-vella/example/.github/workflows/ci file.yml@refs/heads/main',
      ],
    })
  ]);
  assert.match(errors.join('\n'), /not a valid Git branch ref/);
  assert.match(errors.join('\n'), /must be a \.yml or \.yaml file under \.github\/workflows/);
});

test('looks up repository metadata only once per case-insensitive repository', () => {
  const calls = [];
  const second = entry({ name: 'other', labels: ['ghr-other'] }, 'other.json');
  const errors = validateRegistry(
    [entry(), { ...second, consumer: { ...second.consumer, repo: 'JONATHAN-VELLA/EXAMPLE' } }],
    (repo) => {
      calls.push(repo);
      return publicMetadata;
    },
  );
  assert.equal(calls.length, 1);
  assert.match(errors.join('\n'), /repository "JONATHAN-VELLA\/EXAMPLE" duplicates/);
});

test('reports unknown repository, authentication, and network lookup failures without echoing raw errors', () => {
  const cases = [
    [{ stderr: Buffer.from('gh: Not Found (HTTP 404)') }, /unknown or inaccessible/],
    [{ stderr: Buffer.from('gh: Requires authentication (HTTP 401)') }, /authentication failed/],
    [{ stderr: Buffer.from('socket timeout; token=secret-value') }, /network or API error/],
  ];

  for (const [failure, expected] of cases) {
    assert.throws(
      () => getGitHubRepoMetadata('owner/repo', () => { throw failure; }),
      (error) => {
        assert.match(error.message, expected);
        assert.doesNotMatch(error.message, /secret-value/);
        return true;
      },
    );
  }
});

test('uses a bounded GitHub metadata request and validates its response shape', () => {
  let actualArguments;
  let actualOptions;
  const metadata = getGitHubRepoMetadata('owner/repo', (command, args, options) => {
    assert.equal(command, 'gh');
    actualArguments = args;
    actualOptions = options;
    return JSON.stringify({
      full_name: 'owner/repo',
      private: false,
      default_branch: 'main',
    });
  });

  assert.deepEqual(metadata, {
    full_name: 'owner/repo',
    private: false,
    default_branch: 'main',
  });
  assert.deepEqual(actualArguments, [
    'api',
    'repos/owner/repo',
    '--jq',
    '{full_name, private, default_branch}',
  ]);
  assert.equal(actualOptions.timeout, 30_000);
  assert.equal(actualOptions.maxBuffer, 64 * 1024);
});

test('ignores samples and non-JSON files when loading active consumers', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ghr-consumers-'));
  try {
    fs.writeFileSync(path.join(directory, 'example.json.sample'), JSON.stringify(sample));
    fs.writeFileSync(path.join(directory, '.gitkeep'), '');
    fs.writeFileSync(path.join(directory, 'notes.txt'), 'not an active registry entry');
    assert.deepEqual(loadRegistry(directory), { entries: [], errors: [] });
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
