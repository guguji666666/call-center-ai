param cognitiveCommunicationLocation string
param embeddingDeploymentType string
param embeddingModel string
param embeddingQuota int
param embeddingVersion string
param imageVersion string
param llmRealtimeContext int
param llmRealtimeDeploymentType string
param llmRealtimeModel string
param llmRealtimeQuota int
param llmRealtimeVersion string
param llmSequentialContext int
param llmSequentialDeploymentType string
param llmSequentialModel string
param llmSequentialQuota int
param llmSequentialVersion string
param location string
param openaiLocation string
param promptContentFilter bool
param searchLocation string
param tags object

var appName = 'call-center-ai'
var prefix = deployment().name
var appUrl = 'https://call-center-ai.${acaEnv.properties.defaultDomain}'
var llmRealtimeModelFullName = toLower('${llmRealtimeModel}-${llmRealtimeVersion}')
var llmSequentialModelFullName = toLower('${llmSequentialModel}-${llmSequentialVersion}')
var embeddingModelFullName = toLower('${embeddingModel}-${embeddingVersion}')
var cosmosContainerName = 'calls-v3' // Third schema version
var localConfig = loadYamlContent('../config.yaml')
var phonenumberSanitized = replace(localConfig.communication_services.phone_number, '+', '')
var config = {
  public_domain: appUrl
  database: {
    mode: 'cosmos_db'
    cosmos_db: {
      container: container.name
      database: database.name
      endpoint: cosmos.properties.documentEndpoint
    }
  }
  resources: {
    public_url: storageAccount.properties.primaryEndpoints.web
  }
  conversation: {
    initiate: {
      agent_phone_number: localConfig.conversation.initiate.agent_phone_number
      bot_company: localConfig.conversation.initiate.bot_company
      bot_name: localConfig.conversation.initiate.bot_name
      lang: localConfig.conversation.initiate.lang
    }
  }
  communication_services: {
    access_key: communicationServices.listKeys().primaryKey
    endpoint: communicationServices.properties.hostName
    phone_number: localConfig.communication_services.phone_number
    recording_container_url: '${storageAccount.properties.primaryEndpoints.blob}${recordingsBlob.name}'
    resource_id: communicationServices.properties.immutableResourceId
  }
  queue: {
    account_url: storageAccount.properties.primaryEndpoints.queue
    call_name: callQueue.name
    post_name: postQueue.name
    sms_name: smsQueue.name
    training_name: trainingsQueue.name
  }
  sms: localConfig.sms
  cognitive_service: {
    endpoint: cognitiveCommunication.properties.endpoint
  }
  llm: {
    realtime: {
      api_key: cognitiveOpenai.listKeys().key1
      context: llmRealtimeContext
      deployment: llmRealtime.name
      endpoint: cognitiveOpenai.properties.endpoint
      model: llmRealtimeModel
    }
    sequential: {
      context: llmSequentialContext
      deployment: llmSequential.name
      endpoint: cognitiveOpenai.properties.endpoint
      model: llmSequentialModel
    }
  }
  ai_search: {
    endpoint: 'https://${search.name}.search.windows.net'
    index: 'trainings'
  }
  prompts: {
    llm: localConfig.prompts.llm
    tts: localConfig.prompts.tts
  }
  ai_translation: {
    access_key: translate.listKeys().key1
    endpoint: 'https://${translate.name}.cognitiveservices.azure.com/'
  }
  cache: {
    mode: 'redis'
    redis: {
      host: redis.properties.hostName
      password: redis.listKeys().primaryKey
      port: redis.properties.sslPort
    }
  }
  app_configuration: {
    endpoint: configStore.properties.endpoint
  }
}

