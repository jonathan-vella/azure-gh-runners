import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const read = name => readFileSync(new URL(name, import.meta.url), 'utf8');
const workflow = read('../../../.github/workflows/spike-vmss-flex.yml');
const execution = read('../Execution.psm1');

test('spike workflow is disabled, owner/main-only, non-replayable and SHA-pinned', () => {
  assert.match(workflow, /github\.run_attempt == 1/);
  assert.match(workflow, /github\.actor == 'jonathan-vella'/);
  assert.match(workflow, /github\.ref == 'refs\/heads\/main'/);
  assert.match(workflow, /vars\.GHR_SPIKE60_EXECUTION_ENABLED == 'true'/);
  assert.doesNotMatch(workflow, /secrets\.GH_APP_PRIVATE_KEY/);
  assert.doesNotMatch(workflow, /GH_APP_PRIVATE_KEY:/);
  assert.equal((workflow.match(/environment: platform-prod/g) ?? []).length, 3);
  for (const action of workflow.matchAll(/uses: ([^\s]+)/g)) {
    assert.match(action[1], /@[a-f0-9]{40}$/);
  }
  assert.match(workflow, /npm run validate/);
  assert.doesNotMatch(workflow, /upload.*secure-|path:.*\/vmss60\/$/m);
});

test('independent supervisor authority and active cleanup step precede execution', () => {
  assert.match(workflow, /name -CEQ 'deadline-cleanup'/);
  assert.match(workflow, /'Verify exact cleanup authorization'.*'success'/);
  assert.match(workflow, /'Independent original-deadline cleanup on a separate hosted runner'.*'in_progress'/);
  assert.match(read('../Supervisor.ps1'), /finally[\s\S]*Remove-OwnedSpike/);
  assert.match(read('../Run.ps1'), /finally[\s\S]*Remove-OwnedSpike/);
});

test('executor has no role writes, includes inherited roles and checks retained dispatch history', () => {
  assert.doesNotMatch(execution, /'role', 'assignment', 'create'|'group', 'create'|'deployment', 'group', 'create'/);
  assert.equal((execution.match(/--include-inherited/g) ?? []).length, 2);
  assert.match(execution, /9980e02c-c2be-4d73-94e8-173b1dc7cf3c/);
  assert.match(execution, /4d97b98b-1d4f-4787-a291-c67834d212e7/);
  assert.match(execution, /This full-run ordinal already dispatched/);
  assert.match(execution, /Reviewed smoke workflow absent\/inaccessible/);
  assert.match(execution, /function Test-SpikeControllerRoleAssignments/);
  assert.match(execution, /function Assert-SpikeKeyVaultAvailable/);
  assert.match(execution, /runOrdinal = \$Manifest\.runOrdinal/);
  assert.match(execution, /keyVaultSoftDeleteRetentionInDays\.value -ne \$Manifest\.keyVaultSoftDeleteRetentionInDays/);
  assert.match(execution, /keyVaultPurgeProtectionEnabled\.value -ne \$Manifest\.keyVaultPurgeProtectionEnabled/);
});
