# `ceph_rgw_multisite`

This role configures RadosGW multisite replication between two regions
using the Rook object multisite resources, so that the objects written in
one region, such as the platform backups, remain readable from the other
region after the loss of the primary site.
