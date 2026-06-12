######################
Platform backup guide
######################

This guide explains how to take backups of the platform itself, which covers
the Kubernetes resources and the persistent volumes hosting the control plane
services. It complements the database backups and the ``staffeln`` service
which covers the backups of the Cinder volumes used by the workloads.

Platform backups are taken by `Velero <https://velero.io>`_, which is shipped
with Atmosphere but disabled by default. Backups are stored in any
S3-compatible object storage, defaulting to the Ceph RadosGW instance deployed
by Atmosphere.

**********
Enablement
**********

Before enabling Velero, you need a bucket and a set of credentials to access
it. With the built-in RadosGW, you can create them with the following
commands inside one of the Ceph toolbox pods:

.. code-block:: console

  radosgw-admin user create --uid=velero --display-name=velero
  s3cmd mb s3://velero

Once the bucket exists, you can enable Velero by setting the following
variables inside your inventory:

.. code-block:: yaml

  atmosphere_velero_enabled: true
  velero_storage_access_key: <access key of the velero user>
  velero_storage_secret_key: <secret key of the velero user>

The deployment enables the CSI integration with snapshot data movement, which
means that the contents of the persistent volumes are uploaded to the object
storage instead of relying only on Ceph snapshots. This makes the backups
usable even if the Ceph cluster itself is lost.

*****************
Scheduled backups
*****************

By default, a single schedule named ``platform-daily`` takes a daily backup
of all namespaces at 1 AM with a 30 day retention. You can replace or extend
the schedules using the ``velero_schedules`` variable, for example to add a
backup with a shorter retention for a specific set of namespaces:

.. code-block:: yaml

  velero_schedules:
    platform-daily:
      schedule: "0 1 * * *"
      template:
        ttl: 720h
        includedNamespaces:
          - "*"
    tenant-daily:
      schedule: "0 2 * * *"
      template:
        ttl: 336h
        includedNamespaces:
          - my-namespace

*******
Restore
*******

You can list the existing backups and restore one of them using the Velero
CLI from any system with access to the cluster:

.. code-block:: console

  velero backup get
  velero restore create --from-backup <backup name>

For more details on how to filter the restored resources, you can refer to
the `restore reference <https://velero.io/docs/latest/restore-reference/>`_
of the Velero documentation.
