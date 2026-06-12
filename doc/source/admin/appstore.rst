#########################
Application catalog guide
#########################

This guide explains how to operate the application catalog, which offers a
set of curated applications that can be installed in a self-service manner.
The catalog is built on two principles: every image and chart is served
from the local registry rather than from the internet, and every
installation goes through Git rather than being applied directly.

The catalog relies on two components which are shipped with Atmosphere but
disabled by default:

* **Harbor** is the registry hosting the curated images and charts, with
  its embedded Trivy scanner auditing every artifact.
* **Argo CD** is the only deployment channel: installing, upgrading or
  removing an application is a commit in a Git repository which Argo CD
  reconciles.

**********
Enablement
**********

You can enable both components by setting the following variables inside
your inventory:

.. code-block:: yaml

  atmosphere_argocd_enabled: true
  atmosphere_harbor_enabled: true
  harbor_host: harbor.example.com
  harbor_admin_password: <password>

Harbor is exposed through the Ingress controller with a TLS certificate
issued by the cluster issuer of the deployment, and its persistent volumes
are created using the default storage class of the cluster unless the
``harbor_storage_class`` variable points to another one.

******************
Curating the entry
******************

Every application of the catalog goes through the same curation pipeline
before being offered:

#. Mirror the upstream images into a Harbor project, which scans them with
   Trivy on push. Harbor proxy cache projects can also be used to mirror
   on demand while keeping the scanning.
#. Host the chart of the application in a Harbor OCI repository, with its
   image references relocated to the local registry and its version
   pinned.
#. Validate the deployment of the curated chart on a staging environment
   before publishing it to the catalog.

********************
Signing the catalog
********************

The images of the catalog can be signed with `Cosign
<https://docs.sigstore.dev/cosign/signing/overview/>`_ and verified at
admission, so that an unsigned or tampered image is rejected before it
runs. The verification is enforced by Kyverno, which is shipped with
Atmosphere but disabled by default.

The curation pipeline signs every image after pushing it to Harbor, with
a key pair generated once and kept in a safe place:

.. code-block:: console

  cosign generate-key-pair
  cosign sign --key cosign.key harbor.example.com/catalog/<image>@<digest>

The signatures are stored in Harbor next to the images. You can then
enable the verification by providing the public key and the image
references to protect, which rejects any matching image without a valid
signature and pins the verified images to their digest so that a tag
cannot be moved afterwards:

.. code-block:: yaml

  atmosphere_kyverno_enabled: true
  kyverno_verify_images:
    - name: catalog
      images:
        - harbor.example.com/catalog/*
      public_key: |
        -----BEGIN PUBLIC KEY-----
        <contents of cosign.pub>
        -----END PUBLIC KEY-----

The policy applies to all namespaces by default and can be scoped with
an optional list of namespaces per entry.

**************************
Installing an application
**************************

Applications are installed by committing an Argo CD ``Application``
resource to the Git repository watched by Argo CD, never by running
``helm install`` directly. The following example installs a curated
WordPress in the namespace of a project:

.. code-block:: yaml

  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: wordpress-example
    namespace: argocd
  spec:
    project: default
    source:
      repoURL: harbor.example.com/catalog
      chart: wordpress
      targetRevision: 1.0.0
    destination:
      server: https://kubernetes.default.svc
      namespace: wordpress-example
    syncPolicy:
      syncOptions:
        - CreateNamespace=true

Removing the application is a removal of the resource from the Git
repository, which keeps the full lifecycle auditable from the Git history.
