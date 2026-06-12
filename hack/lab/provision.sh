#!/usr/bin/env bash

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

# Provision the two-region disaster recovery lab on an OpenStack cloud:
# region1 simulates the primary region with two availability zones and
# region2 the recovery region. Every node receives a data volume for the
# Ceph OSDs and no floating IP is assigned: the router only provides
# SNAT egress and the nodes are reached through the OVN metadata
# namespaces (see the ssh-config command). The script is idempotent.
#
#   Usage: OS_CLOUD=<cloud> ./provision.sh [up|status|ssh-config|down]

set -o errexit
set -o nounset
set -o pipefail

: "${OS_CLOUD:?OS_CLOUD must point to a clouds.yaml entry}"
OPENSTACK="${OPENSTACK:-openstack}"

LAB_PREFIX="${LAB_PREFIX:-kclab}"
LAB_IMAGE="${LAB_IMAGE:-ubuntu-22.04}"
LAB_GATEWAY_NETWORK="${LAB_GATEWAY_NETWORK:-public1}"
LAB_GATEWAY_IP="${LAB_GATEWAY_IP:-}"
LAB_KEYPAIR="${LAB_KEYPAIR:-${LAB_PREFIX}-key}"
LAB_KEYFILE="${LAB_KEYFILE:-${HOME}/.ssh/${LAB_PREFIX}}"
LAB_FLAVOR_CONTROLLER="${LAB_FLAVOR_CONTROLLER:-m1.3xlarge}"
LAB_FLAVOR_WORKER="${LAB_FLAVOR_WORKER:-m1.2xlarge}"
LAB_DATA_VOLUME_SIZE="${LAB_DATA_VOLUME_SIZE:-50}"
LAB_HYPERVISOR_USER="${LAB_HYPERVISOR_USER:-ubuntu}"

# name network flavor zone
SERVERS="
${LAB_PREFIX}-r1-ctl-1 region1 ${LAB_FLAVOR_CONTROLLER} az1
${LAB_PREFIX}-r1-ctl-2 region1 ${LAB_FLAVOR_CONTROLLER} az2
${LAB_PREFIX}-r1-ctl-3 region1 ${LAB_FLAVOR_CONTROLLER} az1
${LAB_PREFIX}-r1-cmp-1 region1 ${LAB_FLAVOR_WORKER} az1
${LAB_PREFIX}-r1-cmp-2 region1 ${LAB_FLAVOR_WORKER} az2
${LAB_PREFIX}-r2-ctl-1 region2 ${LAB_FLAVOR_CONTROLLER} dr
${LAB_PREFIX}-r2-cmp-1 region2 ${LAB_FLAVOR_WORKER} dr
${LAB_PREFIX}-r2-cmp-2 region2 ${LAB_FLAVOR_WORKER} dr
"

log() {
    echo "$(date --iso-8601=seconds) | $*" >&2
}

ensure_network() {
    local region="$1" cidr="$2"
    local net="${LAB_PREFIX}-${region}"

    if ! ${OPENSTACK} network show "${net}" > /dev/null 2>&1; then
        log "creating network ${net} (${cidr})"
        ${OPENSTACK} network create "${net}" > /dev/null
        ${OPENSTACK} subnet create "${net}" \
            --network "${net}" \
            --subnet-range "${cidr}" \
            --dns-nameserver 8.8.8.8 > /dev/null
    fi
}

ensure_router() {
    local router="${LAB_PREFIX}-router"
    local gateway_args=("--external-gateway" "${LAB_GATEWAY_NETWORK}")

    if [ -n "${LAB_GATEWAY_IP}" ]; then
        gateway_args+=("--fixed-ip" "ip-address=${LAB_GATEWAY_IP}")
    fi

    if ! ${OPENSTACK} router show "${router}" > /dev/null 2>&1; then
        log "creating router ${router}"
        ${OPENSTACK} router create "${router}" > /dev/null
        ${OPENSTACK} router set "${router}" "${gateway_args[@]}" > /dev/null
        ${OPENSTACK} router add subnet "${router}" "${LAB_PREFIX}-region1" > /dev/null
        ${OPENSTACK} router add subnet "${router}" "${LAB_PREFIX}-region2" > /dev/null
    fi
}

ensure_security_group() {
    local sg="${LAB_PREFIX}-sg"

    if ! ${OPENSTACK} security group show "${sg}" > /dev/null 2>&1; then
        log "creating security group ${sg}"
        ${OPENSTACK} security group create "${sg}" \
            --description "KubeCenter DR lab" > /dev/null
        ${OPENSTACK} security group rule create "${sg}" \
            --protocol tcp --dst-port 22 > /dev/null
        ${OPENSTACK} security group rule create "${sg}" \
            --protocol icmp > /dev/null
        ${OPENSTACK} security group rule create "${sg}" \
            --remote-ip 10.10.0.0/16 > /dev/null
    fi
}