output appUrl string = appUrl
output blobStoragePublicName string = storageAccount.name
output containerAppName string = containerApp.name
output logAnalyticsCustomerId string = logAnalytics.properties.customerId

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: prefix
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018' // Pay-as-you-go
    }
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: prefix
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource acaEnv 'Microsoft.App/managedEnvironments@2024-02-02-preview' = {
  name: prefix
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

var containerAppScaleRules = [
  for queue in [
    callQueue.name
    postQueue.name
    smsQueue.name
    trainingsQueue.name
  ]: {
    name: 'queue-${queue}'
    azureQueue: {
      accountName: storageAccount.name
      identity: 'system'
      queueLength: 1
      queueName: queue
    }
  }
]

resource containerApp 'Microsoft.App/containerApps@2024-02-02-preview' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
      }
    }
    environmentId: acaEnv.id
    template: {
      containers: [
        {
          image: 'ghcr.io/microsoft/call-center-ai:${imageVersion}'
          name: 'call-center-ai'
          env: [
            // App configuration
            {
              name: 'CONFIG_JSON'
              value: string(config)
            }
            // Application Insights
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: applicationInsights.properties.ConnectionString
            }
          ]
          resources: {
            cpu: 1
            memory: '2Gi'
          }
          probes: [
            {
              type: 'Startup'
              tcpSocket: {
                port: 8080
              }
            }
            {
              type: 'Liveness'
              httpGet: {
                path: '/health/liveness'
                port: 8080
              }
              periodSeconds: 10 // 2x the timeout
              timeoutSeconds: 5 // Fast to check if the app is running
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health/readiness'
                port: 8080
              }
              periodSeconds: 20 // 2x the timeout
              timeoutSeconds: 10 // Database can take a while to be ready, query is necessary but expensive to run
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        rules: concat(containerAppScaleRules, [
          {
            name: 'cpu-utilization'
            custom: {
              type: 'cpu'
              metadata: {
                type: 'Utilization'
                value: '80'
              }
            }
          }
        ])
      }
    }
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: replace(toLower(prefix), '-', '')
  location: location
  tags: tags
  sku: {
    name: 'Standard_ZRS'
  }
  kind: 'StorageV2'
  properties: {
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource callQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: 'call-${phonenumberSanitized}'
}

resource smsQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: 'sms-${phonenumberSanitized}'
}

resource postQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: 'post-${phonenumberSanitized}'
}

resource trainingsQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: 'trainings-${phonenumberSanitized}'
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource publicBlob 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: '$web'
}

resource recordingsBlob 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'recordings'
}

// Storage Blob Data Contributor
resource roleDataContributor 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
}

resource assignmentCommunicationServicesContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, prefix, storageAccount.name, 'assignmentCommunicationServicesContributor')
  scope: storageAccount
  properties: {
    principalId: communicationServices.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDataContributor.id
  }
}

// Storage Queue Data Contributor
resource roleQueueContributor 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
}

resource assignmentContainerAppQueueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, prefix, storageAccount.name, 'assignmentContainerAppQueueContributor')
  scope: storageAccount
  properties: {
    principalId: containerApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleQueueContributor.id
  }
}

resource communicationServices 'Microsoft.Communication/CommunicationServices@2023-06-01-preview' existing = {
  name: prefix
}

resource eventgridTopic 'Microsoft.EventGrid/systemTopics@2024-06-01-preview' = {
  name: prefix
  location: 'global'
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    source: communicationServices.id
    topicType: 'Microsoft.Communication.CommunicationServices'
  }
}

// Storage Queue Data Message Sender
resource roleQueueSender 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'c6a89b2d-59bc-44d0-9896-0f6e12d7b80a'
}

resource assignmentEventgridTopicQueueSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, prefix, storageAccount.name, 'assignmentEventgridTopicQueueSender')
  scope: storageAccount
  properties: {
    principalId: eventgridTopic.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleQueueSender.id
  }
}

