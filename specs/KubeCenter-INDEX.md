# KubeCenter — Index maître de la documentation d'ingénierie

**Version :** 1.1 — Juin 2026
**Rôle :** point d'entrée unique du corpus documentaire KubeCenter. Décrit les documents, leurs dépendances, les conventions communes, l'ordre de lecture/construction et l'état d'avancement.
**À lire en premier**, avant tout module.

---

## 1. Le corpus en un coup d'œil

| # | Document | Rôle | Réf. exigences | Tests | Statut |
|---|---|---|---|---|---|
| 0 | **CDC-PCA-PRA-K8S** | Cahier des charges maître (architecture, lots, PCA/PRA) | `EXG-####` (18 lots) | 22 (T-xx) | ✅ Établi |
| 1 | **SPEC-KubeCenter-Storage-Portfolio** | Vue d'ensemble du domaine stockage, ancrée au CDC | `EXG-STO-####` | 22 (T-STO) | ✅ Rédigé |
| 2 | **SPEC-KubeCenter-VM** | Module IaaS — machines virtuelles (KubeVirt) | `EXG-VM-####` | 25 (T-VM) | ✅ Rédigé |
| 3 | **SPEC-KubeCenter-Storage** | Module bloc — disques (Ceph RBD + local) | `EXG-ST-####` | 25 (T-ST) | ✅ Rédigé |
| 4 | **SPEC-KubeCenter-Network** | Module réseau (OVN/Cilium + fabric SONiC) | `EXG-NET-####` | 25 (T-NET) | ✅ Rédigé |
| 5 | **SPEC-KubeCenter-GPU** | Module GPUaaS (RTX PRO 6000 / GPU Operator) | `EXG-GPU-####` | 25 (T-GPU) | ✅ Rédigé |
| 6 | **SPEC-KubeCenter-LLMaaS** | Module IA générative (vLLM/KServe/LiteLLM) | `EXG-LLM-####` | 25 (T-LLM) | ✅ Rédigé |
| 7 | **SPEC-KubeCenter-AppStore** | Catalogue d'applications managées (Harbor/Helm/ArgoCD) | `EXG-APP-####` | 25 (T-APP) | ✅ Rédigé |
| 8 | **SPEC-KubeCenter-Console** | Console self-service & API unifiée | `EXG-CON-####` | 20 (T-CON) | ✅ Rédigé |

Légende : ✅ rédigé · ⏳ planifié.

---

## 2. Méthode commune (rappel)

Tous les modules suivent la même fabrication :
1. **Grille de complétude** issue de la doc Google Cloud du domaine correspondant (jamais de copie : contenu transformatif).
2. **Transposition** sur le socle souverain (KubeVirt, Rook-Ceph, OVN/Cilium, NVIDIA GPU Operator, vLLM/KServe…).
3. **Exigences tracées** `EXG-<MODULE>-####`, priorisées `MUST` (phase 1) / `SHOULD` (phase ultérieure).
4. **Tests d'acceptation** `T-<MODULE>-##`.
5. **Annexe de correspondance** GCP ↔ KubeCenter ↔ implémentation.
6. **Chapitre « options écartées »** avec justification.
7. **Renvois croisés** entre modules et vers le CDC.

---

## 3. Carte des dépendances

```
                         ┌───────────────────────────┐
                         │   CDC-PCA-PRA-K8S (maître) │
                         └─────────────┬─────────────┘
                                       │ (tous les modules s'y rattachent)
        ┌───────────────┬─────────────┼─────────────┬───────────────┐
        ▼               ▼             ▼             ▼               ▼
   ┌─────────┐    ┌──────────┐   ┌─────────┐   ┌─────────┐    ┌──────────┐
   │ Network │    │ Storage  │   │   VM    │   │  GPU    │    │ Storage- │
   │ (NET)   │    │ (bloc ST)│   │ (VM)    │   │ (GPU)   │    │ Portfolio│
   └────┬────┘    └────┬─────┘   └────┬────┘   └────┬────┘    └────┬─────┘
        │              │              │             │              │
        │              │   VM ─────────┘ dépend de Storage + Network
        │              │                            │   (Portfolio chapeaute ST)
        │              └──────────── GPU dépend de Network (RoCE) + Storage (poids)
        │                                           │
        └───────────────────── LLMaaS ─────────────┘
                          (dépend de GPU + Storage + Network)

   ┌──────────────────────────────────────────────────────────┐
   │  Surfaces self-service (par-dessus tous les modules)       │
   │   Console (EXG-CON, ⏳)  ──►  AppStore (EXG-APP, ✅)        │
   │   AppStore : catalogue central + instances par namespace   │
   │   (Harbor + Helm + ArgoCD Application + Kyverno)           │
   └──────────────────────────────────────────────────────────┘
```

