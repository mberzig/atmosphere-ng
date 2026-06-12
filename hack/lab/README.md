# Two-region disaster recovery lab

This directory provisions the staging environment used to functionally
test the disaster recovery extensions, as a pair of simulated regions on
an OpenStack cloud:

* **region1** is the primary region: three controllers and two workers
  spread over two simulated availability zones (`az1`/`az2`).
* **region2** is the recovery region: one controller and two workers.

Every node receives a data volume for the Ceph OSDs. The two tenant
networks are connected by a shared router whose external gateway only
provides SNAT egress: **no floating IP is assigned**, the nodes are not
reachable from outside the cloud.

## Usage

```console
python3 -m venv ~/.venvs/osclient
~/.venvs/osclient/bin/pip install python-openstackclient
export OS_CLOUD=<cloud> PATH=~/.venvs/osclient/bin:$PATH

./provision.sh up        # create (idempotent)
./provision.sh status    # list the lab servers
./provision.sh ssh-config > ~/.ssh/kclab-config
./provision.sh down      # delete the servers and volumes
```

The external gateway needs one address on the egress network. When the
allocation pool of the network is exhausted, a free address can be
assigned explicitly with `LAB_GATEWAY_IP`.

## Access path

The nodes carry no floating IP: they are reached through the OVN
metadata namespace of the hypervisor hosting each instance, which has a
port on the tenant network. The `ssh-config` command generates the SSH
configuration with the right `ProxyCommand` per node:

```console
ssh -F ~/.ssh/kclab-config kclab-r1-ctl-1
```

The jump only relays TCP: the authentication happens end to end from
the operator workstation and the private key never leaves it. Note that
the OVN metadata port is a `localport`, so each node is only reachable
through the hypervisor which hosts it; the generated configuration
resolves the right hypervisor for every node.
