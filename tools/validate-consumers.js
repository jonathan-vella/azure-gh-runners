const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const Ajv2020 = require('ajv/dist/2020');

const root = path.resolve(__dirname, '..');
const schemaPath = path.join(root, 'config', 'schema', 'consumer.v1.json');
const consumersPath = path.join(root, 'config', 'consumers');
const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
const validateSchema = new Ajv2020({ allErrors: true }).compile(schema);
const publicEvents = new Set(['workflow_dispatch', 'schedule', 'push']);
const forbiddenEvents = new Set(['pull_request_target', 'workflow_run']);
const defaultRunnerLabels = new Set([
  'self-hosted',
  'linux',
  'windows',
  'macos',
  'x64',
  'arm',
  'arm64',
]);

function loadRegistry(directory = consumersPath) {
  const entries = [];
  const errors = [];

  for (const filename of fs.readdirSync(directory).filter((name) => name.endsWith('.json')).sort()) {
    const filePath = path.join(directory, filename);
    try {
      entries.push({ filename, consumer: JSON.parse(fs.readFileSync(filePath, 'utf8')) });
    } catch (error) {
      errors.push(`${filename}: invalid JSON (${error.message}).`);
    }
  }

  return { entries, errors };
}

function classifyGitHubError(error) {
  const stderr = Buffer.isBuffer(error.stderr) ? error.stderr.toString('utf8') : String(error.stderr || '');

  if (error.code === 'ENOENT') {
    return 'GitHub CLI is not installed or is unavailable.';
  }
  if (/\bHTTP 401\b|requires authentication|authentication required/i.test(stderr)) {
    return 'GitHub authentication failed; authenticate with access to the registered repository.';
  }
  if (/\bHTTP 403\b|forbidden|resource not accessible/i.test(stderr)) {
    return 'GitHub denied access to the registered repository.';
  }
  if (/\bHTTP 404\b|not found/i.test(stderr)) {
    return 'Repository is unknown or inaccessible to the authenticated GitHub account.';
  }
  return 'GitHub repository lookup failed (network or API error).';
}

function getGitHubRepoMetadata(repo, execute = execFileSync) {
  let response;
  try {
    response = execute(
      'gh',
      ['api', `repos/${repo}`, '--jq', '{full_name, private, default_branch}'],
      {
        encoding: 'utf8',
        maxBuffer: 64 * 1024,
        stdio: ['ignore', 'pipe', 'pipe'],
        timeout: 30_000,
      },
    );
  } catch (error) {
    throw new Error(classifyGitHubError(error));
  }

  try {
    const metadata = JSON.parse(response);
    if (
      !metadata
      || typeof metadata.full_name !== 'string'
      || typeof metadata.private !== 'boolean'
      || typeof metadata.default_branch !== 'string'
      || metadata.default_branch.length === 0
    ) {
      throw new Error('GitHub returned incomplete repository metadata.');
    }
    return metadata;
  } catch (error) {
    if (error instanceof SyntaxError) {
      throw new Error('GitHub returned invalid repository metadata.');
    }
    throw error;
  }
}

function isValidBranchRef(ref) {
  if (typeof ref !== 'string' || !ref.startsWith('refs/heads/')) {
    return false;
  }
  try {
    execFileSync('git', ['check-ref-format', ref], { stdio: 'ignore', timeout: 5_000 });
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') {
      throw new Error('Git is required to validate branch refs.');
    }
    return false;
  }
}

function rememberUnique(map, value, filename, label, errors) {
  const normalized = value.toLowerCase();
  const previous = map.get(normalized);
  if (previous) {
    errors.push(`${filename}: ${label} "${value}" duplicates ${previous}.`);
  } else {
    map.set(normalized, `${filename} (${value})`);
  }
}

function workflowParts(workflow) {
  const match = /^([^/]+\/[^/]+)\/\.github\/workflows\/(.+)@refs\/heads\/(.+)$/.exec(workflow);
  if (!match) {
    return null;
  }
  const [, repo, workflowPath, branch] = match;
  const pathParts = workflowPath.split('/');
  if (
    !/\.(?:yml|yaml)$/i.test(workflowPath)
    || workflowPath.includes('/')
    || pathParts.some((part) => !part || part === '.' || part === '..')
    || /[@\x00-\x20\x7f\\]/.test(workflowPath)
  ) {
    return null;
  }
  return { repo, ref: `refs/heads/${branch}` };
}

