# Cahier des Charges — Spécifications Techniques Détaillées
## Plateforme Kubernetes multi-tenant avec PCA/PRA — Alger (2 AZ) ↔ Constantine

**Destinataire :** Claude Code (agent de développement)
**Objet :** Développement de la procédure complète de mise en œuvre (IaC, manifests, scripts, runbooks, plan de tests) d'une plateforme Kubernetes multi-tenant neuve, assurant PCA et PRA.
**Version :** 3.1 — Juin 2026 (Lot 19 Day-2/AIOps ; hiérarchie revendeur Option A — EXG-505/506/507 + module console EXG-1711)
**Langue :** Documentation en français, code/manifests/commentaires en anglais.
**Nature :** Projet **greenfield**, datacenter dédié, **totalement indépendant** de toute plateforme existante. Aucune intégration à un cloud, un hyperviseur ou un orchestrateur préexistant : tous les composants ci-dessous sont déployés à neuf.

---

## 1. Objet du document

Spécification des exigences techniques pour une plateforme Kubernetes multi-tenant répartie sur deux régions :

- **Alger = région primaire**, étendue sur **deux zones de disponibilité (AZ-1, AZ-2)**. C'est cette répartition multi-AZ qui assure le **PCA** : la perte d'une AZ entière est transparente.
- **Constantine = région secondaire (site PRA)**. C'est la cible du **PRA** : perte complète de la région d'Alger → bascule vers Constantine.

La plateforme doit assurer :

