// Chroma on Azure Container Apps, with the data on an Azure Files SMB share and scale to zero.
// One replica at most. A lock file in front of the server keeps one process on the data: during a change of revision
// the new replica waits until the old one stops (see the README for the manual step). Backups of the share with Azure
// Backup.

metadata description = 'Chroma 1.5.9 on Azure Container Apps, with the data on Azure Files SMB, scale to zero and backups with Azure Backup.'

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

@description('Backups of the file share: files (Azure Backup, snapshots of the share in its storage account) or none.')
@allowed([
  'files'
  'none'
])
param backup string = 'files'

@description('Hours between two backups of the file share.')
@allowed([
  4
  6
  8
  12
  24
])
param backupEveryHours int = 24

@description('Days a backup is kept. A share keeps at most 200 snapshots: up to 200 days with a backup every 24 hours, 99 every 12, 65 every 8, 49 every 6 and 32 every 4.')
@minValue(1)
@maxValue(200)
param backupRetentionDays int = 7

@description('true on a new deployment of this template when its backups are already on: the share stays protected as it is, and only the schedule and the days kept are applied again. Without it, a new deployment protects the share again, and Azure Backup reports one of its two configure jobs as failed. Never true on the first deployment: the share would not be protected.')
param backupAlreadyOn bool = false

var backupsPerDay = 24 / backupEveryHours
// With more backups a day, Azure Backup allows the snapshots of a day for each day kept, plus one day.
var backupMaxDays = backupEveryHours == 24 ? 200 : 200 / backupsPerDay - 1
var checks = [
  access == 'allowed-ips' && empty(allowedIpRanges)
    ? fail('access allowed-ips needs at least one range in allowedIpRanges.')
    : 'ok'
  backup == 'files' && backupRetentionDays > backupMaxDays
    ? fail('With a backup every ${backupEveryHours} hours, backupRetentionDays can be at most ${backupMaxDays}: a share keeps at most 200 snapshots.')
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

// Backups of the file share with Azure Backup: snapshots of the share, kept in its storage account. As Microsoft's samples
// recovery-services-backup-file-share and recovery-services-backup-file-share-hourly (azure-quickstart-templates).
var backupFabric = 'Azure'
var backupManagementType = 'AzureStorage'
var backupRunTimes = [
  '2020-01-01T02:00:00Z'
]

resource vault 'Microsoft.RecoveryServices/vaults@2021-12-01' = if (backup == 'files') {
  name: '${name}-backup'
  location: location
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {}
}

resource backupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2022-02-01' = if (backup == 'files') {
  parent: vault
  name: 'data-share'
  properties: {
    backupManagementType: backupManagementType
    // The first backup of the day at 02:00 UTC; with more backups a day, the last one 24 hours minus the interval later.
    schedulePolicy: backupEveryHours == 24
      ? {
          schedulePolicyType: 'SimpleSchedulePolicy'
          scheduleRunFrequency: 'Daily'
          scheduleRunTimes: backupRunTimes
        }
      : {
          schedulePolicyType: 'SimpleSchedulePolicy'
          scheduleRunFrequency: 'Hourly'
          scheduleRunTimes: backupRunTimes
          hourlySchedule: {
            interval: backupEveryHours
            scheduleWindowStartTime: '2020-01-01T02:00:00.000Z'
            scheduleWindowDuration: 24 - backupEveryHours
          }
        }
    retentionPolicy: {
      dailySchedule: {
        retentionTimes: backupRunTimes
        retentionDuration: {
          count: backupRetentionDays
          durationType: 'Days'
        }
      }
      retentionPolicyType: 'LongTermRetentionPolicy'
    }
    timeZone: 'UTC'
    workLoadType: 'AzureFileShare'
  }
}

// The storage account registered to the vault, then the share protected with the policy. A new deployment that puts
// both the policy and the protected share again starts two configure jobs on the share, and one fails: with
// backupAlreadyOn the protection stays as it is, and the policy alone applies the changes.
resource backupContainer 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers@2021-12-01' = if (backup == 'files' && !backupAlreadyOn) {
  name: '${vault.name}/${backupFabric}/storagecontainer;Storage;${resourceGroup().name};${account.name}'
  properties: {
    backupManagementType: backupManagementType
    containerType: 'StorageContainer'
    sourceResourceId: account.id
  }
  dependsOn: [
    backupPolicy
    share
  ]
}

resource protectShare 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2021-12-01' = if (backup == 'files' && !backupAlreadyOn) {
  parent: backupContainer
  name: 'AzureFileShare;${share.name}'
  properties: {
    protectedItemType: 'AzureFileShareProtectedItem'
    sourceResourceId: account.id
    policyId: backupPolicy.id
    // As the daily sample: the API takes it, the types of Bicep do not know it.
    #disable-next-line BCP037
    isInlineInquiry: true
  }
}

@description('Address for the clients. With internal access it answers only inside the Container Apps environment.')
output url string = 'https://${app.properties.configuration.ingress.fqdn}'

output storageAccount string = account.name
output image string = image
