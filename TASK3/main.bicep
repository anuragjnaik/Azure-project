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

/* ---------------- 1. NETWORK SECURITY GROUPS (NSGs) ---------------- */

resource webNsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: 'web-nsg'
  location: location1
  properties: {
    securityRules: [
      { name: 'Allow-RDP', properties: { priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourcePortRange: '*', destinationPortRange: '3389', sourceAddressPrefix: '*', destinationAddressPrefix: '*' } }
      { name: 'Allow-HTTP', properties: { priority: 110, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourcePortRange: '*', destinationPortRange: '80', sourceAddressPrefix: '*', destinationAddressPrefix: '*' } }
    ]
  }
}

// TASK 3 REQUIREMENT: Restrict unauthorized access to the backend
resource appNsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: 'app-nsg'
  location: location2
  properties: {
    securityRules: [
      {
        name: 'Allow-Only-Web-Subnet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '10.0.1.0/24' // Only allows traffic from the Web Subnet!
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

/* ---------------- 2. VNETS & ROUTING ---------------- */

resource routeTable 'Microsoft.Network/routeTables@2023-05-01' = {
  name: 'ws11-route-table'
  location: location2
  properties: {
    routes: [ { name: 'Route-To-Firewall', properties: { addressPrefix: '0.0.0.0/0', nextHopType: 'VirtualAppliance', nextHopIpAddress: '10.1.2.4' } } ]
  }
}

resource vnet1 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnet1Name
  location: location1
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    subnets: [
      { name: 'web-subnet', properties: { addressPrefix: '10.0.1.0/24', networkSecurityGroup: { id: webNsg.id } } }
      { name: 'GatewaySubnet', properties: { addressPrefix: '10.0.3.0/24' } } // Required for VPN
    ]
  }
}

resource vnet2 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnet2Name
  location: location2
  properties: {
    addressSpace: { addressPrefixes: ['10.1.0.0/16'] }
    subnets: [
      { name: 'app-subnet', properties: { addressPrefix: '10.1.1.0/24', networkSecurityGroup: { id: appNsg.id }, routeTable: { id: routeTable.id } } }
      { name: 'AzureFirewallSubnet', properties: { addressPrefix: '10.1.2.0/24' } }
      { name: 'GatewaySubnet', properties: { addressPrefix: '10.1.3.0/24' } } // Required for VPN
    ]
  }
}

/* ---------------- 3. TASK 3: VPN GATEWAYS & CONNECTIONS ---------------- */

// Public IPs for the Gateways
resource gw1Pip 'Microsoft.Network/publicIPAddresses@2023-05-01' = { name: 'pip-vpngw1', location: location1, sku: { name: 'Standard' }, zones: [ '1', '2', '3' ] , properties: { publicIPAllocationMethod: 'Static' } }
resource gw2Pip 'Microsoft.Network/publicIPAddresses@2023-05-01' = { name: 'pip-vpngw2', location: location2, sku: { name: 'Standard' }, zones: [ '1', '2', '3' ] , properties: { publicIPAllocationMethod: 'Static' } }

// The Security Checkpoints (VPN Gateways)
resource vpngw1 'Microsoft.Network/virtualNetworkGateways@2023-05-01' = {
  name: 'vpngw-eastus'
  location: location1
  properties: {
    ipConfigurations: [ { name: 'gw1-ipconfig', properties: { privateIPAllocationMethod: 'Dynamic', subnet: { id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet1Name, 'GatewaySubnet') }, publicIPAddress: { id: gw1Pip.id } } } ]
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: { name: 'VpnGw1AZ', tier: 'VpnGw1AZ' }
  }
}

resource vpngw2 'Microsoft.Network/virtualNetworkGateways@2023-05-01' = {
  name: 'vpngw-eastus2'
  location: location2
  properties: {
    ipConfigurations: [ { name: 'gw2-ipconfig', properties: { privateIPAllocationMethod: 'Dynamic', subnet: { id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet2Name, 'GatewaySubnet') }, publicIPAddress: { id: gw2Pip.id } } } ]
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: { name: 'VpnGw1AZ', tier: 'VpnGw1AZ' }
  }
}

