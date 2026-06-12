# `velero`

This role installs and configures Velero to take platform-level backups of
the cluster resources and persistent volumes. Backups are stored in any
S3-compatible object storage, defaulting to the Ceph RadosGW instance
deployed by Atmosphere.
