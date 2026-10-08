# VMSS spike cost sources and assumptions

Issue #84 replaces placeholder category allocations with a deterministic public-retail planning projection.
`priceOriginalEnvelope(pricing, now)` keeps the existing caller contract and accepts only `schemaVersion: 1`,
`source: "azure-retail-prices-api"`, the Azure Retail Prices API URL, `currencyCode: "USD"`, `region:
"swedencentral"`, a `retrievedUtc` no more than 24 hours old, and these exact positive USD meter fields:

| Evidence field | Meter and unit | Retail input |
| --- | --- | ---: |
| `b2sHourly` | Linux Standard_B2s VM, 1 hour | $0.0432 |
| `d2lsHourly` | Linux Standard_D2ls_v5 VM, 1 hour | $0.091 |
| `p4MonthlyUsd` | Premium SSD P4 LRS, 32 GiB, monthly | $5.8072 |
| `natHourly` | Standard NAT Gateway, 1 hour | $0.045 |
| `natProcessedGb` | NAT Gateway data processed, decimal GB | $0.045 |
| `standardIpv4Hourly` | Standard static IPv4 public IP, 1 hour | $0.005 |
| `privateEndpointHourly` | Private Endpoint, 1 hour | $0.01 |
| `privateEndpointIngressGb` | Private Endpoint data processed, ingress decimal GB | $0.01 |
| `privateEndpointEgressGb` | Private Endpoint data processed, egress decimal GB | $0.01 |
| `internetEgressGb` | Internet data transfer out, decimal GB | $0.12 conservative rate |
| `privateDnsZoneMonthly` | Private DNS zone hosting, per zone/month | $0.50 |
| `privateDnsQueriesPerMillion` | Private DNS queries, per million | $0.40 |
| `keyVaultOperationsPer10k` | Standard Key Vault operations, per 10,000 | $0.03 |

Sources:

- [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
  is the public, non-authenticated source for USD retail meter values. Query with `currencyCode eq 'USD'`,
  `armRegionName eq 'swedencentral'`, the relevant `armSkuName`/service, and `priceType eq 'Consumption'`.
- [Azure NAT Gateway pricing](https://azure.microsoft.com/pricing/details/nat-gateway/) and
  [NAT Gateway resource pricing notes](https://learn.microsoft.com/en-us/azure/nat-gateway/nat-gateway-resource#pricing)
  cover resource-hour and processed-data charges.
- [Azure Public IP pricing](https://azure.microsoft.com/pricing/details/ip-addresses/) identifies the Standard
  static IPv4 meter.
- [Azure Private Link pricing](https://azure.microsoft.com/pricing/details/private-link/) covers endpoint-hours
  and data processing; ingress and egress are both priced against their respective whole-direction quotas.
- [Azure bandwidth pricing](https://azure.microsoft.com/pricing/details/bandwidth/) maps Sweden Central to Zone 1.
  The projection uses $0.12/GB and does not subtract free monthly allowances or assume account-specific credits.
- [Azure DNS pricing](https://azure.microsoft.com/pricing/details/dns/) covers private-zone hosting and queries.
  One zone is created per full run; each is charged a full monthly zone rate rather than assuming a short-lived
  proration. All guest DNS queries are charged as if they hit the private zone.
- [Azure managed disk types](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types) and
  [managed disk pricing](https://azure.microsoft.com/pricing/details/managed-disks/) cover the Premium SSD tier.
  The published monthly P4 amount is divided by 672 (28 days × 24 hours), the shortest calendar month, rather than
  730 hours. Azure bills provisioned managed disks hourly; disk use is reserved through the full planned cleanup.
- [Azure Key Vault pricing](https://azure.microsoft.com/pricing/details/key-vault/) prices Standard operations.
  The code contract permits only one secret create and one controller secret read per full run (four operations
  across the two-run maximum). Seven-day soft-delete retention remains as specified; purge/recovery/name reuse is
  not assumed.

The quantity contract is intentionally conservative: one B2s, two D2ls v5, three P4 disks, one NAT Gateway, one
public IP, and two Private Endpoints are charged for all four hours even though the full runs are sequential.
Traffic caps in `guest-bootstrap.sh` apply before archive/package downloads: each of two guests per run is limited
to 2 GiB in each direction, and UDP DNS is limited to 2 queries/second with a 20-query burst. On a later boot,
the root-owned guard is an explicit `Requires`/`After` dependency of the available systemd network managers and
blocks all IPv4/IPv6 traffic before they start; a guard failure powers the VM off rather than allowing uncapped
networking. If neither supported network-manager unit exists, bootstrap drops all traffic and powers off before
installing tools or starting the controller. Thus iptables quota counters cannot reset into an unmetered session.
Across two runs this reserves 17.179869184 decimal GB NAT-processed, 8.589934592 GB Internet egress, 8.589934592 GB Private Endpoint
ingress, 8.589934592 GB Private Endpoint egress, and 115,280 DNS queries. Each separately billed traffic meter is
charged against its whole applicable quota, even where that conservatively prices the same packet in more than
one category.

No Azure Log Analytics workspace/paid log sink, ACR, custom image, gallery, image builder, storage account,
snapshot, backup, extra public IP, extra endpoint, Private DNS resolver, Key Vault Premium/HSM, or extra secret
operation is created or priced by the spike templates. These are contract prohibitions, not zero-valued rate
fallbacks. Adding any of them requires a sourced meter and revised cap before execution. VNet, subnet, NIC, NSG,
zero-capacity VMSS shell, and ARM deployment metadata have no separate resource-hour allocation in this model.

This is a public retail **planning projection**, not a customer-account quote or final invoice. It does not include
account discounts, taxes, credits, or a billing guarantee. Four hours includes the planned cleanup hour; cleanup
starts by the three-hour work deadline. If Azure refuses or delays deletion, any surviving metered resource can
continue accruing beyond four hours, so post-deadline provider-refusal liability is unbounded and is not represented
by an arbitrary reserve or by the $10 planned-use comparison.
