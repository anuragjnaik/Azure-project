targetScope = 'resourceGroup'

param location1 string = 'eastus'
param location2 string = 'eastus2'

var vnet1Name = 'eastus-vnet'
var vnet2Name = 'eastus2-vnet'

/* ---------------- VNET 1 ---------------- */

resource vnet1 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnet1Name
  location: location1
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'web-subnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
        }
      }
    ]
  }
}

/* ---------------- VNET 2 ---------------- */

resource vnet2 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnet2Name
  location: location2
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.1.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'app-subnet'
        properties: {
          addressPrefix: '10.1.1.0/24'
        }
      }
    ]
  }
}

/* ---------------- PEERING ---------------- */

resource peer1 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-05-01' = {
  name: 'peer1'
  parent: vnet1
  properties: {
    remoteVirtualNetwork: {
      id: vnet2.id
    }
    allowVirtualNetworkAccess: true
  }
}

resource peer2 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-05-01' = {
  name: 'peer2'
  parent: vnet2
  properties: {
    remoteVirtualNetwork: {
      id: vnet1.id
    }
    allowVirtualNetworkAccess: true
  }
}