function validateRegistry(entries, metadataProvider = getGitHubRepoMetadata) {
  const errors = [];
  const names = new Map();
  const repositories = new Map();
  const labels = new Map();
  const metadataCache = new Map();
  const refCache = new Map();

  function checkRef(ref) {
    if (!refCache.has(ref)) {
      refCache.set(ref, isValidBranchRef(ref));
    }
    return refCache.get(ref);
  }

  for (const { filename, consumer } of entries) {
    if (consumer && Array.isArray(consumer.allowedEvents)) {
      for (const event of consumer.allowedEvents) {
        if (forbiddenEvents.has(event)) {
          errors.push(`${filename}: event "${event}" is never allowed.`);
        } else if (
          consumer.visibility === 'public'
          && !publicEvents.has(event)
        ) {
          errors.push(`${filename}: public repositories cannot allow event "${event}".`);
        }
      }
    }

    if (!validateSchema(consumer)) {
      for (const issue of validateSchema.errors || []) {
        errors.push(`${filename}: schema ${issue.instancePath || '/'} ${issue.message}.`);
      }
      continue;
    }

    if (consumer.backend === 'vmss') {
      errors.push(
        `${filename}: backend "vmss" is schema-preparation only and cannot be used by the active registry until backend runtime support is implemented.`,
      );
      continue;
    }

    if (filename !== `${consumer.name}.json`) {
      errors.push(`${filename}: filename must be exactly "${consumer.name}.json".`);
    }

    rememberUnique(names, consumer.name, filename, 'consumer name', errors);
    rememberUnique(repositories, consumer.repo, filename, 'repository', errors);

    const localLabels = new Set();
    for (const label of consumer.labels) {
      const normalized = label.toLowerCase();
      if (defaultRunnerLabels.has(normalized)) {
        errors.push(`${filename}: label "${label}" is a GitHub default runner label, not a custom label.`);
      }
      if (localLabels.has(normalized)) {
        errors.push(`${filename}: label "${label}" duplicates another label in this consumer.`);
      } else {
        localLabels.add(normalized);
      }
      rememberUnique(labels, label, filename, 'runner label', errors);
    }
    if (!localLabels.has(`ghr-${consumer.name}`.toLowerCase())) {
      errors.push(`${filename}: labels must include the required custom label "ghr-${consumer.name}".`);
    }

    for (const ref of consumer.allowedRefs) {
      if (!checkRef(ref)) {
        errors.push(`${filename}: "${ref}" is not a valid Git branch ref.`);
      }
    }

    const cacheKey = consumer.repo.toLowerCase();
    if (!metadataCache.has(cacheKey)) {
      try {
        metadataCache.set(cacheKey, { metadata: metadataProvider(consumer.repo) });
      } catch (error) {
        metadataCache.set(cacheKey, { error: error.message });
      }
    }
    const lookup = metadataCache.get(cacheKey);
    if (lookup.error) {
      errors.push(`${filename}: could not verify ${consumer.repo}: ${lookup.error}`);
      continue;
    }

    const metadata = lookup.metadata;
    if (
      !metadata
      || typeof metadata.full_name !== 'string'
      || typeof metadata.private !== 'boolean'
      || typeof metadata.default_branch !== 'string'
      || metadata.default_branch.length === 0
    ) {
      errors.push(`${filename}: GitHub returned incomplete repository metadata for ${consumer.repo}.`);
      continue;
    }

    if (metadata.full_name.toLowerCase() !== consumer.repo.toLowerCase()) {
      errors.push(`${filename}: GitHub resolved ${consumer.repo} to a different repository.`);
    }

    const actualVisibility = metadata.private ? 'private' : 'public';
    if (consumer.visibility !== actualVisibility) {
      errors.push(
        `${filename}: declared visibility "${consumer.visibility}" does not match GitHub visibility "${actualVisibility}".`,
      );
    }

    const defaultRef = `refs/heads/${metadata.default_branch}`;
    if (!checkRef(defaultRef)) {
      errors.push(`${filename}: GitHub returned an invalid default branch for ${consumer.repo}.`);
    }
    if (
      consumer.visibility === 'public'
      && consumer.allowedRefs.some((ref) => ref !== defaultRef)
    ) {
      errors.push(`${filename}: public repositories may allow only the actual default branch "${defaultRef}".`);
    }

    for (const workflow of consumer.allowedWorkflows) {
      const parts = workflowParts(workflow);
      if (!parts) {
        errors.push(`${filename}: workflow "${workflow}" must be a .yml or .yaml file under .github/workflows.`);
        continue;
      }
      if (parts.repo.toLowerCase() !== consumer.repo.toLowerCase()) {
        errors.push(`${filename}: workflow "${workflow}" must belong to ${consumer.repo}.`);
      }
      if (!consumer.allowedRefs.includes(parts.ref)) {
        errors.push(`${filename}: workflow "${workflow}" uses a ref not listed in allowedRefs.`);
      }
      if (!checkRef(parts.ref)) {
        errors.push(`${filename}: workflow "${workflow}" contains an invalid Git branch ref.`);
      }
      if (consumer.visibility === 'public' && parts.ref !== defaultRef) {
        errors.push(`${filename}: public repository workflows must use the actual default branch "${defaultRef}".`);
      }
    }
  }

  return errors;
}

function main() {
  let registry;
  try {
    registry = loadRegistry();
  } catch (error) {
    console.error(`Consumer registry could not be read: ${error.message}`);
    process.exitCode = 1;
    return;
  }

  const errors = [...registry.errors, ...validateRegistry(registry.entries)];
  if (errors.length > 0) {
    console.error(`Consumer registry validation failed (${errors.length} error${errors.length === 1 ? '' : 's'}):`);
    for (const error of errors) {
      console.error(`- ${error}`);
    }
    process.exitCode = 1;
    return;
  }

  console.log(`Consumer registry is valid (${registry.entries.length} active consumer${registry.entries.length === 1 ? '' : 's'}).`);
}

if (require.main === module) {
  main();
}

module.exports = { getGitHubRepoMetadata, loadRegistry, validateRegistry };