// The Armored Tunnels (Connections)
resource conn1to2 'Microsoft.Network/connections@2023-05-01' = {
  name: 'conn-east-to-east2'
  location: location1
  properties: {
    virtualNetworkGateway1: { id: vpngw1.id, properties: {} }
    virtualNetworkGateway2: { id: vpngw2.id, properties: {} }
    connectionType: 'Vnet2Vnet'
    sharedKey: 'upgradvpnsecret123'
  }
}

resource conn2to1 'Microsoft.Network/connections@2023-05-01' = {
  name: 'conn-east2-to-east'
  location: location2
  properties: {
    virtualNetworkGateway1: { id: vpngw2.id, properties: {} }
    virtualNetworkGateway2: { id: vpngw1.id, properties: {} }
    connectionType: 'Vnet2Vnet'
    sharedKey: 'upgradvpnsecret123'
  }
}

/* ---------------- 4. STORAGE, FIREWALL, LB, NICS & VMS (From Task 2) ---------------- */

resource storage1 'Microsoft.Storage/storageAccounts@2023-01-01' = { name: storageAccountEastUSName, location: location1, sku: { name: 'Standard_LRS' }, kind: 'StorageV2' }
resource storage2 'Microsoft.Storage/storageAccounts@2023-01-01' = { name: storageAccountEastUS2Name, location: location2, sku: { name: 'Standard_GRS' }, kind: 'StorageV2' }

resource fwPip 'Microsoft.Network/publicIPAddresses@2023-05-01' = { name: 'pip-firewall', location: location2, sku: { name: 'Standard' }, properties: { publicIPAllocationMethod: 'Static' } }
resource firewall 'Microsoft.Network/azureFirewalls@2023-05-01' = { name: 'eastus2-firewall', location: location2, properties: { sku: { name: 'AZFW_VNet', tier: 'Standard' }, ipConfigurations: [ { name: 'fw-ipconfig', properties: { subnet: { id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet2Name, 'AzureFirewallSubnet') }, publicIPAddress: { id: fwPip.id } } } ], applicationRuleCollections: [ { name: 'Block-Social-Media', properties: { priority: 100, action: { type: 'Deny' }, rules: [ { name: 'Block-Facebook-Twitter', protocols: [ { protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 } ], sourceAddresses: [ '10.1.1.0/24' ], targetFqdns: [ '*.facebook.com', '*.twitter.com' ] } ] } } ], networkRuleCollections: [ { name: 'Allow-DNS', properties: { priority: 100, action: { type: 'Allow' }, rules: [ { name: 'DNS-Rule', protocols: [ 'UDP' ], sourceAddresses: [ '10.1.1.0/24' ], destinationAddresses: [ '*' ], destinationPorts: [ '53' ] } ] } } ] } }

resource lbPip 'Microsoft.Network/publicIPAddresses@2023-05-01' = { name: 'lb-pip', location: location1, sku: { name: 'Standard' }, properties: { publicIPAllocationMethod: 'Static' } }
resource lb 'Microsoft.Network/loadBalancers@2023-05-01' = { name: 'web-lb', location: location1, sku: { name: 'Standard' }, properties: { frontendIPConfigurations: [ { name: 'LoadBalancerFrontEnd', properties: { publicIPAddress: { id: lbPip.id } } } ], backendAddressPools: [ { name: 'backendPool' } ], probes: [ { name: 'httpProbe', properties: { protocol: 'Tcp', port: 80 } } ], loadBalancingRules: [ { name: 'httpRule', properties: { protocol: 'Tcp', frontendPort: 80, backendPort: 80, frontendIPConfiguration: { id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', 'web-lb', 'LoadBalancerFrontEnd') }, backendAddressPool: { id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', 'web-lb', 'backendPool') }, probe: { id: resourceId('Microsoft.Network/loadBalancers/probes', 'web-lb', 'httpProbe') } } } ] } }

resource avset 'Microsoft.Compute/availabilitySets@2023-03-01' = { name: 'avset', location: location1, sku: { name: 'Aligned' }, properties: { platformFaultDomainCount: 2, platformUpdateDomainCount: 2 } }

