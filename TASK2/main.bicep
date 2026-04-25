targetScope = 'resourceGroup'

param location1 string = 'eastus'
param location2 string = 'eastus2'

param adminUsername string = 'anuragadmin'

@secure()
param adminPassword string

param storageAccountEastUSName string = 'anuragstorage497'
param storageAccountEastUS2Name string = 'anuragstorage6003'

var vnet1Name = 'eastus-vnet'
var vnet2Name = 'eastus2-vnet'

/* ---------------- NETWORK SECURITY GROUP (NSG) ---------------- */

resource webNsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: 'web-nsg'
  location: location1
  properties: {
    securityRules: [
      {
        name: 'Allow-RDP'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-HTTP'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

/* ---------------- VNET 1 (EAST US) ---------------- */

resource vnet1 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnet1Name
  location: location1
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    subnets: [
      {
        name: 'web-subnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: { id: webNsg.id }
        }
      }
    ]
  }
}

/* ---------------- VNET 2 (EAST US 2) - BASE VNET ---------------- */

// Deployed first with ONLY the Firewall subnet to prevent a circular dependency.
resource vnet2 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnet2Name
  location: location2
  properties: {
    addressSpace: { addressPrefixes: ['10.1.0.0/16'] }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: { addressPrefix: '10.1.2.0/24' }
      }
    ]
  }
}

/* ---------------- AZURE FIREWALL & ROUTING (EAST US 2) ---------------- */

resource fwPip 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: 'pip-firewall'
  location: location2
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource firewall 'Microsoft.Network/azureFirewalls@2023-05-01' = {
  name: 'eastus2-firewall'
  location: location2
  properties: {
    sku: { name: 'AZFW_VNet', tier: 'Standard' }
    ipConfigurations: [
      {
        name: 'fw-ipconfig'
        properties: {
          // Changed to 'vnet2.name' to ensure an implicit dependency exists
          subnet: { id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet2.name, 'AzureFirewallSubnet') }
          publicIPAddress: { id: fwPip.id }
        }
      }
    ]
    applicationRuleCollections: [
      {
        name: 'Block-Social-Media'
        properties: {
          priority: 100
          action: { type: 'Deny' }
          rules: [
            {
              name: 'Block-Facebook-Twitter'
              protocols: [
                { protocolType: 'Https', port: 443 }
                { protocolType: 'Http', port: 80 }
              ]
              sourceAddresses: [ '10.1.1.0/24' ]
              targetFqdns: [ '*.facebook.com', '*.twitter.com', '*.instagram.com' ]
            }
          ]
        }
      }
      {
        name: 'Allow-Other-Web'
        properties: {
          priority: 200
          action: { type: 'Allow' }
          rules: [
            {
              name: 'Allow-All-Else'
              protocols: [
                { protocolType: 'Https', port: 443 }
                { protocolType: 'Http', port: 80 }
              ]
              sourceAddresses: [ '10.1.1.0/24' ]
              targetFqdns: [ '*' ]
            }
          ]
        }
      }
    ]
    networkRuleCollections: [
      {
        name: 'Allow-DNS'
        properties: {
          priority: 100
          action: { type: 'Allow' }
          rules: [
            {
              name: 'DNS-Rule'
              protocols: [ 'UDP' ]
              sourceAddresses: [ '10.1.1.0/24' ]
              destinationAddresses: [ '*' ]
              destinationPorts: [ '53' ]
            }
          ]
        }
      }
    ]
  }
}

// Route Table is now built safely AFTER the firewall is established
resource routeTable 'Microsoft.Network/routeTables@2023-05-01' = {
  name: 'ws11-route-table'
  location: location2
  properties: {
    routes: [
      {
        name: 'Route-To-Firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
        }
      }
    ]
  }
}

/* ---------------- APP SUBNET (EAST US 2) ---------------- */

// Added as a separate resource to break the dependency loop. 
// This creates the subnet and attaches the Route Table in one final step.
resource appSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' = {
  parent: vnet2
  name: 'app-subnet'
  properties: {
    addressPrefix: '10.1.1.0/24'
    routeTable: { id: routeTable.id }
  }
}

/* ---------------- PEERING ---------------- */

