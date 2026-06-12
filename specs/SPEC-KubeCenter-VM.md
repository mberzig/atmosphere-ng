# KubeCenter VM — Spécifications techniques du module VMaaS

**Version :** 1.0 — Juin 2026
**Statut :** Spécification d'ingénierie (destinée au développement assisté, type Claude Code)
**Référence amont :** CDC-PCA-PRA-K8S (Lot KubeVirt / VMaaS) — le présent document détaille ce lot.
**Modèle fonctionnel de référence :** Google Compute Engine (utilisé comme grille de complétude ; aucune dépendance à GCP — toute l'implémentation repose sur des composants open source souverains).

---

## 0. Préambule

### 0.1 Objet

KubeCenter VM est le module *Infrastructure-as-a-Service* (machines virtuelles à la demande) de la plateforme KubeCenter. Il fournit aux locataires (tenants) la capacité de créer, exploiter et superviser des machines virtuelles Linux et Windows en libre-service, avec un modèle de ressources, une API et une expérience comparables à ceux d'un hyperscaler — tout en garantissant la souveraineté des données (loi 18-07), la continuité contractuelle (tiers T0–T3) et la reprise inter-régions (PRA Alger → Constantine).

### 0.2 Principe directeur

Pour chaque capacité de Compute Engine jugée structurante, le présent document définit **l'équivalent KubeCenter** et **son implémentation sur le socle KubeVirt/Kubernetes/Ceph**. L'objectif n'est pas de copier GCP mais de garantir qu'aucune fonction attendue d'un IaaS professionnel n'est omise.

### 0.3 Socle technique retenu

| Couche | Composant |
|---|---|
| Hyperviseur / orchestration VM | KubeVirt (sur Kubernetes) — `VirtualMachine` / `VirtualMachineInstance` |
| Import & préparation d'images | Containerized Data Importer (CDI) — `DataVolume` |
| Stockage bloc | Ceph RBD via CSI (`csi-rbd`) ; classes de stockage par profil de performance |
| Stockage fichier partagé | CephFS via CSI (`csi-cephfs`) pour les volumes RWX |
| Réseau | Multus + OVN-Kubernetes (réseaux tenant), Cilium (politique L3/L4), MetalLB/OVN pour IP flottantes |
| Multi-tenancy | Capsule (Tenant/quota) + Kyverno (admission) + Keycloak (OIDC) |
| Haute disponibilité | Medik8s : Node Health Check (NHC) + Fence Agents Remediation (FAR, fencing iDRAC) |
| Sauvegarde / PRA | Velero + plugin KubeVirt + snapshots Ceph RBD + mirroring RBD vers Constantine |
| GitOps / cycle de vie | ArgoCD (réconciliation déclarative des objets de plateforme) |
| Observabilité | Pile LGTM (Loki, Grafana, Tempo, Mimir/Prometheus) |

### 0.4 Glossaire des correspondances (synthèse — détaillée en Annexe A)

| Concept GCP | Concept KubeCenter VM | Objet d'implémentation |
|---|---|---|
| Instance | Instance (VM) | `kubevirt.io/VirtualMachine` |
| Machine type | Gabarit | `instancetype.kubevirt.io` + politique de profil |
| Image | Image | `DataVolume` source / golden image dans le registre d'images |
| Persistent Disk | Disque persistant | PVC (Ceph RBD) attaché à la VM |
| Snapshot | Instantané | `VolumeSnapshot` (Ceph RBD snapshot) |
| Machine image | Modèle d'instance | `VirtualMachineSnapshot` + manifeste exporté |
| VPC / Subnet | Réseau tenant / sous-réseau | `NetworkAttachmentDefinition` (OVN) |
| Firewall rule | Règle de pare-feu | `CiliumNetworkPolicy` / groupe de sécurité KubeCenter |
| External IP | IP flottante | service `LoadBalancer` / annonce OVN |
| Zone | Zone de disponibilité (AZ) | topologie de nœuds (`topology.kubernetes.io/zone`) |
| Region | Région | cluster régional (Alger ; Constantine = PRA) |
| Project | Projet / tenant | `Namespace` régi par `Tenant` (Capsule) |
| Instance group (MIG) | Groupe d'instances géré | contrôleur KubeCenter + modèle de VM |
| Operation | Opération asynchrone | objet `Operation` exposé par l'API KubeCenter |

---

## 1. Modèle de ressources

**EXG-VM-1000** — L'API expose un modèle de ressources hiérarchique : `Organisation > Projet (tenant) > {Instances, Disques, Images, Instantanés, Réseaux, Sous-réseaux, Règles de pare-feu, Groupes d'instances, Modèles d'instance}`. Chaque ressource possède un identifiant stable, un nom lisible unique dans son projet, des libellés (`labels`) clé/valeur et des horodatages de création/modification.

**EXG-VM-1001** — Toute ressource est rattachée à un projet (namespace régi par Capsule). L'isolation inter-tenants est stricte : aucun objet d'un tenant n'est listable, lisible ou modifiable par un autre (RBAC + Kyverno + NetworkPolicy par défaut « deny »).

**EXG-VM-1002** — Chaque ressource porte obligatoirement le libellé `kubecenter.dz/dr-tier` (valeurs `T0`|`T1`|`T2`|`T3`) déterminant son régime de continuité/reprise (chapitre 11). Valeur par défaut au niveau projet, surchargée au niveau instance.

**EXG-VM-1003** — Les noms de ressources respectent une convention RFC 1123 (minuscules, tirets, ≤ 63 caractères), validée à l'admission.

---

## 2. Gabarits de machines (machine types)

### 2.1 Familles de gabarits

**EXG-VM-1100** — Le catalogue propose au minimum trois familles, alignées sur les familles GCP « usage général / mémoire élevée / calcul intensif » :

| Famille KubeCenter | Inspiration GCP | Ratio vCPU:RAM | Usage cible |
|---|---|---|---|
| `ku-std` (standard) | N2/E2 | 1:4 | applications générales, serveurs web/applicatifs |
| `ku-mem` (mémoire élevée) | M | 1:8 | bases de données, en mémoire |
| `ku-cpu` (calcul intensif) | C2 | 1:2 | calcul, traitement par lots |
| `ku-gpu` (accélérée) | A/G | variable | renvoi au module **KubeCenter GPU** (hors périmètre VM standard) |

**EXG-VM-1101** — Chaque famille décline des tailles prédéfinies (`*-2`, `*-4`, `*-8`, `*-16`, `*-32` vCPU) implémentées via des `VirtualMachineClusterInstancetype` KubeVirt. Le catalogue est versionné et publié au tenant.

### 2.2 Gabarits personnalisés

**EXG-VM-1102** — Le tenant peut définir un gabarit personnalisé (à la manière des *custom machine types*) en choisissant vCPU et RAM dans des bornes contrôlées : vCPU pair entre 2 et 64 ; RAM par incréments de 1 Gio ; ratio vCPU:RAM compris entre 1:1 et 1:8 (validation Kyverno, rejet motivé sinon).

**EXG-VM-1103** — Surengagement (*overcommit*) : CPU 4:1 (vCPU:cœur physique), RAM 1:1 (pas de surengagement mémoire). Ces ratios sont appliqués au scheduling et reflétés dans la facturation UC.

### 2.3 Alignement commercial (unité de charge)

**EXG-VM-1104** — La consommation est convertie en **UC** (1 UC = 2 vCPU + 8 Gio + 100 Gio de disque, conformément au modèle commercial). L'API expose pour chaque instance son équivalent UC instantané et cumulé, exploité par la facturation à l'usage.

---

## 3. Cycle de vie de l'instance

**EXG-VM-1200** — Les états exposés (modelés sur le *VM instance lifecycle* GCP) et leur correspondance KubeVirt :

| État KubeCenter | Équivalent GCP | État KubeVirt (VM/VMI) |
|---|---|---|
| `PROVISIONING` | PROVISIONING | VM `Starting`, VMI `Scheduling` |
| `STAGING` | STAGING | VMI `Scheduled`/`Pending` |
| `RUNNING` | RUNNING | VMI `Running` |
| `STOPPING` | STOPPING | VM `Stopping` |
| `STOPPED` | TERMINATED (arrêtée) | VM `Stopped` (RunStrategy `Halted`) |
| `SUSPENDED` | SUSPENDED | VMI `Paused` (état mémoire conservé) |
| `DELETING` / `DELETED` | (suppression) | suppression de la VM et des ressources liées |

**EXG-VM-1201** — Opérations supportées : `create`, `start`, `stop` (arrêt gracieux avec délai puis ACPI/forçage), `restart`, `suspend`/`resume`, `reset` (à froid), `delete`. Chaque opération est **asynchrone** et renvoie un objet `Operation` interrogeable (chapitre 14).

**EXG-VM-1202** — **Protection contre la suppression** (équiv. *deletion protection*) : un drapeau `deletionProtection` empêche `delete` tant qu'il n'est pas levé. Implémentation par finaliseur Kubernetes + admission Kyverno.

**EXG-VM-1203** — **Politique de redémarrage automatique** (`automaticRestart`) : redémarrage de l'instance après défaillance hôte, selon le tier. **Maintenance hôte** (`onHostMaintenance`) : `MIGRATE` (migration à chaud) par défaut, `TERMINATE` pour les instances non migrables (ex. attachement GPU/PCI).

**EXG-VM-1204** — **Migration à chaud** (*live migration*) : déclenchée automatiquement lors de la maintenance planifiée d'un nœud (cordon/drain) pour les instances éligibles, sans interruption de service perceptible. Stratégie d'éviction `LiveMigrate` (sauf instances à passthrough matériel : `evictionStrategy: None` + `TERMINATE`).

**EXG-VM-1205** — Toute transition d'état est journalisée (audit) et notifiée via événement consultable par le tenant.

---

## 4. Images et catalogue

**EXG-VM-1300** — **Images publiques** : catalogue maintenu par la plateforme, durci et tenu à jour (au minimum : Ubuntu LTS, Debian, Rocky Linux/AlmaLinux, openSUSE/SLES, Windows Server). Chaque image publie une **famille d'images** (`image family`) pointant toujours vers la dernière version ; les versions antérieures restent référençables (N-1, N-2).

**EXG-VM-1301** — **Images personnalisées** : un tenant crée une image à partir d'un disque existant ou d'une instance (capture). Les images sont privées au projet, versionnées, avec famille d'images optionnelle.

**EXG-VM-1302** — **Import d'images** (équiv. *migration path / image import*) : ingestion de fichiers `qcow2`, `raw` ou `vmdk` via CDI (`DataVolume` source HTTP/registry/upload). Contrôle d'intégrité (checksum) et antivirus à l'ingestion. Conversion automatique au format interne.

**EXG-VM-1303** — **Initialisation** : prise en charge de `cloud-init` (Linux) et `sysprep`/`cloudbase-init` (Windows) pour personnalisation au premier démarrage (hostname, utilisateurs, clés, paquets, scripts).

**EXG-VM-1304** — **Signature et provenance** : les images publiques sont signées ; la signature est vérifiée à l'admission (Kyverno `verifyImages` / cosign). Les images non signées ou altérées sont refusées.

**EXG-VM-1305** — **Durcissement** : les images publiques appliquent un profil de durcissement documenté (CIS-like) ; un rapport de conformité est associé à chaque image.

---

## 5. Stockage bloc (disques)

### 5.1 Disque de démarrage et disques additionnels

**EXG-VM-1400** — Chaque instance possède un **disque de démarrage** (créé depuis une image) et peut recevoir des **disques additionnels** (data disks) attachés/détachés à chaud (hotplug KubeVirt). Chaque disque est un PVC sur Ceph RBD.

### 5.2 Classes de stockage (types de disque)

**EXG-VM-1401** — Trois classes, alignées sur la logique GCP « standard / balanced / SSD performance » :

| Classe KubeCenter | Inspiration GCP | Profil | Implémentation Ceph |
|---|---|---|---|
| `ku-disk-std` | pd-standard | capacitif | pool HDD/économique, réplication 3 |
| `ku-disk-bal` | pd-balanced | équilibré (défaut) | pool SSD/NVMe, réplication 3 |
| `ku-disk-perf` | pd-ssd / Hyperdisk | haute perf. | pool NVMe dédié, paramètres IOPS/débit élevés |

**EXG-VM-1402** — Plages d'IOPS et de débit documentées par classe et par taille ; le QoS RBD applique des plafonds par disque pour garantir l'isolation entre tenants (anti *noisy neighbor*).

### 5.3 Opérations sur disque

**EXG-VM-1403** — **Redimensionnement à chaud** (augmentation uniquement) sans interruption (expansion CSI + croissance du système de fichiers invité via guest agent).

**EXG-VM-1404** — **Multi-attachement** en lecture seule supporté ; lecture/écriture partagée réservée aux volumes CephFS (RWX) explicitement provisionnés (jamais RBD en RWX bloc).

**EXG-VM-1405** — **Disque éphémère local** (équiv. *Local SSD*) optionnel pour scratch hautes performances, non répliqué, dont la perte au redéploiement est documentée et signalée au tenant.

**EXG-VM-1406** — **Chiffrement au repos** systématique : OSD Ceph sur LUKS, clés gérées par le KMS interne (cf. chapitre 12). Option de clé fournie par le client (équiv. CMEK) en phase ultérieure.

---

## 6. Instantanés et protection des données

**EXG-VM-1500** — **Instantanés de disque** (équiv. *snapshots*) : `VolumeSnapshot` (snapshot RBD), incrémentaux, restaurables vers un nouveau disque ou une nouvelle instance.

**EXG-VM-1501** — **Instantanés programmés** (équiv. *snapshot schedules*) : politiques par projet/disque (fréquence, fenêtre, rétention, génération N). Implémentation par planificateur de plateforme + opérateur de snapshot.

**EXG-VM-1502** — **Cohérence applicative** : avant instantané, gel des E/S et vidage des tampons via `qemu-guest-agent` (fs-freeze) ; hooks applicatifs optionnels (ex. base de données). Mode *crash-consistent* à défaut, clairement étiqueté.

**EXG-VM-1503** — **Instantané d'instance complète** (équiv. *machine image*) : `VirtualMachineSnapshot` capturant la définition de la VM et tous ses disques, exportable comme modèle réutilisable.

**EXG-VM-1504** — **Sauvegarde** (équiv. *Backup and DR*) : Velero + plugin KubeVirt sauvegarde l'objet VM, ses PVC et ses métadonnées vers le stockage objet (RGW), avec **immutabilité (Object Lock)** anti-rançongiciel et rétention configurable.

**EXG-VM-1505** — **Restauration** : restauration granulaire (un disque), au niveau instance, ou vers la région PRA. Les procédures et RPO/RTO atteignables dépendent du tier (chapitre 11).

---

## 7. Réseau

**EXG-VM-1600** — **Réseaux tenant et sous-réseaux** (équiv. *VPC/subnets*) : un tenant dispose d'un ou plusieurs réseaux isolés (overlay OVN via Multus), segmentés en sous-réseaux avec plages CIDR propres. Isolation L2/L3 stricte entre tenants.

**EXG-VM-1601** — **Adressage** : IP interne stable par interface ; **IP flottante** (équiv. *external IP*) optionnelle, réservable, ré-attribuable entre instances. IPAM géré par la plateforme.

**EXG-VM-1602** — **Pare-feu / groupes de sécurité** (équiv. *firewall rules*) : règles d'entrée/sortie par étiquettes et par CIDR, priorités, journalisation optionnelle. Implémentation `CiliumNetworkPolicy` ; posture par défaut « deny » entrant, « allow » sortant contrôlé.

**EXG-VM-1603** — **Accès sortant Internet** via passerelle NAT mutualisée par tenant (équiv. *Cloud NAT*) ; aucune exposition entrante sans IP flottante + règle explicite.

**EXG-VM-1604** — **Équilibrage de charge** (équiv. *Cloud Load Balancing*) : exposition de services L4 (TCP/UDP) devant un groupe d'instances ; option L7 (HTTP/S) via le contrôleur d'ingress mutualisé en phase ultérieure.

**EXG-VM-1605** — **DNS interne** (équiv. *Cloud DNS* interne) : résolution automatique des noms d'instances dans le réseau tenant (PowerDNS/BIND9 interne) ; zones privées par projet.

**EXG-VM-1606** — **Interfaces multiples** : une instance peut porter plusieurs interfaces (plusieurs réseaux/sous-réseaux), à la manière des *multiple network interfaces*.

**EXG-VM-1607** — **MTU et performance** : MTU configurable par réseau ; chemins réseau alignés sur le fabric spine/leaf SONiC du Lot underlay.

---

## 8. Métadonnées, accès et agent invité

**EXG-VM-1700** — **Serveur de métadonnées** (équiv. *metadata server*) : chaque instance accède à un point d'accès interne fournissant identité, réseau, clés publiques, scripts de démarrage/arrêt et métadonnées personnalisées (clé/valeur).

**EXG-VM-1701** — **Scripts de démarrage/arrêt** (`startup-script`/`shutdown-script`) exécutés via cloud-init / guest agent.

**EXG-VM-1702** — **Gestion des accès SSH** (équiv. *OS Login*) : intégration Keycloak (OIDC) — l'autorisation d'accès SSH et l'injection de clés sont régies par l'IAM de la plateforme, avec MFA et révocation centralisée. Accès console série/VNC sécurisé via la console KubeCenter.

**EXG-VM-1703** — **Agent invité** : `qemu-guest-agent` requis pour le gel cohérent, le redimensionnement de FS à chaud, l'arrêt gracieux et la remontée d'informations (IP, FS). Présent dans les images publiques.

**EXG-VM-1704** — **Gestion de parc / correctifs** (équiv. *VM Manager*) : inventaire des instances, état des correctifs OS, campagnes de patch planifiées et rapports de conformité.

---

## 9. Groupes d'instances et élasticité

**EXG-VM-1800** — **Modèle d'instance** (équiv. *instance template*) : définition réutilisable (gabarit, image, disques, réseau, métadonnées, tier) servant à instancier des VM identiques.

**EXG-VM-1801** — **Groupe d'instances géré** (équiv. *MIG*) : ensemble d'instances créées depuis un modèle, avec **taille cible**, **réparation automatique** (recréation des instances défaillantes via la santé applicative) et **distribution multi-AZ**.

**EXG-VM-1802** — **Mise à l'échelle automatique** (équiv. *autoscaler*) : phase 1 = mise à l'échelle **manuelle** et **programmée** (horaires) ; mise à l'échelle sur métriques (CPU/charge) en phase ultérieure. Bornes min/max obligatoires.

**EXG-VM-1803** — **Mises à jour progressives** du groupe (équiv. *rolling update*) : remplacement par vagues lors d'un changement de modèle (nouvelle image), avec surcapacité et/ou indisponibilité maximales paramétrables.

---

## 10. Placement, haute disponibilité et maintenance

**EXG-VM-1900** — **Zones de disponibilité** : la région primaire d'Alger expose **deux AZ** ; le tenant choisit l'AZ d'une instance ou laisse la plateforme équilibrer.

**EXG-VM-1901** — **Politiques de placement** (équiv. *placement policies*) : `spread` (anti-affinité — répartir les instances d'un groupe sur des hôtes/AZ distincts pour la résilience) et `stack` (compacité). Implémentation par contraintes d'affinité/anti-affinité et `topologySpreadConstraints`.

**EXG-VM-1902** — **Réparation et fencing** : Medik8s NHC détecte un nœud défaillant ; FAR isole le nœud (fencing iDRAC) avant relance des instances ailleurs, évitant tout *split-brain* / double exécution.

**EXG-VM-1903** — **Maintenance planifiée** : annoncée au tenant ; les instances éligibles sont migrées à chaud (`MIGRATE`), les autres arrêtées/relancées (`TERMINATE`) selon leur configuration.

**EXG-VM-1904** — **Disponibilité intra-AZ** : réplication synchrone Ceph (mode stretch) entre AZ-1 et AZ-2 d'Alger ; la perte d'une AZ complète est absorbée sans perte de données pour les charges T0.

---

## 11. Résilience contractuelle et PRA (intégration tiers)

**EXG-VM-2000** — Toute instance hérite d'un **tier de continuité** (`kubecenter.dz/dr-tier`) :

| Tier | Protection | RPO | RTO |
|---|---|---|---|
| T0 | multi-AZ synchrone (Alger) | 0 | automatique |
| T1 | sauvegarde quotidienne répliquée à Constantine | 24 h | 8 h |
| T2 | réplication continue vers Constantine + bascule orchestrée | 15 min | 4 h |
| T3 | actif-actif Alger/Constantine | ≈ 0 | < 15 min |

**EXG-VM-2001** — Pour T2/T3, les disques RBD des instances sont répliqués vers la région Constantine (mirroring RBD, mode snapshot, intervalle ≤ 15 min) ; la définition des VM est synchronisée par GitOps/Velero pour permettre une reconstruction à l'identique.

**EXG-VM-2002** — La bascule d'une instance (ou d'un projet) vers Constantine est exposée via le **cockpit PRA** (orchestration gouvernée, point de décision go/no-go, journal de preuve horodaté) — cf. module Console / Lot PRA.

**EXG-VM-2003** — Un indicateur de **préparation à la reprise** (DR-readiness) par instance/projet est calculé en continu (fraîcheur de réplication vs RPO contractuel) et exposé à l'API et à la console.

**EXG-VM-2004** — Les tests de bascule (exercices) sont déclenchables sans impact sur la production (clones isolés en région PRA) ; un rapport chronométré (RTO mesuré) est produit et communiqué au tenant.

---

## 12. Sécurité

**EXG-VM-2100** — **Isolation des tenants** : namespaces régis par Capsule, RBAC OIDC (Keycloak), NetworkPolicy par défaut « deny », quotas, et admission Kyverno (liste blanche des champs autorisés des manifestes VM).

**EXG-VM-2101** — **Démarrage sécurisé** (équiv. *Shielded VM*) : UEFI Secure Boot, vTPM et *measured boot* activables par instance (fonctions KubeVirt `bootloader.efi.secureBoot` et `tpm`).

**EXG-VM-2102** — **Chiffrement** : au repos (LUTS sur OSD Ceph, clés au KMS interne) et en transit (réseaux overlay chiffrés/segmentés). Clés gérées par PKI interne + cert-manager.

**EXG-VM-2103** — **Images de confiance** : seules les images signées et référencées au catalogue (ou importées et validées) peuvent démarrer une instance ; vérification de signature à l'admission.

**EXG-VM-2104** — **Journalisation d'audit** : toute opération (création, démarrage, accès console, snapshot, suppression, bascule) est journalisée avec acteur, horodatage et contexte, conservée de façon inviolable et consultable par le tenant pour ses propres ressources.

**EXG-VM-2105** — **Accès d'administration** : via bastion durci + MFA ; aucun accès direct des opérateurs aux données tenant sans traçabilité.

**EXG-VM-2106** — **Conformité loi 18-07 / ANPDP** : localisation garantie des données (instances et réplicas exclusivement à Alger et Constantine) ; aucune sortie de données hors du territoire.

---

## 13. Observabilité, quotas et facturation

**EXG-VM-2200** — **Métriques** par instance et par projet : CPU, mémoire, IOPS/débit disque, trafic réseau, disponibilité ; exposées via la console et l'API (source Prometheus/Mimir).

**EXG-VM-2201** — **Journaux** : journaux d'événements d'instance et journaux système (option agent) centralisés (Loki), filtrables par le tenant.

**EXG-VM-2202** — **Quotas et limites** (équiv. *Quotas and limits*) : par projet — nombre d'instances, total vCPU, total RAM, total stockage, IP flottantes, snapshots. Dépassement bloqué à l'admission avec message explicite ; relèvement par demande tracée.

**EXG-VM-2203** — **Alertes** configurables (seuils CPU, saturation disque, échec de réplication PRA, dérive RPO) avec notifications.

**EXG-VM-2204** — **Facturation à l'usage** : mesure de la consommation (UC, UC-GPU le cas échéant, stockage Go-mois, IP flottantes, trafic sortant, snapshots Go-mois) ; export vers le moteur de facturation (intégration Odoo) ; tarification modulée par tier.

---

## 14. API, CLI et automatisation

**EXG-VM-2300** — **API REST** (modelée sur le *resource model* de Compute Engine) : ressources `instances`, `instanceTemplates`, `instanceGroups`, `machineTypes`, `images`, `disks`, `snapshots`, `networks`, `subnetworks`, `firewalls`, `addresses`, `operations`. Verbes CRUD + actions (`start`, `stop`, `reset`, `suspend`, `resume`, `attachDisk`, `detachDisk`, `createSnapshot`, `failover`).

**EXG-VM-2301** — **Opérations asynchrones** : toute mutation longue renvoie un objet `Operation` (statut `PENDING`/`RUNNING`/`DONE`, erreur structurée, ressource cible) interrogeable et notifiable (webhook).

**EXG-VM-2302** — **Idempotence et concurrence** : requêtes de création idempotentes (clé de requête), contrôle de version optimiste (ETag/`resourceVersion`) sur les mutations.

**EXG-VM-2303** — **Pagination, filtrage, tri** sur toutes les collections ; quotas d'appel par tenant (limitation de débit, code 429).

**EXG-VM-2304** — **Authentification** : OIDC (Keycloak), jetons à portée projet, clés d'API à privilèges restreints, RBAC fin par ressource/action.

**EXG-VM-2305** — **CLI `kubecenter`** : couverture complète de l'API (création/gestion d'instances, disques, images, réseaux, snapshots, bascule), sortie JSON/tableau, scriptable.