resource w1Pip 'Microsoft.Network/publicIPAddresses@2023-05-01' = { name: 'pip-w1', location: location1, sku: { name: 'Standard' }, properties: { publicIPAllocationMethod: 'Static' } }
resource w2Pip 'Microsoft.Network/publicIPAddresses@2023-05-01' = { name: 'pip-w2', location: location1, sku: { name: 'Standard' }, properties: { publicIPAllocationMethod: 'Static' } }
resource ws11Pip 'Microsoft.Network/publicIPAddresses@2023-05-01' = { name: 'pip-ws11', location: location2, sku: { name: 'Standard' }, properties: { publicIPAllocationMethod: 'Static' } }

resource w1Nic 'Microsoft.Network/networkInterfaces@2023-05-01' = { name: 'nic-w1', location: location1, properties: { ipConfigurations: [ { name: 'ipconfig1', properties: { privateIPAllocationMethod: 'Dynamic', publicIPAddress: { id: w1Pip.id }, subnet: { id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet1.name, 'web-subnet') }, loadBalancerBackendAddressPools: [ { id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', 'web-lb', 'backendPool') } ] } } ] } }
resource w2Nic 'Microsoft.Network/networkInterfaces@2023-05-01' = { name: 'nic-w2', location: location1, properties: { ipConfigurations: [ { name: 'ipconfig1', properties: { privateIPAllocationMethod: 'Dynamic', publicIPAddress: { id: w2Pip.id }, subnet: { id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet1.name, 'web-subnet') }, loadBalancerBackendAddressPools: [ { id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', 'web-lb', 'backendPool') } ] } } ] } }
resource ws11Nic 'Microsoft.Network/networkInterfaces@2023-05-01' = { name: 'nic-ws11', location: location2, properties: { ipConfigurations: [ { name: 'ipconfig1', properties: { privateIPAllocationMethod: 'Dynamic', publicIPAddress: { id: ws11Pip.id }, subnet: { id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet2.name, 'app-subnet') } } } ] } }

resource w1Vm 'Microsoft.Compute/virtualMachines@2023-03-01' = { name: 'w1', location: location1, properties: { availabilitySet: { id: avset.id }, hardwareProfile: { vmSize: 'Standard_B2ms' }, osProfile: { computerName: 'w1', adminUsername: adminUsername, adminPassword: adminPassword }, storageProfile: { imageReference: { publisher: 'MicrosoftWindowsServer', offer: 'WindowsServer', sku: '2019-Datacenter', version: 'latest' }, osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'StandardSSD_LRS' } } }, networkProfile: { networkInterfaces: [{ id: w1Nic.id }] } } }
resource w2Vm 'Microsoft.Compute/virtualMachines@2023-03-01' = { name: 'w2', location: location1, properties: { availabilitySet: { id: avset.id }, hardwareProfile: { vmSize: 'Standard_B2ms' }, osProfile: { computerName: 'w2', adminUsername: adminUsername, adminPassword: adminPassword }, storageProfile: { imageReference: { publisher: 'MicrosoftWindowsServer', offer: 'WindowsServer', sku: '2019-Datacenter', version: 'latest' }, osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'StandardSSD_LRS' } } }, networkProfile: { networkInterfaces: [{ id: w2Nic.id }] } } }
resource ws11Vm 'Microsoft.Compute/virtualMachines@2023-03-01' = { name: 'ws11', location: location2, properties: { hardwareProfile: { vmSize: 'Standard_B1ms' }, osProfile: { computerName: 'ws11', adminUsername: adminUsername, adminPassword: adminPassword }, storageProfile: { imageReference: { publisher: 'MicrosoftWindowsServer', offer: 'WindowsServer', sku: '2019-Datacenter', version: 'latest' }, osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'StandardSSD_LRS' } }, dataDisks: [ { diskSizeGB: 10, lun: 0, createOption: 'Empty' } ] }, networkProfile: { networkInterfaces: [{ id: ws11Nic.id }] } } }
