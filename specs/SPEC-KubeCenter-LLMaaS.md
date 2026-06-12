# KubeCenter LLMaaS — Spécifications techniques du module d'IA générative

**Version :** 1.0 — Juin 2026
**Statut :** Spécification d'ingénierie (destinée au développement assisté, type Claude Code)
**Référence amont :** CDC-PCA-PRA-K8S (Lot GPU/IA) ; **dépend** du module **KubeCenter GPU** (infrastructure d'accélération) et s'appuie sur **Storage**, **Network**, **VM**.
**Modèle fonctionnel de référence :** standard d'**API OpenAI** (compatibilité native de vLLM/LiteLLM) comme surface d'API, et **Vertex AI (Generative AI)** comme grille de complétude des capacités d'une plateforme d'IA managée.
**Contrainte de périmètre :** API d'IA **souveraine** — uniquement des modèles **open source** hébergés en Algérie, servis sur le socle GPU KubeCenter, facturés à l'usage, **sans rétention** des données par défaut. Les fonctions propres aux modèles fermés/propriétaires sont écartées et justifiées au chapitre 16.

---

## 0. Préambule

### 0.1 Objet

KubeCenter LLMaaS expose une **API d'inférence d'IA générative** (la « 1ère API d'IA souveraine » de la plateforme) : grands modèles de langage et d'embeddings open source, hébergés sur le territoire, accessibles via une API compatible avec les standards mondiaux, facturés au token, avec garanties de confidentialité et de localisation (loi 18-07).

### 0.2 Principe directeur

Trois couches :
1. **Service de modèles** — vLLM/SGLang sur KServe, exposant chaque modèle via un endpoint d'inférence performant (batching continu, PagedAttention, parallélisme tensoriel) sur des partitions GPU (UC-GPU) du module GPU.
2. **Passerelle d'API** — LiteLLM Proxy + Kong : surface **compatible OpenAI** unique, routage par modèle, clés d'API, quotas, limitation de débit, repli (fallback), comptage des tokens.
3. **Gouvernance** — Keycloak (OIDC, clés à portée projet), facturation au token (Odoo), observabilité, confidentialité (zéro rétention), conformité 18-07.

### 0.3 Socle technique retenu

| Couche | Composant |
|---|---|
| Moteurs d'inférence | **vLLM** (par défaut), **SGLang** (alternatif, charges spécifiques) |
| Service sur Kubernetes | **KServe** (`InferenceService`) — autoscaling, scale-to-zero, multi-modèle |
| Passerelle / routage | **LiteLLM Proxy** (compat OpenAI, clés virtuelles, budgets) + **Kong** (gestion d'API, débit) |
| Authentification | **Keycloak** (OIDC) ; clés d'API à portée projet |
| Facturation | comptage tokens → **Odoo** (facturation à l'usage) |
| Stockage des modèles | poids sur **CephFS/RGW** (renvoi Storage) ; cache local NVMe |
| Accélération | **UC-GPU** (MIG) / GPU entier (renvoi **KubeCenter GPU**) |
| Interfaces | **Open WebUI** / **LibreChat** (multi-tenant), playground console |
| Observabilité | métriques vLLM/DCGM → Prometheus/Mimir + Grafana (LGTM) |
| Multi-tenancy | Capsule + Kyverno + Keycloak |

### 0.4 Synthèse des correspondances (détaillée en Annexe A)

| Concept (OpenAI / Vertex AI) | KubeCenter LLMaaS | Implémentation |
|---|---|---|
| `/v1/chat/completions` | Endpoint de chat | vLLM (OpenAI-compat) via LiteLLM |
| `/v1/completions` | Complétion de texte | vLLM |
| `/v1/embeddings` | Embeddings | modèle d'embedding servi |
| `/v1/models` | Catalogue de modèles | registre LiteLLM |
| Streaming (SSE) | Réponses en flux | SSE vLLM/LiteLLM |
| Function/tool calling | Appel d'outils | vLLM tool calling |
| Structured outputs / JSON mode | Sortie structurée | grammaires/JSON schema (vLLM) |
| Vision (multimodal input) | Entrée multimodale | modèles VLM servis |
| Model Garden / model registry | Catalogue de modèles | catalogue KubeCenter |
| Online prediction / endpoints | Déploiement de modèle | `InferenceService` KServe |
| Tuning (LoRA/adapters) | Personnalisation | adaptateurs LoRA par tenant |
| Provisioned throughput / quotas | Quotas & débit | LiteLLM + Kueue (GPU) |
| API keys / IAM | Clés & accès | Keycloak + clés LiteLLM |

---

## 1. Modèle de ressources

**EXG-LLM-1000** — L'API expose, par projet (tenant) : `Modèles` (catalogue), `Déploiements` (endpoints servis), `ClésAPI`, `Quotas`, `Adaptateurs` (LoRA), `RegistresUsage` (consommation tokens). Identifiant stable, nom RFC 1123, libellés, horodatages.

**EXG-LLM-1001** — Isolation stricte inter-tenants : clés, quotas, adaptateurs et journaux d'usage cloisonnés ; aucune fuite de prompt/réponse entre tenants (RBAC + Keycloak + LiteLLM key scoping).

**EXG-LLM-1002** — Chaque déploiement porte le libellé `kubecenter.dz/dr-tier` (T0–T3) déterminant son régime de continuité/reprise (chapitre 11).

---

## 2. Catalogue de modèles

**EXG-LLM-1100** — **Catalogue souverain** (≈ *Model Garden*) : uniquement des modèles **open source** (licences permissives ou ouvertes), hébergés en propre, couvrant au minimum :

| Catégorie | Exemples de familles (open source) | Usage |
|---|---|---|
| Chat/instruct (généraliste) | Qwen3, Llama, Mistral/Mixtral, MoE type MiniMax/Kimi | assistants, génération, raisonnement |
| Code | familles « coder » open source | assistance au développement |
| Embeddings | modèles d'embedding open source | RAG, recherche sémantique |
| Multimodal (VLM) | modèles vision-langage open source | analyse d'images/documents |

**EXG-LLM-1101** — **Versions et cartes de modèle** : chaque modèle est versionné ; une **carte de modèle** publie taille (paramètres), contexte maximal, langues, licence, empreinte VRAM, et limites connues.

**EXG-LLM-1102** — **Dimensionnement** : la VRAM/RAM requise (poids + KV cache pour le contexte cible) est documentée par modèle et confrontée à la capacité UC-GPU (MIG 24 Go) ; les très grands modèles (MoE) sont servis sur GPU entier ou multi-GPU intra-nœud.

**EXG-LLM-1103** — **Souveraineté & provenance** : poids téléchargés, vérifiés (checksum/signature), stockés et servis exclusivement depuis l'infrastructure KubeCenter ; aucune dépendance d'inférence à un service externe.

**EXG-LLM-1104** — **Cycle de vie** : ajout, dépréciation et retrait de modèles annoncés au tenant (alias de version stable, fenêtre de migration).

---

## 3. Surface d'API (compatible OpenAI)

**EXG-LLM-1200** — **Endpoints compatibles OpenAI** : `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/models` (liste/détail). La compatibilité permet l'usage direct des SDK existants (openai-python/-node, LangChain, LlamaIndex) en pointant vers l'URL souveraine.

**EXG-LLM-1201** — **Streaming** : réponses en flux (Server-Sent Events) pour le chat et la complétion ; gestion de l'annulation côté client.

**EXG-LLM-1202** — **Appel d'outils** (function/tool calling) : déclaration d'outils, génération d'appels structurés, pour les modèles qui le supportent.

**EXG-LLM-1203** — **Sorties structurées** : mode JSON et contraintes par schéma/grammaire (sortie garantie conforme), via les fonctions de décodage contraint de vLLM.

**EXG-LLM-1204** — **Entrée multimodale** : messages avec images pour les modèles vision-langage (VLM), selon le format de messages standard.

**EXG-LLM-1205** — **Paramètres d'inférence** : température, top-p, top-k, pénalités, `max_tokens`, `stop`, graine (`seed`) pour la reproductibilité, et `logprobs` lorsque pertinent.

**EXG-LLM-1206** — **Comptage de tokens** : endpoint/outil de tokenisation pour estimer le coût avant appel ; en-têtes de réponse exposant les tokens consommés (entrée/sortie).

**EXG-LLM-1207** — **Erreurs normalisées** : codes et corps d'erreur alignés sur le standard (400/401/403/404/429/5xx), avec messages exploitables et `retry-after` sur 429.

---

## 4. Service et inférence

**EXG-LLM-1300** — **Déploiement de modèle** (≈ *online prediction endpoint*) : chaque modèle est exposé par un `InferenceService` KServe adossé à vLLM/SGLang ; un déploiement précise le modèle, la version, les ressources GPU (UC-GPU/GPU entier), et le tier.

**EXG-LLM-1301** — **Performances de service** : batching continu, PagedAttention (gestion efficace du KV cache), parallélisme tensoriel intra-nœud, **quantification** (ex. AWQ/GPTQ/FP8) documentée par modèle pour optimiser l'empreinte VRAM.

**EXG-LLM-1302** — **Multi-modèle & densité** : plusieurs modèles coexistent sur le parc GPU ; placement et partage via MIG/UC-GPU (renvoi GPU) ; les petits modèles peuvent partager une partition.

**EXG-LLM-1303** — **Mise à l'échelle** : autoscaling des répliques selon la charge (requêtes en file, latence, utilisation GPU) ; **scale-to-zero** optionnel pour les modèles peu sollicités (libération de GPU), avec démarrage à froid documenté.

**EXG-LLM-1304** — **Files et priorités GPU** : l'allocation GPU des déploiements passe par **Kueue** (renvoi GPU) ; les charges d'inférence prioritaires peuvent préempter le best-effort.

**EXG-LLM-1305** — **Chargement des poids** : depuis CephFS/RGW avec cache local NVMe pour réduire le temps de démarrage ; préchauffage optionnel des modèles critiques.

---

## 5. Passerelle et routage

**EXG-LLM-1400** — **Passerelle unique** (LiteLLM Proxy + Kong) : point d'entrée compatible OpenAI pour tous les modèles ; routage par nom de modèle vers le bon `InferenceService`.

**EXG-LLM-1401** — **Clés virtuelles & budgets** : LiteLLM émet des clés par projet/usage avec budget (plafond de dépense/tokens), liste de modèles autorisés, et expiration.

**EXG-LLM-1402** — **Équilibrage & repli** : répartition de charge entre répliques d'un même modèle ; **fallback** vers un modèle/réplique de secours en cas d'échec ou de saturation, selon politique.

**EXG-LLM-1403** — **Limitation de débit** : plafonds **RPM** (requêtes/min) et **TPM** (tokens/min) par clé/projet ; réponses 429 avec `retry-after`.

**EXG-LLM-1404** — **Réécriture & politiques** : Kong applique les politiques transverses (authentification, quotas, journalisation d'accès, CORS) sans exposer la topologie interne.

---

## 6. Authentification, quotas et accès

**EXG-LLM-1500** — **Authentification** : OIDC (Keycloak) pour la console et l'émission de clés ; **clés d'API** Bearer à portée projet pour les appels programmatiques, révocables et auditées.

**EXG-LLM-1501** — **Quotas** par projet : tokens/mois, requêtes concurrentes, modèles accessibles, nombre de clés ; dépassement → 429 ou blocage selon politique, message explicite.

**EXG-LLM-1502** — **Contrôle d'accès aux modèles** : un tenant ne voit/n'appelle que les modèles qui lui sont ouverts (catalogue filtré par politique).

---

## 7. Facturation à l'usage

**EXG-LLM-1600** — **Comptage** : tokens d'entrée et de sortie comptés par appel, par modèle, par clé et par projet (source LiteLLM), avec horodatage ; tokens multimodaux (images) comptés selon barème documenté.

**EXG-LLM-1601** — **Tarification** : prix au **million de tokens** par modèle (différencié entrée/sortie), dégressif possible ; export vers **Odoo** pour facturation ; les déploiements dédiés (réservation GPU) facturés à la capacité (UC-GPU) en complément.

**EXG-LLM-1602** — **Budgets & alertes** : plafonds de dépense par projet/clé ; alertes à seuils (80/100 %) ; arrêt ou throttling au dépassement selon politique.

**EXG-LLM-1603** — **Relevés** : tableau de bord et export de consommation (tokens, coût, par modèle/clé/jour) consultable par le tenant.

---

## 8. Confidentialité et sécurité

**EXG-LLM-1700** — **Zéro rétention par défaut** : les prompts et les réponses **ne sont pas conservés** au-delà du traitement de la requête ; aucun stockage des contenus, sauf **opt-in explicite** du tenant (ex. pour son propre débogage), avec durée de rétention bornée et documentée.

**EXG-LLM-1701** — **Aucun entraînement sur les données client** : les contenus des tenants ne servent jamais à entraîner ou affiner des modèles partagés. Engagement contractuel.

**EXG-LLM-1702** — **Isolation** : exécution des requêtes d'un tenant sans visibilité sur celles des autres ; nettoyage de la mémoire GPU entre allocations dédiées (renvoi GPU).

**EXG-LLM-1703** — **Garde-fous optionnels** (≈ *safety attributes*) : modération de contenu et filtres activables **à la demande du tenant** (modèle/règles), désactivés par défaut pour ne pas altérer les sorties ; jamais imposés silencieusement.

**EXG-LLM-1704** — **Chiffrement** : TLS en transit (passerelle), poids et caches chiffrés au repos (renvoi Storage) ; clés au KMS interne.

**EXG-LLM-1705** — **Audit** : appels (métadonnées : qui, quand, quel modèle, tokens — **pas le contenu** sauf opt-in), émission/révocation de clés, déploiements, journalisés et consultables par le tenant.

**EXG-LLM-1706** — **Conformité loi 18-07 / ANPDP** : inférence, poids, caches et journaux résident exclusivement à Alger et Constantine ; aucune donnée (prompt/réponse) ne quitte le territoire.

---

## 9. Personnalisation (fine-tuning léger / RAG)

**EXG-LLM-1800** — **Adaptateurs LoRA** (≈ *tuning*) : un tenant peut déployer des adaptateurs LoRA privés sur un modèle de base partagé (sans dupliquer le modèle), servis dynamiquement par vLLM (multi-LoRA), isolés par tenant.

**EXG-LLM-1801** — **Pipeline d'affinage** : entraînement d'adaptateurs via le module GPU (renvoi entraînement Kubeflow) à partir des données du tenant, qui restent sa propriété et sur le territoire.

**EXG-LLM-1802** — **RAG / embeddings** : modèles d'embeddings exposés pour alimenter une base vectorielle ; l'orchestration RAG applicative relève du tenant (ou du futur volet applicatif), le LLMaaS fournissant embeddings + génération.

**EXG-LLM-1803** — **Pas de pré-entraînement** de modèles de fondation sur la plateforme (hors périmètre) ; uniquement service + affinage léger (LoRA).

---

## 10. Modalités

**EXG-LLM-1900** — **Texte** (chat, complétion) : modalité principale, tous modèles instruct/chat.

**EXG-LLM-1901** — **Embeddings** : vecteurs pour recherche/RAG.

**EXG-LLM-1902** — **Multimodal (vision-langage)** : analyse d'images/documents pour les VLM du catalogue.

**EXG-LLM-1903** — **Audio (STT/TTS)** : transcription/synthèse via modèles open source — **phase ultérieure** (chapitre 16). **Génération d'images** : hors périmètre phase 1.

---

## 11. Multi-AZ, continuité et PRA

**EXG-LLM-2000** — **Répartition** : les déploiements critiques sont répliqués sur les nœuds GPU des deux AZ d'Alger ; la passerelle LiteLLM équilibre et bascule entre répliques.

**EXG-LLM-2001** — **Continuité (PCA)** : la passerelle reste disponible (répliquée) même si un endpoint modèle tombe ; les requêtes sont reroutées vers une réplique saine ou un modèle de repli ; la capacité GPU étant best-effort (renvoi GPU), une dégradation contrôlée (file, modèle plus léger) est documentée.

**EXG-LLM-2002** — **PRA (tier T2)** : les modèles IA critiques peuvent être servis depuis **Constantine** (poids déjà répliqués via Storage) en cas de sinistre, avec RPO/RTO du tier ; la passerelle redirige le trafic (GSLB/LiteLLM).

**EXG-LLM-2003** — Les définitions de déploiement (InferenceService, routes LiteLLM) sont gérées en GitOps et reconstruites à l'identique en région PRA.

---

## 12. Observabilité

**EXG-LLM-2100** — **Métriques d'inférence** : latence au premier token (TTFT), latence par token (TPOT), débit (tokens/s), requêtes en file, taux d'erreur, longueur de contexte, occupation du KV cache — par modèle/déploiement/tenant.

**EXG-LLM-2101** — **Métriques GPU** corrélées (utilisation, VRAM, via DCGM — renvoi GPU).

**EXG-LLM-2102** — **Journaux d'accès** (métadonnées sans contenu) et **alertes** : saturation/file longue, latence anormale, taux d'erreur, dépassement de budget, dérive PRA.

**EXG-LLM-2103** — **Tableaux de bord** par tenant (usage, performance) et plateforme (capacité, santé des endpoints).

---

## 13. Interfaces et expérience

**EXG-LLM-2200** — **Interface de chat multi-tenant** : **Open WebUI** / **LibreChat** intégrés (SSO Keycloak), permettant l'usage des modèles sans code, avec sélection de modèle, historique (local au tenant, soumis à la politique de rétention) et gestion des clés.

**EXG-LLM-2201** — **Playground** dans la console : test interactif des modèles, réglage des paramètres, génération de snippets de code (curl/python) pré-remplis avec l'URL et la clé.

**EXG-LLM-2202** — **Documentation développeur** : référence d'API compatible OpenAI, exemples SDK, cartes de modèles, limites et tarifs.

---

## 14. SLA, limites et réversibilité

**EXG-LLM-2300** — **Disponibilité** publiée par tier pour la passerelle et les endpoints critiques ; mesure et reporting.

**EXG-LLM-2301** — **Réversibilité** (anti-verrouillage) : modèles **open source** (poids portables) + API **standard OpenAI** → un tenant peut migrer son intégration vers une autre plateforme compatible sans réécriture, et récupérer ses adaptateurs LoRA et embeddings.

**EXG-LLM-2302** — **Limites** documentées : contexte maximal par modèle, taille de requête, RPM/TPM par défaut, concurrence — relevables sur demande dans la limite du capacitaire GPU.

---

## 15. Alignement au cahier des charges initial (CDC-PCA-PRA-K8S)

**EXG-LLM-2400** — Traçabilité vers le CDC :

| Élément du CDC initial | Couverture LLMaaS |
|---|---|
| Lot **GPU/IA** (vLLM, KServe, LiteLLM, Keycloak) | Ch. 3–5 (service, passerelle), socle §0.3 |
| Modèle économique **token / Odoo** | Ch. 7 (facturation à l'usage) |
| **Zéro rétention**, souveraineté des données | Ch. 8 (confidentialité), 18-07 |
| **PRA** (réplication, bascule, tiers) | Ch. 11 (multi-AZ + PRA T2) |
| **Console self-service** / UI (Open WebUI/LibreChat) | Ch. 13 |
| Dépendance **GPU** (UC-GPU, MIG, Kueue) | Renvois ch. 4, 9, 11 → SPEC-KubeCenter-GPU |
| Stockage des poids (CephFS/RGW) | Renvoi SPEC-KubeCenter-Storage |

**EXG-LLM-2401** — Aucune brique LLMaaS ne contredit l'architecture du CDC (modèles open source souverains, hébergement Alger/Constantine, facturation au token, zéro rétention).

---

## 16. Options écartées (et justification)

| Élément (OpenAI / Vertex AI) non retenu | Raison |
|---|---|
| **Modèles propriétaires fermés** (GPT, Gemini, Claude via API) | Contraire à la souveraineté ; données hors territoire ; seuls les modèles open source hébergés sont servis |
| **Entraînement de modèles de fondation** | Hors périmètre ; uniquement service + affinage LoRA |
| **Génération d'images** | Hors phase 1 (priorité au texte/embeddings/vision) |
| **Audio temps réel (STT/TTS)** | Phase ultérieure (modèles open source) |
| **Batch prediction managé à très grande échelle** | Couvert au besoin via jobs GPU (module GPU), pas un service managé dédié en phase 1 |
| **Grounding/agents managés Google, connecteurs propriétaires** | Orchestration applicative laissée au tenant / futur volet applicatif |
| **Modération imposée par défaut** | Garde-fous **opt-in** seulement, pour ne pas altérer les sorties sans consentement |
| **Provisioned throughput propriétaire** | Remplacé par réservation GPU (UC-GPU) + quotas LiteLLM |

---

## 17. Exigences — récapitulatif de traçabilité

Les exigences `EXG-LLM-1000` à `EXG-LLM-2401` constituent le référentiel traçable du module. Chacune est vérifiable (chapitre 18), rattachée à un composant (§0.3) et priorisée `MUST` (phase 1) sauf : multimodal avancé (1902 selon catalogue), audio STT/TTS (1903), scale-to-zero (1303 — `SHOULD`), fallback inter-régions automatique (2002 — `SHOULD`).

---

## 18. Tests d'acceptation

| ID | Objet | Critère de réussite |
|---|---|---|
| T-LLM-01 | Compat OpenAI | Le SDK openai-python pointé sur l'URL souveraine obtient une réponse `chat/completions` valide |
| T-LLM-02 | Streaming | Réponse en flux (SSE) reçue token par token ; annulation client prise en compte |
| T-LLM-03 | Embeddings | `/v1/embeddings` renvoie des vecteurs de dimension attendue |
| T-LLM-04 | Catalogue | `/v1/models` liste les modèles autorisés au tenant ; cartes de modèle accessibles |
| T-LLM-05 | Tool calling | Un modèle compatible renvoie un appel d'outil structuré conforme |
| T-LLM-06 | Sortie structurée | Mode JSON/schéma : sortie garantie conforme au schéma fourni |
| T-LLM-07 | Multimodal | Un VLM analyse une image fournie dans le message |
| T-LLM-08 | Déploiement KServe | `InferenceService` vLLM déployé sur UC-GPU ; endpoint sain |
| T-LLM-09 | Multi-modèle | Deux modèles servis simultanément sur le parc GPU ; routage correct par nom |
| T-LLM-10 | Scale-to-zero | Modèle peu sollicité libère le GPU puis redémarre à la 1ère requête (délai documenté) |
| T-LLM-11 | Clés & budgets | Clé virtuelle avec budget : appels bloqués au dépassement |
| T-LLM-12 | Rate limiting | Dépassement RPM/TPM → 429 avec `retry-after` |
| T-LLM-13 | Repli | Saturation d'une réplique → bascule vers réplique/modèle de secours |
| T-LLM-14 | Comptage tokens | Tokens entrée/sortie comptés exactement ; exposés en en-têtes/relevé |
| T-LLM-15 | Facturation | Consommation par modèle/clé exportée vers Odoo ; relevé tenant correct |
| T-LLM-16 | Zéro rétention | Aucun prompt/réponse persisté par défaut (vérifié) ; opt-in borné si activé |
| T-LLM-17 | Pas d'entraînement | Aucune donnée tenant utilisée pour entraîner un modèle partagé (contrôle de conception) |
| T-LLM-18 | Isolation | Deux tenants : pas d'accès croisé aux clés, usages, adaptateurs |
| T-LLM-19 | Garde-fous opt-in | Modération activée à la demande seulement ; désactivée par défaut |
| T-LLM-20 | LoRA | Adaptateur LoRA privé servi sur un modèle de base partagé, isolé par tenant |
| T-LLM-21 | Multi-AZ | Endpoint répliqué sur 2 AZ ; bascule sur perte d'une réplique sans coupure perçue |
| T-LLM-22 | PRA T2 | Service d'un modèle critique depuis Constantine après sinistre ; RPO/RTO T2 |
| T-LLM-23 | Observabilité | TTFT/TPOT/débit/erreurs/KV cache remontés par modèle et tenant |
| T-LLM-24 | UI multi-tenant | Open WebUI/LibreChat en SSO Keycloak ; sélection de modèle ; clés gérées |
| T-LLM-25 | 18-07 & audit | Inférence/poids/journaux en Algérie ; audit (métadonnées sans contenu) consultable |

---

## Annexe A — Correspondance OpenAI / Vertex AI ↔ KubeCenter LLMaaS ↔ implémentation

| Capacité (OpenAI / Vertex AI) | KubeCenter LLMaaS | Implémentation |
|---|---|---|
| `chat/completions`, `completions` | Chat / complétion | vLLM (OpenAI-compat) + LiteLLM |
| `embeddings` | Embeddings | modèle d'embedding servi |
| `models` (list/retrieve) | Catalogue | registre LiteLLM |
| Streaming SSE | Flux | vLLM/LiteLLM SSE |
| Function/tool calling | Appel d'outils | vLLM tool calling |
| JSON mode / structured outputs | Sortie structurée | décodage contraint vLLM |
| Vision input | Multimodal | modèles VLM |
| Model Garden / Model Registry | Catalogue souverain | catalogue KubeCenter (open source) |
| Online prediction endpoint | Déploiement | `InferenceService` KServe |
| Tuning | LoRA par tenant | multi-LoRA vLLM + entraînement GPU |
| API keys / IAM | Clés & accès | Keycloak + clés virtuelles LiteLLM |
| Quotas / provisioned throughput | Quotas & débit | LiteLLM (RPM/TPM, budgets) + Kueue |
| Safety attributes | Garde-fous opt-in | modération à la demande |
| Usage / billing | Facturation au token | LiteLLM → Odoo |
| Monitoring | Observabilité | métriques vLLM/DCGM → LGTM |
| Playground / Studio | Playground & UI | console + Open WebUI/LibreChat |
| Modèles propriétaires fermés | (écarté) | open source souverain uniquement |

---

*Fin du document — SPEC-KubeCenter-LLMaaS v1.0. À lire conjointement avec SPEC-KubeCenter-GPU (infrastructure d'accélération), SPEC-KubeCenter-Storage (poids/caches), SPEC-KubeCenter-Network (passerelle/endpoints privés), SPEC-KubeCenter-VM et le CDC-PCA-PRA-K8S (Lots GPU/IA, Sécurité, PRA, Console).*
