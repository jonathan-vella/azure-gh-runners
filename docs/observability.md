# Observability

## Log Analytics workspace

`infra/modules/observability.bicep` deploys `law-ghrunners-prod-swc` through the Azure Verified Module
`br/public:avm/res/operational-insights/workspace:0.16.1`. The wrapper explicitly disables workspace shared-key
authentication and outputs both the workspace resource ID (for diagnostic settings) and customer ID (for the
Container Apps environment). It does not output either workspace shared key; the ACA environment work item must
retrieve the key through a secure deployment path.

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

`infra/diagnostics-config.json` is the category contract loaded by `infra/main.bicep`; the observability validation
tests this exact file before deployment. The contract rejects unsupported, duplicate, empty, and malformed category
requests. Enable `AllMetrics` only when the resource supports metric export through diagnostic settings; platform
metrics existing in Azure Monitor does not by itself mean they can be exported. Do not copy categories from another
service.

| Resource | Diagnostic categories configured | Decision |
| --- | --- | --- |
| ACA and ACR-agent NSGs | `NetworkSecurityGroupEvent`, `NetworkSecurityGroupFlowEvent`, `NetworkSecurityGroupRuleCounter` | All three published log categories; no `AllMetrics` category is listed for NSGs. |
| VNet | `VMProtectionAlerts`, `AllMetrics` | Published VNet logs and metrics include these diagnostic categories; the metrics reference marks supported metrics as exportable. |
| NAT public IP | `DDoSMitigationFlowLogs`, `DDoSMitigationReports`, `DDoSProtectionNotifications`, `AllMetrics` | All published public-IP logs and exportable metrics. DDoS logs contain data only when the relevant protection telemetry is generated. |
| Standard NAT Gateway | None | `NatGatewayFlowlogsV1` is for StandardV2 NAT Gateways; NAT platform metrics are not exportable through diagnostic settings. Empty settings are not deployed. |
| Private DNS zones | None | Published zone metrics are not exportable through diagnostic settings. No published resource-log category reference was available to verify an exportable category, so no setting is deployed without one. |

The issue #13–15 resources (Key Vault, ACR, and Container Apps environment) are not yet declared. Their owning
infrastructure changes must add entries to the shared category contract and wire this module only after verifying
the resource type's supported categories from Microsoft documentation or the live category list
(`az monitor diagnostic-settings categories list --resource <resource-id>`).

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