resource peer1 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-05-01' = {
  name: 'peer1'
  parent: vnet1
  properties: {
    remoteVirtualNetwork: { id: vnet2.id }
    allowVirtualNetworkAccess: true
  }
  // Waits for appSubnet to finish injecting into VNet2 to avoid concurrent state lock
  dependsOn: [ appSubnet ] 
}

resource peer2 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-05-01' = {
  name: 'peer2'
  parent: vnet2
  properties: {
    remoteVirtualNetwork: { id: vnet1.id }
    allowVirtualNetworkAccess: true
  }
  dependsOn: [ appSubnet ]
}

/* ---------------- AVSET + STORAGE ---------------- */

resource avset 'Microsoft.Compute/availabilitySets@2023-03-01' = {
  name: 'avset'
  location: location1
  sku: { name: 'Aligned' }
  properties: {
    platformFaultDomainCount: 2
    platformUpdateDomainCount: 2
  }
}

resource storage1 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountEastUSName
  location: location1
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
}

resource storage2 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountEastUS2Name
  location: location2
  sku: { name: 'Standard_GRS' }
  kind: 'StorageV2'
}

/* ---------------- PUBLIC IPs (For VMs) ---------------- */

resource w1Pip 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: 'pip-w1'
  location: location1
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource w2Pip 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: 'pip-w2'
  location: location1
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource ws11Pip 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: 'pip-ws11'
  location: location2
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

/* ---------------- LOAD BALANCER ---------------- */

resource lbPip 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: 'lb-pip'
  location: location1
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource lb 'Microsoft.Network/loadBalancers@2023-05-01' = {
  name: 'web-lb'
  location: location1
  sku: { name: 'Standard' }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'LoadBalancerFrontEnd'
        properties: { publicIPAddress: { id: lbPip.id } }
      }
    ]
    backendAddressPools: [
      { name: 'backendPool' }
    ]
    probes: [
      {
        name: 'httpProbe'
        properties: { protocol: 'Tcp', port: 80 }
      }
    ]
    loadBalancingRules: [
      {
        name: 'httpRule'
        properties: {
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          frontendIPConfiguration: { id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', 'web-lb', 'LoadBalancerFrontEnd') }
          backendAddressPool: { id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', 'web-lb', 'backendPool') }
          probe: { id: resourceId('Microsoft.Network/loadBalancers/probes', 'web-lb', 'httpProbe') }
        }
      }
    ]
  }
}

/* ---------------- NICs ---------------- */

resource w1Nic 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: 'nic-w1'
  location: location1
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: w1Pip.id }
          subnet: { id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet1.name, 'web-subnet') }
          loadBalancerBackendAddressPools: [
            { id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', 'web-lb', 'backendPool') }
          ]
        }
      }
    ]
  }
}

resource w2Nic 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: 'nic-w2'
  location: location1
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: w2Pip.id }
          subnet: { id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet1.name, 'web-subnet') }
          loadBalancerBackendAddressPools: [
            { id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', 'web-lb', 'backendPool') }
          ]
        }
      }
    ]
  }
}

resource ws11Nic 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: 'nic-ws11'
  location: location2
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: ws11Pip.id }
          subnet: { id: appSubnet.id } // Updated to reference the new detached subnet
        }
      }
    ]
  }
}

/* ---------------- VMs ---------------- */

resource w1Vm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: 'w1'
  location: location1
  properties: {
    availabilitySet: { id: avset.id }
    hardwareProfile: { vmSize: 'Standard_B2ms' }
    osProfile: {
      computerName: 'w1'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2019-Datacenter'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    networkProfile: { networkInterfaces: [{ id: w1Nic.id }] }
  }
}

resource w2Vm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: 'w2'
  location: location1
  properties: {
    availabilitySet: { id: avset.id }
    hardwareProfile: { vmSize: 'Standard_B2ms' }
    osProfile: {
      computerName: 'w2'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2019-Datacenter'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    networkProfile: { networkInterfaces: [{ id: w2Nic.id }] }
  }
}

resource ws11Vm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: 'ws11'
  location: location2
  properties: {
    hardwareProfile: { vmSize: 'Standard_B1ms' }
    osProfile: {
      computerName: 'ws11'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2019-Datacenter'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
      dataDisks: [
        {
          diskSizeGB: 10
          lun: 0
          createOption: 'Empty'
        }
      ]
    }
    networkProfile: { networkInterfaces: [{ id: ws11Nic.id }] }
  }
}
