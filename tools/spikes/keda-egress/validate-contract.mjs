import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (path) => readFileSync(path, 'utf8');
const workflow = read('.github/workflows/spike-keda-egress.yml');
const runner = read('tools/spikes/keda-egress/run.ps1');
const bootstrap = read('tools/spikes/keda-egress/bootstrap.ps1');
const oidc = read('tools/spikes/keda-egress/oidc-claims.ps1');
const secretTemplate = read('tools/spikes/keda-egress/secret.bicep');
const synthetic = read('.github/workflows/spike8-queued-probe.yml');
const processModule = read('tools/spikes/keda-egress/Process.psm1');
const lifecycleModule = read('tools/spikes/keda-egress/Lifecycle.psm1');
const functionalTests = read('tools/spikes/keda-egress/test-harness.ps1');
const expectedSubject =
  'repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:platform-prod';

assert.match(workflow, /if: github\.ref == 'refs\/heads\/main'/);
assert.match(workflow, /environment: platform-prod/);
assert.match(workflow, /capacity_recovered:[\s\S]*confirmed-recovered/);
assert.match(workflow, /Require operator confirmation of recovered regional capacity[\s\S]*until the issue #7 swedencentral capacity blocker is confirmed resolved/);
assert.match(workflow, /- oidc-preflight[\s\S]*- test/);
assert.match(workflow, /client-id: \$\{\{ secrets\.AZURE_SPIKE8_CLIENT_ID \}\}/);
assert.match(workflow, /if: inputs\.mode == 'oidc-preflight'[\s\S]*oidc-claims\.ps1/);
assert.match(workflow, /if: always\(\) && inputs\.mode == 'test' && steps\.azure-login\.outcome == 'success'/);

const actionPins = [...workflow.matchAll(/uses:\s+[^@\s]+@([^\s]+)/g)].map((match) => match[1]);
assert.equal(actionPins.length, 3, 'all external workflow actions must be pinned');
assert.ok(actionPins.every((pin) => /^[0-9a-f]{40}$/i.test(pin)), 'action refs must be full commit SHAs');
assert.match(workflow, /az extension add --name containerapp --version 1\.3\.0b5/);

assert.match(secretTemplate, /@secure\(\)\s*param appKey string/);
assert.match(secretTemplate, /name: 'gh-runner-app-key'/);
assert.match(runner, /appKey = \@\{ value = \$env:GH_APP_PRIVATE_KEY \}/);
assert.match(runner, /keyVaultUrl = "\$\(\$keyVault\.properties\.vaultUri\)secrets\/gh-runner-app-key"/);
assert.match(runner, /identity = \$uami\.id/);
assert.match(runner, /lifecycle = 'None'/);
assert.doesNotMatch(runner, /name = 'github-app-key'\s+value\s*=/);
assert.doesNotMatch(runner, /Write-Output[^\r\n]*GH_APP_PRIVATE_KEY/);
assert.match(runner, /Remove-Item Env:\\GH_APP_PRIVATE_KEY/);

assert.match(runner, /publicNetworkAccess = 'Disabled'/);
assert.match(runner, /properties\.publicNetworkAccess -ne 'Disabled'/);
assert.match(runner, /name = 'DenyRfc1918'; priority = 4000/);
assert.match(runner, /name = 'DenyInternetOutbound'; priority = 4090/);
assert.match(runner, /name = 'AllowAcaSubnetDependencies'; priority = 100; protocol = '\*'; source = '10\.252\.8\.0\/27'; destination = @\('10\.252\.8\.0\/27'\)/);
assert.match(runner, /function Set-NsgOutboundRules[\s\S]*--source-address-prefixes', \$rule\.source/);
assert.match(runner, /Set-NsgOutboundRules -ApiPrefixes \$apiPrefixes/);
assert.match(runner, /priority = 165[\s\S]*access = 'Deny'/);
assert.match(runner, /priority = 170; protocol = 'Tcp'; source = '10\.252\.8\.0\/27'; destination = \$ApiPrefixes; ports = @\('443'\); access = 'Allow'/);
assert.match(runner, /CAPACITY_RECOVERED -cne 'confirmed-recovered'/);
assert.match(runner, /New-GitHubInstallationToken/);
assert.match(runner, /Get-SyntheticRunState -RunUrl/);
assert.match(runner, /workflowPath = \$run\.path/);
assert.match(runner, /customLabelPresent = \$true/);
assert.match(runner, /syntheticRunObservations \+= Get-SyntheticRunState/);
assert.match(runner, /kedaEvents\.allow = Wait-KedaEvents/);
assert.match(runner, /kedaEvents\.deny = Wait-KedaEvents/);
assert.match(runner, /scaleRuleExecutionsDuringDeny/);
assert.match(runner, /No timestamped, structured KEDA events attributed to the exact github-runner rule and spike job/);
assert.doesNotMatch(runner, /role', 'assignment', 'delete/);
assert.match(runner, /operator-cleanup-required/);
assert.match(runner, /Invoke-BoundedProcess/);
assert.match(runner, /Get-CleanupResourcePlan/);

assert.match(bootstrap, /AZURE_SPIKE8_CLIENT_ID/);
assert.match(bootstrap, /--role', \$contributorRoleId,[\s\S]*--scope', \$scope/);
assert.match(bootstrap, /--role', \$secretsOfficerRoleId,[\s\S]*--scope', \$keyVaultId/);
assert.match(bootstrap, /--role',\s+'4633458b-17de-408a-b874-0445c86b69e6',[\s\S]*--scope', \$keyVaultId/);
assert.match(bootstrap, /--subject', \$OidcSubject/);
assert.match(bootstrap, /Get-ValidatedScopedAssignments/);
assert.match(bootstrap, /WorkflowPrincipalId/);
assert.match(bootstrap, /WorkloadPrincipalId/);
assert.ok(bootstrap.includes(expectedSubject));
assert.doesNotMatch(bootstrap, /5ee406c4-2cac-4c4a-a900-f9bb6f95b6d0|24ebb9cc-0e3b-4956-a333-5665a060f2c7/);

assert.match(oidc, /ACTIONS_ID_TOKEN_REQUEST_TOKEN/);
assert.match(oidc, /Authorization\s*=/);
assert.ok(oidc.includes(expectedSubject));
assert.match(oidc, /https:\/\/token\.actions\.githubusercontent\.com/);
assert.match(oidc, /api:\/\/AzureADTokenExchange/);
assert.match(oidc, /issuer=\$issuer/);
assert.match(oidc, /audience=\$audience/);
assert.match(oidc, /subject=\$subject/);
assert.doesNotMatch(oidc, /Write-Output[^\r\n]*\$token/);
assert.match(synthetic, /runs-on: ghr-spike8-probe/);
assert.match(synthetic, /sleep 600/);
assert.match(processModule, /WaitForExit\(\$TimeoutSeconds \* 1000\)/);
assert.match(processModule, /WaitForExit\(5000\)/);
assert.match(processModule, /process\.Dispose\(\)/);
assert.match(processModule, /Kill\(\$true\)/);
assert.match(lifecycleModule, /exact recorded principal and role/);
assert.match(functionalTests, /hung child process is terminated/);
assert.match(functionalTests, /Windows prefers az\.cmd and its bundled Python/);
assert.match(functionalTests, /Runtime emits every shared NSG rule/);
assert.match(functionalTests, /Runtime NSG rule includes its source subnet/);
assert.match(functionalTests, /Repeated cleanup is an empty no-op/);
assert.match(functionalTests, /Only exact rule and job events count/);

console.log('KEDA spike static contract checks passed.');
