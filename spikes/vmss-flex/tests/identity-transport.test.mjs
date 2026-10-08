import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';

const transportPath = fileURLToPath(new URL('../Identity-Transport.ps1', import.meta.url)).replaceAll("'", "''");
const operationUrl = 'https://management.azure.com/subscriptions/b47d2942-f5ad-4d3c-b28e-c23e4f83d97e/providers/Microsoft.Resources/locations/swedencentral/operations/11111111-1111-1111-1111-111111111111?api-version=2024-03-01';

test('disabled HTTP helper captures real response headers and suppresses ambiguous/error bodies using loopback fixtures only', async () => {
  let response = {};
  const server = createServer((request, reply) => {
    assert.equal(request.headers.authorization, 'Bearer synthetic-fixture-only');
    reply.writeHead(response.status, response.headers);
    reply.end(response.body);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    for (const scenario of [
      { status: 204, body: '', expected: { value: {}, operationUrl: null } },
      { status: 202, headers: { 'Azure-AsyncOperation': operationUrl }, body: '{}', expected: { value: {}, operationUrl } },
      { status: 202, headers: { Location: operationUrl }, body: '{}', expected: { value: {}, operationUrl } },
      { status: 202, body: '{}', error: /lacks usable provider receipt/ },
      { status: 403, body: 'sensitive-provider-fixture', error: /HTTP 403/ },
      { status: 404, body: 'sensitive-provider-fixture', error: /HTTP 404/ },
      { status: 200, body: '{broken-sensitive-provider-fixture', error: /metadata invalid/ },
      { status: 200, body: '[]', error: /metadata object/ },
      { status: 200, body: '{"properties":{"provisioningState":"Running"}}', error: /not terminal success/ },
      { status: 202, headers: { Location: 'https://example.invalid/sensitive-provider-fixture' }, body: '{}', error: /Unsupported ARM operation handle/ },
    ]) {
      response = scenario;
      const script = `
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile('${transportPath}', [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Transport syntax invalid.' }
foreach ($name in @('Assert-SpikeOperationUrl', 'Invoke-IdentityHttp')) {
  $node = $ast.Find({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -ceq $name }, $true)
  . ([scriptblock]::Create($node.Extent.Text))
}
$cli = @{ fileName='fixture'; prefix=@() }
$subscription = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
function Invoke-BoundedProcess { return @{ exitCode=0; stdout='{"accessToken":"synthetic-fixture-only"}' } }
try {
  Invoke-IdentityHttp 'DELETE' 'http://127.0.0.1:${server.address().port}/fixture' 'arm' $null | ConvertTo-Json -Depth 10 -Compress
} catch { [Console]::Error.Write($_.Exception.Message); exit 1 }
`;
      const child = spawn('pwsh', ['-NoProfile', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')], {
        stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
      });
      let stdout = '';
      let stderr = '';
      child.stdout.on('data', data => { stdout += data; });
      child.stderr.on('data', data => { stderr += data; });
      const [code] = await once(child, 'exit');
      assert.doesNotMatch(stdout + stderr, /sensitive-provider-fixture|synthetic-fixture-only/);
      if (scenario.error) {
        assert.equal(code, 1);
        assert.match(stderr, scenario.error);
      } else {
        assert.equal(code, 0, stderr);
        assert.deepEqual(JSON.parse(stdout), scenario.expected);
      }
    }
  } finally { server.close(); }
});