resource eventgridSubscriptionCall 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2024-06-01-preview' = {
  parent: eventgridTopic
  name: '${prefix}-${phonenumberSanitized}'
  properties: {
    eventDeliverySchema: 'EventGridSchema'
    deliveryWithResourceIdentity: {
      identity: {
        type: 'SystemAssigned'
      }
      destination: {
        endpointType: 'StorageQueue'
        properties: {
          queueMessageTimeToLiveInSeconds: 30 // Short lived messages, only new call events
          queueName: callQueue.name
          resourceId: storageAccount.id
        }
      }
    }
    filter: {
      enableAdvancedFilteringOnArrays: true
      advancedFilters: [
        {
          operatorType: 'StringBeginsWith'
          key: 'data.to.PhoneNumber.Value'
          values: [
            localConfig.communication_services.phone_number
          ]
        }
      ]
      includedEventTypes: ['Microsoft.Communication.IncomingCall']
    }
  }
  dependsOn: [assignmentEventgridTopicQueueSender]
}

resource eventgridSubscriptionSms 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2024-06-01-preview' = {
  parent: eventgridTopic
  name: '${prefix}-${phonenumberSanitized}-sms'
  properties: {
    eventDeliverySchema: 'EventGridSchema'
    deliveryWithResourceIdentity: {
      identity: {
        type: 'SystemAssigned'
      }
      destination: {
        endpointType: 'StorageQueue'
        properties: {
          queueMessageTimeToLiveInSeconds: -1 // Infinite persistence, SMS is async
          queueName: smsQueue.name
          resourceId: storageAccount.id
        }
      }
    }
    filter: {
      enableAdvancedFilteringOnArrays: true
      advancedFilters: [
        {
          operatorType: 'StringBeginsWith'
          key: 'data.to'
          values: [
            localConfig.communication_services.phone_number
          ]
        }
      ]
      includedEventTypes: ['Microsoft.Communication.SMSReceived']
    }
  }
  dependsOn: [assignmentEventgridTopicQueueSender]
}

// Cognitive Services User
resource roleCognitiveUser 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'a97b65f3-24c7-4388-baec-2e87135dc908'
}

resource assignmentsCommunicationServicesCognitiveUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, prefix, cognitiveCommunication.name, 'assignmentsCommunicationServicesCognitiveUser')
  scope: cognitiveCommunication
  properties: {
    principalId: communicationServices.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleCognitiveUser.id
  }
}

resource cognitiveCommunication 'Microsoft.CognitiveServices/accounts@2024-06-01-preview' = {
  name: '${prefix}-${cognitiveCommunicationLocation}-communication'
  location: cognitiveCommunicationLocation
  tags: tags
  sku: {
    name: 'S0' // Only one available
  }
  kind: 'CognitiveServices'
  properties: {
    customSubDomainName: '${prefix}-${cognitiveCommunicationLocation}-communication'
  }
}

// Cognitive Services OpenAI Contributor
resource roleOpenaiContributor 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'a001fd3d-188f-4b5d-821b-7da978bf7442'
}

resource assignmentsContainerAppOpenaiContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, prefix, cognitiveOpenai.name, 'assignmentsContainerAppOpenaiContributor')
  scope: cognitiveOpenai
  properties: {
    principalId: containerApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleOpenaiContributor.id
  }
}

resource cognitiveOpenai 'Microsoft.CognitiveServices/accounts@2024-06-01-preview' = {
  name: '${prefix}-${openaiLocation}-openai'
  location: openaiLocation
  tags: tags
  sku: {
    name: 'S0' // Pay-as-you-go
  }
  kind: 'OpenAI'
  properties: {
    customSubDomainName: '${prefix}-${openaiLocation}-openai'
  }
}

