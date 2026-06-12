# `litellm`

This role deploys the LiteLLM proxy, the multi-tenant gateway of the LLM
service. It exposes a single OpenAI-compatible API in front of the vLLM
inference servers and handles the virtual API keys, the budgets, the rate
limits and the usage accounting per key.

The role manages plain Kubernetes resources instead of a vendored chart
since the upstream chart depends on the Bitnami catalog, which the
platform does not allow.
