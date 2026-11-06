# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
variable "account_id" {
  description = "Cloudflare account id."
  type        = string
}

variable "script_name" {
  description = "Worker name."
  type        = string
  default     = "kskill-token-broker"
}

variable "hostname" {
  description = "Host the broker answers on; empty turns on the workers.dev address. The zone must not challenge GitHub's runners (README)."
  type        = string
  default     = ""
}

variable "zone_id" {
  description = "Zone of var.hostname."
  type        = string
  default     = ""
}

variable "app_id" {
  description = "The GitHub App's id."
  type        = string
}

variable "policy" {
  description = "Who may ask for what: see the head of worker/index.mjs."
  type        = any
}
