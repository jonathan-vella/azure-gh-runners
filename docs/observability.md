# Observability

## Log Analytics workspace

`infra/modules/observability.bicep` deploys `law-ghrunners-prod-swc` through the Azure Verified Module
`br/public:avm/res/operational-insights/workspace:0.16.1`. The wrapper explicitly disables workspace shared-key
authentication and outputs the workspace resource ID (for diagnostic settings) and non-secret customer ID. It does
not output either workspace shared key.

The Container Apps environment uses the documented Azure Monitor logs destination and diagnostic settings routed to
this workspace. This path uses the workspace resource ID and does not require retrieving or exporting a workspace
shared key. The AVM `log-analytics` destination resolves the workspace shared key and is not used because local
authentication is disabled.

The workspace uses standard Azure Monitor endpoints without an Azure Monitor Private Link Scope (AMPLS):

- `publicNetworkAccessForIngestion: Enabled`
- `publicNetworkAccessForQuery: Enabled`

This is a deliberate, narrow exception to the platform's public-network restrictions. Both settings are enabled
because the approved design uses standard endpoints without an AMPLS/private endpoint; otherwise normal ingestion
and query traffic would be blocked. The query endpoint is needed for operators to use Azure Monitor Logs, and Entra
authorization plus Azure RBAC govern that access; local workspace authentication is disabled. These are not inbound
endpoints on the runner platform or its workload resources. They do mean that authorized clients can ingest or query
over the public service endpoints. Private Monitor connectivity would require an AMPLS, private endpoint, DNS and
network integration, which is outside the approved no-AMPLS design.

Microsoft references:

