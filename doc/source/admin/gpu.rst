#########
GPU guide
#########

This guide explains how to make the GPUs of the deployment consumable by
the containerized workloads. The GPUs of the Nova instances keep using the
PCI passthrough configuration of Nova and are not covered by this guide.

GPU support is provided by the NVIDIA GPU Operator, which is shipped with
Atmosphere but disabled by default. The operator manages the lifecycle of
the driver, the container toolkit, the device plugin, the MIG manager and
the DCGM exporter on the nodes which expose a GPU, with the discovery
relying on the Node Feature Discovery instance already deployed by
Atmosphere.

**********
Enablement
**********

You can enable the GPU Operator by setting the following variable inside
your inventory:

.. code-block:: yaml

  atmosphere_gpu_operator_enabled: true

************
MIG strategy
************

The deployment defaults to the ``mixed`` MIG strategy, which allows full
GPUs and MIG instances to coexist in the same cluster. The partitioning of
each node is driven by its ``nvidia.com/mig.config`` label, for example to
split every GPU of a node into four isolated instances:

.. code-block:: console

  kubectl label node <node> nvidia.com/mig.config=all-1g.24gb --overwrite

The workloads then request either a full GPU with the ``nvidia.com/gpu``
resource or a MIG instance with the matching ``nvidia.com/mig-*`` resource,
and the quotas of the projects can be enforced on those resources.

**********
Monitoring
**********

The DCGM exporter publishes the utilization, memory, temperature and error
metrics of every GPU and MIG instance, and the deployment enables its
``ServiceMonitor`` so that the metrics are scraped by the existing
monitoring stack.
