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
import * as ecr_assets from 'aws-cdk-lib/aws-ecr-assets'
import { BaseStackProps } from '../types';
import * as path from 'path';

export interface DockerImageStackProps extends BaseStackProps {}

export class DockerImageStack extends cdk.Stack {
    readonly imageUri: string

    constructor(scope: Construct, id: string, props: DockerImageStackProps) {
        super(scope, id, props);

        const asset = new ecr_assets.DockerImageAsset(this, `${props.appName}-AppImage`, {
            directory: path.join(__dirname, "../../../"), // path to root of the project
        });

        this.imageUri = asset.imageUri;
        new cdk.CfnOutput(this, 'ImageUri', { value: this.imageUri });
    }
}