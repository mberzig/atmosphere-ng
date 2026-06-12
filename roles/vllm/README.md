# `vllm`

This role deploys vLLM inference servers for a list of large language
models, each exposed as an OpenAI-compatible service inside the cluster.
The servers are not meant to be reached directly by the users: they sit
behind the LiteLLM gateway which handles the authentication, the quotas
and the routing.

The role manages plain Kubernetes resources instead of a vendored chart
since there is no mature upstream chart for vLLM that fits the catalog
constraints of the platform.
