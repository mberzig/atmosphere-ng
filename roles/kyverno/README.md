# `kyverno`

This role installs and configures Kyverno, the admission policy engine of
the platform. Its first duty is the software supply chain: it verifies the
cosign signatures of the images at admission, so that an unsigned or
tampered image is rejected before it runs.
