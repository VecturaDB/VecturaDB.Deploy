// Chroma on Azure Container Apps, with the data on an Azure Files SMB share and scale to zero.
// One replica at most. A lock file in front of the server keeps one process on the data: during a change of revision
// the new replica waits until the old one stops (see the README for the manual step).

metadata description = 'Chroma 1.5.9 on Azure Container Apps, with the data on Azure Files SMB and scale to zero.'

@description('Name of the container app, and prefix of the other resources: 2 to 20 lowercase letters, digits and hyphens.')
@minLength(2)
@maxLength(20)
param name string = 'chroma'

@description('Region of the resources.')
param location string = resourceGroup().location

@description('Image of the server. Chroma 1.5.9; the same image is on Docker Hub as chromadb/chroma.')
param image string = 'ghcr.io/chroma-core/chroma:1.5.9'

@description('Who reaches the server: allowed-ips (HTTPS from the allowed IP ranges) or internal (only apps in the same Container Apps environment). Chroma 1.5.9 has no API keys, so the server is never open to everyone.')
@allowed([
  'allowed-ips'
  'internal'
])
param access string = 'allowed-ips'

@description('IP ranges, in CIDR notation, that may reach the server over HTTPS when access is allowed-ips.')
param allowedIpRanges array = []

@description('CPU cores of the replica: 0.5 with 1Gi of memory, or 1.0 with 2Gi.')
param cpu string = '0.5'

@description('Memory of the replica.')
param memory string = '1Gi'

@description('Days of logs in Log Analytics.')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 30

var checks = [
  access == 'allowed-ips' && empty(allowedIpRanges)
    ? fail('access allowed-ips needs at least one range in allowedIpRanges.')
    : 'ok'
]
var suffix = uniqueString(resourceGroup().id, name)

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${name}-logs'
  location: location
  // The checks of the parameters: fail() stops the deployment at validation, before any resource is created.
  tags: {
    'parameter-checks': join(checks, ' ')
  }
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionDays
  }
}

resource account 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: 'st${take(replace(name, '-', ''), 10)}${take(suffix, 12)}'
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    // Container Apps mounts the share with the account key.
    allowSharedKeyAccess: true
  }
}

resource files 'Microsoft.Storage/storageAccounts/fileServices@2024-01-01' = {
  parent: account
  name: 'default'
  properties: {
    // A deleted share can be restored for 7 days.
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = {
  parent: files
  name: 'data'
  properties: {
    enabledProtocols: 'SMB'
    accessTier: 'TransactionOptimized'
    shareQuota: 100
  }
}

resource env 'Microsoft.App/managedEnvironments@2026-01-01' = {
  name: '${name}-env'
  location: location
  properties: {
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

resource storage 'Microsoft.App/managedEnvironments/storages@2026-01-01' = {
  parent: env
  name: 'data'
  properties: {
    azureFile: {
      accountName: account.name
      accountKey: account.listKeys().keys[0].value
      shareName: share.name
      accessMode: 'ReadWrite'
    }
  }
}

resource app 'Microsoft.App/containerApps@2026-01-01' = {
  name: name
  location: location
  properties: {
    environmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: access == 'allowed-ips'
        targetPort: 8000
        transport: 'auto'
        allowInsecure: false
        ipSecurityRestrictions: [
          for (range, i) in allowedIpRanges: {
            name: 'allowed-${i}'
            action: 'Allow'
            ipAddressRange: range
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'chroma'
          image: image
          // dumb-init stays process 1. The shell opens the lock file as descriptor 9, waits for the lock, then becomes
          // the server, which keeps descriptor 9: the lock goes only when the server stops.
          command: [
            'dumb-init'
            '--'
            'sh'
            '-c'
            'exec 9>>/lock/.lock; echo "waiting for the lock"; flock 9; echo "lock taken"; exec chroma run /config.yaml'
          ]
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          volumeMounts: [
            {
              volumeName: 'data'
              mountPath: '/data'
              subPath: 'chroma'
            }
            {
              volumeName: 'lock'
              mountPath: '/lock'
            }
          ]
          probes: [
            {
              type: 'Startup'
              httpGet: {
                path: '/api/v2/heartbeat'
                port: 8000
              }
              periodSeconds: 5
              timeoutSeconds: 3
              failureThreshold: 60
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/api/v2/heartbeat'
                port: 8000
              }
              periodSeconds: 10
              timeoutSeconds: 5
              failureThreshold: 3
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
      volumes: [
        {
          // The data with nobrl: byte-range locks stay on the replica. With the locks sent to the server, Chroma 1.5.9
          // did not start in our tests.
          name: 'data'
          storageType: 'AzureFile'
          storageName: storage.name
          mountOptions: 'nobrl'
        }
        {
          // The lock file without nobrl: the lock reaches the server, so it holds across replicas and hosts.
          name: 'lock'
          storageType: 'AzureFile'
          storageName: storage.name
        }
      ]
    }
  }
}

@description('Address for the clients. With internal access it answers only inside the Container Apps environment.')
output url string = 'https://${app.properties.configuration.ingress.fqdn}'

output storageAccount string = account.name
output image string = image
