// Chroma or VecturaDB on one Azure VM with Docker, the data on a managed disk.
// One process on the data at a time: at every deployment the old container stops before the new one starts.

metadata description = 'Chroma or VecturaDB on one Azure VM with Docker, the data on a managed disk.'

@description('Name of the VM, and prefix of the other resources: 2 to 20 lowercase letters, digits and hyphens.')
@minLength(2)
@maxLength(20)
param name string = 'chroma'

@description('Region of the resources.')
param location string = resourceGroup().location

@description('The server: chroma (Chroma 1.5.9) or vecturadb (VecturaDB, built from Chroma, with sparse vectors, BM25, the Search API, collection fork and API keys).')
@allowed([
  'chroma'
  'vecturadb'
])
param engine string = 'chroma'

@description('Image of Chroma. The same image is on Docker Hub as chromadb/chroma.')
param chromaImage string = 'ghcr.io/chroma-core/chroma:1.5.9'

@description('Image of VecturaDB.')
param vecturadbImage string = 'ghcr.io/vecturadb/vecturadb:1.0.0-preview.3.post1'

@description('Size of the VM. Tested: Standard_B2pts_v2 (Arm), Standard_B1s, Standard_B1ms. Standard_B1ls runs out of memory at the first boot.')
param vmSize string = 'Standard_B2pts_v2'

@description('CPU of the VM size. auto: arm64 when the letters after the size number hold a p, like Standard_B2pts_v2 or Standard_D2ps_v5, x64 otherwise.')
@allowed([
  'auto'
  'x64'
  'arm64'
])
param cpuArchitecture string = 'auto'

@description('Who reaches the server: internal (only the virtual network, HTTP on the private address), allowed-ips (HTTPS from the allowed IP ranges), or public (HTTPS from anywhere, VecturaDB with an API key only).')
@allowed([
  'internal'
  'allowed-ips'
  'public'
])
param access string = 'internal'

@description('IP ranges, in CIDR notation, that may reach the server over HTTPS when access is allowed-ips.')
param allowedIpRanges array = []

@description('VecturaDB only: the API key of the admin user. Every request then needs it, in the x-chroma-token header. Required when access is public.')
@secure()
param apiKey string = ''

@description('Your own domain name for HTTPS, like chroma.example.com, with a DNS A record to the public IP. Empty: the Azure name of the public IP.')
param domainName string = ''

@description('Email for the account of the HTTPS certificate at Let\'s Encrypt. Optional.')
param acmeEmail string = ''

@description('Size of the data disk in GiB (Standard SSD).')
@minValue(4)
@maxValue(32767)
param dataDiskSizeGB int = 16

@description('Name of the admin account of the VM.')
param adminUsername string = 'azureuser'

@description('SSH public key of the admin account. Port 22 stays closed: the key is only for access through Azure Bastion or after you open the port yourself.')
param adminPublicKey string

@description('Backups of the data disk: disk (Azure Disk Backup, incremental snapshots) or none.')
@allowed([
  'disk'
  'none'
])
param backup string = 'disk'

@description('Hours between two backups of the data disk.')
@allowed([
  4
  6
  8
  12
  24
])
param backupEveryHours int = 24

@description('Days a backup is kept.')
@minValue(1)
@maxValue(360)
param backupRetentionDays int = 7

@description('Soft delete of the backup vault. On keeps deleted backups for 14 days, against a deletion by mistake or by an attacker; the vault then stays 14 days after its deletion. Off only for tests.')
@allowed([
  'On'
  'Off'
])
param backupSoftDelete string = 'On'

@description('Time of the deployment: leave the default. A run command with unchanged properties does not run again, so this value makes every deployment run configure.sh, even with the same parameters.')
param deployedAt string = utcNow()