- [Log Analytics workspace resource properties](https://learn.microsoft.com/azure/templates/microsoft.operationalinsights/workspaces)
- [Azure Monitor Private Link and AMPLS](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-security)
- [Manage access to Log Analytics workspaces](https://learn.microsoft.com/azure/azure-monitor/logs/manage-access)
- [Container Apps log destinations and Azure Monitor diagnostic settings](https://learn.microsoft.com/azure/container-apps/log-options)
- [Published AVM workspace versions](https://mcr.microsoft.com/v2/bicep/avm/res/operational-insights/workspace/tags/list) (latest stable verified: `0.16.1`)

## Diagnostic settings pattern

`infra/modules/diagnostic-settings.bicep` is the reusable extension-resource module. The root deployment wires it to
the two network security groups, virtual network, and NAT public IP. A caller supplies an actual target resource ID,
the workspace resource ID, explicit supported service log categories, and whether `AllMetrics` is supported. Empty
requests emit no diagnostic setting. The nested ARM template is needed because a generic Bicep module cannot type an
arbitrary resource ID as an extension-resource scope.

| Parameter | Contract |
| --- | --- |
| `targetResourceId` | Resource ID of an actual resource declared by the owning infrastructure module |
| `workspaceResourceId` | `workspaceResourceId` output from `observability.bicep` |
| `name` | Stable diagnostic-setting name |
| `logCategories` | Explicit category names verified for this target resource |
| `enableAllMetrics` | `true` only when the target supports `AllMetrics`; defaults to `false` |

`infra/diagnostics-config.json` is the category contract loaded by `infra/main.bicep`; `npm run validate` checks this
exact file before deployment. The contract rejects unsupported, duplicate, empty, and malformed category requests.
Enable `AllMetrics` only when the resource supports metric export through diagnostic settings; platform metrics
existing in Azure Monitor does not by itself mean they can be exported. Do not copy categories from another service.

| Resource | Diagnostic categories configured | Decision |
| --- | --- | --- |
| ACA and ACR-agent NSGs | `NetworkSecurityGroupEvent`, `NetworkSecurityGroupFlowEvent`, `NetworkSecurityGroupRuleCounter` | All three published log categories; no `AllMetrics` category is listed for NSGs. |
| VNet | `VMProtectionAlerts`, `AllMetrics` | Published VNet logs and metrics include these diagnostic categories; the metrics reference marks supported metrics as exportable. |
| NAT public IP | `DDoSMitigationFlowLogs`, `DDoSMitigationReports`, `DDoSProtectionNotifications`, `AllMetrics` | All published public-IP logs and exportable metrics. DDoS logs contain data only when the relevant protection telemetry is generated. |
| Container Apps environment | `ContainerAppConsoleLogs`, `ContainerAppSystemLogs`, `AllMetrics` | Documented for the Azure Monitor destination. The environment's live categories must still pass the preflight before settings are enabled. |
| Standard NAT Gateway | None | `NatGatewayFlowlogsV1` is for StandardV2 NAT Gateways; NAT platform metrics are not exportable through diagnostic settings. Empty settings are not deployed. |
| Private DNS zones | None | Published zone metrics are not exportable through diagnostic settings. No published resource-log category reference was available to verify an exportable category, so no setting is deployed without one. |

The Container Apps environment adds its categories to the shared contract and wires this module behind the same live
category gate as the network resources. The categories documented for its Azure Monitor destination are
`ContainerAppConsoleLogs`, `ContainerAppSystemLogs`, and `AllMetrics`; the static contract is not evidence that the
deployed environment supports them. Issues #13 and #14 must add their own categories only after verifying the actual
resource types.

This is the intended no-shared-key path. The live preflight checks the categories against the actual environment
resource before enabling the settings; it does not prove capacity or successful environment provisioning.

## Live category gate

The resources do not exist until the infrastructure is deployed, so the live Azure category check cannot run before
the foundation deployment. `infra/main.bicep` therefore defaults `enableDiagnostics` to `false`; its first deployment
creates the workspace, network, and ACA environment and publishes their resource IDs. Before enabling diagnostics in
a subsequent deployment:

1. Export the deployment outputs to a local JSON file (for example, `az deployment group show --resource-group
   rg-ghrunners-prod-swc --name <deployment-name> --query properties.outputs --output json > deployment-outputs.json`).
2. Run `node tools/validate-diagnostics.mjs --live deployment-outputs.json`. The command queries Azure's live
   diagnostic categories for both NSGs, the VNet, the NAT public IP, and the ACA environment using the explicitly
   configured `shared` subscription ID. It accepts only the exact expected resource types, names, subscription, and
   resource group, and rejects duplicate IDs or any configured log/metric category absent from the corresponding
   resource. Azure CLI execution has a 30-second timeout, a 1 MiB output bound, and sanitized errors.
3. Only after the check succeeds, run the protected deployment with `enableDiagnostics=true`.

The outputs contain non-secret resource IDs. Do not commit the local outputs file. The live command requires an
authenticated Azure CLI context and must be run against the approved shared subscription and resource group. This
issue does not perform either deployment or add a production deployment workflow; the `enableDiagnostics` parameter
is the explicit handoff between foundation creation and live-validated diagnostics.

References:

- [Diagnostic settings in Azure Monitor](https://learn.microsoft.com/azure/azure-monitor/data-collection/diagnostic-settings)
- [Supported NSG log categories](https://learn.microsoft.com/azure/azure-monitor/reference/supported-logs/microsoft-network-networksecuritygroups-logs)
- [Supported VNet log categories](https://learn.microsoft.com/azure/azure-monitor/reference/supported-logs/microsoft-network-virtualnetworks-logs)
- [Supported VNet metrics](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-network-virtualnetworks-metrics)
- [Supported public IP log categories](https://learn.microsoft.com/azure/azure-monitor/reference/supported-logs/microsoft-network-publicipaddresses-logs)
- [Supported public IP metrics](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-network-publicipaddresses-metrics)
- [Supported NAT Gateway metrics](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-network-natgateways-metrics)
- [StandardV2 NAT Gateway Flow Logs](https://learn.microsoft.com/azure/nat-gateway/monitor-nat-gateway-flow-logs)
- [Supported Private DNS zone metrics](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-network-privatednszones-metrics)