ensure_keypair() {
    if ! ${OPENSTACK} keypair show "${LAB_KEYPAIR}" > /dev/null 2>&1; then
        log "creating keypair ${LAB_KEYPAIR}"
        if [ ! -f "${LAB_KEYFILE}" ]; then
            ssh-keygen -t ed25519 -N "" -C "${LAB_KEYPAIR}" -f "${LAB_KEYFILE}"
        fi
        ${OPENSTACK} keypair create "${LAB_KEYPAIR}" \
            --public-key "${LAB_KEYFILE}.pub" > /dev/null
    fi
}

ensure_server() {
    local name="$1" region="$2" flavor="$3" zone="$4"
    local volume="${name}-data"

    if ! ${OPENSTACK} volume show "${volume}" > /dev/null 2>&1; then
        log "creating volume ${volume} (${LAB_DATA_VOLUME_SIZE}G)"
        ${OPENSTACK} volume create "${volume}" \
            --size "${LAB_DATA_VOLUME_SIZE}" > /dev/null
    fi

    if ! ${OPENSTACK} server show "${name}" > /dev/null 2>&1; then
        log "creating server ${name} (${flavor}, ${region}, zone ${zone})"
        ${OPENSTACK} server create "${name}" \
            --image "${LAB_IMAGE}" \
            --flavor "${flavor}" \
            --network "${LAB_PREFIX}-${region}" \
            --security-group "${LAB_PREFIX}-sg" \
            --key-name "${LAB_KEYPAIR}" \
            --property "kclab.region=${region}" \
            --property "kclab.zone=${zone}" > /dev/null
    fi
}

attach_volume() {
    local name="$1"
    local volume="${name}-data"
    local status

    status="$(${OPENSTACK} volume show "${volume}" -f value -c status)"
    if [ "${status}" = "available" ]; then
        log "attaching ${volume} to ${name}"
        ${OPENSTACK} server add volume "${name}" "${volume}" > /dev/null
    fi
}

wait_active() {
    local name="$1" tries=0

    until [ "$(${OPENSTACK} server show "${name}" -f value -c status)" = "ACTIVE" ]; do
        tries=$((tries + 1))
        if [ "${tries}" -gt 60 ]; then
            log "ERROR: ${name} did not become ACTIVE"
            return 1
        fi
        sleep 5
    done
}

server_address() {
    ${OPENSTACK} server show "$1" -f value -c addresses \
        | grep -oE '10\.10\.[0-9]+\.[0-9]+' | head -1
}

lab_ssh_config() {
    local name network flavor zone chassis address chassis_ip net_id

    echo "${SERVERS}" | while read -r name network flavor zone; do
        [ -z "${name}" ] && continue
        chassis="$(${OPENSTACK} server show "${name}" -f value -c 'OS-EXT-SRV-ATTR:host')"
        chassis_ip="$(${OPENSTACK} hypervisor list -f value -c 'Hypervisor Hostname' -c 'Host IP' | awk -v h="${chassis}" '$1 == h {print $2}')"
        address="$(server_address "${name}")"
        net_id="$(${OPENSTACK} network show "${LAB_PREFIX}-${network}" -f value -c id)"
        cat <<EOF
Host ${name}
  HostName ${address}
  User ubuntu
  IdentityFile ${LAB_KEYFILE}
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ProxyCommand ssh -o StrictHostKeyChecking=no ${LAB_HYPERVISOR_USER}@${chassis_ip} sudo ip netns exec ovnmeta-${net_id} nc %h %p

EOF
    done
}

lab_status() {
    ${OPENSTACK} server list --name "^${LAB_PREFIX}-" \
        -c Name -c Status -c Networks -c Flavor
}

lab_down() {
    local name network flavor zone
    echo "${SERVERS}" | while read -r name network flavor zone; do
        [ -z "${name}" ] && continue
        log "deleting ${name}"
        ${OPENSTACK} server delete "${name}" --wait > /dev/null 2>&1 || true
        ${OPENSTACK} volume delete "${name}-data" > /dev/null 2>&1 || true
    done
    log "lab servers deleted (networks, router and keypair are kept)"
}

lab_up() {
    local name network flavor zone

    ensure_network region1 10.10.1.0/24
    ensure_network region2 10.10.2.0/24
    ensure_router
    ensure_security_group
    ensure_keypair

    echo "${SERVERS}" | while read -r name network flavor zone; do
        [ -z "${name}" ] && continue
        ensure_server "${name}" "${network}" "${flavor}" "${zone}"
    done

    echo "${SERVERS}" | while read -r name network flavor zone; do
        [ -z "${name}" ] && continue
        wait_active "${name}"
        attach_volume "${name}"
    done

    lab_status
}

case "${1:-up}" in
    up) lab_up ;;
    status) lab_status ;;
    ssh-config) lab_ssh_config ;;
    down) lab_down ;;
    *) echo "usage: $0 [up|status|ssh-config|down]" >&2; exit 2 ;;
esac