1. **PCA** : haute disponibilité inter-AZ dans Alger (réplication synchrone, RPO 0 sur perte d'AZ) + actif-actif optionnel inter-régions pour le stateless.
2. **PRA** : bascule orchestrée Alger → Constantine (et failback), RTO/RPO contractuels par tier.
3. **Multi-tenancy "soft"** de type OpenShift Projects (isolation namespace, self-service, quotas, policies).
4. **Workloads mixtes** : conteneurs ET machines virtuelles (KubeVirt).

Claude Code produit les livrables du §6 en respectant les exigences numérotées `EXG-xxx` (matrice de traçabilité).

---

## 2. Contexte et contraintes

### 2.1 Tout est à déployer (rien à intégrer)

Le datacenter fournit du **bare-metal** (serveurs physiques) réparti sur les AZ et la région PRA, plus la connectivité réseau. **Aucune** brique logicielle n'est préexistante. Claude Code spécifie le déploiement neuf de la totalité de la pile : Kubernetes, stockage Ceph, CNI, identité, registre, dépôt Git, GitOps, virtualisation, sauvegarde, observabilité, DNS/GSLB.

### 2.2 Souveraineté et conformité

- **EXG-001** : Aucune dépendance obligatoire à un service SaaS ou cloud externe en exploitation. Toutes les images proviennent du registre interne ; tous les charts Helm d'un dépôt miroir interne.
- **EXG-002** : Toutes les données (workloads, backups, logs, métriques, sauvegardes) résident exclusivement dans le datacenter, sur les régions Alger et Constantine (conformité loi 18-07 / ANPDP, données en Algérie).
- **EXG-003** : La plateforme doit pouvoir être installée et opérée en connectivité Internet restreinte : prévoir les procédures de mirroring d'images conteneurs et de charts Helm vers le registre/dépôt interne.

### 2.3 Hors périmètre

- Multi-tenancy "hard" (Kamaji, vCluster) et fédération multi-cluster (Karmada) — exclus de cette phase.
- Réplication applicative des bases de données clients (Patroni, Galera…) — tier "Critique", sur étude ; l'architecture ne doit pas l'empêcher.
- **Phase 2 (reportés mais à anticiper)** : metering/facturation par tenant (OpenCost ou requêtes Mimir — les labels tenant/tier définis dans ce document doivent suffire à l'agrégation des consommations) et stockage objet S3 en libre-service tenant (le RGW déployé au Lot 3 doit pouvoir être ouvert aux tenants sans refonte).

---

## 3. Architecture cible

```
                         ┌──────────────────────────────┐
                         │  Dépôt Git auto-hébergé (HA)  │
                         │  source de vérité unique      │
                         │  répliqué Alger → Constantine │
                         └───────────────┬───────────────┘
                                         │
        ┌────────────────────────────────┴────────────────┐
        │                                                  │
┌───────▼──────────────────────────────────┐   ┌──────────▼────────────────┐
│  RÉGION ALGER (PRIMAIRE)                  │   │ RÉGION CONSTANTINE (PRA)   │
│  cluster k8s-alger (étendu sur 2 AZ)      │   │ cluster k8s-constantine    │
│                                           │   │                            │
│  ┌─────── AZ-1 ───────┐ ┌─── AZ-2 ──────┐ │   │  Stateless: optionnel A/A  │
│  │ ctrl-plane #1,#2   │ │ ctrl-plane #3 │ │   │  Stateful : PASSIF         │
│  │ workers            │ │ workers       │ │   │  VMs      : PASSIF         │
│  └────────────────────┘ └───────────────┘ │   │  (activés au PRA)          │
│   + TÉMOIN / tiebreaker (3e emplacement)  │   │                            │
│                                           │   │                            │
│  Ceph STRETCH sur 2 AZ                     │═══│  Ceph-Constantine          │
│  réplication SYNCHRONE inter-AZ (RPO 0)   │RBD│  (cible mirroring async)   │
│                                           │mir│                            │
│  RadosGW zone "alger"                     │═ms│  RadosGW zone "constantine"│
└───────────────────────────────────────────┘   └────────────────────────────┘
        │                                                  │
        └───────────────────┬───────────────────────────────┘
                            │
                 DNS autoritatif interne HA + GSLB
                 (health-checked, bascule Alger → Constantine)
```

- **EXG-010** : **Cluster d'Alger étendu sur 2 AZ** (un seul cluster Kubernetes dont les nœuds sont répartis sur AZ-1 et AZ-2). Latence inter-AZ **validée à < 5 ms RTT** — confortablement sous la limite pratique d'etcd (~10 ms) et compatible avec une réplication Ceph synchrone inter-AZ. Claude Code intègre une surveillance continue de cette latence (alerte si RTT p99 > 8 ms, Lot 11) car une dérive remettrait en cause le modèle synchrone.
- **EXG-011** : **Cluster de Constantine indépendant** (control plane et stockage propres), normalement passif pour le stateful/VMs, activé au PRA.
- **EXG-012** : **Quorum à 2 AZ — décision actée : un troisième emplacement témoin (tiebreaker) est retenu, situé dans la région d'Alger** (local technique distinct des deux AZ de données), avec une **latence < 10 ms** vers chacune des deux AZ — suffisant pour l'arbitrage etcd et le mon arbitre Ceph (l'arbitre ne porte pas de données, il ne fait que voter, la latence n'est donc pas sur le chemin d'écriture critique inter-AZ). etcd et les moniteurs Ceph exigeant un nombre impair de votants, ce site héberge le **mon arbitre Ceph** (Ceph en **mode stretch** : 2 sites de données AZ-1/AZ-2 + 1 arbitre) **et** un membre etcd, garantissant la tolérance à la perte de n'importe quelle AZ de données. Claude Code spécifie les besoins minimaux de ce site (un nœud léger suffit : aucun workload, uniquement des rôles de quorum), sa connectivité requise vers les 2 AZ, et le comportement en cas de perte du témoin lui-même (dégradation sans interruption tant qu'une seule AZ de données est perdue à la fois).
  > Note d'architecture : le témoin partageant la région d'Alger, il protège contre la perte d'**une AZ**, mais **pas** contre un sinistre détruisant toute la région d'Alger (les 2 AZ + témoin) — ce scénario relève précisément du **PRA vers Constantine**. La répartition des rôles est donc cohérente : témoin intra-région pour le PCA, Constantine pour le PRA.
- **EXG-013** : Git est l'unique source de vérité ; aucune ressource de production appliquée manuellement hors bootstrap et runbook PRA.

---

## 4. Matrice de service (tiers contractuels)

| Tier | Workloads visés | Mécanisme | RPO | RTO cible |
|---|---|---|---|---|
| **T0 Intra-région** | Tout workload sur Alger | Étalement 2 AZ + Ceph synchrone | **0** (perte d'AZ) | reprise auto, sans bascule de site |
| **T1 Standard** | Stateful non critique, VMs de dev | Sauvegarde quotidienne → RadosGW multisite | 24 h | 8 h |
| **T2 Continuité** | Stateful prod, VMs prod | RBD mirroring snapshot 15 min Alger→Constantine + runbook PRA | 15 min | 4 h |
| **T3 Continuité+** | Conteneurs **stateless** prod | Actif-actif Alger↔Constantine + GSLB | ~0 | < 15 min |
| **T4 Critique** | BDD répliquées applicativement | Hors périmètre automatisé (sur étude) | ~0 | < 15 min |

- **EXG-020** : Tout tenant/application est classé via un label normalisé `kubecenter.dz/dr-tier: t1|t2|t3` exploité par les schedules de sauvegarde, les policies et les scripts PRA. (Le préfixe de domaine du label est un paramètre, Annexe A.)
- **EXG-021** : Le tier **T0 est implicite et universel** sur Alger : la résilience inter-AZ ne se "souscrit" pas, elle est native de l'architecture multi-AZ.

---
## 5. Spécifications techniques par lot

### Lot 0 — Prérequis, conventions, versions

- **EXG-030** : Toutes les versions épinglées (images par digest dans le registre interne, charts par version exacte) dans un `versions.yaml` unique. Versions minimales **indicatives — Claude Code vérifie et propose les dernières stables et leur compatibilité mutuelle** : Kubernetes ≥ 1.31, Cilium ≥ 1.16, KubeVirt ≥ 1.4, CDI ≥ 1.61, Capsule ≥ 0.7, Kyverno ≥ 1.13, ArgoCD ≥ 2.13, Velero ≥ 1.15, Multus ≥ 4.x, Medik8s (NHC/SNR/FAR) dernières stables, Ceph ≥ Squid.
- **EXG-031** : Tout script est idempotent, avec `--dry-run`, journalisation horodatée, codes retour exploitables.
- **EXG-032** : Conventions de nommage : clusters `k8s-alger` / `k8s-constantine` ; régions `topology.kubernetes.io/region = alger|constantine` ; zones `topology.kubernetes.io/zone = alger-az1|alger-az2` ; namespaces plateforme préfixés `platform-` ; namespaces tenants `t-<tenant>-` ; StorageClasses voir Lot 3.
- **EXG-033** : Secrets jamais en clair dans Git : External Secrets Operator (backend à définir) ou Sealed Secrets — Claude Code propose et justifie.

### Lot 1 — Socle Kubernetes (Alger étendu 2 AZ + Constantine)

- **EXG-101** : Cluster d'Alger : **3 nœuds control plane répartis sur les AZ avec le témoin** (EXG-012) ; workers répartis équitablement AZ-1/AZ-2, labellisés `topology.kubernetes.io/zone`. Cluster de Constantine : control plane 3 nœuds local.
- **EXG-102** : Déploiement via **Kubespray** (bare-metal). Fournir inventaires + `group_vars` complets pour les deux clusters, et procédure d'upgrade sans interruption (drain + live migration des VMs, Lot 6).
- **EXG-103** : Backup etcd : snapshot horaire, rétention 48 h, copie quotidienne vers le RadosGW de la région distante.
- **EXG-104** : CRI containerd avec le registre interne (Lot 11) comme registre par défaut + miroirs pour les registres publics usuels (mode connectivité restreinte, EXG-003).
- **EXG-105** : PSA cluster `baseline`, `restricted` imposé aux namespaces tenants (Lot 5), exceptions KubeVirt (Lot 6).
- **EXG-106** : Étiquetage des domaines de panne cohérent entre Kubernetes (zones), Ceph (CRUSH) et le scheduler, pour garantir que les réplicas (pods et données) traversent réellement les 2 AZ.

### Lot 2 — Réseau : Cilium + Multus + DNS interne

- **EXG-201** : Cilium CNI principal, kube-proxy replacement, Hubble (relay + UI réservée plateforme). Conscience des zones (`topology-aware routing`) pour limiter le trafic inter-AZ inutile.
- **EXG-202** : Multus pour les attachements secondaires des VMs (bridges/VLANs). Les `NetworkAttachmentDefinition` sont gérées **plateforme uniquement**, création interdite aux tenants (policy Kyverno, Lot 5).
- **EXG-203** : Politique réseau par défaut de tout namespace tenant : **default-deny ingress+egress inter-namespaces**, autorisations explicites (intra-tenant, DNS, egress selon profil). En `CiliumNetworkPolicy` propagées par Capsule.
- **EXG-204** : Ingress : ingress-nginx **ou** Cilium Ingress (comparer/justifier), IngressClass partagée + wildcard par tenant `*.<tenant>.<domaine-apps>`, IngressClass dédiée possible pour tenant premium.
- **EXG-205** : Exposition L4 bare-metal : **Cilium LB-IPAM** ou **MetalLB** (comparer/justifier), pools d'IP par AZ et par région ; quota de services LoadBalancer par tenant.
- **EXG-206** : **DNS autoritatif interne** (remplace toute solution externe) : **PowerDNS** (recommandé, API REST) ou BIND9 (comparer/justifier), déployé en HA, autoritaire sur les zones de la plateforme. Intégration `external-dns` pour publier automatiquement les enregistrements Ingress/Service par tenant.
- **EXG-207** : **GSLB** : couche de bascule DNS pilotée par health checks, pour le tier T3 (actif-actif Alger↔Constantine) et pour la bascule de site au PRA. Mécanisme à proposer (ex. health-checker interne pilotant l'API PowerDNS, ou dnsdist/pools). TTL des enregistrements GSLB ≤ 60 s.

### Lot 3 — Stockage : Ceph (stretch 2 AZ + mirroring vers Constantine)

- **EXG-301** : Déploiement Ceph **à neuf**. Méthode : **cephadm** (recommandé pour maîtriser le mode stretch et le RGW multisite) ou **Rook-Ceph** (comparer/justifier). Un cluster Ceph pour Alger (étendu 2 AZ), un cluster Ceph pour Constantine.
- **EXG-302** : Ceph d'Alger en **mode stretch sur 2 AZ** : CRUSH map à 2 datacenters + **moniteur arbitre** au 3ᵉ emplacement témoin (EXG-012), règle de réplication forçant des copies dans chaque AZ → **RPO 0 sur perte d'une AZ**, écriture confirmée seulement quand les deux AZ ont acquitté.
- **EXG-303** : StorageClasses :
  - `ceph-rbd` (RWO fs, répliqué synchrone inter-AZ) — défaut, couvre T0 ;
  - `ceph-rbd-dr` (RWO, pool **également mirroré async vers Constantine**) — tier T2 ;
  - `ceph-rbd-block-rwx` (volumeMode Block, RWX, mirroré) — disques VMs avec live migration ;
  - `cephfs` (RWX fs).
- **EXG-304** : VolumeSnapshotClass CSI opérationnelle (prérequis Velero CSI + VirtualMachineSnapshot).
- **EXG-305** : **Mirroring RBD Alger → Constantine** : par pool, mode snapshot, schedule 15 min, sur les pools `*-dr` uniquement. Livrer : scripts de configuration des peers Ceph, vérification de santé (`rbd mirror pool status` parsé), métriques vers Mimir (lag, images non synchronisées), alerte si lag > 2× intervalle.
- **EXG-306** : **Export PVC ↔ image RBD** (pièce maîtresse du PRA) : CronJob produisant un mapping déterministe `namespace / workload / PVC / StorageClass / volumeHandle / image RBD`, stocké dans le bucket RadosGW répliqué. Sert à recréer statiquement les PV/PVC à Constantine en réutilisant les `volumeHandle` d'origine (format CSI RBD `0001-<cluster-fsid>-<pool-id>-<image-id>`). Livrer le générateur de manifests PV/PVC à partir de cet export.
- **EXG-307** : **RadosGW multisite** : zonegroup unique, zone `alger` et zone `constantine`, réplication asynchrone bidirectionnelle ; les buckets de backup écrits à Alger sont lisibles à Constantine. Procédure de configuration complète livrée (realm, zonegroup, zones, period).

### Lot 4 — Identité : Keycloak OIDC

- **EXG-401** : Keycloak **déployé à neuf**, en HA sur les 2 AZ d'Alger (cluster Infinispan/JGroups inter-AZ ou PostgreSQL HA — justifier). Realm `kubecenter` : clients OIDC pour les API servers des deux clusters, ArgoCD, Grafana, le registre, le Git. Groupes : `k8s-platform-admins`, `t-<tenant>-owners`, `t-<tenant>-devs`, `t-<tenant>-viewers`.
- **EXG-402** : API servers en OIDC (issuer Keycloak, claim `groups`). Si reconfiguration jugée trop intrusive : alternative kube-oidc-proxy/Dex (comparer/justifier).
- **EXG-403** : Accès **break-glass** : kubeconfig admin par certificat, indépendant de l'OIDC, scellé, procédure de sortie de coffre documentée (cas indisponibilité Keycloak).
- **EXG-404** : **Résilience inter-régions** : réplica Keycloak à Constantine avec base répliquée (mirroring/streaming), promu au PRA. RTO Keycloak ≤ 30 min (conditionne le RTO global).
- **EXG-405** : RBAC : ClusterRoles `admin`/`edit`/`view` mappés aux groupes tenant par RoleBindings propagés par Capsule. Aucun ClusterRole non namespacé pour les tenants.

### Lot 5 — Multi-tenancy : Capsule + Kyverno

- **EXG-501** : Capsule sur les deux clusters. Une CRD `Tenant` par client, owner = groupe `t-<tenant>-owners`, self-service de namespaces préfixés `t-<tenant>-`.
- **EXG-502** : Chart `tenant-onboarding` générant : Tenant Capsule, ResourceQuota agrégée (CPU, RAM, GPU si applicable, PVC count/capacité par StorageClass, services LB), LimitRange, NetworkPolicies default-deny, label de tier (EXG-020), AppProject ArgoCD (Lot 7), bucket de backup dédié (Lot 8).
- **EXG-503** : Policies Kyverno (mode `Enforce`, livrées avec tests `kyverno test`) :
  1. images uniquement depuis le registre interne ;
  2. interdiction `hostPath`, `hostNetwork`, `hostPID`, pods privilégiés (hors plateforme et exceptions KubeVirt) ;
  3. requests/limits obligatoires ;
  4. PSA `restricted` sur namespaces tenants, profil dédié pour les namespaces KubeVirt autorisés (Lot 6) ;
  5. unicité des hostnames Ingress inter-tenants + restriction au wildcard du tenant ;
  6. NAD non créables par les tenants, référencement limité à une liste autorisée par tenant ;
  7. StorageClasses `*-dr` réservées aux tenants T2+ ;
  8. **anti-affinité AZ** : pour les workloads multi-réplicas, imposer/avertir `topologySpreadConstraints` sur `zone` (force la répartition AZ-1/AZ-2) ;
  9. génération auto des NetworkPolicies et du RoleBinding par namespace tenant.
- **EXG-504** : Analyse d'impact des webhooks (failurePolicy) : la perte de Capsule/Kyverno ne doit pas bloquer le cluster ; documenter.
- **EXG-505** : **Hiérarchie revendeur — modèle à 3 niveaux (DÉCISION ACTÉE : Option A — Capsule + console ; vCluster écarté).** Modèle : `Plateforme → Revendeur → Client final → Projet`. Le **revendeur** est un **regroupement logique** (Organization Keycloak + entité de gouvernance gérée par la console), **pas un objet cluster** ; il n'a **aucun accès direct à l'API cluster** et agit **exclusivement via la console → commit Git → ArgoCD** (déclenche le `tenant-onboarding` EXG-502), cohérent EXG-013 et le principe d'identité du Lot 4. Chaque **client final reste un Tenant Capsule** (isolation native EXG-501) ; chaque **projet** est un namespace self-service du client dans son tenant.
- **EXG-506** : **Délégation d'administration & isolation inter-revendeurs.** Rôle `reseller-admin` (groupe/Organization Keycloak) : **onboarder, suspendre et offboarder ses propres clients finaux en self-service**, et **ne voir/gérer QUE ses clients** (RBAC console filtré par appartenance — aucun revendeur ne voit les clients d'un autre). Les owners des clients finaux conservent leur self-service de namespaces (EXG-501) dans leur tenant. L'offboarding d'un client par le revendeur suit la procédure de réversibilité EXG-906. Audit OIDC systématique de toute action revendeur (Lot 4).
- **EXG-507** : **Quota en cascade & rattachement facturation.** Chaque revendeur dispose d'un **pool de ressources contractuel** ; la **somme des quotas alloués à ses clients ne peut dépasser ce pool** — contrôle à l'onboarding et à toute modification (logique **console + admission** ; Kyverno seul n'agrège pas l'inter-tenant). Un label `<prefix>/reseller=<id>` est apposé sur le Tenant (extension d'EXG-502) pour rattacher chaque client à son revendeur ; ce label est la base de l'**agrégation de facturation à deux niveaux** (plateforme↔revendeur, revendeur↔client) en **phase 2** (cohérent §2.3, metering anticipé). La **suspension d'un revendeur** gèle les nouveaux onboarding (option : cordon de ses tenants) **sans perte de données**.

### Lot 6 — KubeVirt + Medik8s

- **EXG-601** : KubeVirt operator + CDI via GitOps. Feature gates requis documentés (live migration, snapshot, hotplug).
- **EXG-602** : Standards VM imposés par Kyverno : `runStrategy: Always`, `evictionStrategy: LiveMigrate`, disques sur `ceph-rbd-block-rwx`, qemu-guest-agent dans les images de base. Catalogue d'images (Rocky, Ubuntu, Debian, Windows Server) en DataVolumes sources clonables.
- **EXG-603** : Live migration calibrée (parallélisme, bande passante), **migration garantie entre AZ** ; test de drain complet d'un hyperviseur sans interruption VM.
- **EXG-604** : Remédiation panne nœud : Medik8s **NodeHealthCheck + Fence Agents Remediation** (fencing iDRAC/Redfish), VM redémarrée ailleurs (autre AZ si besoin) en < 3 min après panne franche. SNR en fallback. Timeouts documentés et testés (Lot 12).
- **EXG-605** : Snapshots cohérents `VirtualMachineSnapshot` (freeze/thaw via guest agent), intégrés à Velero (Lot 8).
- **EXG-606** : Anti-affinité applicative `kubecenter.dz/anti-affinity-group` (VMs d'un même groupe sur des hyperviseurs/AZ distincts).
- **EXG-607** : MAC explicites pour les VMs T2 (candidates PRA) : mutation Kyverno figeant la MAC au 1er déploiement **ou** KubeMacPool (comparer/justifier).

### Lot 7 — GitOps : ArgoCD

- **EXG-701** : Un ArgoCD **par région** (Alger, Constantine), en HA, pointant sur le même Git. Pas d'ArgoCD unique inter-région (SPOF du PRA).
- **EXG-702** : Structure de repos imposée (le préfixe d'organisation Git est un paramètre, Annexe A) :

```
<git-interne>/platform/
├── platform-core/          # appliqué sur les 2 clusters
│   ├── versions.yaml
│   ├── bootstrap/           # app-of-apps racine (une par cluster)
│   ├── infra/               # cilium, multus, ceph-csi, lb-ipam, dns/external-dns
│   ├── governance/          # capsule, kyverno + policies, PSA
│   ├── identity/            # config OIDC, RBAC plateforme
│   ├── virtualization/      # kubevirt, cdi, medik8s, vm-catalog
│   ├── backup/              # velero, schedules, BSL
│   ├── observability/       # LGTM, alertes
│   └── dr/                  # CronJob export PVC↔RBD, scripts PRA versionnés
├── tenants/
│   └── <tenant>/            # Tenant Capsule, AppProject, quotas (chart EXG-502)
└── workloads/
    └── <tenant>/<app>/      # manifests applicatifs des tenants
```

- **EXG-703** : Sync waves obligatoires : (1) governance → (2) infra/storage → (3) virtualization/backup → (4) tenants → (5) workloads. Reconstruction complète d'un cluster vierge depuis le bootstrap démontrée (test Lot 12).
- **EXG-704** : ApplicationSets par tier : T3 (stateless) → actif sur les deux clusters ; T1/T2 (stateful, VMs) → actif Alger, **présent mais sync désactivé/paused à Constantine**, activable par le runbook PRA en une commande.
- **EXG-705** : AppProjects par tenant : restriction repos sources, destinations (namespaces du tenant), kinds autorisés (pas de cluster-scoped).
- **EXG-706** : Bootstrap : d'un cluster Kubespray nu à la plateforme complète en ≤ 10 commandes manuelles, le reste en app-of-apps.

### Lot 8 — Sauvegarde : Velero + RadosGW multisite

- **EXG-801** : RadosGW multisite (Lot 3, EXG-307) : buckets de backup d'Alger lisibles à Constantine.
- **EXG-802** : Velero sur chaque cluster : plugin CSI (snapshots), plugin **kubevirt-velero-plugin**, BSL principal = RadosGW local, BSL secondaire en lecture = zone répliquée distante.
- **EXG-803** : Schedules pilotés par label de tier : T1 quotidien (rétention 30 j), T2 quotidien + avant toute opération PRA (rétention 14 j), plateforme quotidien. Sélection par label `capsule.clastix.io/tenant` (restauration granulaire par tenant).
- **EXG-804** : Backups VM cohérents (freeze via guest agent, EXG-605), exclusion des objets éphémères (VMI, virt-launcher).
- **EXG-805** : **Test de restauration automatisé hebdomadaire** : restauration d'un namespace témoin sur Constantine depuis le BSL répliqué, vérification d'intégrité, rapport vers l'observabilité. Un backup non testé est réputé inexistant.

### Lot 9 — PRA : runbooks failover / failback

Deux runbooks markdown pas-à-pas + scripts d'orchestration **semi-automatiques** (chaque étape destructive exige confirmation explicite ; pas de failover entièrement automatique — décision humaine, anti split-brain).

- **EXG-901** : Runbook **failover Alger → Constantine** :
  1. constat et décision (critères de déclenchement, qui décide, main courante) ;
  2. isolation d'Alger si partiellement vivant (couper sync ArgoCD Alger, geler les écritures si possible) ;
  3. promotion Keycloak Constantine (EXG-404) ;
  4. promotion des images RBD (`rbd mirror image promote`, `--force` si Alger perdu), par pool, scripté, vérif image par image ;
  5. recréation statique PV/PVC depuis l'export EXG-306 ;
  6. activation des ApplicationSets T1/T2 à Constantine (EXG-704) ;
  7. démarrage ordonné (dépendances/BDD/VMs de données d'abord, puis applicatif) via annotation `kubecenter.dz/start-order` ;
  8. bascule DNS GSLB (TTL préalablement ≤ 60 s) ;
  9. vérifications de service par tenant et communication.
- **EXG-902** : Runbook **failback Constantine → Alger** : resynchronisation inverse (`rbd mirror image resync`), fenêtre planifiée, demote/promote propre, retour des sync ArgoCD, vérification de non-divergence Git/cluster.
- **EXG-903** : Runbook **restauration granulaire tenant** (suppression accidentelle) : restore Velero ciblé, sans PRA global.
- **EXG-904** : Chaque runbook : prérequis, durée estimée par étape, commandes exactes copiables, critères go/no-go, rollback d'étape, annexe « mode dégradé ».
- **EXG-905** : Scripts PRA versionnés dans `platform-core/dr/`, testés en CI (lint + dry-run), exécutables depuis un bastion/poste admin **hors des deux régions**.
- **EXG-906** : Runbook **réversibilité / offboarding tenant** : export complet des données du tenant (manifests Git, contenus PV, disques VMs, objets S3, images) dans un format réutilisable, puis **suppression certifiée** (effacement des images RBD et snapshots, des backups Velero, purge des logs nominatifs selon rétention) avec procès-verbal de suppression — exigence classique des marchés publics et de l'ANPDP.

### Lot 10 — PCA : multi-AZ + actif-actif optionnel

- **EXG-1001** : **PCA de base = intra-Alger multi-AZ** : pour T0, la perte d'une AZ est absorbée par l'étalement des réplicas (pods et données Ceph synchrones) — aucune bascule de site, aucune action humaine. C'est l'engagement par défaut.
- **EXG-1002** : Exigences applicatives "multi-AZ-ready" documentées (réplicas ≥ 2 répartis par zone, PDB, probes correctes), imposées par policy (EXG-503.8).
- **EXG-1003** : **Actif-actif inter-régions optionnel (T3)** : applications stateless déployées aussi à Constantine (EXG-704), GSLB DNS (EXG-207) avec health checks ; bascule automatique **autorisée pour T3 uniquement**. Guide "T3-ready" (stateless strict, sessions externalisées, idempotence) à destination des tenants.

### Lot 11 — Briques transverses (à déployer, et résilientes)

- **EXG-1101** : **Dépôt Git interne** (GitLab CE recommandé ; Gitea en alternative légère — comparer/justifier) déployé en HA sur Alger, **répliqué/sauvegardé vers Constantine** (RTO ≤ 1 h). Sans Git, pas de reconstruction ArgoCD.
- **EXG-1102** : **Registre d'images** (Harbor) déployé sur chaque région, **réplication des projets Alger → Constantine** ; chaque cluster tire depuis le registre de sa région.
- **EXG-1103** : **Observabilité LGTM** : multi-tenant via `X-Scope-OrgID` (un org par tenant + org plateforme), données stockées localement par région, Grafana capable d'interroger les deux ; l'observabilité de Constantine survit seule à la perte d'Alger.
- **EXG-1104** : **Alerting** : Alertmanager par région, routes d'astreinte (e-mail + webhook). Alertes minimales : lag mirroring RBD, échec schedule/restore Velero, **perte d'une AZ**, perte d'un mon/témoin, certificats < 15 j, nœud NotReady > 2 min, désync ArgoCD > 30 min, santé Keycloak/Git/registre.

### Lot 12 — Tests, validation, critères d'acceptation

| ID | Test | Critère d'acceptation |
|---|---|---|
| T-01 | Kill d'un pod T3 | Reprise < 30 s, 0 perte de requêtes |
| T-02 | Drain d'un nœud portant des VMs | Live migration, 0 interruption perceptible |
| T-03 | Panne franche d'un nœud à VMs | Fencing + redémarrage < 3 min |
| T-04 | **Perte d'une AZ complète d'Alger** | Service maintenu (T0), quorum etcd + Ceph préservés via témoin, RPO 0 |
| T-05 | Perte d'un nœud control plane | API disponible en continu |
| T-06 | Tenant : accès cross-namespace / image hors registre / hostPath / NAD non autorisée | 100 % bloqué |
| T-07 | Restore Velero d'un namespace tenant sur Constantine | Données + VMs restaurées, app fonctionnelle |
| T-08 | Reconstruction cluster vierge via bootstrap GitOps | Plateforme complète sans intervention hors EXG-706 |
| T-09 | **Test PRA complet** : perte région Alger | RTO mesuré ≤ cibles §4, RPO ≤ 15 min (témoin horodaté), rapport chronométré |
| T-10 | Failback vers Alger | Sans perte de données post-failover |
| T-11 | Indisponibilité Keycloak | Break-glass fonctionnel, promotion ≤ 30 min |
| T-12 | Déploiement d'une image non signée / CVE critique | Bloqué à l'admission (Kyverno/Trivy) |
| T-13 | Tentative de suppression d'un backup (droits admin) | Refusée (Object Lock), backup restaurable |
| T-14 | Console : tentative d'action cross-tenant | 100 % bloqué, action tracée dans l'audit |
| T-15 | Bascule d'un lien serveur et d'un switch leaf | Aucune interruption (MC-LAG/ESI), 0 boucle |
| T-16 | Isolation MIG : 2 tenants sur le même GPU physique | Aucune interférence perf/mémoire, quotas GPU respectés |
| T-17 | File GPU saturée + arrivée d'un job prioritaire | Préemption Kueue du batch, reprise auto du job préempté |
| T-18 | LLMaaS : dépassement du quota de tokens d'une clé tenant | Requêtes refusées (429), usage exact comptabilisé par tenant |
| T-19 | Pipeline LLM : nouvelle révision avec éval sous les seuils | Canary stoppé, rollback auto vers N-1, alerte émise, prod intacte |
| T-20 | AppStore : installation PostgreSQL (CR CNPG) par un tenant, tentative de CR non autorisée par un autre | Install via Git/ArgoCD OK, sauvegarde native vers S3 vérifiée ; CR hors liste blanche bloquée |
| T-21 | Console : restauration self-service par un tenant + tentative de suppression d'un backup en vue admin | Restauration OK et tracée ; suppression impossible (Object Lock préservé) |
| T-22 | Console : pilotage du runbook PRA (T-09) depuis l'instance de Constantine, Alger isolé | Orchestration étape par étape avec go/no-go, main courante générée ; chemin bastion vérifié en parallèle |

- **EXG-1201** : T-04 et T-09 incluent un jeu de données témoin (écritures horodatées continues) prouvant le RPO réel.
- **EXG-1202** : Rapport de test type fourni (réutilisable pour les tests trimestriels contractuels).

### Lot 13 — Sécurité plateforme

- **EXG-1501** : **PKI interne** : CA racine hors-ligne, CA intermédiaires par usage (clusters, Ingress, infra), **cert-manager** sur les deux clusters pour émission/rotation automatiques. Aucune dépendance ACME externe (connectivité restreinte). Inventaire de tous les endpoints TLS livré.
- **EXG-1502** : **Chiffrement at-rest** : OSD Ceph chiffrés (dmcrypt/LUKS au déploiement), gestion des clés documentée ; chiffrement des secrets etcd (`EncryptionConfiguration`). Requis pour des données institutionnelles (loi 18-07).
- **EXG-1503** : **Chiffrement in-transit** : TLS sur tous les services ; messenger Ceph en mode `secure` sur les liens inter-régions ; le flux **RBD mirroring + RGW multisite Alger↔Constantine est chiffré** (mode secure Ceph et/ou tunnel IPsec/WireGuard si le lien n'est pas privé de bout en bout).
- **EXG-1504** : **Supply chain** : scan Trivy intégré au registre (blocage des CVE critiques, seuils paramétrables), signature des images en CI (cosign), vérification des signatures à l'admission (Kyverno `verifyImages`) — complète la policy "registre interne uniquement" (EXG-503.1).
- **EXG-1505** : **Audit** : audit policy des API servers (niveau Metadata minimum, RequestResponse sur les verbes sensibles), centralisation vers Loki (org plateforme), rétention paramétrable (Annexe A), horodatage NTP fiable. C'est la traçabilité opposable en cas d'incident chez un tenant.
- **EXG-1506** : **Accès administratif** : bastion dédié (celui d'EXG-905), **MFA obligatoire** sur Keycloak pour les groupes admins, réseaux management et BMC/iDRAC strictement isolés des workloads (VRF dédiées, Lot 14) — les BMC qui font le fencing ne sont jamais joignables depuis un tenant.
- **EXG-1507** : **Immutabilité des backups** : S3 **Object Lock** (mode compliance) sur les buckets Velero, rétention alignée sur les schedules — protection ransomware/erreur admin. Testé en Lot 12 (T-13).
- **EXG-1508** : **Durcissement** : passes kube-bench (CIS) sur les deux clusters avec écarts justifiés, SSH par clés uniquement, politique de mises à jour de sécurité OS documentée.

### Lot 14 — Underlay réseau & prérequis datacenter (DÉCISION ACTÉE : spine/leaf SONiC)

- **EXG-1601** : Fabric **spine/leaf sous SONiC** : underlay routé **eBGP** (BGP unnumbered, ECMP), overlay **EVPN-VXLAN** pour les segments L2 nécessaires (VLAN tenants attachés aux VMs via Multus, réseau de migration). Multihoming des serveurs (2× 25 GbE) en **MC-LAG ou EVPN-ESI multihoming** — comparer/justifier, avec procédure de validation **anti-boucle** et test de bascule de lien avant mise en production.
- **EXG-1602** : Topologie minimale : par AZ d'Alger 2 leafs ToR (+ 2 spines, ou modèle collapsed spine/leaf à justifier vu la taille initiale) ; Constantine 2 switches ; uplinks leaf↔spine 100G ; **liens inter-AZ dédiés ≥ 2× 100G** (chemin d'écriture Ceph synchrone) ; le témoin est raccordé aux deux AZ.
- **EXG-1603** : **Ségrégation** par VRF/VLAN : management, **OOB/BMC sur switches 1G dédiés** (réseau totalement séparé), stockage/réplication Ceph, workloads, migration live. **Matrice des flux** complète livrée (source/destination/port/justification).
- **EXG-1604** : **Cilium BGP control plane** : peering BGP des nœuds vers les ToR pour l'annonce des pools LB-IPAM (ECMP), cohérent avec EXG-205.
- **EXG-1605** : **NTP interne** : ≥ 2 serveurs de temps par région (source fiable, GPS si possible), tous équipements synchronisés (serveurs, switches, BMC), alerte sur dérive d'horloge — critique pour Ceph stretch (clock skew des moniteurs).
- **EXG-1606** : Livrables réseau : design détaillé du fabric (plan ASN, adressage point-à-point, plan VNI/VLAN), **templates de configuration SONiC** (`config_db.json` + procédures CLI) par rôle (spine, leaf, mgmt), procédures de validation et de test de bascule.
- **EXG-1607** : **Environnement de maquette** obligatoire : mini-plateforme reproduisant les chemins critiques (3-4 nœuds + fabric réduit, ou variante virtualisée sonic-vs + clusters imbriqués). Toute montée de version (Kubernetes, Ceph, SONiC) transite par la maquette ; elle sert aussi aux répétitions PRA. À chiffrer en option du BOM.

### Lot 15 — Console self-service multi-tenant (développement sur mesure par Claude Code)

- **EXG-1701** : Application web développée sur mesure par Claude Code. **SSO Keycloak (OIDC)**, mêmes groupes que le RBAC cluster. Principe de sécurité central : la console agit **avec l'identité de l'utilisateur** (passthrough du token OIDC ou impersonation auditée vers les API Kubernetes/Capsule) — jamais de service account omnipotent exécutant les actions des tenants.
- **EXG-1702** : Fonctionnalités MVP : tableau de bord du tenant (namespaces, quotas, consommation vs quota), création de namespace en self-service (via Capsule), catalogue et cycle de vie des **VMs KubeVirt** (création depuis le catalogue d'images, start/stop, console VNC/série via l'API KubeVirt), état des sauvegardes + demande de restauration granulaire (EXG-903), inventaire Ingress/DNS du tenant, lien Grafana scopé (org du tenant), gestion des membres (délégation des groupes Keycloak du tenant).
- **EXG-1703** : Stack technique proposée et justifiée par Claude Code (ex. frontend React/Vue + API backend Go/Python). Exigences : application **stateless** (état = les API Kubernetes ; sessions portées par OIDC), 2 réplicas multi-AZ, packagée en chart, déployée par ArgoCD, classée **T3** (active aussi à Constantine).
- **EXG-1704** : Sécurité console : toute action tracée (qui/quoi/quand, corrélée à l'audit API server), rate limiting, aucune élévation possible au-delà des droits RBAC de l'utilisateur, tests d'isolation inter-tenant dédiés (T-14).
- **EXG-1705** : Phasage du développement : MVP lecture/observation d'abord, actions (création namespace/VM, restauration) ensuite, le tout après stabilisation des Lots 4/5/6 dont la console n'est qu'un client.
- **EXG-1706** : **Modules d'extension de la console (architecture extensible obligatoire)** : la console est conçue dès le MVP pour accueillir des modules additionnels sans refonte — sont d'ores et déjà spécifiés : le **volet ML** (EXG-2006, Lot 17), le **module AppStore** (EXG-2104/2105, Lot 18), les modules d'exploitation **Backup/Restore, PRA et PCA** (EXG-1707 à 1710 ci-dessous), et le **module Revendeur/Partenaire** (EXG-1711, hiérarchie revendeur EXG-505/507). Chaque module respecte les mêmes principes : identité OIDC de l'utilisateur, actions via Git/ArgoCD ou orchestrateurs audités uniquement, audit systématique.
- **EXG-1707** : **Vue opérateur plateforme** : la console comporte deux espaces strictement séparés — la **vue tenant** (self-service) et la **vue opérateur plateforme**, réservée aux groupes admins Keycloak avec **MFA obligatoire** (EXG-1506), audit renforcé de chaque action, et pleinement fonctionnelle depuis l'instance de Constantine (la console est T3 : elle doit servir précisément quand Alger est perdu).
- **EXG-1708** : **Module Backup/Restore** : côté tenant — déclenchement d'une sauvegarde Velero à la demande (dans son quota), historique et état de ses sauvegardes, **restauration granulaire en self-service** (namespace/application, avec confirmation explicite — automatisation du runbook EXG-903) ; côté plateforme — gestion des schedules par tier, suivi des tests de restauration hebdomadaires (EXG-805). **Garde-fou absolu : aucune suppression ni réduction de rétention de backup n'est possible via la console**, quelle que soit la vue — l'immutabilité Object Lock (EXG-1507) ne souffre aucun contournement applicatif.
- **EXG-1709** : **Module PRA (vue opérateur uniquement)** : (a) **tableau de bord DR-readiness permanent** — lag du mirroring RBD, fraîcheur de l'export PVC↔RBD (EXG-306), état des réplications Keycloak/Git/registre, date et résultat du dernier test PRA ; (b) **configuration** — tier par tenant, ordre de démarrage (`kubecenter.dz/start-order`), TTL DNS ; (c) **déclenchement orchestré du failover/failback** : la console pilote l'orchestrateur des runbooks EXG-901/902 **étape par étape**, chaque étape destructive exigeant une confirmation go/no-go distincte, avec **main courante générée automatiquement** (qui, quoi, quand, résultat). **Règle absolue : la console est une interface de l'orchestrateur, jamais le seul chemin d'exécution** — le bastion hors régions (EXG-905) reste le chemin autoritaire, testé à chaque exercice PRA, pour le cas où la console elle-même serait indisponible.
- **EXG-1710** : **Module PCA (configuration et conformité — pas de "déclenchement")** : le PCA étant automatique par architecture (multi-AZ, GSLB), le module couvre : activation/désactivation du mode T3 actif-actif par application (génère le commit ApplicationSet correspondant), **rapport de conformité multi-AZ en continu** par tenant (réplicas ≥ 2, `topologySpreadConstraints`, PDB — sur la base des policies EXG-503.8), état des health checks GSLB et de la répartition du trafic entre régions, et alertes de non-conformité (une application T3 devenue mono-AZ est signalée avant que la panne ne le révèle).
- **EXG-1711** : **Module Revendeur/Partenaire (hiérarchie revendeur Option A, EXG-505/507)** : espace dédié au rôle `reseller-admin`, strictement scopé à ses propres clients (EXG-506). Fonctions : **onboarder un client final** (formulaire → commit Git `tenant-onboarding` EXG-502, **plafonné par le pool du revendeur** EXG-507), **tableau de bord agrégé** (consommation par client et cumul vs pool), gestion des membres des clients (groupes Keycloak), **suspension/offboarding** d'un client (réversibilité EXG-906). Mêmes principes que les autres modules : identité OIDC du revendeur (jamais de SA omnipotent), **actions via Git/ArgoCD uniquement** (aucun accès API cluster direct, EXG-505), audit systématique. Espace **distinct** de la vue opérateur plateforme (EXG-1707) et de la vue tenant (le client final, lui, garde sa vue self-service standard).

### Lot 16 — Ressources GPU / Workloads IA (DÉCISION ACTÉE : NVIDIA RTX PRO 6000 Blackwell Server Edition, 2 GPU par nœud dédié)

- **EXG-1901** : **Profil de nœud GPU unifié (DÉCISION ACTÉE)** : nœuds dédiés, non hyperconvergés (aucun OSD), **châssis certifié constructeur pour 8× RTX PRO 6000 Blackwell Server Edition** (96 Go GDDR7, MIG 4 instances, PCIe Gen5, 600 W passif), **peuplé de 4 GPU au départ**. Spec nœud : 64 cœurs / 1 Tio RAM (slots DIMM libres pour extension 2 Tio) / 2× 7,68 To NVMe scratch local / 2× 100 GbE RoCE-capable (EXG-1909). Déploiement : **1 nœud par AZ à Alger + 1 nœud à Constantine** (3 nœuds, 12 GPU initiaux). **L'enveloppe électrique et thermique du rack est provisionnée dès le jour 0 pour la pleine capacité 8 GPU (~6 kW/nœud)**, pas pour la configuration initiale (~3,6 kW) — Lot 14.
- **EXG-1902** : **NVIDIA GPU Operator** déployé via GitOps (`platform-core/infra/gpu/`) : driver précompilé épinglé, container toolkit, device plugin, **MIG Manager**, DCGM exporter, NFD/GFD. Versions dans `versions.yaml`, compatibilité driver/CUDA/KubeVirt vérifiée (EXG-1303).
- **EXG-1903** : **Partage GPU** — stratégie par défaut : **MIG** (4 instances isolées de 24 Go par GPU = l'UC-GPU, Annexe B.5) avec QoS garantie par tenant ; **time-slicing** autorisé uniquement sur des pools dev explicitement étiquetés ; **GPU complet** à la demande (profil MIG désactivé par GPU via MIG Manager) pour les workloads exigeant les 96 Go.
- **EXG-1904** : **VMs KubeVirt avec GPU** : passthrough PCI (vfio) d'un GPU complet ou d'une instance MIG ; le **vGPU NVIDIA (sous licence)** est optionnel — comparer/justifier si retenu (paramètre Annexe A). Contrainte assumée : **pas de live migration avec GPU attaché** → ces VMs reçoivent `evictionStrategy: None` (exception Kyverno dédiée à la policy EXG-602) et subissent une interruption planifiée lors des maintenances — à refléter dans le contrat de service.
- **EXG-1905** : **Isolation et scheduling** : taint `nvidia.com/gpu=true:NoSchedule` sur les nœuds GPU + tolerations contrôlées par policy, `runtimeClass: nvidia`, quotas Capsule sur `nvidia.com/gpu` et les ressources MIG (`nvidia.com/mig-*`), réservés aux tenants ayant souscrit l'option GPU (label dédié).
- **EXG-1906** : **PCA GPU** : briques réparties 1 nœud/AZ, mais **sans headroom ×2** (doubler le parc GPU pour absorber une perte d'AZ n'est pas retenu économiquement) → en perte d'AZ, la capacité GPU tombe à 50 % : **mode best-effort assumé et contractualisé**, avec priorisation (préemption des pools dev/time-slicing d'abord, tenants prioritaires ensuite).
- **EXG-1907** : **PRA GPU (DÉCISION ACTÉE)** : un nœud GPU à Constantine (4 GPU = 16 UC-GPU = 50 % de la capacité d'Alger) rend les workloads IA **éligibles au tier T2**, avec capacité réduite contractualisée et **politique de préemption au failover** (les workloads IA T2 d'Alger prennent la place des workloads préemptibles de Constantine). En nominal, ce nœud **ne reste pas inactif** : il sert des workloads préemptibles (dev, batch, file d'attente basse priorité), évacués automatiquement au déclenchement du PRA. Les données IA (datasets, modèles) suivent le régime standard : classe `*-dr` ou Velero.
- **EXG-1908** : **Observabilité GPU** : métriques DCGM (utilisation, mémoire, température, erreurs ECC, par instance MIG) vers Mimir, **ventilées par tenant** (socle du metering GPU en phase 2) ; alertes thermiques et ECC.
- **EXG-1909** : **Préparation RDMA (assurance phase 2, non activé en phase 1)** : les NICs des nœuds GPU sont obligatoirement **RoCE-capable** (classe ConnectX-6/7 ou équivalent) ; des ports 100G restent disponibles sur les leafs GPU. Le RDMA n'est **pas requis** par le design actuel (MIG + jobs intra-nœud ; pas de trafic GPU inter-nœuds ; GPUDirect Storage inapplicable sur RBD/CephFS), mais son activation ultérieure ne doit exiger que de la configuration (RoCEv2 lossless : PFC, ECN/DCQCN, file dédiée sur SONiC) et non un changement de matériel.
- **EXG-1910** : **Extension in-chassis 4 → 8 GPU (LLM larges, option à la demande)** : la montée en capacité IA se fait d'abord **en ajoutant des cartes dans les châssis existants** (jusqu'à 8 GPU/nœud = **768 Go de VRAM agrégée**, tensor/pipeline parallelism intra-nœud PCIe Gen5 P2P — modèles classe 400B FP8 / 600B+ quantifiés **sans RDMA** ; dès la config initiale, 4 GPU = 384 Go couvrent un 405B quantifié ou un 120B FP8). **Règle de dimensionnement actée** : la config initiale 4 GPU supporte le full-MIG (16 tranches = 960 Gio RAM ≤ 1 Tio, 192 vCPU ≤ 232 utiles) ; **les 4 GPU d'extension sont destinés aux workloads full-GPU (LLM)** — un usage full-MIG à 8 GPU exigerait l'extension RAM à 2 Tio (slots prévus, EXG-1901). Continuité d'un LLM mono-nœud : tier T1 (rechargement depuis Ceph/scratch) ou réplication sur le nœud de l'autre AZ à la charge du client.
- **EXG-1911** : **Inférence multi-nœuds (phase 2, sur étude)** : uniquement si un modèle dépasse la capacité d'un nœud dense. Conditions préalables : ≥ 2 nœuds denses **co-localisés dans la même AZ**, activation RoCEv2 lossless (EXG-1909) + GPUDirect RDMA, validation de performance préalable (l'absence de NVLink sur cette carte limite le scaling inter-nœuds — acceptable en inférence pipeline, déconseillé en entraînement distribué). Jamais proposé contractuellement sans test de qualification.
- **EXG-1912** : **Kueue (PHASE 1, obligatoire)** : déployé dès la phase 1 comme ordonnanceur de files GPU — `ClusterQueues` par classe de service (garantie / batch-préemptible), `LocalQueues` par tenant, priorités et préemption. C'est le **mécanisme d'exécution des politiques déjà actées** : EXG-1906 (perte d'AZ → préemption des workloads batch/dev en premier) et EXG-1907 (le nœud GPU de Constantine sert du préemptible en nominal, évacué au déclenchement du PRA). Les quotas Kueue sont alignés sur les quotas GPU Capsule (cohérence vérifiée par test).

### Lot 17 — Plateforme ML & Inference-as-a-Service (PHASE 2 — option commerciale au-dessus du GPUaaS)

Objectif : vendre la même ressource GPU sous trois formes à valeur croissante — notebooks, entraînement managé, endpoints d'inférence — en plus du GPUaaS brut. Lot activable après stabilisation des Lots 5/15/16.

- **EXG-2001** : **KServe est acté** comme couche de serving (EXG-2004). La décision restante en ouverture du lot porte sur l'**enrobage** : Kubeflow complet **vs** composants à la carte (Kueue + Training Operator + KServe + notebooks) — comparer/justifier en évaluant : Istio embarqué (redondant avec Cilium), modèle multi-tenant Profiles à réconcilier avec Capsule (1 Profile ↔ 1 Tenant, conventions de nommage, OIDC commun), et charge d'exploitation récurrente. Le choix "à la carte" est l'hypothèse par défaut.
- **EXG-2002** : **Notebooks-as-a-Service** : JupyterLab self-service par tenant, images de catalogue durcies (registre interne, scannées EXG-1504), attachement d'UC-GPU (MIG) à la demande, **culling d'inactivité** (arrêt automatique — un notebook oublié ne monopolise pas une tranche GPU), home sur stockage du tenant (CephFS/RBD).
- **EXG-2003** : **Training-as-a-Service** : Training Operator (jobs PyTorch/TF distribués intra-nœud), soumission exclusivement **via Kueue** (classes garantie/préemptible), datasets et artefacts sur le S3 interne du tenant (RGW), logs et métriques vers l'org LGTM du tenant.
- **EXG-2004** : **Inference-as-a-Service (DÉCISION ACTÉE : KServe + runtime vLLM)** : vLLM comme moteur d'inférence (continuous batching, tensor parallelism intra-nœud sur les châssis 4-8 GPU, API OpenAI-compatible native), orchestré par KServe (cycle de vie, scale-to-zero, canary, multi-modèles). Deux modes : **modèles mutualisés** (un LLM ouvert servi une fois, consommé par plusieurs tenants — le mode le plus rentable par UC-GPU) et **modèles privés** (poids du tenant, scale-to-zero pour ne pas immobiliser le GPU). Les endpoints ne sont **jamais exposés directement** aux clients : tout passe par la passerelle EXG-2009.
- **EXG-2005** : **Intégration plateforme** : SSO Keycloak de bout en bout, tenants ML = tenants Capsule, quotas Kueue/Capsule cohérents, policies Kyverno pleinement applicables aux pods notebooks/jobs/serving (mêmes règles images, sécurité, réseau que tout workload tenant — aucun régime d'exception).
- **EXG-2006** : **Extension de la console (Lot 15)** : volet ML — lancer un notebook, soumettre un job et suivre sa position dans la file Kueue, déployer/consommer un endpoint, visualiser sa consommation GPU.
- **EXG-2007** : **Metering ML** : consommation par notebook/job/endpoint, construite sur les métriques DCGM par tenant (EXG-1908) et les métriques KServe (requêtes/tokens) — alimente directement la facturation (phase 2, §2.3).
- **EXG-2008** : **PCA/PRA des services ML** : composants de la plateforme ML classés **T3** (stateless, déployés sur les deux régions) ; les états (modèles, datasets) sur S3/classes `*-dr` ; les endpoints d'inférence critiques éligibles **T2-GPU** via le nœud de Constantine (EXG-1907).
- **EXG-2009** : **Passerelle API LLM multi-tenant — LLMaaS (DÉCISION ACTÉE : LiteLLM Proxy + Keycloak)** : façade unique de l'offre LLMaaS, placée devant tous les endpoints KServe/vLLM. Exigences : **clés API virtuelles** par tenant/application, dont l'émission et la révocation sont liées à l'identité Keycloak du tenant et exposées en self-service dans la console (EXG-2006) ; **budgets et quotas de tokens** par clé et par tenant (dépassement → refus 429, jamais de facturation surprise) ; **rate limiting** par souscription ; **routage multi-modèles** (le client cible un alias de modèle, la passerelle route vers l'endpoint mutualisé ou privé) ; **API strictement OpenAI-compatible** (le client utilise les SDK standards sans savoir ce qui tourne derrière) ; **comptage d'usage par clé/tenant/modèle** (tokens in/out) alimentant directement le metering EXG-2007 et la facturation ; déploiement **HA, classé T3** (les deux régions), persistance de la configuration et de l'usage sur PostgreSQL HA ; journalisation des appels conforme à la politique d'audit (EXG-1505) **sans rétention du contenu des prompts par défaut** (paramètre de confidentialité par tenant — argument de souveraineté commercial).
- **EXG-2010** : **Pipeline de mise à jour automatique des LLM open source (Kubeflow Pipelines)** : un **template de pipeline unique et paramétré**, instancié pour chaque modèle du catalogue (paramètres : source/repo, révision, profil GPU cible, seuils d'évaluation, politique de promotion). Étapes obligatoires :
  1. **Veille** : run récurrent (schedule paramétrable) interrogeant la source amont (API Hugging Face) pour détecter une nouvelle révision ;
  2. **Ingestion contrôlée** : téléchargement via la **zone d'egress dédiée** (seul composant autorisé à sortir, EXG-003), vérification des checksums, **format safetensors exclusivement** (tout artefact pickle est rejeté), enregistrement de la licence du modèle (traçabilité juridique par version) ;
  3. **Registre de modèles** : stockage versionné sur le S3 interne (RGW, bucket répliqué vers Constantine pour les modèles servis en T2-GPU), métadonnées (révision, licence, empreintes, résultats d'éval), **rétention N-1 minimum** pour rollback + garbage collection des versions anciennes (les poids pèsent 100-800 Go : la capacité du registre est planifiée et supervisée) ;
  4. **Validation technique** : chargement effectif sous la version de vLLM en production (matrice de compatibilité), smoke test de génération ;
  5. **Évaluation qualité** : benchmarks automatisés + jeu d'évaluation interne, comparaison aux scores de la version en production, **seuils de blocage** ;
  6. **Déploiement canary** : nouvelle version déployée par KServe en canary, bascule progressive du trafic via l'alias LiteLLM (EXG-2009) ;
  7. **Promotion ou rollback** : promotion automatique si les seuils sont atteints **et** que le modèle est configuré en promotion auto, sinon **gate d'approbation humaine** (défaut pour les modèles mutualisés facturés) ; rollback automatique vers N-1 sur échec ou régression constatée en canary ; notification (Alertmanager) à chaque transition.
- **EXG-2011** : Le pipeline et ses instances sont **déclarés dans Git** (définitions KFP versionnées, déployées par ArgoCD) ; l'historique des runs constitue la traçabilité de provenance de chaque modèle servi (quelle révision, quelle source, quels scores, qui a approuvé) — opposable aux clients et à l'audit (EXG-1505). Note : Kubeflow Pipelines peut être déployé en standalone — à intégrer à la décision EXG-2001.

### Lot 18 — AppStore multi-tenant (catalogue d'applications en self-service)

Objectif : offrir aux tenants un catalogue des applications les plus demandées, installables en self-service. Principe d'architecture acté : **Helm comme format de packaging et d'expérience catalogue, operators Kubernetes comme moteurs de cycle de vie du stateful, ArgoCD comme unique canal d'exécution** — l'appstore est une interface au-dessus du GitOps, jamais un canal de déploiement parallèle.

- **EXG-2101** : **Catalogue curé interne** : chaque entrée du catalogue est un chart Helm hébergé sur le dépôt interne, issu des sources officielles upstream et passé par le **pipeline de curation** : relocalisation des images vers le registre interne (EXG-003), scan et signature (EXG-1504), versions épinglées, test de déploiement sur la maquette (EXG-1607), classification DR (label de tier EXG-020) et stratégie de sauvegarde documentée par application. **Interdiction de dépendre des catalogues Bitnami** (basculés en modèle payant, images versionnées gelées sans correctifs) **ou de Kubeapps** (projet archivé) — la chaîne de curation est entièrement interne.
- **EXG-2102** : **Deux classes d'applications** : (a) **stateless/web** = chart Helm pur (CMS, wikis, outils collaboratifs…) ; (b) **stateful** = le chart du catalogue est un *wrapper* qui instancie la **Custom Resource d'un operator** curé par la plateforme. Operators de référence à déployer et maintenir côté plateforme (liste initiale, paramètre Annexe A) : **CloudNativePG** (PostgreSQL), operator MySQL/MariaDB, operator Redis/Valkey, **Strimzi** (Kafka), operator RabbitMQ — chacun évalué sur sa maturité (niveau de capacité, sauvegardes natives, upgrades automatisés) avant admission au catalogue.
- **EXG-2103** : **Multi-tenancy des operators** : les CRDs étant cluster-scoped, les operators sont **installés exclusivement par la plateforme** (namespaces `platform-`, déployés par ArgoCD, versions dans `versions.yaml`). Les tenants ne consomment que des **CR namespace-scoped** dans leurs namespaces ; une **liste blanche Kyverno** définit quelles CR chaque tenant peut instancier (selon ses souscriptions). Les ressources créées par les operators comptent dans les quotas Capsule du tenant. L'upgrade d'un operator (partagé entre tous les tenants) suit la procédure : maquette → fenêtre annoncée → rollout, avec analyse d'impact sur les CR existantes.
- **EXG-2104** : **Flux d'installation 100 % GitOps** : console (module appstore, extension du Lot 15) → formulaire généré depuis `values.schema.json` du chart → **commit Git dans le repo workloads du tenant** → synchronisation ArgoCD → statut, santé et URL d'accès remontés dans la console. **Aucun `helm install` direct** : l'appstore respecte strictement EXG-013. Désinstallation et mise à jour suivent le même canal (commit de suppression / bump de version proposé par la console).
- **EXG-2105** : **Cycle de vie côté tenant** : la console affiche les mises à jour disponibles par application installée (nouvelle version du chart au catalogue), avec changelog ; l'application de la mise à jour reste une action du tenant (commit généré), sauf correctifs de sécurité critiques que la plateforme peut imposer avec préavis (politique paramétrable). Chaque application du catalogue documente sa procédure de restauration (Velero ou sauvegarde native de l'operator vers le S3 du tenant).
- **EXG-2106** : **Périmètre PCA/PRA par application** : chaque entrée du catalogue déclare son comportement : stateless → éligible T3 (actif-actif) ; stateful → T1 ou T2 selon la StorageClass choisie à l'installation (le formulaire propose le choix si le tenant y a droit) ; les applications opérées par operator documentent leur procédure de reprise spécifique au failover (ex. : promotion d'un réplica CNPG vs restauration). Intégré aux runbooks du Lot 9.
- **EXG-2107** : **Gouvernance du catalogue** : processus d'admission d'une nouvelle application (demande, évaluation sécurité/maintenance/licence, curation, publication), revue trimestrielle des versions, et retrait ordonné (application dépréciée = gel des nouvelles installations + plan de migration communiqué aux tenants installés).

---

### Lot 19 — Exploitation Day-2 automatisée & agents IA (AIOps) (comparer/justifier l'outillage)

Objectif : faire porter l'**exploitation Day-2** (diagnostic, remédiation, mises à jour, capacité, sécurité courante) par une **automatisation entièrement pilotée par GitOps**, dont la main-d'œuvre de *jugement* est constituée d'**agents IA** développés par Claude Code. Ce lot répond au principal risque d'un cloud souverain opéré par une petite équipe : la charge Day-2. **Séquencement : ce lot démarre une fois les Lots de services (0–18) implémentés et stabilisés** ; il s'appuie sur eux (GitOps Lot 7, observabilité Lot 11, policies Lot 5, runbooks Lot 9, console Lot 15) et ne les remplace pas.

- **EXG-2201** : **Principe directeur — concevoir en supposant l'agent faillible.** L'incident maquette du 2026-06-11 (un agent a cassé le quorum etcd des deux clusters via un `Service externalIPs` sur l'IP primaire d'un nœud, appliqué *en direct* hors pipeline) fixe le cahier des charges des garde-fous. Conséquence non négociable : **les « mains » d'un agent sont des commits/PR Git, jamais une mutation directe du cluster** (`kubectl apply`/`helm install` direct interdits, cohérent EXG-013). GitOps/ArgoCD est le substrat *parce qu'*il rend toute action déclarative, **revusable, réversible (`git revert`), auditable et testable avant impact**.
- **EXG-2202** : **Modèle à deux étages.** (a) **Automatisation déterministe** (cible ≈ 85 % du Day-2) : self-healing K8s, autoscaling, rotation des certificats (cert-manager), schedules Velero, réconciliation des versions (ArgoCD), fencing nœud (Medik8s, Lot 6), bumps de versions (ex. Renovate) — **à privilégier systématiquement**. (b) **Couche agentique** réservée au *jugement* : triage et corrélation d'alertes, analyse de cause racine, tri des CVE (Trivy, Lot 13), prévision de capacité, rédaction de runbook/postmortem. **Interdiction d'utiliser un agent LLM là où un opérateur/CronJob déterministe suffit.**
- **EXG-2203** : **Pipeline de garde-fous obligatoire (chaîne unique d'exécution).** Toute action mutante d'un agent traverse, dans l'ordre : **PR Git** → **CI dure** (`kubeconform`, `kyverno test`, `shellcheck` + policies de sûreté, dont une **règle anti-`externalIPs == IP de nœud`** qui aurait stoppé l'incident) → **admission Kyverno en Enforce** (Lot 5) → **déploiement progressif / canari** (un cluster ou une AZ d'abord) → **vérification de santé post-apply automatique** → **rollback automatique sur échec**. Aucune action agent en dehors de cette chaîne.
- **EXG-2204** : **Catégorie « jamais autonome » — gate humain/policy go/no-go.** Sont exclues de toute exécution autonome : **bascule PRA** (déjà semi-auto, Lot 9), suppression de données, toute opération **irréversible**, et tout ce qui touche **etcd/quorum ou la réplication de stockage**. Conforme au principe « chaque étape destructrice exige un go/no-go explicite » du Lot 9/10. Pour les SLA contractuels, **l'humain reste responsable de l'irréversible**.
- **EXG-2205** : **Sens et contrat d'outils de l'agent.** Entrées (lecture) : LGTM (Lot 11), events Kubernetes, statut ArgoCD, alertes. **Outils en lecture seule par défaut** ; toute écriture passe par l'ouverture d'une PR signée et tracée. **Identité dédiée** de l'agent : compte de service à **privilèges minimaux**, jamais un SA omnipotent (cohérent avec le principe d'identité du Lot 4 — l'agent agit avec ses propres droits bornés, pas en super-utilisateur).
- **EXG-2206** : **Runbooks-as-code — l'agent n'improvise pas l'exécution.** Les remédiations invoquent des **runbooks idempotents `--dry-run`** à codes de sortie exploitables (EXG-031, Lot 9), pas des commandes ad hoc. Le périmètre d'actions **auto-approuvées** s'élargit **progressivement, en fonction d'un track-record mesuré**, en partant du plus sûr.
- **EXG-2207** : **Phasage interne du lot.** **A — Ops-as-code** (faible risque, gros gain) : tout changement plateforme = changement Git, CI dure, **rollback auto** sur échec de santé ; **B — Agent diagnostic en lecture seule** : triage/corrélation/RCA, propose une PR ou un runbook pour validation humaine ; **C — Agent de remédiation *gated*** : exécute des runbooks **pré-approuvés** via pipeline (vérif + rollback), périmètre élargi selon EXG-2206. **Jamais l'irréversible** (EXG-2204).
- **EXG-2208** : **Observabilité et redevabilité de l'agent lui-même.** Chaque décision agent est tracée (entrée, raisonnement, action proposée, résultat) ; métriques de fiabilité publiées (taux de PR acceptées, MTTR, faux positifs) ; **kill-switch** désactivant immédiatement la couche agentique et repassant en mode humain. L'agent est traité comme un composant à superviser, pas comme une autorité.
- **EXG-2209** : **Extension de la console (Lot 15) — module « Exploitation / AIOps »** (cohérent EXG-1706) : visualiser les PR proposées par les agents, **approuver/rejeter (go/no-go)**, suivre la file d'actions et leur vérification, déclencher le kill-switch, consulter le track-record. Toutes les actions humaines y sont auditées (identité OIDC, Lot 4).
- **EXG-2210** : **comparer/justifier (en fin de lot)** : le **framework d'agents** (ex. Claude Agent SDK vs autre), le moteur d'analyse de cause racine, et la **frontière exacte auto-approuvé vs gated**. **Cadrage commercial à retenir** : positionner l'offre comme **« Day-2 codifié en GitOps, opéré par des agents sous garde-fous déterministes, avec gate humain sur l'irréversible »** — *pas* « exploitation 100 % autonome » (plus sûr, plus crédible, et différenciant).

---

## 6. Livrables attendus de Claude Code

1. **Repo `platform-core`** complet (structure EXG-702) : manifests/charts/kustomize, app-of-apps, policies Kyverno avec tests, chart `tenant-onboarding`, `versions.yaml`.
2. **Inventaires et group_vars Kubespray** des deux clusters + procédures d'installation et d'upgrade.
3. **Procédures de déploiement Ceph** (stretch Alger + Constantine + mirroring + RadosGW multisite).
4. **Scripts** : config RBD mirroring + monitoring, export PVC↔RBD (EXG-306), génération PV statiques, orchestrateur PRA semi-auto, bascule DNS/GSLB, bootstrap.
5. **Runbooks** : failover, failback, restauration tenant, réversibilité/offboarding tenant (EXG-906), perte Keycloak, perte Git/registre, perte d'AZ, upgrade cluster.
6. **Documentation d'exploitation** : architecture détaillée, onboarding tenant, guide "multi-AZ-ready" et "T3-ready", matrice des flux réseau (EXG-1603), procédure de mirroring images/charts (EXG-003), dossier sécurité (PKI, chiffrement, audit, durcissement — Lot 13).
7. **Design et configurations réseau** : design fabric SONiC, plans ASN/VNI/adressage, templates `config_db.json` par rôle, procédures de validation (Lot 14).
8. **Console self-service** : code source complet, chart de déploiement, documentation utilisateur et d'exploitation (Lot 15).
9. **Plan de tests** scripté (Lot 12) + modèles de rapports.
10. **Exploitation Day-2 automatisée (Lot 19, après stabilisation des Lots 0–18)** : pipeline de garde-fous (PR → CI → admission → canari → vérif/rollback), policies de sûreté (dont anti-`externalIPs`-sur-IP-de-nœud), runbooks-as-code, agents IA (diagnostic puis remédiation *gated*) avec leur contrat d'outils, kill-switch et module console AIOps.
11. **Matrice de traçabilité** EXG-xxx ↔ livrable ↔ test.

## 7. Exigences de méthode pour Claude Code

- **EXG-1301** : Travailler par phases dans l'ordre des lots ; à la fin de chaque lot, récapituler les choix techniques avec justification (points "comparer/justifier" : EXG-204, 205, 206, 301, 402, 607, 1101, 1601 [MC-LAG vs EVPN-ESI], 1602 [spines dédiés vs collapsed], 1703 [stack console], 1904 [passthrough vs vGPU], 2001 [Kubeflow complet vs composants à la carte]).
- **EXG-1302** : Poser des questions **avant** d'implémenter si une donnée de l'Annexe A manque ou est ambiguë ; ne jamais inventer une valeur d'infrastructure.
- **EXG-1303** : Vérifier versions courantes et compatibilité mutuelle (matrices KubeVirt/K8s, Cilium/K8s, Capsule/K8s, Ceph/K8s) avant d'épingler `versions.yaml`.
- **EXG-1304** : Manifests validés `kubeconform` ; policies Kyverno avec `kyverno test` ; scripts bash `shellcheck`.
- **EXG-1305** : Commits atomiques par lot, messages conventionnels (`feat(lot3): ...`).
- **EXG-1306** : Aucune action sur cluster réel sans instruction explicite ; livrer d'abord, appliquer ensuite sur maquette.

## 8. Annexe A — Paramètres d'entrée à fournir (à compléter avant exécution)

| Paramètre | Exemple/format | Valeur |
|---|---|---|
| Préfixe de domaine des labels | `kubecenter.dz` | **`kubecenter.dz`** (acté — ex-`gridale.dz`) |
| Domaine racine plateforme | ex. `cloud.example.dz` | À COMPLÉTER |
| FQDN API clusters | `api.k8s-alger…` / Constantine | À COMPLÉTER |
| Wildcard apps par région | `*.apps-alger…` / Constantine | À COMPLÉTER |
| CIDR pods/services par cluster | `10.x.0.0/16` | À COMPLÉTER |
| Plan d'adressage par AZ + pools LB | plages par AZ et région | À COMPLÉTER |
| Latence inter-AZ mesurée (RTT) | **< 5 ms (validé)** | OK |
| Topologie serveurs par AZ et à Constantine | nb nœuds, rôles | **Alger** : 2 control plane (1/AZ) + 1 témoin + 6 workers HCI (3 briques) + 2 GPU (1/AZ) ; **Constantine** : 3 HCI + 1 GPU — **15 serveurs** (voir BOM) |
| Constructeur et modèles serveurs (BOM) | constructeur / modèles | **xFusion FusionServer** — 1288H V7 (control plane + témoin, 1U), 2288H V7 (HCI Alger/Constantine, 2U), G5500 V7 (nœuds GPU, 4U) |
| Pools RBD (synchrones / DR mirrorés) | noms à créer | À COMPLÉTER |
| Endpoints RadosGW Alger/Constantine | URL | À COMPLÉTER |
| Solution DNS retenue (PowerDNS/BIND9) | — | À COMPLÉTER |
| Solution LB L4 (Cilium LB-IPAM/MetalLB) | — | À COMPLÉTER |
| Méthode déploiement Ceph (cephadm/Rook) | — | À COMPLÉTER |
| Dépôt Git retenu (GitLab CE/Gitea) | — | À COMPLÉTER |
| Accès iDRAC/Redfish (plages, méthode) | — | À COMPLÉTER |
| VLANs disponibles pour NAD VMs | liste | À COMPLÉTER |
| GPU retenu | **RTX PRO 6000 Blackwell SE — châssis 8 GPU, 4 montés au départ** | OK (acté) |
| Parc GPU initial | **1 nœud/AZ Alger + 1 nœud Constantine (12 GPU)** | OK (acté) |
| vGPU NVIDIA sous licence (vs passthrough seul) | oui/non | À COMPLÉTER |
| Modèle de châssis GPU certifié 8× cartes passives 600 W | constructeur/modèle | **xFusion FusionServer G5500 V7** (4U, ≤ 10 GPU PCIe double-largeur, PCIe x32 CPU↔GPU) — certification 8× RTX PRO 6000 SE 600 W passif à qualifier |
| Catalogue initial de modèles LLM mutualisés (LLMaaS) | liste de modèles ouverts | À COMPLÉTER |
| Rétention du contenu des prompts (LLMaaS) | défaut : aucune | À COMPLÉTER |
| Fréquence de veille des modèles (pipeline EXG-2010) | ex. hebdomadaire | À COMPLÉTER |
| Politique de promotion par modèle (auto / gate humaine) | défaut : gate humaine | À COMPLÉTER |
| Versions de modèles conservées (rollback) | défaut : N-1 | À COMPLÉTER |
| Capacité allouée au registre de modèles (RGW) | To | À COMPLÉTER |
| Liste initiale des applications du catalogue AppStore | ex. PostgreSQL, Redis, Kafka, WordPress, Nextcloud… | À COMPLÉTER |
| Operators admis au catalogue (et politique d'upgrade) | défaut : CNPG, Strimzi, RabbitMQ, MySQL, Redis | À COMPLÉTER |
| Politique de mise à jour imposée (correctifs critiques) | préavis en jours | À COMPLÉTER |
| NICs nœuds GPU RoCE-capable | **obligatoire (acté)** | OK — **NVIDIA ConnectX-7 2× 100GbE** (proposé, BOM) |
| Activation RoCEv2/GPUDirect | non en phase 1, sur étude phase 2 | OK (acté) |
| Outil de secrets (ESO backend / Sealed Secrets) | — | À COMPLÉTER |
| Modèle/édition des switches SONiC (communautaire ou entreprise) | — | À COMPLÉTER |
| Plan ASN BGP (privés) | plage | À COMPLÉTER |
| Débit des liens inter-AZ et Alger↔Constantine | ≥ 2× 100G / à mesurer | À COMPLÉTER |
| Sources de temps NTP (GPS/amont) | — | À COMPLÉTER |
| Rétention des audit logs | ex. 12 mois | À COMPLÉTER |
| Seuil CVE bloquantes (Trivy) | ex. CRITICAL | À COMPLÉTER |
| Lien Alger↔Constantine privé de bout en bout ? (sinon tunnel) | oui/non | À COMPLÉTER |

---

## 9. Annexe B — Dimensionnement matériel (modèle linéaire, paramètres figés)

### B.1 Unité de charge et ratios (DÉCISIONS ACTÉES)

- **EXG-1401** : L'unité de dimensionnement est l'**UC (Unité de Charge)** = **2 vCPU / 8 Gio RAM / 100 Gio stockage alloué** (profil workload modéré). Ratios de mutualisation : **CPU 4:1**, **RAM 1:1 (aucun overcommit RAM — impératif avec KubeVirt)**, stockage dimensionné sur l'alloué.
- **EXG-1402** : Cible initiale : **100 UC client**, plus ~10 UC d'overhead plateforme à Alger et ~8 UC à Constantine. **30 % de la charge client est répliquée sur Constantine** (tier T2) = 30 UC.

### B.2 Équation linéaire de consommation

Compte tenu du headroom AZ (×2 : chaque AZ tourne à ≤ 50 % pour absorber l'autre) et du Ceph stretch (×4 copies), chaque UC consomme en matériel brut à Alger :

> **1 UC = 1 cœur physique + 16 Gio RAM + 400 Gio NVMe brut** (réparti sur les 2 AZ)

À Constantine (pas de headroom AZ, Ceph 3 copies) : **1 UC répliquée = 0,5 cœur + 8 Gio + 300 Gio brut**. Toute extension de capacité suit strictement ces coefficients — c'est l'exigence de **linéarité**.

### B.3 Nœud équilibré et brique d'extension

- **EXG-1403** : Nœud worker HCI standard (identique partout, y compris Constantine — standardisation, pièces communes) : **32 cœurs physiques / 512 Gio RAM / 2× 7,68 To NVMe OSD + 2× 480 Go NVMe OS (RAID1) / 2× 25 GbE / BMC Redfish**. Ce ratio (16 Gio et ~480 Gio brut par cœur) garantit que CPU, RAM et stockage se remplissent au même rythme ; le CPU est le compteur de capacité (~26 UC nominal/nœud), la RAM garde toujours une marge.
- **EXG-1404** : **Brique d'extension = 2 nœuds workers (1 par AZ) ≈ 50 UC vendables.** Toute montée en capacité se fait par briques, jamais par nœud isolé (équilibre inter-AZ obligatoire).

### B.4 BOM initial (100 UC / 30 % Constantine)

| Site | Rôle | Qté | Spec |
|---|---|---|---|
| Alger | Control plane (1/AZ) | 2 | 12c / 64 Gio / 2× 480 Go NVMe / 2× 25 GbE |
| Alger | Témoin (etcd + mon arbitre) | 1 | 4c / 16 Gio / 240 Go SSD / 2× 10 GbE |
| Alger | Worker HCI (3 briques) | 6 | nœud standard EXG-1403 |
| Constantine | Nœud HCI (control+worker+OSD) | 3 | nœud standard EXG-1403 |
| **Total** | | **12** | |

Capacités résultantes : Alger = 156 UC totales installées (100 client + 10 plateforme + ~46 UC de marge ≈ 46 % de croissance avant la 4ᵉ brique) ; stockage utilisable Alger ≈ 23 To (92 To bruts ÷ 4) ; Constantine = 3 nœuds (plancher HA Ceph), couvrant les 30 UC répliquées + plateforme + capacité backups RadosGW.

- **EXG-1405** : Liens réseau : inter-AZ ≥ 2× 25 GbE dédiés (chemin d'écriture Ceph synchrone, < 5 ms validé) ; Alger↔Constantine dimensionné sur le **débit de changement** des pools `-dr` pour tenir le RPO 15 min (mesure à instrumenter, Lot 3) ; témoin ≥ 10 GbE vers chaque AZ (< 10 ms validé).
- **EXG-1406** : Le BOM détaillé et paramétrable (UC, ratios, % Constantine modifiables avec recalcul automatique) est fourni dans le fichier `BOM-PCA-PRA.xlsx` joint au présent cahier des charges.

### B.5 Extension GPU — workloads IA (DÉCISION ACTÉE)

- **EXG-1407** : Unité GPU : **1 UC-GPU = 1 instance MIG de 24 Go** (¼ de RTX PRO 6000 Blackwell SE) **+ 12 vCPU + 56 Gio RAM**. Le nœud GPU (EXG-1901) en config initiale 4 GPU = 4 × 4 MIG = **16 UC-GPU**, qui tombent exactement dans la spec 64c/1 Tio (16 × 56 + 64 de réserve = 960 Gio ; 192 vCPU ≤ 232 utiles).
- **EXG-1408** : **Parc GPU initial (acté)** : 1 nœud/AZ à Alger + 1 nœud à Constantine = **3 nœuds, 12 GPU, 48 UC-GPU installées** (32 à Alger, 16 à Constantine), portant le total plateforme à **15 serveurs**. Croissance : d'abord extension in-chassis 4→8 GPU (EXG-1910), ensuite ajout de nœuds (toujours par paire 1/AZ à Alger).
- **EXG-1409** : Puissance : **~3,6 kW par nœud GPU en config initiale, ~6 kW à pleine capacité 8 GPU** — l'enveloppe électrique/thermique par rack est provisionnée pour 6 kW dès le jour 0 (Lot 14), châssis au flux d'air certifié pour 8 cartes passives 600 W.

---

*Fin du cahier des charges. Toute exigence EXG-xxx non couverte par un livrable doit être signalée explicitement avec justification.*
