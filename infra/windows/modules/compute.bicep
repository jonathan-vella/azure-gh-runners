@description('Azure region.')
param location string

@description('Azure Compute Gallery name. Underscores are valid in gallery names.')
param galleryName string

@description('Image definition that the image bake publishes versions into.')
param imageDefinitionName string

@description('Name of the VMSS Flex that worker VMs attach to.')
param vmssName string

@description('Governance tags.')
param tags object

module gallery 'br/public:avm/res/compute/gallery:0.9.5' = {
  name: 'gallery-${uniqueString(galleryName)}'
  params: {
    name: galleryName
    location: location
    description: 'Windows runner images for the isolated Windows backend.'
    images: [
      {
        name: imageDefinitionName
        osType: 'Windows'
        osState: 'Generalized'
        hyperVGeneration: 'V2'
        identifier: {
          publisher: 'ghrunners'
          offer: 'windows-runner'
          sku: '2025'
        }
        securityType: 'TrustedLaunchSupported'
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

// Flex scale set used only as a placement container: zero instances, no autoscale, no VM profile.
resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2024-07-01' = {
  name: vmssName
  location: location
  tags: tags
  properties: {
    orchestrationMode: 'Flex'
    platformFaultDomainCount: 1
    singlePlacementGroup: false
  }
}

output galleryResourceId string = gallery.outputs.resourceId
output imageDefinitionResourceId string = '${gallery.outputs.resourceId}/images/${imageDefinitionName}'
output vmssResourceId string = vmss.id
output vmssName string = vmss.name
