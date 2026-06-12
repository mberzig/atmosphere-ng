#!/bin/sh

# Copyright (c) 2026 Mohamed Berzig
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

# Reconcile the namespaces covered by the tier driven Velero schedules
# from the tier label of the namespaces: every schedule backs up exactly
# the namespaces labeled with its tier and is paused while no namespace
# carries the label.

set -eu

: "${TIER_LABEL:?TIER_LABEL is required}"
: "${VELERO_NAMESPACE:?VELERO_NAMESPACE is required}"
: "${TIERS:?TIERS is required}"

for tier in ${TIERS}; do
    list=""
    for namespace in $(kubectl get namespaces -l "${TIER_LABEL}=${tier}" -o name); do
        namespace="${namespace#namespace/}"
        list="${list:+${list},}\"${namespace}\""
    done

    if [ -z "${list}" ]; then
        echo "tier ${tier}: no labeled namespace, pausing the schedule"
        kubectl patch schedule "velero-tier-${tier}" \
            --namespace "${VELERO_NAMESPACE}" \
            --type merge \
            --patch '{"spec":{"paused":true}}'
    else
        echo "tier ${tier}: covering [${list}]"
        kubectl patch schedule "velero-tier-${tier}" \
            --namespace "${VELERO_NAMESPACE}" \
            --type merge \
            --patch "{\"spec\":{\"paused\":false,\"template\":{\"includedNamespaces\":[${list}]}}}"
    fi
done
