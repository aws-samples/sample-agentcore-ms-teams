/*
 * Copyright 2026 Amazon.com, Inc. or its affiliates
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs/lib/construct';
import * as bedrockagentcore from 'aws-cdk-lib/aws-bedrockagentcore';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda'
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as kms from 'aws-cdk-lib/aws-kms';
import { BaseStackProps } from '../types';
import * as path from 'path';

export interface AgentCoreStackProps extends BaseStackProps {
    imageUri: string
}

export class AgentCoreStack extends cdk.Stack {
    readonly agentCoreRuntime: bedrockagentcore.CfnRuntime;
    readonly agentCoreGateway: bedrockagentcore.CfnGateway;
    readonly agentCoreMemory: bedrockagentcore.CfnMemory;
    readonly mcpLambda: lambda.Function;

    constructor(scope: Construct, id: string, props: AgentCoreStackProps) {
        super(scope, id, props);

        const region = cdk.Stack.of(this).region;
        const accountId = cdk.Stack.of(this).account;

        /*****************************
        * AgentCore Gateway
        ******************************/

        this.mcpLambda = new lambda.Function(this, `${props.appName}-McpLambda`, {
            runtime: lambda.Runtime.PYTHON_3_12,
            handler: "handler.lambda_handler",
            code: lambda.AssetCode.fromAsset(path.join(__dirname, '../../../mcp/lambda'))
        });

        const agentCoreGatewayRole = new iam.Role(this, `${props.appName}-AgentCoreGatewayRole`, {
            // aws:SourceAccount closes the confused-deputy path (only this account's
            // bedrock-agentcore service may assume the role).
            assumedBy: new iam.ServicePrincipal('bedrock-agentcore.amazonaws.com', {
                conditions: { StringEquals: { 'aws:SourceAccount': accountId } },
            }),
            description: 'IAM role for Bedrock AgentCore Runtime',
        });

        this.mcpLambda.grantInvoke(agentCoreGatewayRole);

        // Create gateway resource
        // Cognito resources
        const cognitoUserPool = new cognito.UserPool(this, `${props.appName}-CognitoUserPool`);

        // create resource server to work with client credentials auth flow
        const cognitoResourceServerScope = {
            scopeName: 'basic',
            scopeDescription: 'Basic access to teamsagent',
        };

        const cognitoResourceServer = cognitoUserPool.addResourceServer(`${props.appName}-CognitoResourceServer`, {
            identifier: `${props.appName}-CognitoResourceServer`,
            scopes: [cognitoResourceServerScope],
        });

        const cognitoAppClient = new cognito.UserPoolClient(this, `${props.appName}-CognitoAppClient`, {
            userPool: cognitoUserPool,
            generateSecret: true,
            oAuth: {
                flows: {
                    clientCredentials: true,
                },
                scopes: [cognito.OAuthScope.resourceServer(cognitoResourceServer, cognitoResourceServerScope)],
            },
            supportedIdentityProviders: [cognito.UserPoolClientIdentityProvider.COGNITO],
        });
        const cognitoDomain = cognitoUserPool.addDomain(`${props.appName}-CognitoDomain`, {
            cognitoDomain: {
                domainPrefix: `${props.appName.toLowerCase()}-${region}`,
            },
        });
        const cognitoTokenUrl = cognitoDomain.baseUrl() + '/oauth2/token';

        // Store the Cognito app client secret in Secrets Manager instead of
        // injecting it as a plaintext runtime environment variable. The runtime
        // reads it at startup via its execution role's GetSecretValue permission.
        // Encrypted with a customer-managed KMS key (rotation enabled) rather than
        // the AWS-managed default key.
        const cognitoSecretKey = new kms.Key(this, `${props.appName}-CognitoSecretKey`, {
            enableKeyRotation: true,
            description: 'CMK for the Cognito app client secret',
        });
        const cognitoClientSecret = new secretsmanager.Secret(this, `${props.appName}-CognitoClientSecret`, {
            secretStringValue: cognitoAppClient.userPoolClientSecret,
            encryptionKey: cognitoSecretKey,
        });

        this.agentCoreGateway = new bedrockagentcore.CfnGateway(this, `${props.appName}-AgentCoreGateway`, {
            name: `${props.appName}-Gateway`,
            protocolType: "MCP",
            roleArn: agentCoreGatewayRole.roleArn,
            authorizerType: "CUSTOM_JWT",
            authorizerConfiguration: {
                customJwtAuthorizer: {
                discoveryUrl:
                    'https://cognito-idp.' +
                    region +
                    '.amazonaws.com/' +
                    cognitoUserPool.userPoolId +
                    '/.well-known/openid-configuration',
                allowedClients: [cognitoAppClient.userPoolClientId],
                },
            },
        });

        new bedrockagentcore.CfnGatewayTarget(this, `${props.appName}-AgentCoreGatewayLambdaTarget`, {
            name: `${props.appName}-Target`,
            gatewayIdentifier: this.agentCoreGateway.attrGatewayIdentifier,
            credentialProviderConfigurations: [
                {
                    credentialProviderType: "GATEWAY_IAM_ROLE",
                },
            ],
            targetConfiguration: {
                mcp: {
                    lambda: {
                        lambdaArn: this.mcpLambda.functionArn,
                        toolSchema: {
                            inlinePayload: [
                                {
                                    name: "placeholder_tool",
                                    description: "No-op tool that demonstrates passing arguments",
                                    inputSchema: {
                                        type: "object",
                                        properties: {
                                            string_param: { type: 'string', description: 'Example string parameter' },
                                            int_param: { type: 'integer', description: 'Example integer parameter' },
                                            float_array_param: {
                                                type: 'array',
                                                description: 'Example float array parameter',
                                                items: {
                                                    type: 'number',
                                                }
                                            }
                                        },
                                        required: []
                                    }
                                }
                            ]
                        }
                    }
                }
            }
        })
        
        /*****************************
        * AgentCore Memory
        ******************************/

        this.agentCoreMemory = new bedrockagentcore.CfnMemory(this, `${props.appName}-AgentCoreMemory`, {
            name: "teamsagent_Memory",
            eventExpiryDuration: 30,
            description: "Memory resource with 30 days event expiry",
            memoryStrategies: [
                // can take a built-in strategy from https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/built-in-strategies.html or define a custom one
            ],
        });
        
        /*****************************
        * AgentCore Runtime
        ******************************/

        // taken from https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-permissions.html#runtime-permissions-execution
        const runtimePolicy = new iam.PolicyDocument({
            statements: [
                new iam.PolicyStatement({
                    sid: 'ECRImageAccess',
                    effect: iam.Effect.ALLOW,
                    actions: ['ecr:BatchGetImage', 'ecr:GetDownloadUrlForLayer'],
                    resources: [
                        `arn:aws:ecr:${region}:${accountId}:repository/*`,
                    ],
                }),
                new iam.PolicyStatement({
                    effect: iam.Effect.ALLOW,
                    actions: ['logs:DescribeLogStreams', 'logs:CreateLogGroup'],
                    resources: [
                        `arn:aws:logs:${region}:${accountId}:log-group:/aws/bedrock-agentcore/runtimes/*`,
                    ],
                }),
                new iam.PolicyStatement({
                    effect: iam.Effect.ALLOW,
                    actions: ['logs:DescribeLogGroups'],
                    resources: [
                        `arn:aws:logs:${region}:${accountId}:log-group:*`,
                    ],
                }),
                new iam.PolicyStatement({
                    effect: iam.Effect.ALLOW,
                    actions: ['logs:CreateLogStream', 'logs:PutLogEvents'],
                    resources: [
                        `arn:aws:logs:${region}:${accountId}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*`,
                    ],
                }),
                new iam.PolicyStatement({
                    sid: 'ECRTokenAccess',
                    effect: iam.Effect.ALLOW,
                    actions: ['ecr:GetAuthorizationToken'],
                    resources: ['*'],
                }),
                new iam.PolicyStatement({
                    effect: iam.Effect.ALLOW,
                    actions: [
                        'xray:PutTraceSegments',
                        'xray:PutTelemetryRecords',
                        'xray:GetSamplingRules',
                        'xray:GetSamplingTargets',
                    ],
                resources: ['*'],
                }),
                new iam.PolicyStatement({
                    effect: iam.Effect.ALLOW,
                    actions: ['cloudwatch:PutMetricData'],
                    resources: ['*'],
                    conditions: {
                        StringEquals: { 'cloudwatch:namespace': 'bedrock-agentcore' },
                    },
                }),
                new iam.PolicyStatement({
                    sid: 'GetAgentAccessToken',
                    effect: iam.Effect.ALLOW,
                    actions: [
                        'bedrock-agentcore:GetWorkloadAccessToken',
                        'bedrock-agentcore:GetWorkloadAccessTokenForJWT',
                        'bedrock-agentcore:GetWorkloadAccessTokenForUserId',
                    ],
                    resources: [
                        `arn:aws:bedrock-agentcore:${region}:${accountId}:workload-identity-directory/default`,
                        `arn:aws:bedrock-agentcore:${region}:${accountId}:workload-identity-directory/default/workload-identity/agentName-*`,
                    ],
                }),
                new iam.PolicyStatement({
                    sid: 'BedrockModelInvocation',
                    effect: iam.Effect.ALLOW,
                    actions: ['bedrock:InvokeModel', 'bedrock:InvokeModelWithResponseStream'],
                    // Scoped to the Claude Sonnet 4 model family in this region only.
                    // Do NOT broaden to arn:aws:bedrock:<region>:<account>:* or an
                    // all-region/all-model wildcard.
                    resources: [
                        `arn:aws:bedrock:${region}::foundation-model/anthropic.claude-sonnet-4*`,
                        `arn:aws:bedrock:${region}::foundation-model/us.anthropic.claude-sonnet-4*`,
                    ],
                }),
            ],
        });

        const runtimeRole = new iam.Role(this, `${props.appName}-AgentCoreRuntimeRole`, {
            // aws:SourceAccount closes the confused-deputy path (only this account's
            // bedrock-agentcore service may assume the role).
            assumedBy: new iam.ServicePrincipal('bedrock-agentcore.amazonaws.com', {
                conditions: { StringEquals: { 'aws:SourceAccount': accountId } },
            }),
            description: 'IAM role for Bedrock AgentCore Runtime',
            inlinePolicies: {
                RuntimeAccessPolicy: runtimePolicy
            }
        });

        // Allow the runtime to read only the Cognito client secret (scoped to that ARN).
        cognitoClientSecret.grantRead(runtimeRole);

        // Inbound auth is enforced on the runtime at deploy time, so the PUBLIC
        // endpoint is never reachable unauthenticated (no reliance on post-deploy
        // scripts). Pass `-c entraTenantId=<tenant> -c entraAudience=<bot app id>`
        // to validate Entra ID tokens from the Teams bot; otherwise the runtime
        // accepts tokens from this stack's Cognito app client (same as the gateway).
        const entraTenantId = this.node.tryGetContext('entraTenantId');
        const entraAudience = this.node.tryGetContext('entraAudience');
        const runtimeJwtAuthorizer = entraTenantId && entraAudience
            ? {
                discoveryUrl: `https://login.microsoftonline.com/${entraTenantId}/v2.0/.well-known/openid-configuration`,
                allowedAudience: [entraAudience],
            }
            : {
                discoveryUrl:
                    'https://cognito-idp.' + region + '.amazonaws.com/' +
                    cognitoUserPool.userPoolId + '/.well-known/openid-configuration',
                allowedClients: [cognitoAppClient.userPoolClientId],
            };

        this.agentCoreRuntime = new bedrockagentcore.CfnRuntime(this, `${props.appName}-AgentCoreRuntime`, {
            authorizerConfiguration: {
                customJwtAuthorizer: runtimeJwtAuthorizer,
            },
            agentRuntimeArtifact: {
                containerConfiguration: {
                    containerUri: props.imageUri
                }
            },
            agentRuntimeName: "teamsagent_Agent",
            protocolConfiguration: "HTTP",
            networkConfiguration: {
                networkMode: "PUBLIC"
            },
            roleArn: runtimeRole.roleArn,
            environmentVariables: {
                "AWS_REGION": region,
                "GATEWAY_URL": this.agentCoreGateway.attrGatewayUrl,
                
                "MEMORY_ID":  this.agentCoreMemory.attrMemoryId,
                "COGNITO_CLIENT_ID": cognitoAppClient.userPoolClientId,
                // Pass the Secrets Manager ARN, not the secret value. The runtime
                // fetches the secret at startup (see mcp_client/client.py).
                "COGNITO_CLIENT_SECRET_ARN": cognitoClientSecret.secretArn,
                "COGNITO_TOKEN_URL": cognitoTokenUrl,
                "COGNITO_SCOPE": `${cognitoResourceServer.userPoolResourceServerId}/${cognitoResourceServerScope.scopeName}`
            }
        });

        // DEFAULT endpoint always points to newest published version. Optionally, can use these versioned endpoints below
        // https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agent-runtime-versioning.html
        void new bedrockagentcore.CfnRuntimeEndpoint(this, `${props.appName}-AgentCoreRuntimeProdEndpoint`, {
            agentRuntimeId: this.agentCoreRuntime.attrAgentRuntimeId,
            agentRuntimeVersion: "1",
            name: "PROD"
        });

        void new bedrockagentcore.CfnRuntimeEndpoint(this, `${props.appName}-AgentCoreRuntimeDevEndpoint`, {
            agentRuntimeId: this.agentCoreRuntime.attrAgentRuntimeId,
            agentRuntimeVersion: "1",
            name: "DEV"
        });
    }
}