var checks = [
  access == 'public' && (engine != 'vecturadb' || empty(apiKey))
    ? fail('access public needs engine vecturadb and an apiKey: Chroma 1.5.9 has no API keys.')
    : 'ok'
  access == 'allowed-ips' && empty(allowedIpRanges)
    ? fail('access allowed-ips needs at least one range in allowedIpRanges.')
    : 'ok'
]
var suffix = uniqueString(resourceGroup().id, name)
var image = engine == 'chroma' ? chromaImage : vecturadbImage
// Standard_B2pts_v2 -> b2pts: the first two characters are the family and the first digit, the rest says p for Arm.
var sizeName = toLower(split(vmSize, '_')[1])
var architecture = cpuArchitecture != 'auto' ? cpuArchitecture : (contains(substring(sizeName, 2), 'p') ? 'arm64' : 'x64')
var isPublic = access != 'internal'
var host = empty(domainName) ? publicIp!.properties.dnsSettings.fqdn : domainName

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${name}-nsg'
  location: location
  // The checks of the parameters: fail() stops the deployment at validation, before any resource is created.
  tags: {
    'parameter-checks': join(checks, ' ')
  }
  properties: {
    // Port 80 is open only for the HTTP-01 challenge of the certificate: Caddy answers nothing else on it.
    // Port 443 is open to the allowed ranges, or to anyone when access is public. Port 22 and port 8000 stay closed.
    securityRules: access == 'internal'
      ? []
      : [
          {
            name: 'certificate-challenge'
            properties: {
              priority: 100
              direction: 'Inbound'
              access: 'Allow'
              protocol: 'Tcp'
              sourceAddressPrefix: 'Internet'
              sourcePortRange: '*'
              destinationAddressPrefix: '*'
              destinationPortRange: '80'
            }
          }
          {
            name: 'https'
            properties: union(
              {
                priority: 110
                direction: 'Inbound'
                access: 'Allow'
                protocol: 'Tcp'
                sourcePortRange: '*'
                destinationAddressPrefix: '*'
                destinationPortRange: '443'
              },
              access == 'public' ? { sourceAddressPrefix: 'Internet' } : { sourceAddressPrefixes: allowedIpRanges }
            )
          }
        ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${name}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.42.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'vm'
        properties: {
          addressPrefix: '10.42.0.0/24'
          // Without a public IP the VM still needs to reach the package and image registries.
          defaultOutboundAccess: true
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (isPublic) {
  name: '${name}-ip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${name}-${take(suffix, 6)}'
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${name}-nic'
  location: location
  properties: {
    networkSecurityGroup: {
      id: nsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: union(
          {
            subnet: {
              id: vnet.properties.subnets[0].id
            }
            privateIPAllocationMethod: 'Dynamic'
          },
          isPublic
            ? {
                publicIPAddress: {
                  id: publicIp.id
                }
              }
            : {}
        )
      }
    ]
  }
}

resource dataDisk 'Microsoft.Compute/disks@2024-03-02' = {
  name: '${name}-data'
  location: location
  sku: {
    name: 'StandardSSD_LRS'
  }
  properties: {
    creationData: {
      createOption: 'Empty'
    }
    diskSizeGB: dataDiskSizeGB
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: name
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      customData: base64(loadTextContent('cloud-init.sh'))
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: architecture == 'arm64' ? 'server-arm64' : 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          createOption: 'Attach'
          caching: 'ReadOnly'
          deleteOption: 'Detach'
          managedDisk: {
            id: dataDisk.id
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource configure 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'configure'
  location: location
  properties: {
    source: {
      script: loadTextContent('configure.sh')
    }
    parameters: [
      {
        name: 'ENGINE'
        value: engine
      }
      {
        name: 'IMAGE'
        value: image
      }
      {
        name: 'ACCESS'
        value: access
      }
      {
        name: 'HOST'
        value: isPublic ? host : ''
      }
      {
        name: 'ALLOWED_IPS'
        value: join(allowedIpRanges, ' ')
      }
      {
        name: 'ACME_EMAIL'
        value: acmeEmail
      }
      {
        name: 'DEPLOYED_AT'
        value: deployedAt
      }
    ]
    protectedParameters: [
      {
        name: 'API_KEY'
        value: apiKey
      }
    ]
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
}

// Backups of the data disk with Azure Disk Backup: incremental snapshots in this resource group.
resource vault 'Microsoft.DataProtection/backupVaults@2024-04-01' = if (backup == 'disk') {
  name: '${name}-backup'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    storageSettings: [
      {
        datastoreType: 'OperationalStore'
        type: 'LocallyRedundant'
      }
    ]
    securitySettings: {
      softDeleteSettings: {
        state: backupSoftDelete
        retentionDurationInDays: 14
      }
      immutabilitySettings: {
        state: 'Disabled'
      }
    }
  }
}

resource policy 'Microsoft.DataProtection/backupVaults/backupPolicies@2024-04-01' = if (backup == 'disk') {
  parent: vault
  name: 'data-disk'
  properties: {
    objectType: 'BackupPolicy'
    datasourceTypes: [
      'Microsoft.Compute/disks'
    ]
    policyRules: [
      {
        name: 'Backup'
        objectType: 'AzureBackupRule'
        backupParameters: {
          objectType: 'AzureBackupParams'
          backupType: 'Incremental'
        }
        dataStore: {
          objectType: 'DataStoreInfoBase'
          dataStoreType: 'OperationalStore'
        }
        trigger: {
          objectType: 'ScheduleBasedTriggerContext'
          schedule: {
            repeatingTimeIntervals: [
              'R/2026-01-01T02:00:00+00:00/PT${backupEveryHours}H'
            ]
            timeZone: 'UTC'
          }
          taggingCriteria: [
            {
              isDefault: true
              taggingPriority: 99
              tagInfo: {
                tagName: 'Default'
              }
            }
          ]
        }
      }
      {
        name: 'Default'
        objectType: 'AzureRetentionRule'
        isDefault: true
        lifecycles: [
          {
            deleteAfter: {
              objectType: 'AbsoluteDeleteOption'
              duration: 'P${backupRetentionDays}D'
            }
            sourceDataStore: {
              objectType: 'DataStoreInfoBase'
              dataStoreType: 'OperationalStore'
            }
            targetDataStoreCopySettings: []
          }
        ]
      }
    ]
  }
}

// The vault reads the disk, writes the snapshots into this resource group, and restores them as new disks here.
var diskBackupReader = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3e5e47e6-65f7-47ef-90b5-e5dd4d455f24')
var diskSnapshotContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7efff54f-a5b4-42b5-a1c5-5411624893ce')
var diskRestoreOperator = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b50d9833-a0cb-478e-945f-707fcc997c13')

resource readDisk 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (backup == 'disk') {
  name: guid(dataDisk.id, 'disk-backup-reader', name)
  scope: dataDisk
  properties: {
    roleDefinitionId: diskBackupReader
    principalId: vault!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource writeSnapshots 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (backup == 'disk') {
  name: guid(resourceGroup().id, 'disk-snapshot-contributor', name)
  properties: {
    roleDefinitionId: diskSnapshotContributor
    principalId: vault!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource restoreDisks 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (backup == 'disk') {
  name: guid(resourceGroup().id, 'disk-restore-operator', name)
  properties: {
    roleDefinitionId: diskRestoreOperator
    principalId: vault!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource protectDisk 'Microsoft.DataProtection/backupVaults/backupInstances@2024-04-01' = if (backup == 'disk') {
  parent: vault
  name: '${name}-data'
  properties: {
    objectType: 'BackupInstance'
    dataSourceInfo: {
      objectType: 'Datasource'
      datasourceType: 'Microsoft.Compute/disks'
      resourceID: dataDisk.id
      resourceLocation: location
      resourceName: dataDisk.name
      resourceType: 'Microsoft.Compute/disks'
      resourceUri: dataDisk.id
    }
    policyInfo: {
      policyId: policy.id
      policyParameters: {
        dataStoreParametersList: [
          {
            objectType: 'AzureOperationalStoreParameters'
            dataStoreType: 'OperationalStore'
            resourceGroupId: resourceGroup().id
          }
        ]
      }
    }
  }
  dependsOn: [
    readDisk
    writeSnapshots
  ]
}

@description('Address for the clients.')
output url string = isPublic ? 'https://${host}' : 'http://${nic.properties.ipConfigurations[0].properties.privateIPAddress}:8000'

@description('Public IP of the VM; with your own domain name, its DNS A record points here.')
output publicIp string = isPublic ? publicIp!.properties.ipAddress : ''

output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output engine string = engine
output image string = image

@description('CPU architecture of the VM image.')
output architecture string = architecture