**Lecture des dépendances :**
- **Network** et **Storage (bloc)** sont les fondations (consommés par tout le reste).
- **VM** dépend de **Storage** (disques) et **Network** (réseaux/IP).
- **GPU** dépend de **Network** (RoCE/RDMA, à terme) et **Storage** (jeux de données, checkpoints, poids).
- **LLMaaS** dépend de **GPU** (UC-GPU/MIG), **Storage** (poids/caches) et **Network** (passerelle, endpoints privés).
- **Storage-Portfolio** est un volet de **vue d'ensemble** : il chapeaute Storage (bloc) et ajoute fichier/objet/sauvegarde-PRA/transfert.
- **AppStore** s'appuie sur Storage (persistance), Network (exposition), VM (apps à base d'image VM) et, selon les apps, GPU/LLMaaS ; il passe par la **Console** pour le déploiement guidé.
- **Console** (à venir) est la surface unifiée par-dessus tous les modules.

---

## 4. Matrice des renvois croisés

| Module ↓ renvoie vers → | CDC | NET | ST | VM | GPU | LLM | Portfolio |
|---|---|---|---|---|---|---|---|
| **VM** | ✓ | ✓ | ✓ | — | ✓ (GPU attaché) | ✓ (inférence) | — |
| **Storage (ST)** | ✓ | ✓ | — | ✓ | — | — | chapeauté par |
| **Network (NET)** | ✓ | — | — | ✓ | ✓ (RoCE) | ✓ (endpoints privés) | — |
| **GPU** | ✓ | ✓ | ✓ | ✓ (TERMINATE) | — | ✓ (sert LLMaaS) | — |
| **LLMaaS** | ✓ | ✓ | ✓ | ✓ | ✓ | — | — |
| **Storage-Portfolio** | ✓ | ✓ | ✓ (détail bloc) | ✓ | — | — | — |
| **AppStore** | ✓ | ✓ (exposition) | ✓ (persistance) | ✓ (apps VM) | ○ (selon app) | ○ (selon app) | — |

Légende : ✓ renvoi explicite · ○ renvoi conditionnel selon l'application déployée.

---

## 5. Conventions de numérotation

| Préfixe | Module | Plage |
|---|---|---|
| `EXG-####` | CDC maître | 18 lots |
| `EXG-VM-####` | VM | 1000–2402 |
| `EXG-ST-####` | Storage (bloc) | 1000–2105 |
| `EXG-NET-####` | Network | 1000–2403 |
| `EXG-GPU-####` | GPU | 1000–2104 |
| `EXG-LLM-####` | LLMaaS | 1000–2401 |
| `EXG-STO-####` | Storage-Portfolio | 1000–1901 |
| `EXG-APP-####` | AppStore | 1000–2301 |
| `T-<MODULE>-##` | Tests d'acceptation | par module |

Règle : une exigence ne change jamais d'identifiant ; une exigence retirée est marquée « obsolète » et son numéro n'est pas réutilisé.

---

## 6. Architecture de référence (rappel transversal)

- **Région primaire : Alger**, étendue sur **2 zones de disponibilité (AZ)** — cluster Kubernetes unique, Ceph **stretch** + **site témoin** intra-Alger (moniteur arbitre + 3ᵉ etcd).
- **Région PRA : Constantine** — réplication RBD (mode snapshot, ≤ 15 min).
- **Tiers de continuité** (label `kubecenter.dz/dr-tier`) : **T0** (multi-AZ, RPO 0) · **T1** (24 h / RTO 8 h) · **T2** (15 min / RTO 4 h) · **T3** (actif-actif, RTO < 15 min).
- **GPU** : NVIDIA RTX PRO 6000 Blackwell (96 Go, MIG 4), 12 GPU → 48 UC-GPU ; **UC-GPU = 1 MIG ≈24 Go + 12 vCPU + 56 Gio**.
- **UC (calcul)** commerciale = 2 vCPU / 8 Gio / 100 Gio.
- **Socle** : Kubespray · Cilium+Multus+OVN-Kubernetes · Ceph stretch (Rook) · KubeVirt+Medik8s · Capsule+Kyverno+Keycloak · ArgoCD · Velero+RGW · vLLM/KServe/LiteLLM · fabric SONiC (eBGP/EVPN-VXLAN).
- **Conformité** : loi 18-07 / ANPDP — toutes les données et tout le calcul à Alger et Constantine.