**EXG-VM-2306** — **Infrastructure as Code** : fournisseur Terraform/OpenTofu (phase ultérieure) exposant les ressources VM ; en interne, les objets de plateforme sont réconciliés par ArgoCD (déclaratif/GitOps).

**EXG-VM-2307** — **Console self-service** : tous les parcours ci-dessus sont disponibles sans ligne de commande dans la console KubeCenter (création guidée d'instance, gestion du cycle de vie, disques, snapshots/restaurations, réseau, cockpit PRA), avec passthrough OIDC.

---

## 15. SLA, limites et réversibilité

**EXG-VM-2400** — **Engagements de disponibilité** publiés par tier (ex. T2/T3 mensuel) ; mesure et reporting de disponibilité par instance.

**EXG-VM-2401** — **Réversibilité** (anti-verrouillage) : un tenant peut **exporter** ses instances au format ouvert (`qcow2`/`raw`) et ses définitions (manifestes) à tout moment, pour migration hors plateforme. Procédure documentée et testée.

**EXG-VM-2402** — **Limites par défaut** documentées (taille max. de disque, nombre d'interfaces, d'instances par groupe, de snapshots par disque), relevables sur demande dans les limites du capacitaire.

---

## 16. Exigences — récapitulatif de traçabilité

Les exigences `EXG-VM-1000` à `EXG-VM-2402` ci-dessus constituent le référentiel traçable du module. Chaque exigence est :
- **vérifiable** par au moins un test d'acceptation (chapitre 17) ;
- **rattachée** à un composant du socle (§0.3) ;
- **priorisée** : `MUST` (phase 1) sauf mention « phase ultérieure » = `SHOULD`.

Sont en **phase ultérieure** (SHOULD) : autoscaling sur métriques (1802), L7 LB (1604), CMEK (1406), provider Terraform (2306).

---

## 17. Tests d'acceptation

| ID | Objet | Critère de réussite |
|---|---|---|
| T-VM-01 | Création d'instance | Une VM `ku-std-4` Ubuntu démarre, est joignable en SSH (clé Keycloak) en < 3 min |
| T-VM-02 | Cycle de vie | `stop`/`start`/`suspend`/`resume`/`reset` aboutissent aux états attendus ; `Operation` reflète chaque transition |
| T-VM-03 | Protection suppression | `delete` refusé tant que `deletionProtection` actif, accepté après levée |
| T-VM-04 | Gabarit personnalisé | Création 6 vCPU/24 Gio acceptée ; 2 vCPU/64 Gio (ratio > 1:8) refusée avec message |
| T-VM-05 | Image personnalisée | Capture d'une VM → image → nouvelle VM identique amorcée |
| T-VM-06 | Import qcow2 | Import d'un `qcow2` externe (checksum vérifié) → VM démarrable |
| T-VM-07 | Disque à chaud | Attachement et extension d'un disque sans redémarrage ; FS étendu dans l'invité |
| T-VM-08 | Classes de disque | IOPS mesurées conformes aux plages publiées par classe ; QoS isole deux tenants |
| T-VM-09 | Snapshot cohérent | Snapshot avec fs-freeze ; restauration → données cohérentes |
| T-VM-10 | Snapshots programmés | Politique horaire respectée ; rétention N appliquée |
| T-VM-11 | Sauvegarde Velero | Sauvegarde VM complète vers RGW (Object Lock) ; restauration intégrale |
| T-VM-12 | Réseau & pare-feu | Isolation inter-tenants vérifiée ; règle d'entrée appliquée ; NAT sortant fonctionnel |
| T-VM-13 | IP flottante | Réservation puis ré-attribution d'une IP flottante entre deux instances |
| T-VM-14 | Métadonnées/cloud-init | `startup-script` exécuté ; clé SSH injectée ; métadonnées lisibles depuis l'invité |
| T-VM-15 | Groupe géré + réparation | Suppression forcée d'une instance du groupe → recréée automatiquement ; distribution multi-AZ respectée |
| T-VM-16 | Migration à chaud | Drain d'un nœud → instance migrée à chaud sans coupure SSH perceptible |
| T-VM-17 | Fencing | Panne simulée d'un nœud → fencing iDRAC + relance ailleurs, sans double exécution |
| T-VM-18 | Multi-AZ T0 | Perte d'une AZ d'Alger → charges T0 maintenues, RPO 0 vérifié |
| T-VM-19 | Bascule T2 vers Constantine | Exercice de bascule → RTO mesuré ≤ 4 h, RPO ≤ 15 min ; rapport produit |
| T-VM-20 | Shielded VM | VM avec Secure Boot + vTPM démarre ; image non signée refusée |
| T-VM-21 | Quotas | Dépassement de quota vCPU bloqué à l'admission avec message explicite |
| T-VM-22 | Facturation | Consommation UC/stockage/IP d'une instance correctement mesurée et exportée |
| T-VM-23 | API asynchrone | Création via API renvoie `Operation` ; ETag empêche une mise à jour concurrente |
| T-VM-24 | Réversibilité | Export `qcow2` + manifeste d'une instance → réimport et démarrage hors plateforme |
| T-VM-25 | Audit & 18-07 | Toutes opérations journalisées (acteur/horodatage) ; aucune donnée localisée hors Alger/Constantine |

---

## Annexe A — Tableau de correspondance complet GCP ↔ KubeCenter ↔ implémentation

| Capacité Compute Engine | KubeCenter VM | Implémentation |
|---|---|---|
| Instance | Instance (VM) | `VirtualMachine`/`VirtualMachineInstance` (KubeVirt) |
| Machine families & types | Familles `ku-*` + gabarits | `VirtualMachineClusterInstancetype` + politique de profil |
| Custom machine types | Gabarit personnalisé | instancetype dynamique + validation Kyverno |
| VM instance lifecycle | États & opérations | RunStrategy KubeVirt + contrôleur d'opérations |
| Live migration / host maintenance | Migration à chaud / maintenance | `LiveMigrate` + cordon/drain + Medik8s |
| Images / image families | Images / familles | Registre d'images + `DataVolume` (CDI) |
| Image import / migration | Import d'images | CDI (HTTP/upload/registry), conversion qcow2/raw |
| Shielded VM | Démarrage sécurisé | UEFI Secure Boot + vTPM (KubeVirt) |
| Persistent Disk / Hyperdisk | Classes `ku-disk-*` | PVC Ceph RBD + StorageClass + QoS |
| Local SSD | Disque éphémère local | volume local non répliqué |
| Snapshots / schedules | Instantanés / programmés | `VolumeSnapshot` (RBD) + planificateur |
| Machine images | Modèle / instantané d'instance | `VirtualMachineSnapshot` + export |
| Backup and DR | Sauvegarde | Velero + plugin KubeVirt + RGW (Object Lock) |
| VPC / Subnets | Réseaux / sous-réseaux tenant | Multus + OVN (`NetworkAttachmentDefinition`) |
| Firewall rules | Groupes de sécurité | `CiliumNetworkPolicy` |
| External IP / Cloud NAT | IP flottante / NAT | OVN/MetalLB + passerelle NAT |
| Cloud Load Balancing | Équilibrage de charge | service `LoadBalancer` (L4), ingress (L7, ultérieur) |
| Cloud DNS (interne) | DNS interne | PowerDNS/BIND9, zones privées par projet |
| Metadata server / OS Login | Métadonnées / accès | endpoint métadonnées + cloud-init + Keycloak OIDC |
| VM Manager | Gestion de parc/correctifs | inventaire + campagnes de patch |
| Instance groups (MIG) / autoscaler | Groupes gérés / élasticité | modèle d'instance + contrôleur KubeCenter |
| Placement policies | Politiques de placement | affinité/anti-affinité + topologySpread |
| Zones / Regions | AZ / Régions | topologie de nœuds ; Alger (2 AZ) + Constantine (PRA) |
| Projects / IAM | Projets / IAM | Namespaces + Capsule + RBAC OIDC |
| Quotas and limits | Quotas | ResourceQuota + admission |
| Operations | Opérations asynchrones | objet `Operation` de l'API |
| REST API / gcloud / Terraform | API REST / CLI / IaC | API KubeCenter + CLI `kubecenter` + provider (ultérieur) |
| Confidential / CMEK | Chiffrement clés client | KMS interne (CMEK en phase ultérieure) |

---

*Fin du document — SPEC-KubeCenter-VM v1.0. À lire conjointement avec le CDC-PCA-PRA-K8S (lots Réseau underlay, Sécurité, Console self-service, PRA, GPU, Stockage).*
