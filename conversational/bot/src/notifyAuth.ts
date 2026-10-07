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

import { Request } from "restify";

const NOTIFY_SECRET = process.env.NOTIFY_SECRET || "";

export function validateNotifyRequest(req: Request): { valid: boolean; error?: string } {
  // Deny by default: NOTIFY_SECRET is required. Never fall through to allow-all
  // when it is unset — an unconfigured deployment must fail closed, not open.
  if (!NOTIFY_SECRET) {
    return { valid: false, error: "NOTIFY_SECRET is not configured; refusing request" };
  }

  const authHeader = req.headers["authorization"] || "";
  const token = authHeader.replace("Bearer ", "");
  if (token !== NOTIFY_SECRET) {
    return { valid: false, error: "Invalid or missing authorization token" };
  }
  return { valid: true };
}