---

## 7. Ordre de construction recommandé (pour Claude Code)

Construire en respectant les dépendances :

1. **Underlay & Network** (fabric SONiC, OVN/Cilium, IPAM, DNS) — fondation réseau.
2. **Storage (bloc)** + briques fichier/objet du Portfolio (Ceph RBD/CephFS/RGW, stretch).
3. **VM** (KubeVirt, images, cycle de vie) — consomme Network + Storage.
4. **GPU** (GPU Operator, MIG, Kueue, DCGM) — consomme Network + Storage.
5. **LLMaaS** (vLLM/KServe/LiteLLM) — consomme GPU + Storage + Network.
6. **Sauvegarde & PRA** transverse (Velero, mirroring, cockpit) — s'applique à tout.
7. **Console** (à spécifier) — surface unifiée par-dessus l'ensemble.
8. **AppStore** (✅ spécifié) — catalogue central + instances par namespace (Harbor → Helm → `Application` ArgoCD → admission Kyverno). Démarrage du catalogue : **WordPress** (rodage du pipeline), puis **Odoo** (1ʳᵉ app stateful), puis briques de soutien.

Chaque lot se livre avec : code/IaC (OpenTofu/Helm/Kustomize, GitOps ArgoCD), passage des **tests d'acceptation** du module, et mise à jour de la traçabilité `EXG`.

---

## 8. Phasage (synthèse)

**Phase 1 (MUST)** — socle exploitable : réseaux tenant, disques (3 classes) + CephFS + RGW, VM complètes, GPU (passthrough/MIG/time-slicing + Kueue), LLMaaS (API OpenAI-compat, catalogue, facturation token, zéro rétention), sauvegarde + PRA T0–T3, console de base, **AppStore first-party open source** (catalogue curé, mirroring Harbor + scan, instances par namespace, Kyverno zéro-privilège ; WordPress → Odoo → briques de soutien).

**Phase ultérieure (SHOULD)** — RDMA/GPUDirect multi-nœuds, autoscaling sur métriques, L7 LB généralisé, CMEK (clés client), provider Terraform public, audio STT/TTS, génération d'images, périmètres VPC-SC complets, fichier parallèle Lustre dédié, transfert par support physique, **catalogue AppStore tiers/ISV commercial** (découplage licence), apps à base d'image VM.

---

## 9. Actions ouvertes

**Documentation (assistant) :**
- ✅ **SPEC-KubeCenter-Console** rédigé (`EXG-CON-####`, 20 tests T-CON) — **corpus complet (8 modules)**.
- ✅ **SPEC-KubeCenter-AppStore** rédigé.
- 🔄 Mettre à jour le **CDC** et les renvois si une décision d'architecture évolue.

**Côté porteur (Mohamed) :**
- Voir le dossier de labellisation (BP, pitch, prototype) — suivi hors de cet index.
- Alimenter les valeurs réelles (capacités, prix UC/UC-GPU/token) lorsqu'arrêtées, pour figer les chapitres « facturation ».

---

## 10. Glossaire express

| Terme | Sens |
|---|---|
| **AZ** | Zone de disponibilité (Alger en compte deux) |
| **PCA / PRA** | Plan de continuité / de reprise d'activité |
| **RPO / RTO** | Perte de données max. tolérée / délai de reprise cible |
| **UC / UC-GPU** | Unité de calcul / unité de calcul GPU (MIG) |
| **MIG** | Multi-Instance GPU (partition matérielle d'un GPU) |
| **RBD / CephFS / RGW** | Bloc / fichier / objet de Ceph |
| **stretch** | Cluster Ceph étiré synchrone entre AZ |
| **mirroring** | Réplication RBD asynchrone vers la région PRA |
| **CSI / CNI** | Interfaces standard stockage / réseau de Kubernetes |
| **LLMaaS** | LLM-as-a-Service (API d'IA générative) |
| **TTFT / TPOT** | Latence au 1ᵉʳ token / latence par token (inférence) |

---

*Fin de l'index — KubeCenter-INDEX v1.2. Documents référencés dans /outputs : CDC-PCA-PRA-K8S, SPEC-KubeCenter-{Storage-Portfolio, VM, Storage, Network, GPU, LLMaaS, AppStore, Console}. **Corpus complet (8 modules).** À mettre à jour à chaque nouveau module ou décision d'architecture.*
