# KubeCenter GPU — Spécifications techniques du module GPUaaS

**Version :** 1.0 — Juin 2026
**Statut :** Spécification d'ingénierie (destinée au développement assisté, type Claude Code)
**Référence amont :** CDC-PCA-PRA-K8S (Lot GPU/IA) ; complément des modules **KubeCenter VM**, **Storage** et **Network**.
**Modèle fonctionnel de référence :** Google Compute Engine — *Cloud GPUs / Accelerator-optimized machines* (grille de complétude).
**Contrainte de périmètre :** matériel standardisé sur le **NVIDIA RTX PRO 6000 Blackwell Server Edition** — qui correspond directement à la **série G4** de GCP (`nvidia-rtx-pro-6000` / `-vws`). Les familles GPU et accélérateurs propres à l'infrastructure Google sont écartés et justifiés au chapitre 14. L'inférence servie (LLM) relève du module **KubeCenter LLMaaS** ; ce document spécifie la **couche d'infrastructure GPU** (exposition, partitionnement, ordonnancement, supervision, facturation).

---

## 0. Préambule

### 0.1 Objet

KubeCenter GPU fournit le calcul accéléré à la demande : exposition de GPU (entiers ou partitionnés) aux machines virtuelles et aux conteneurs, ordonnancement multi-tenant équitable, supervision, et facturation à l'usage — pour l'entraînement, les notebooks, le calcul scientifique et l'inférence (cette dernière servie via LLMaaS/KServe).

### 0.2 Principe directeur

