import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

const root = new URL("../", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1");
const read = (path) => readFileSync(join(root, path), "utf8").replace(/\r\n/g, "\n");
const code = (text) => text.replace(/^\s*\/\/.*$/gm, "");
const listBicep = (dir) => readdirSync(join(root, dir), { recursive: true })
  .filter((name) => String(name).endsWith(".bicep"))
  .map((name) => join(dir, String(name)));

const bicepFiles = ["infra/windows/main.bicep", ...listBicep("infra/windows/modules")];
const allBicep = bicepFiles.map((path) => [path, code(read(path))]);
const main = code(read("infra/windows/main.bicep"));
const network = code(read("infra/windows/modules/network.bicep"));
const compute = code(read("infra/windows/modules/compute.bicep"));
const job = code(read("infra/windows/modules/orchestrator-job.bicep"));
const workflow = read(".github/workflows/deploy-windows.yml");
const bootstrap = read("tools/bootstrap-windows.ps1");

test("every AVM module is pinned to an exact version", () => {
  for (const [path, text] of allBicep) {
    for (const [, reference] of text.matchAll(/'(br\/public:[^']+)'/g)) {
      assert.match(reference, /^br\/public:avm\/res\/[\w/-]+:\d+\.\d+\.\d+$/, `${path}: ${reference}`);
    }
  }
});

test("the Windows network is an island: no peering, private DNS or private endpoints", () => {
  for (const [path, text] of allBicep) {
    assert.doesNotMatch(text, /virtualNetworkPeerings|privateDnsZone|privateEndpoint|privatelink/i, path);
  }
  assert.match(main, /var consumers = loadJsonContent\('\.\.\/generated\/windows-consumers\.json'\)/);
  assert.doesNotMatch(main, /generated\/consumers\.json|network-config\.json/);
});

test("worker NSG denies all inbound, allows no inbound, and denies private ranges outbound", () => {
  const rules = [...network.matchAll(/name: '([\w-]+)'\n\s+properties: \{([\s\S]*?)\n    \}\n  \}/g)];
  assert.ok(rules.length >= 9);
  for (const [, name, body] of rules) {
    const direction = /direction: '(\w+)'/.exec(body)?.[1];
    const access = /access: '(\w+)'/.exec(body)?.[1];
    if (direction === "Inbound") assert.equal(access, "Deny", `${name} must not allow inbound`);
  }
  assert.match(network, /name: 'Deny-All-Inbound'[\s\S]*?priority: 4096/);
  for (const range of ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]) {
    assert.match(network, new RegExp(`destinationAddressPrefix: '${range.replace(/[./]/g, "\\$&")}'`));
  }
  assert.match(network, /Allow-Internet-HTTPS[\s\S]*?destinationPortRange: '443'/);
  assert.match(network, /Allow-Internet-HTTP'[\s\S]*?destinationPortRange: '80'/);
  assert.match(network, /Allow-Azure-DNS[\s\S]*?destinationAddressPrefix: '168\.63\.129\.16'[\s\S]*?destinationPortRange: '53'/);
  assert.match(network, /Deny-Internet-Other-Outbound[\s\S]*?access: 'Deny'[\s\S]*?destinationAddressPrefix: 'Internet'[\s\S]*?destinationPortRange: '\*'[\s\S]*?direction: 'Outbound'[\s\S]*?priority: 3900/);
});

test("NAT Gateway public IP is the only public IP and subnets use it without default outbound", () => {
  assert.equal([...allBicep.map(([, text]) => text).join("\n").matchAll(/public-ip-address:/g)].length, 1);
  assert.equal([...network.matchAll(/natGatewayResourceId: natGateway\.outputs\.resourceId/g)].length, 2);
  assert.equal([...network.matchAll(/defaultOutboundAccess: false/g)].length, 2);
  assert.match(network, /publicIPAllocationMethod: 'Static'/);
});