resource contentfilter 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-06-01-preview' = {
  parent: cognitiveOpenai
  name: 'disabled'
  tags: tags
  properties: {
    basePolicyName: 'Microsoft.Default'
    mode: 'Asynchronous_filter'
    contentFilters: [
      // Indirect attacks
      {
        blocking: true
        enabled: true
        name: 'indirect_attack'
        severityThreshold: 'Medium'
        source: 'Prompt'
      }
      // Jailbreak
      {
        blocking: true
        enabled: true
        name: 'jailbreak'
        severityThreshold: 'Medium'
        source: 'Prompt'
      }
      // Prompt
      {
        blocking: !promptContentFilter
        enabled: !promptContentFilter
        name: 'hate'
        severityThreshold: 'Low'
        source: 'Prompt'
      }
      {
        blocking: !promptContentFilter
        enabled: !promptContentFilter
        name: 'sexual'
        severityThreshold: 'Low'
        source: 'Prompt'
      }
      {
        blocking: !promptContentFilter
        enabled: !promptContentFilter
        name: 'selfharm'
        severityThreshold: 'Low'
        source: 'Prompt'
      }
      {
        blocking: !promptContentFilter
        enabled: !promptContentFilter
        name: 'violence'
        severityThreshold: 'Low'
        source: 'Prompt'
      }
      {
        blocking: !promptContentFilter
        enabled: !promptContentFilter
        name: 'profanity'
        severityThreshold: 'Low'
        source: 'Prompt'
      }
      // Completion
      {
        blocking: !promptContentFilter
        enabled: !promptContentFilter
        name: 'hate'
        severityThreshold: 'Low'
        source: 'Completion'
      }
      {
        blocking: !promptContentFilter
        enabled: !promptContentFilter
        name: 'sexual'
        severityThreshold: 'Low'
        source: 'Completion'
      }
      {
        blocking: !promptContentFilter
        enabled: !promptContentFilter
        name: 'selfharm'
        severityThreshold: 'Low'
        source: 'Completion'
      }
      {
        blocking: !promptContentFilter
        enabled: !promptContentFilter
        name: 'violence'
        severityThreshold: 'Low'
        source: 'Completion'
      }
      {
        blocking: !promptContentFilter
        enabled: !promptContentFilter
        name: 'profanity'
        severityThreshold: 'Low'
        source: 'Completion'
      }
    ]
  }
}

resource llmSequential 'Microsoft.CognitiveServices/accounts/deployments@2024-06-01-preview' = {
  parent: cognitiveOpenai
  name: llmSequentialModelFullName
  tags: tags
  sku: {
    capacity: llmSequentialQuota
    name: llmSequentialDeploymentType
  }
  properties: {
    raiPolicyName: contentfilter.name
    versionUpgradeOption: 'NoAutoUpgrade'
    model: {
      format: 'OpenAI'
      name: llmSequentialModel
      version: llmSequentialVersion
    }
  }
}

resource llmRealtime 'Microsoft.CognitiveServices/accounts/deployments@2024-06-01-preview' = {
  parent: cognitiveOpenai
  name: llmRealtimeModelFullName
  tags: tags
  sku: {
    capacity: llmRealtimeQuota
    name: llmRealtimeDeploymentType
  }
  properties: {
    raiPolicyName: contentfilter.name
    versionUpgradeOption: 'NoAutoUpgrade'
    model: {
      format: 'OpenAI'
      name: llmRealtimeModel
      version: llmRealtimeVersion
    }
  }
  dependsOn: [
    llmSequential
  ]
}

resource embedding 'Microsoft.CognitiveServices/accounts/deployments@2024-06-01-preview' = {
  parent: cognitiveOpenai
  name: embeddingModelFullName
  tags: tags
  sku: {
    capacity: embeddingQuota
    name: embeddingDeploymentType
  }
  properties: {
    raiPolicyName: contentfilter.name
    versionUpgradeOption: 'NoAutoUpgrade'
    model: {
      format: 'OpenAI'
      name: embeddingModel
      version: embeddingVersion
    }
  }
  dependsOn: [
    llmRealtime
  ]
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: prefix
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    consistencyPolicy: {
      defaultConsistencyLevel: 'BoundedStaleness' // ACID in a single-region, lag in the others
      maxIntervalInSeconds: 600 // 5 mins lags at maximum
      maxStalenessPrefix: 1000 // 1000 requests lags at max
    }
    databaseAccountOfferType: 'Standard'
    disableLocalAuth: true
    locations: [
      {
        locationName: location
      }
    ]
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: cosmos
  name: appName
  properties: {
    resource: {
      id: appName
    }
  }
}

resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: database
  name: cosmosContainerName
  properties: {
    resource: {
      id: cosmosContainerName
      indexingPolicy: {
        automatic: true
        includedPaths: [
          {
            path: '/created_at/?'
            indexes: [
              {
                dataType: 'String'
                kind: 'Range'
                precision: -1
              }
            ]
          }
          {
            path: '/claim/policyholder_phone/?'
            indexes: [
              {
                dataType: 'String'
                kind: 'Hash'
                precision: -1
              }
            ]
          }
        ]
        excludedPaths: [
          {
            path: '/*'
          }
        ]
      }
      partitionKey: {
        paths: [
          '/initiate/phone_number'
        ]
        kind: 'Hash'
      }
    }
  }
}

// Cosmos DB Built-in Data Contributor
resource sqlRoleDefinition 'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions@2024-05-15' existing = {
  parent: cosmos
  name: '00000000-0000-0000-0000-000000000002'
}

resource assignmentContainerAppCosmosBuiltinDataContributor 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmos
  name: guid(cosmos.id, containerApp.id, sqlRoleDefinition.id)
  properties: {
    principalId: containerApp.identity.principalId
    roleDefinitionId: sqlRoleDefinition.id
    scope: cosmos.id
  }
}

resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: prefix
  location: searchLocation
  tags: tags
  sku: {
    name: 'basic' // Smallest with semantic search
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    disableLocalAuth: true
    semanticSearch: 'standard'
  }
}

// Search Index Data Reader
resource roleSearchDataReader 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '1407120a-92aa-4202-b7e9-c0e197c71c8f'
}

resource assignmentSearchDataReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, prefix, search.name, 'assignmentSearchDataReader')
  scope: search
  properties: {
    principalId: containerApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleSearchDataReader.id
  }
}

resource translate 'Microsoft.CognitiveServices/accounts@2024-06-01-preview' = {
  name: '${prefix}-${location}-translate'
  location: location
  tags: tags
  sku: {
    name: 'S1' // Pay-as-you-go
  }
  kind: 'TextTranslation'
  properties: {
    customSubDomainName: '${prefix}-${location}-translate'
  }
}

resource redis 'Microsoft.Cache/redis@2024-03-01' = {
  name: prefix
  location: location
  tags: tags
  properties: {
    sku: {
      capacity: 0 // 250 MB of data
      family: 'C'
      name: 'Standard' // First tier with SLA
    }
    minimumTlsVersion: '1.2'
    redisVersion: '6' // v6.x
  }
}

resource configStore 'Microsoft.AppConfiguration/configurationStores@2023-03-01' = {
  name: prefix
  location: location
  sku: {
    name: 'Standard'
  }
}

// App Configuration Data Reader
resource roleAppConfigurationDataReader 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '516239f1-63e1-4d78-a4de-a74fb236a071'
}

resource assignmentAppConfigurationDataReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, prefix, configStore.name, 'assignmentAppConfigurationDataReader')
  scope: configStore
  properties: {
    principalId: containerApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleAppConfigurationDataReader.id
  }
}

resource configValues 'Microsoft.AppConfiguration/configurationStores/keyValues@2023-03-01' = [
  for item in items({
    answer_hard_timeout_sec: 180
    answer_soft_timeout_sec: 30
    callback_timeout_hour: 72
    phone_silence_timeout_sec: 1
    recording_enabled: false
    slow_llm_for_chat: true
    voice_recognition_retry_max: 2
  }): {
    parent: configStore
    name: item.key
    properties: {
      value: string(item.value)
    }
  }
]
