#################
LLM service guide
#################

This guide explains how to serve large language models on the platform and
how to expose them to the users through a single OpenAI-compatible API.
The service is built from two components which are shipped with Atmosphere
but disabled by default:

* **vLLM** runs one inference server per model on the GPU nodes, with each
  server consuming either a full GPU or a MIG instance managed by the GPU
  Operator.
* **LiteLLM** is the multi-tenant gateway in front of the inference
  servers: the users never reach the servers directly, the gateway handles
  the virtual API keys, the budgets, the rate limits and the usage
  accounting per key.

**********
Enablement
**********

You can enable both components by setting the following variables inside
your inventory, listing the models to serve and how the gateway routes to
them:

.. code-block:: yaml

  atmosphere_vllm_enabled: true
  atmosphere_litellm_enabled: true

  vllm_models:
    - name: qwen3-32b
      model: Qwen/Qwen3-32B
      resources:
        nvidia.com/gpu: 1

  litellm_master_key: sk-<master key>
  litellm_host: llm.example.com
  litellm_model_list:
    - model_name: qwen3-32b
      litellm_params:
        model: openai/Qwen/Qwen3-32B
        api_base: http://vllm-qwen3-32b.llm.svc/v1
        api_key: none

The weights of the models are downloaded into a per-server cache volume
on the first start. On a deployment with restricted connectivity, the
weights can be preloaded into the cache volume instead.

************
Virtual keys
************

With a PostgreSQL database configured through the ``litellm_database_url``
variable, the gateway manages virtual API keys with budgets and rate
limits, which are the unit of consumption of the service:

.. code-block:: console

  curl https://llm.example.com/key/generate \
     --header "Authorization: Bearer <master key>" \
     --header "Content-Type: application/json" \
     --data '{"models": ["qwen3-32b"], "max_budget": 100}'

The clients then use the generated key with any OpenAI-compatible SDK
pointed at the gateway URL. A request going over the budget of its key is
refused, and the usage is accounted per key for billing purposes.

.. admonition:: Note
  :class: note

  The gateway does not log the content of the prompts and of the
  completions, only the usage metadata is stored for accounting.