Compute Engine attache des GPU à des instances (séries A pour l'IA/HPC, série G pour graphismes/visualisation + vWS), avec partitionnement MIG, partage temporel, pilotes data-center et vWS, GPUDirect (RDMA), et supervision DCGM. KubeCenter en reprend la sémantique mais sur **un seul modèle souverain de GPU** (RTX PRO 6000 Blackwell), exposé via KubeVirt (passthrough/vGPU) et le NVIDIA GPU Operator (MIG, time-slicing), et ordonnancé par Kueue.

### 0.3 Matériel et dimensionnement actés

| Élément | Valeur |
|---|---|
| Modèle GPU | NVIDIA RTX PRO 6000 Blackwell **Server Edition** |
| Mémoire | 96 Go GDDR7 (ECC) |
| Partitionnement MIG | jusqu'à **4 instances** par GPU (≈ 24 Go chacune) |
| Enveloppe thermique | 600 W (refroidissement passif, châssis serveur) |
| Châssis | 8 emplacements GPU, **peuplés à 4** (extension in-chassis 4→8) |
| Nœuds GPU | 3 : 1 par AZ d'Alger (×2) + 1 à Constantine |
| Capacité | 12 GPU → **48 UC-GPU** (12 × 4 MIG) |
| Unité commerciale | **1 UC-GPU = 1 MIG (≈24 Go) + 12 vCPU + 56 Gio de RAM** |

### 0.4 Socle technique retenu

| Capacité | Composant |
|---|---|
| Découverte & pilotes | NVIDIA **GPU Operator** : driver data-center, container toolkit, device plugin, **MIG manager**, GPU Feature Discovery, Node Feature Discovery |
| Partitionnement matériel | MIG (Multi-Instance GPU) géré par le GPU Operator |
| Partage temporel (conteneurs) | **time-slicing** du device plugin NVIDIA |
| Exposition aux VM | **passthrough VFIO-PCI** (GPU entier) et **vGPU/mdev** (NVAIE + NVIDIA License System) via KubeVirt |
| Ordonnancement & files | **Kueue** (quotas par tenant, files, préemption) + scheduler topologie-aware |
| Charges d'entraînement | Kubeflow **Training Operator** (PyTorchJob, TFJob), notebooks Jupyter |
| Inférence servie | renvoi **KubeCenter LLMaaS** (KServe + vLLM/SGLang) |
| Réseau GPU | NIC RoCE 2×100 GbE (RDMA/GPUDirect **non activé en phase 1**, câblage prêt) |
| Supervision | **DCGM** exporter → Prometheus/Mimir + Grafana (pile LGTM) |
| Multi-tenancy / IAM | Capsule (Tenant) + Kyverno (admission) + Keycloak (OIDC) |

### 0.5 Synthèse des correspondances (détaillée en Annexe A)

| Concept GCP Cloud GPUs | KubeCenter GPU | Implémentation |
|---|---|---|
| Série G4 (RTX PRO 6000) | Gabarits GPU `ku-gpu-*` | KubeVirt + GPU Operator |
| GPU attaché (entier) | Passthrough complet | VFIO-PCI (KubeVirt) |
| MIG (Multi-Instance GPU) | Partition MIG (UC-GPU) | MIG manager (GPU Operator) |
| GPU time-sharing | Partage temporel | time-slicing (device plugin) |
| vWS (RTX Virtual Workstation) | Poste de travail virtuel GPU | vGPU/mdev + pilote vWS (NVAIE) |
| Install GPU/vWS drivers | Gestion des pilotes | GPU Operator (data-center + vGPU/vWS) |
| GPUDirect (RDMA) | Réseau GPU RDMA | RoCE (phase ultérieure) |
| GPU host maintenance (no live migrate) | Maintenance hôte GPU | `TERMINATE` (pas de migration à chaud en passthrough) |
| Monitor GPU performance | Supervision GPU | DCGM exporter |
| GPU quotas | Quotas GPU | Kueue + ResourceQuota |
| Reservations / Spot GPU | (écarté) | modèle UC-GPU + préemption Kueue |
| Séries A (B200/H200/H100/A100), TPU | (écarté) | matériel non retenu (chapitre 14) |

---

## 1. Modèle de ressources

**EXG-GPU-1000** — L'API expose, par projet (tenant) : `RessourcesGPU` (allocations), `GabaritsGPU`, `Partitions` (profils MIG), `FilesGPU` (Kueue), `Quotas`, `JobsGPU` (entraînement/notebook). Identifiant stable, nom RFC 1123, libellés, horodatages.

**EXG-GPU-1001** — Isolation stricte entre tenants : une partition MIG ou un GPU passthrough est dédié à un seul tenant à un instant donné ; aucune coallocation inter-tenants sur la même partition.

**EXG-GPU-1002** — Toute ressource GPU porte le libellé `kubecenter.dz/dr-tier` (chapitre 9) alignant son régime de continuité/reprise.

---

## 2. Gabarits GPU

**EXG-GPU-1100** — Catalogue de gabarits, alignés sur l'unité UC-GPU et les modes d'exposition (chapitre 3) :

| Gabarit | Exposition | GPU | vCPU | RAM | Usage cible |
|---|---|---|---|---|---|
| `ku-gpu-mig-1` | 1 MIG (≈24 Go) | 1/4 | 12 | 56 Gio | inférence, notebooks, fine-tuning léger (= 1 UC-GPU) |
| `ku-gpu-mig-2` | 2 MIG (≈48 Go) | 1/2 | 24 | 112 Gio | modèles moyens |
| `ku-gpu-full` | 1 GPU entier (96 Go) | 1 | 48 | 224 Gio | entraînement, gros modèles, passthrough VM |
| `ku-gpu-shared` | time-slicing | fraction temporelle | variable | variable | dev/test, charges intermittentes (best-effort) |

**EXG-GPU-1101** — Les profils MIG disponibles (1g, 2g, 4g…) sont publiés au catalogue ; le découpage d'un GPU en profils est administré (MIG manager) et reconfigurable par fenêtre planifiée (drain préalable).

**EXG-GPU-1102** — Un gabarit GPU compose toujours GPU + vCPU + RAM cohérents (pas de partition MIG « orpheline » sans CPU/RAM associés), conformément à la définition de l'UC-GPU.

---

## 3. Modes d'exposition du GPU

**EXG-GPU-1200** — **Passthrough complet** (équiv. *attached GPU* entier) : un GPU physique est assigné en VFIO-PCI à une VM (KubeVirt) ou à un pod, sans partage. Performances natives ; pas de migration à chaud (chapitre 5).

**EXG-GPU-1201** — **MIG / partition matérielle** (équiv. *Multi-Instance GPU*) : un GPU est découpé en jusqu'à 4 instances isolées matériellement (mémoire et SM cloisonnés), chacune exposée comme une UC-GPU à un conteneur ou, en vGPU, à une VM. C'est le mode **par défaut** de mutualisation (isolation forte).

**EXG-GPU-1202** — **Partage temporel** (équiv. *GPU time-sharing*) : plusieurs conteneurs se partagent une même partition/GPU par multiplexage temporel, sans isolation mémoire matérielle — réservé aux charges non sensibles (dev/test, best-effort), clairement étiqueté.

**EXG-GPU-1203** — **vGPU / mdev pour VM** (équiv. *vWS / vGPU*) : exposition de tranches GPU à des machines virtuelles via périphériques médiatisés (mdev), sous licence **NVIDIA AI Enterprise (NVAIE)** servie par un **NVIDIA License System** interne ; prend en charge les postes de travail virtuels accélérés (graphismes) et les VM d'inférence.

**EXG-GPU-1204** — **Conformité de licence** : la consommation de licences NVAIE/vWS est suivie et plafonnée par le License System interne ; aucune VM vGPU ne démarre sans licence valide.

---

## 4. Pilotes, runtime et images

**EXG-GPU-1300** — **Gestion des pilotes** (équiv. *install GPU drivers*) : le NVIDIA GPU Operator déploie et maintient le pilote data-center, le container toolkit, le device plugin, le MIG manager, GFD et l'exporter DCGM, de façon déclarative (versions épinglées, mise à jour par fenêtre).

**EXG-GPU-1301** — **Pilotes vGPU/vWS** (équiv. *install vWS/GRID drivers*) : pilotes hôte et invité vGPU/vWS gérés pour les VM accélérées ; table de compatibilité pilote/CUDA publiée.

**EXG-GPU-1302** — **Images accélérées** : catalogue d'images et de conteneurs préintégrant CUDA, cuDNN, NCCL et les frameworks (PyTorch, TensorFlow, vLLM), versionnés et durcis ; toolkit conteneur configuré pour l'accès GPU.

**EXG-GPU-1303** — **Découverte de capacités** : étiquetage automatique des nœuds (modèle GPU, profils MIG disponibles, version CUDA) via GFD/NFD pour l'ordonnancement.

---

## 5. Cycle de vie et attachement

**EXG-GPU-1400** — **Attachement** d'une ressource GPU (MIG, GPU entier, vGPU) à une VM ou à un pod via le gabarit choisi ; **détachement** à la libération.

**EXG-GPU-1401** — **Ajout/retrait de GPU** (équiv. *add/remove GPUs*) : modification de l'allocation GPU d'une charge arrêtée ; reconfiguration MIG d'un nœud par drain + reprofilage.

**EXG-GPU-1402** — **Pas de migration à chaud en passthrough/vGPU** : conformément à la contrainte matérielle (et au comportement GCP), les instances à GPU attaché ne sont **pas** migrables à chaud ; en maintenance hôte, politique `TERMINATE` (arrêt/relance), annoncée au tenant (renvoi **EXG-VM-1204**).

**EXG-GPU-1403** — **Maintenance hôte GPU** (équiv. *GPU host maintenance events*) : fenêtres planifiées et notifiées ; drain des charges, reprofilage MIG si besoin, relance ordonnancée par Kueue.

---

## 6. Ordonnancement, files d'attente et préemption

**EXG-GPU-1500** — **Quotas par tenant** (équiv. *GPU quotas*) : capacité GPU réservée et plafonnée par projet via Kueue (`ClusterQueue`/`LocalQueue`) ; dépassement → mise en file, pas de rejet silencieux.

**EXG-GPU-1501** — **Files d'attente** : les jobs GPU dépassant la capacité immédiate sont mis en file avec priorités ; admission équitable entre tenants (partage pondéré, *fair-sharing* Kueue).

**EXG-GPU-1502** — **Préemption** : un job de priorité supérieure (ex. production) peut préempter un job best-effort (dev/test) ; la préemption est gracieuse (signal + délai) et journalisée. (Référence CDC EXG-1906/1907.)

**EXG-GPU-1503** — **Affinité topologique** : placement tenant compte de la topologie (GPU/NUMA/NIC) pour les charges multi-GPU ; *gang scheduling* (tout-ou-rien) pour l'entraînement distribué afin d'éviter les blocages partiels.

**EXG-GPU-1504** — **Réservation** : un tenant peut réserver une capacité GPU pour une fenêtre donnée (équiv. fonctionnel des réservations), garantissant la disponibilité au démarrage du job.

---

## 7. Réseau GPU

**EXG-GPU-1600** — **NIC haut débit** : chaque nœud GPU dispose de cartes RoCE 2×100 GbE rattachées au fabric (renvoi **KubeCenter Network** / Lot underlay).

**EXG-GPU-1601** — **RDMA / GPUDirect** (équiv. *GPUDirect*) : le RDMA inter-nœuds (RoCEv2) pour l'entraînement multi-nœuds est **prévu mais non activé en phase 1** (câblage et NIC prêts) ; activation ultérieure via NVIDIA Network Operator (renvoi CDC EXG-1909).

**EXG-GPU-1602** — En phase 1, l'entraînement distribué reste intra-nœud (jusqu'à 4 GPU d'un même nœud) via NVLink/PCIe ; le multi-nœuds est documenté comme évolution.

---

## 8. Charges supportées

**EXG-GPU-1700** — **Entraînement distribué** (équiv. usage série A) : Kubeflow Training Operator (`PyTorchJob`, `TFJob`) ; *gang scheduling* via Kueue ; checkpoints sur stockage CephFS/RBD (renvoi **KubeCenter Storage**).

**EXG-GPU-1701** — **Notebooks** : environnements Jupyter accélérés (1 UC-GPU par défaut), montés sur volumes persistants, intégrés à l'IAM tenant.

**EXG-GPU-1702** — **Inférence servie** : non traitée ici — renvoi **KubeCenter LLMaaS** (KServe + vLLM/SGLang, mise à l'échelle, facturation au token). Ce module fournit l'**infrastructure GPU** sous-jacente.

**EXG-GPU-1703** — **Calcul scientifique / HPC** : exécution de charges CUDA génériques (simulation, traitement) en conteneur ou VM, avec les mêmes mécanismes d'allocation et de file.

---

## 9. Multi-AZ, continuité et PRA

**EXG-GPU-1800** — **Répartition** : 1 nœud GPU par AZ d'Alger + 1 à Constantine ; placement tenant compte de l'AZ pour la résilience des charges multi-instances.

**EXG-GPU-1801** — **Continuité (PCA) GPU en best-effort** : la capacité GPU n'est **pas** dimensionnée en redondance ×2 (coût) ; en cas de perte d'un nœud GPU, les charges prioritaires sont réordonnancées sur la capacité restante par préemption Kueue, les charges best-effort étant suspendues. Ce comportement est documenté contractuellement.

**EXG-GPU-1802** — **PRA IA (tier T2)** : les charges IA critiques peuvent reprendre à Constantine via la file Kueue de la région PRA (préemption des charges locales best-effort), avec RPO/RTO du tier T2 ; les données/modèles sont déjà répliqués (renvoi Storage RBD mirroring).

**EXG-GPU-1803** — **Extension capacitaire** : montée de 4 à 8 GPU par châssis (in-chassis) sans changement d'architecture, doublant la capacité à 96 UC-GPU ; procédure documentée (alimentation/refroidissement vérifiés au préalable).

---

## 10. Supervision et santé

**EXG-GPU-1900** — **Métriques GPU** (équiv. *monitor GPU performance*) via DCGM : taux d'utilisation SM, occupation mémoire, température, puissance, fréquence, erreurs ECC, utilisation par MIG — exposées par GPU/partition/tenant à la console et à l'API.

**EXG-GPU-1901** — **Santé GPU** : détection des erreurs matérielles (XID, ECC non corrigibles, surchauffe) ; un GPU défaillant est marqué non-ordonnançable (cordon) et les charges réordonnancées ; alerte opérateur.

**EXG-GPU-1902** — **Alertes** : saturation de file GPU, dérive de température/puissance, échec de job, indisponibilité de licence NVAIE, dérive PRA.

**EXG-GPU-1903** — **Comptabilité d'usage** : temps GPU/MIG consommé par tenant, par job, exporté pour la facturation (chapitre 12).

---

## 11. Sécurité et multi-tenancy

**EXG-GPU-2000** — **Isolation MIG matérielle** : la mémoire et les unités de calcul d'une partition MIG sont cloisonnées ; pas de fuite entre tenants partageant un même GPU physique.

**EXG-GPU-2001** — **Nettoyage entre allocations** : remise à zéro de la mémoire GPU à la libération d'une partition/GPU avant réattribution à un autre tenant (anti-résidu de données).

**EXG-GPU-2002** — **RBAC & admission** : accès GPU régi par OIDC (Keycloak) et Kyverno (gabarits/profils autorisés) ; le time-slicing (sans isolation mémoire) est interdit en multi-tenant sur données sensibles.

**EXG-GPU-2003** — **Audit** : allocation, attachement, préemption, reprofilage MIG, accès notebook journalisés (acteur, horodatage), consultables par le tenant pour ses ressources.

**EXG-GPU-2004** — **Conformité loi 18-07 / ANPDP** : tout le calcul et toutes les données (jeux d'entraînement, modèles, checkpoints) résident à Alger et Constantine ; aucune donnée ni télémétrie GPU sensible hors du territoire.

---

## 12. Quotas, facturation, API/CLI/console

**EXG-GPU-2100** — **Quotas** par projet : nombre d'UC-GPU, de GPU entiers, de jobs concurrents, de notebooks ; appliqués par Kueue + ResourceQuota ; relèvement tracé.

**EXG-GPU-2101** — **Facturation à l'usage** : UC-GPU à l'heure ou au mois, GPU entier, temps de notebook, licences vGPU/vWS ; export vers le moteur de facturation (Odoo) ; tarification modulée par tier ; les charges best-effort (time-slicing) tarifées à part.

**EXG-GPU-2102** — **API REST** : ressources `gpuResources`, `gpuMachineTypes`, `migProfiles`, `gpuQueues`, `gpuJobs`, `reservations` ; verbes CRUD + actions (`attachGpu`, `detachGpu`, `submitJob`, `preempt`, `reprofileMig`) ; opérations asynchrones, idempotence, pagination, débit limité.

**EXG-GPU-2103** — **CLI `kubecenter`** et **console self-service** : choix de gabarit GPU, soumission de jobs d'entraînement, lancement de notebooks, suivi de file, tableaux de bord DCGM, gestion des réservations.

**EXG-GPU-2104** — **Réversibilité** : les jobs, images et modèles sont des artefacts standard (conteneurs OCI, checkpoints sur volumes exportables) ; aucune dépendance propriétaire empêchant la migration.

---

## 13. (réservé)

*Section fusionnée avec le chapitre 12 — numérotation conservée pour alignement avec les autres specs.*

---

## 14. Options GCP écartées (et justification)

| Option GCP non retenue | Raison |
|---|---|
| **Séries A (A4X GB300/GB200, A4 B200, A3 H200/H100, A2 A100)** | Matériel non retenu ; KubeCenter standardise sur le RTX PRO 6000 Blackwell (= série G4), adapté à l'inférence/fine-tuning/visualisation souverains et au capacitaire visé |
| **TPU (Cloud TPU)** | ASIC propriétaire Google, indisponible hors GCP |
| **Instances *bare metal* A4X Max / NVL72 rack-scale** | Échelle exascale hors périmètre ; pas de superchip Grace-Blackwell |
| **GPUDirect-TCPX/RDMA managé Google** | RDMA/RoCE prévu mais **non activé en phase 1** (câblage prêt) ; la version managée est spécifique à Google |
| **Confidential GPU (calcul confidentiel H100)** | Non retenu en phase 1 ; l'isolation MIG + nettoyage mémoire couvre le besoin multi-tenant |
| **GPU Spot / préemptible + remises d'engagement (CUD)** | Remplacé par le modèle **UC-GPU** + préemption **Kueue** pour le best-effort interne ; pas de marché spot |
| **vWS comme licence auto-ajoutée par Google** | Les licences **NVAIE/vWS** sont gérées en propre via un NVIDIA License System interne |
| **Familles GPU N1 héritées (T4/P4/V100/P100)** | Générations anciennes non pertinentes pour une offre neuve |

---

## 15. Exigences — récapitulatif de traçabilité

Les exigences `EXG-GPU-1000` à `EXG-GPU-2104` constituent le référentiel traçable du module. Chacune est vérifiable (chapitre 16), rattachée à un composant (§0.4) et priorisée `MUST` (phase 1) sauf : RDMA/GPUDirect multi-nœuds (1601), entraînement multi-nœuds (1602), confidential GPU — `SHOULD`/phase ultérieure.

---

## 16. Tests d'acceptation

| ID | Objet | Critère de réussite |
|---|---|---|
| T-GPU-01 | Découverte & pilotes | GPU Operator déployé ; nœuds étiquetés (modèle, profils MIG, CUDA) ; `nvidia-smi` OK dans un pod |
| T-GPU-02 | Passthrough VM | VM avec GPU entier (VFIO) ; charge CUDA exécutée à performance native |
| T-GPU-03 | MIG / UC-GPU | GPU découpé en 4 partitions ; 4 conteneurs de 4 tenants isolés ; mémoire cloisonnée vérifiée |
| T-GPU-04 | vGPU/NVAIE | VM vGPU démarrée sous licence NVAIE valide ; démarrage refusé sans licence |
| T-GPU-05 | Time-slicing | Deux conteneurs dev partagent une partition ; interdit en multi-tenant sensible (admission) |
| T-GPU-06 | Gabarits | Création `ku-gpu-mig-1` (1 UC-GPU) et `ku-gpu-full` ; ressources CPU/RAM associées conformes |
| T-GPU-07 | Reprofilage MIG | Passage 1g→2g d'un nœud par drain + reprofilage sans impact sur les autres nœuds |
| T-GPU-08 | Ajout/retrait GPU | Modification de l'allocation GPU d'une charge arrêtée |
| T-GPU-09 | Maintenance hôte | Drain d'un nœud GPU → charges `TERMINATE` puis relancées ; aucune migration à chaud tentée |
| T-GPU-10 | Quotas tenant | Dépassement de quota UC-GPU → mise en file (pas de rejet) ; message explicite |
| T-GPU-11 | File & fair-share | Deux tenants en contention → partage équitable conforme aux pondérations |
| T-GPU-12 | Préemption | Job production préempte un job best-effort gracieusement ; préemption journalisée |
| T-GPU-13 | Gang scheduling | Job 4-GPU démarre tout-ou-rien ; pas d'allocation partielle bloquante |
| T-GPU-14 | Réservation | Capacité réservée disponible au démarrage du job dans la fenêtre |
| T-GPU-15 | Entraînement | `PyTorchJob` multi-GPU intra-nœud converge ; checkpoints écrits sur CephFS |
| T-GPU-16 | Notebook | Notebook Jupyter 1 UC-GPU lancé depuis la console, volume persistant monté |
| T-GPU-17 | Supervision DCGM | Utilisation/мémoire/température/ECC remontées par GPU et par MIG |
| T-GPU-18 | Santé GPU | Erreur GPU simulée → nœud cordon, charges réordonnancées, alerte émise |
| T-GPU-19 | Multi-AZ | Charge répartie sur les nœuds GPU des deux AZ d'Alger |
| T-GPU-20 | PCA best-effort | Perte d'un nœud GPU → charges prioritaires réordonnancées, best-effort suspendues |
| T-GPU-21 | PRA T2 | Reprise d'une charge IA critique à Constantine via la file PRA ; RPO/RTO T2 respectés |
| T-GPU-22 | Extension 4→8 | Ajout de 4 GPU in-chassis reconnu ; capacité doublée sans reconfiguration majeure |
| T-GPU-23 | Isolation & nettoyage | Mémoire GPU remise à zéro entre deux allocations de tenants différents |
| T-GPU-24 | Facturation | Temps UC-GPU et licences mesurés par tenant et exportés |
| T-GPU-25 | Audit & 18-07 | Allocations/préemptions journalisées ; aucune donnée GPU hors Alger/Constantine |

---

## Annexe A — Correspondance complète GCP Cloud GPUs ↔ KubeCenter ↔ implémentation

| Capacité GCP Cloud GPUs | KubeCenter GPU | Implémentation |
|---|---|---|
| Série G4 (RTX PRO 6000) | Matériel standard | RTX PRO 6000 Blackwell Server Edition |
| GPU attaché entier | Passthrough complet | VFIO-PCI (KubeVirt) |
| Multi-Instance GPU (MIG) | Partition MIG / UC-GPU | MIG manager (GPU Operator) |
| GPU time-sharing | Partage temporel | time-slicing (device plugin) |
| NVIDIA RTX Virtual Workstation (vWS) | Poste virtuel / vGPU | vGPU/mdev + NVAIE + License System |
| Install GPU drivers | Gestion des pilotes | NVIDIA GPU Operator |
| Install vWS/GRID drivers | Pilotes vGPU/vWS | GPU Operator (profil vGPU) |
| GPUDirect (RDMA) | Réseau GPU RDMA | RoCEv2 + Network Operator (phase ultérieure) |
| Add/remove GPUs | Ajout/retrait GPU | reconfiguration d'allocation |
| GPU host maintenance (no live migrate) | Maintenance hôte | `TERMINATE` + drain + Kueue |
| Monitor GPU performance | Supervision | DCGM exporter → LGTM |
| GPU quotas | Quotas GPU | Kueue + ResourceQuota |
| Reservations | Réservation de capacité | Kueue (fenêtre réservée) |
| Spot/preemptible GPU + CUD | (écarté) | UC-GPU + préemption Kueue |
| Accelerator-optimized A series / TPU | (écarté) | matériel non retenu |
| Bulk GPU VM / MIG with GPU | Jobs/notebooks GPU | Training Operator + Kueue |
| Networking & GPU (multi-NIC, bande passante) | Réseau GPU | RoCE 2×100 GbE (renvoi Network) |

---

*Fin du document — SPEC-KubeCenter-GPU v1.0. À lire conjointement avec SPEC-KubeCenter-VM, SPEC-KubeCenter-Storage, SPEC-KubeCenter-Network et le CDC-PCA-PRA-K8S (Lots GPU/IA, Réseau underlay, Sécurité, PRA, Console). L'inférence LLM servie est spécifiée dans le futur module KubeCenter LLMaaS.*
