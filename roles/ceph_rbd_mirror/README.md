# `ceph_rbd_mirror`

This role deploys the `rbd-mirror` daemon using the Ceph orchestrator and
enables snapshot-based mirroring of RBD pools towards a peer Ceph cluster
running in another region, which is the building block for disaster
recovery of the persistent data.
