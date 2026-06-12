##########################
Disaster recovery runbooks
##########################

These runbooks describe the orchestrated procedures to fail over a
deployment to its secondary region and to fail back once the primary region
is recovered. They build on the replication configured in the disaster
recovery guide and are intentionally semi-automated: every destructive step
requires an explicit human confirmation, since an unwarranted promotion
leads to a split-brain between the two regions.

.. warning::

  Run these procedures from a bastion or operator workstation that does not
  depend on either region, with a working inventory for both regions.

*****************
Failover runbook
*****************

Use this runbook when the primary region is lost or must be evacuated. The
expected duration mostly depends on the amount of services to restart on
the secondary region.

#. **Decision (go/no-go).** Confirm that the primary region is effectively
   unavailable or being evacuated, record who takes the decision and when.
   If the primary region is partially alive, prevent it from serving
   writes before continuing (stop the impacted services or isolate the
   region at the network level), since the promotion below does not stop
   the peer.

#. **Promote the replicated data on the secondary region.** Run the
   failover playbook against the secondary region and review the
   mirroring status it prints before confirming:

   .. code-block:: console

     ansible-playbook -i inventory-secondary/hosts.ini \
        vexxhost.atmosphere.dr_failover -e dr_failover_force=true

   Use ``dr_failover_force=true`` only when the primary region is lost.
   For a planned evacuation, first demote the pools on the primary region
   so that a clean promotion can happen without the flag:

   .. code-block:: console

     cephadm shell -- rbd mirror pool demote <pool>

#. **Adopt the replicated volumes.** The promoted RBD images contain the
   data of the volumes, however the OpenStack control plane of the
   secondary region does not know them yet. Adopt the volumes that the
   workloads need with the Cinder manage interface, which imports an
   existing RBD image as a volume:

   .. code-block:: console

     openstack volume manage --id-type source-name <host@backend#pool> volume-<uuid>

#. **Restore the platform state.** If the secondary region also hosts a
   replicated copy of the platform backups (see the object storage
   replication section of the disaster recovery guide), restore the
   needed namespaces or workloads with Velero from the replicated bucket:

   .. code-block:: console

     velero backup get
     velero restore create --from-backup <backup name>

#. **Switch the traffic.** Update the DNS records of the affected services
   to the endpoints of the secondary region. With Designate, update the
   recordsets of the zones (keep their TTL at 60 seconds or less ahead of
   time so that the switchover propagates quickly):

   .. code-block:: console

     openstack recordset set <zone> <name> --record <secondary region address>

#. **Verify and communicate.** Check the services tenant by tenant,
   record the measured recovery time and the data loss window, and
   communicate the status before declaring the failover complete.

*****************
Failback runbook
*****************

Use this runbook once the failed region is repaired and must become the
primary again. No step interrupts the service running on the secondary
region until the final switchover.

#. **Resynchronize the repaired region.** Run the failback playbook
   against the repaired region. It demotes the stale images and requests
   a resync from the region currently serving the data, discarding any
   change that happened on the repaired region since the failover:

   .. code-block:: console

     ansible-playbook -i inventory-primary/hosts.ini \
        vexxhost.atmosphere.dr_failback

#. **Wait for a healthy mirroring state.** The resync duration depends on
   the amount of data changed since the failover. Wait until every pool
   reports a healthy state on both regions before going further:

   .. code-block:: console

     rbd-mirror-health <pool>

#. **Switch back (planned).** During a planned maintenance window, stop
   the writes on the secondary region, demote its pools, then promote the
   primary region cleanly and switch the DNS records back:

   .. code-block:: console

     cephadm shell -- rbd mirror pool demote <pool>    # on the secondary
     ansible-playbook -i inventory-primary/hosts.ini \
        vexxhost.atmosphere.dr_failover                # on the primary

#. **Verify.** Confirm that the mirroring direction is restored, that the
   schedules are active again and that the services are healthy on the
   primary region.

**************************
Tenant level restoration
**************************

The loss of a single namespace or workload does not require a regional
failover. Restore the affected resources from the platform backups with a
targeted Velero restore, which can filter by namespace and resource type:

.. code-block:: console

  velero restore create --from-backup <backup name> \
     --include-namespaces <namespace>
