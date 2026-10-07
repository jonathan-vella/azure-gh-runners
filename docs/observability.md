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

`infra/modules/diagnostic-settings.bicep` is the reusable extension-resource module for future platform resources. A
caller supplies the target resource ID, workspace resource ID, explicit supported service log categories, and whether
`AllMetrics` is supported. It does not discover or assume categories, and metrics are omitted unless the caller
explicitly enables them. Empty requests emit no diagnostic setting. The nested ARM template is needed because a
generic Bicep module cannot type an arbitrary resource ID as an extension-resource scope.

| Parameter | Contract |
| --- | --- |
| `targetResourceId` | Resource ID of an actual resource declared by the owning infrastructure module |
| `workspaceResourceId` | `workspaceResourceId` output from `observability.bicep` |
| `name` | Stable diagnostic-setting name |
| `logCategories` | Explicit category names verified for this target resource |
| `enableAllMetrics` | `true` only when the target supports `AllMetrics`; defaults to `false` |

Before wiring a resource module, establish its supported categories from its service documentation or the live
resource category list (`az monitor diagnostic-settings categories list --resource <resource-id>`). Use
`tools/diagnostics-contract.mjs` to validate category requests before passing its result to the Bicep module. The
contract rejects unsupported log/metric categories and duplicates. Enable `AllMetrics` only when the target reports
that metric category. Category support varies by Azure resource type; do not copy categories from another service.

The network resources and the future Key Vault, ACR, and Container Apps environment do not yet exist in this
deployment. This work therefore adds the module contract without declaring diagnostic settings against placeholder
resources. Each owning infrastructure work item must wire the module once it creates a supported resource, using
that resource's actual categories.

References:

- [Diagnostic settings in Azure Monitor](https://learn.microsoft.com/azure/azure-monitor/data-collection/diagnostic-settings)
- [Supported Azure Monitor resource log categories](https://learn.microsoft.com/azure/azure-monitor/reference/logs-index)