test("gallery image definition is Windows, Gen2, generalized and TrustedLaunch-capable; VMSS is Flex with no capacity", () => {
  assert.match(main, /param galleryName string = 'gal_ghrunners_win_swc'/);
  assert.match(main, /param imageDefinitionName string = 'ghr-windows-2025'/);
  assert.match(compute, /osType: 'Windows'/);
  assert.match(compute, /osState: 'Generalized'/);
  assert.match(compute, /hyperVGeneration: 'V2'/);
  assert.match(compute, /securityType: 'TrustedLaunchSupported'/);
  assert.match(compute, /orchestrationMode: 'Flexible'/);
  assert.match(compute, /platformFaultDomainCount: 1/);
  assert.doesNotMatch(compute, /capacity|autoscale|virtualMachineProfile/i);
});

test("ACA environment is non-zonal Consumption and no job or app has ingress", () => {
  assert.match(main, /zoneRedundant: false/);
  assert.match(main, /name: 'Consumption'\n\s+workloadProfileType: 'Consumption'/);
  assert.doesNotMatch(allBicep.map(([, text]) => text).join("\n"), /ingress|Microsoft\.App\/containerApps/);
});

test("orchestrator identity has exactly VM Contributor, Network Contributor, AcrPull and gallery-scoped Reader", () => {
  assert.match(main, /virtualMachineContributorRoleId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'/);
  assert.match(main, /networkContributorRoleId = '4d97b98b-1d4f-4787-a291-c67834d212e7'/);
  assert.equal([...main.matchAll(/Microsoft\.Authorization\/roleAssignments@/g)].length, 2);
  assert.match(compute, /readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'/);
  assert.match(compute, /resource galleryReader [^\n]*roleAssignments@[\s\S]*?scope: galleryScope/);
  assert.equal([...compute.matchAll(/Microsoft\.Authorization\/roleAssignments@/g)].length, 1);
  assert.equal([...main.matchAll(/roleDefinitionIdOrName: '(\w+)'/g)].map((m) => m[1]).join(), "AcrPull");
  const everything = allBicep.map(([, text]) => text).join("\n");
  assert.doesNotMatch(everything, /b24988ac-6180-42a0-ab88-20f7382dd24c|8e3af657-a8ff-443c-a75c-2fe8c4bcb635|'Contributor'|'Owner'/);
  assert.doesNotMatch(everything, /jobs\/start|Microsoft\.App\/jobs\/start/);
});

test("orchestrator job uses the KEDA github-runner scaler, runs as Main, and bounds concurrency and time", () => {
  assert.match(job, /type: 'github-runner'/);
  assert.match(job, /noDefaultLabels: 'true'/);
  assert.match(job, /enableEtags: 'true'/);
  assert.match(job, /runnerScope: 'repo'/);
  assert.match(job, /maxExecutions: consumer\.maxRunners/);
  assert.match(job, /replicaTimeout: \(consumer\.jobTimeoutMinutes \+ 20\) \* 60/);
  assert.match(job, /lifecycle: 'Main'/);
  assert.match(job, /replicaRetryLimit: 0/);
  assert.match(main, /for consumer in consumers: if \(deployJobs\)/);
  assert.match(main, /@secure\(\)\n@description\([^\n]*\)\nparam githubAppPrivateKey string/);
  assert.match(job, /@secure\(\)\n@description\([^\n]*\)\nparam githubAppPrivateKey string/);
});

test("the cost budget is optional and alert-only", () => {
  assert.match(main, /param budgetAmount int = 0/);
  assert.match(main, /module budget .* = if \(budgetAmount > 0/);
  const budget = read("infra/windows/modules/budget.bicep");
  assert.doesNotMatch(budget, /actionGroup|automation|shutdown/i);
});

test("no personal identifiers, secrets or keys are hard-coded in the Windows backend files", () => {
  const files = [
    ...bicepFiles, "infra/windows/main.bicepparam", ".github/workflows/deploy-windows.yml", "tools/bootstrap-windows.ps1",
    ...readdirSync(join(root, "image/windows-orchestrator")).map((name) => `image/windows-orchestrator/${name}`),
  ];
  for (const path of files) {
    const text = read(path);
    assert.doesNotMatch(text, /jonathan-vella|b47d2942-f5ad-4d3c|30bac921-1547|5ee406c4|BEGIN [A-Z ]*PRIVATE KEY/i, path);
    assert.doesNotMatch(text, /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b(?<!9980e02c-c2be-4d73-94e8-173b1dc7cf3c|4d97b98b-1d4f-4787-a291-c67834d212e7|8e3af657-a8ff-443c-a75c-2fe8c4bcb635|acdd72a7-3385-48ef-bd42-f606fba81ae7)/, `${path} contains a GUID`);
  }
});

test("orchestrator image is pinned by digest and runs only platform code", () => {
  const dockerfile = read("image/windows-orchestrator/Dockerfile");
  const from = [...dockerfile.matchAll(/^FROM (\S+)/gm)].map((m) => m[1]);
  assert.equal(from.length, 2);
  for (const reference of from) assert.match(reference, /@sha256:[0-9a-f]{64}$/);
  assert.doesNotMatch(dockerfile, /sudo|curl|wget|apt-get|tdnf/);
});

test("deploy workflow: dispatch only, main-only, dedicated identity, staged, SHA-pinned", () => {
  assert.match(workflow, /^on:\n  workflow_dispatch:/m);
  assert.doesNotMatch(workflow, /^\s+(push|pull_request|pull_request_target|workflow_run|schedule):/m);
  assert.equal([...workflow.matchAll(/github\.ref == 'refs\/heads\/main'/g)].length, 2);
  assert.match(workflow, /environment: platform-prod/);
  assert.match(workflow, /client-id: \$\{\{ vars\.WINDOWS_AZURE_CLIENT_ID \}\}/);
  assert.doesNotMatch(workflow, /secrets\.AZURE_CLIENT_ID|AZURE_WHATIF_CLIENT_ID/);
  assert.match(workflow, /RESOURCE_GROUP: rg-ghrunners-win-swc/);
  assert.doesNotMatch(workflow, /rg-ghrunners-prod-swc/);
  assert.match(workflow, /foundation_only/);
  for (const [, reference] of workflow.matchAll(/uses: (\S+)/g)) {
    assert.match(reference, /@[0-9a-f]{40}$/, reference);
  }
  const foundation = workflow.indexOf("name: Deploy foundation");
  const readback = workflow.indexOf("name: Read back foundation");
  const importStep = workflow.indexOf("name: Import orchestrator image");
  const jobs = workflow.indexOf("name: Deploy orchestrator jobs");
  assert.ok(foundation > 0 && foundation < readback && readback < importStep && importStep < jobs);
  assert.match(workflow, /DEPLOY_JOBS: 'false'/);
  assert.match(workflow, /DEPLOY_JOBS: 'true'/);
  for (const readbackCheck of ["Deny-All-Inbound", "only public IP", "no peerings", "non-zonal", "role assignments are exact"]) {
    assert.ok(workflow.includes(readbackCheck), readbackCheck);
  }
  assert.match(workflow, /--name "windows-foundation"/);
  assert.match(workflow, /buildSubnetResourceId/);
  assert.doesNotMatch(workflow, /set -x|echo .*GH_APP_PRIVATE_KEY/);
});

test("bootstrap script supports -WhatIf, grants only Owner at the RG, and creates no secrets", () => {
  assert.match(bootstrap, /SupportsShouldProcess/);
  assert.match(bootstrap, /--role \$ownerRoleId --scope \$scope/);
  assert.equal([...bootstrap.matchAll(/role assignment create/g)].length, 1);
  assert.doesNotMatch(bootstrap, /create-for-rbac|--create-password|credential reset|--password|--years|--append|new-secret|--certificate/i);
  assert.match(bootstrap, /sub_claim_prefix/);
  assert.match(bootstrap, /federated-credential create/);
  assert.match(bootstrap, /Teardown/);
  assert.doesNotMatch(bootstrap, /sp-ghrunners-platform-prod|rg-ghrunners-prod-swc/);
});
