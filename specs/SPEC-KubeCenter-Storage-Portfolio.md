# KubeCenter Storage — Volet Portefeuille (vue d'ensemble du domaine stockage)

**Version :** 1.0 — Juin 2026
**Statut :** Spécification d'ingénierie — vue d'ensemble du domaine stockage.
**Référence amont :** **CDC-PCA-PRA-K8S** (cahier des charges initial) — ce volet aligne l'ensemble du domaine stockage sur le CDC (chapitre 9).
**Complète :** **SPEC-KubeCenter-Storage** (qui détaille le stockage **bloc** — disques). Le présent document couvre le **portefeuille complet** (bloc, fichier, objet, sauvegarde/PRA, transfert, stockage pour Kubernetes) et renvoie au document bloc pour le détail des disques.
**Modèle fonctionnel de référence :** Google Cloud — domaine *Storage* (Cloud Storage, Filestore, NetApp Volumes, Managed Lustre, Persistent Disk/Hyperdisk, Backup and DR, Storage Transfer Service).
**Contrainte de périmètre :** tout est réalisé avec **Rook-Ceph** (RBD bloc, CephFS fichier, RGW objet) ou le **stockage local**. Les services managés propriétaires de Google sont écartés et justifiés au chapitre 11.

---

## 0. Préambule

### 0.1 Objet

Donner une vue d'ensemble cohérente de l'offre de stockage de KubeCenter, organisée comme le domaine *Storage* de GCP (par cas d'usage : solutions de stockage, sauvegarde/PRA, transfert), et **démontrer son alignement avec le cahier des charges initial** (CDC-PCA-PRA-K8S). Ce volet sert de porte d'entrée : il oriente vers la bonne brique (bloc/fichier/objet) et vers les spécifications détaillées.

### 0.2 Le portefeuille en une page

| Famille (cas d'usage GCP) | Service KubeCenter | Brique Rook-Ceph / local | Spécification détaillée |
|---|---|---|---|
| Bloc (Persistent Disk / Hyperdisk / Local SSD) | **Disques KubeCenter** | Ceph RBD + stockage local | SPEC-KubeCenter-Storage |
| Fichier (Filestore / NetApp Volumes) | **Fichier partagé KubeCenter** | CephFS (+ export NFS) | présent document, ch. 4 |
| Fichier parallèle HPC (Managed Lustre) | **Fichier HPC** (option) | CephFS hautes perf. / Lustre externe | présent document, ch. 4 |
| Objet (Cloud Storage) | **Objet KubeCenter (S3)** | Ceph RGW | présent document, ch. 5 |
| Sauvegarde & PRA (Backup and DR / Backup for GKE) | **Sauvegarde & PRA KubeCenter** | Velero + snapshots + RBD mirroring | présent document, ch. 6 |
| Transfert (Storage Transfer Service / Appliance) | **Transfert & migration de données** | rclone/CSI/import CDI + appliance | présent document, ch. 7 |
| Stockage pour conteneurs (GKE storage) | **Stockage pour charges Kubernetes** | CSI RBD/CephFS + classes | présent document, ch. 8 |

### 0.3 Principe directeur

Trois primitives physiques (bloc, fichier, objet) servies par **un seul backend souverain mutualisé (Rook-Ceph)** + le stockage local, exposées comme des services distincts en libre-service par tenant, avec sauvegarde/PRA et transfert transverses — conformément à l'architecture du CDC (Ceph stretch multi-AZ Alger + mirroring vers Constantine).

---

## 1. Cartographie par cas d'usage

**EXG-STO-1000** — Le portefeuille expose trois **solutions de stockage** (bloc, fichier, objet), un **service de sauvegarde/PRA** transverse, et un **service de transfert/migration**, tous multi-tenant et régis par l'IAM de la plateforme (Keycloak/Capsule).

**EXG-STO-1001** — Toute ressource de stockage, quelle que soit la famille, porte le tier de continuité (`kubecenter.dz/dr-tier`, T0–T3) qui détermine sa protection (ch. 6) — cohérent avec le CDC.

**EXG-STO-1002** — Une console et une API uniques présentent les trois familles avec une terminologie homogène (capacité, classe, snapshot, quota, chiffrement), pour éviter au tenant d'avoir à connaître Ceph.

---

## 2. Arbre de décision (quelle brique choisir)

**EXG-STO-1100** — La console propose une aide au choix, calquée sur le *decision tree* de GCP :

| Besoin | Brique recommandée |
|---|---|
| Disque attaché à une VM/un conteneur (un seul écrivain), base de données, disque de démarrage | **Bloc** (Ceph RBD) — `ku-disk-*` |
| Accès fichier partagé en lecture/écriture par plusieurs instances (RWX), répertoires partagés, HPC léger | **Fichier** (CephFS, + NFS) |
| Données non structurées, sauvegardes, archives, jeux de données, artefacts, contenu d'application web, accès par API HTTP | **Objet** (RGW S3) |
| Scratch ultra-rapide, éphémère, non répliqué | **Bloc local** (`ku-disk-local`) |
| Très faible latence volatile | **Volume mémoire** (tmpfs) |

**EXG-STO-1101** — L'aide au choix tient compte du tier de continuité requis et de la conformité (localisation 18-07), et oriente vers la classe de performance adéquate.

---

## 3. Bloc (renvoi)

**EXG-STO-1200** — Le stockage bloc (disques de démarrage/données, classes std/bal/perf, snapshots, clones, redimensionnement, multi-attach, chiffrement, réplication multi-AZ et PRA) est **entièrement spécifié dans SPEC-KubeCenter-Storage** (exigences EXG-ST-xxxx). Le présent volet n'en reprend que la place dans le portefeuille. Renvoi : disque local éphémère (≈ Local SSD) et volume mémoire (≈ RAM disk) y sont également traités.

---

## 4. Fichier partagé (≈ Filestore / NetApp Volumes / Managed Lustre)

**EXG-STO-1300** — **Service de fichier partagé** : volumes **RWX** servis par **CephFS** (`CephFilesystem` + `csi-cephfs`), montables simultanément en lecture/écriture par plusieurs instances et conteneurs — équivalent fonctionnel de Filestore (serveur NFS managé).

**EXG-STO-1301** — **Niveaux de performance** : au moins deux profils de partage (capacitif sur SSD, hautes performances sur NVMe), à la manière des paliers Filestore (Basic/Zonal/Enterprise) — sans reprendre les chiffres Google.

**EXG-STO-1302** — **Export NFS** : exposition de partages CephFS en **NFSv4** via `CephNFS` (nfs-ganesha) pour les clients et charges legacy. SMB non retenu en phase 1 (ch. 11).

**EXG-STO-1303** — **Partages multiples** (≈ *Filestore multishares for GKE*) : plusieurs partages logiques (sous-volumes CephFS) au sein d'une même capacité, alloués dynamiquement aux tenants/charges.

**EXG-STO-1304** — **Fonctions de données** : quotas par partage, snapshots CephFS, chiffrement, instantanés programmés — alignés sur la sauvegarde (ch. 6).

**EXG-STO-1305** — **Fichier parallèle HPC** (≈ *Managed Lustre*) : pour les charges HPC/IA exigeant un système de fichiers parallèle, l'offre par défaut est **CephFS hautes performances** ; un déploiement **Lustre dédié** (sur le matériel du tenant) reste une **option** documentée hors backend mutualisé, en cohérence avec l'expérience HPC du CDC (Warewulf/OpenHPC).

---

## 5. Objet (≈ Cloud Storage)

**EXG-STO-1400** — **Service de stockage objet souverain** : Ceph **RGW** (`CephObjectStore`) expose une **API compatible S3** ; les tenants créent des compartiments (`ObjectBucketClaim`) avec clés d'accès dédiées et politiques d'accès.

**EXG-STO-1401** — **Classes de stockage** (≈ Standard/Nearline/Coldline/Archive) : au moins deux classes — « standard » (SSD/NVMe, accès fréquent) et « archive » (HDD, capacitif) — avec **politiques de cycle de vie** (transition standard→archive, expiration) par compartiment.

**EXG-STO-1402** — **Versioning** des objets et **politiques de rétention** ; **immutabilité Object Lock (WORM)** anti-rançongiciel, utilisée notamment par la sauvegarde (ch. 6).

**EXG-STO-1403** — **Contrôle d'accès** : politiques par compartiment/objet, URL pré-signées, clés d'accès par tenant ; isolation stricte inter-tenants.

**EXG-STO-1404** — **Rapports d'inventaire** (≈ *Storage Insights inventory reports*) : génération de rapports de métadonnées d'objets (volumétrie, âge, classe) par compartiment, pour la gouvernance et la facturation.

**EXG-STO-1405** — **Compatibilité** : l'API S3 permet l'usage direct des SDK/outils standard (aws-cli, boto3, rclone, MinIO client), garantissant l'interopérabilité et la réversibilité.

---

## 6. Sauvegarde & PRA (≈ Backup and DR Service / Backup for GKE)

**EXG-STO-1500** — **Service de sauvegarde centralisé** (≈ *Backup and DR*) : plans de sauvegarde **application-cohérents** pour VM (KubeVirt), volumes (PVC) et charges conteneurisées, via **Velero** + plugin KubeVirt + snapshots Ceph, vers le stockage objet **RGW avec Object Lock**.

**EXG-STO-1501** — **Sauvegarde des charges Kubernetes** (≈ *Backup for GKE*) : sauvegarde/restauration des objets applicatifs (manifestes, PVC, configurations) d'un namespace tenant, pour reconstruction à l'identique.

**EXG-STO-1502** — **Plans de sauvegarde** par tier : fréquence, fenêtre, rétention, génération ; réglage par défaut au niveau projet (≈ *default backup setting*), appliqué automatiquement aux nouvelles ressources selon `dr-tier`.

**EXG-STO-1503** — **PRA inter-régions** : réplication continue vers **Constantine** (snapshots/objets répliqués + **RBD mirroring** pour le bloc), bascule et retour orchestrés par le **cockpit PRA** ; RPO/RTO conformes aux tiers du CDC (T0 multi-AZ RPO 0 ; T2 RPO 15 min/RTO 4 h ; etc.).

**EXG-STO-1504** — **Restauration** granulaire (un objet, un volume), au niveau charge, ou vers la région PRA ; tests de restauration périodiques (exercices) avec rapport.

**EXG-STO-1505** — **Conformité & rapports** (≈ *data backup compliance*) : tableau de bord de l'état de protection des ressources (couverture, fraîcheur vs RPO, succès/échecs), exportable pour audit — exigence directement issue de l'esprit PRA du CDC.

---

## 7. Transfert & migration de données (≈ Storage Transfer Service / Transfer Appliance)

**EXG-STO-1600** — **Ingestion vers l'objet** : import de données depuis des sources externes compatibles S3 (autre cloud, MinIO, autre RGW) vers les compartiments KubeCenter, par tâches planifiées (rclone/outillage S3), avec reprise et contrôle d'intégrité.

**EXG-STO-1601** — **Import de disques/images** : ingestion de disques `qcow2`/`raw`/`vmdk` (via CDI) — renvoi **SPEC-KubeCenter-VM / Storage**.

**EXG-STO-1602** — **Migration entrante/sortante** : outillage de migration de données vers et depuis la plateforme (réversibilité), incluant l'export S3 standard et l'export de volumes au format ouvert.

**EXG-STO-1603** — **Transfert par support physique** (≈ *Transfer Appliance*) : pour les très gros volumes initiaux, procédure d'ingestion par support chiffré acheminé au datacenter (chaîne de custody, déchiffrement contrôlé, effacement certifié) — adaptée au contexte algérien (bande passante WAN limitée).

**EXG-STO-1604** — Tout transfert est journalisé, chiffré en transit, et respecte la localisation 18-07 (aucune donnée ne transite hors du territoire sans autorisation explicite).

---

## 8. Stockage pour les charges Kubernetes (≈ Storage for GKE)

**EXG-STO-1700** — **Intégration CSI** : classes de stockage (`StorageClass`) bloc (RBD, RWO) et fichier (CephFS, RWX) disponibles pour les conteneurs des tenants, avec `allowVolumeExpansion`, snapshots (`VolumeSnapshotClass`) et clones CSI.

**EXG-STO-1701** — **Modes d'accès** : RWO (RBD), RWX (CephFS), objet (RGW via SDK), éphémère (local/`emptyDir`) — choix guidé par l'arbre de décision (ch. 2).

**EXG-STO-1702** — **Sauvegarde des volumes conteneurisés** : intégrée au service de sauvegarde (ch. 6) ; cohérence avec les charges KubeVirt (volumes partagés VM/conteneurs).

**EXG-STO-1703** — **Classe par défaut** par tenant et quotas de capacité (`ResourceQuota`) appliqués à l'admission.

---

## 9. Sécurité, conformité et observabilité (transversal)

**EXG-STO-1800** — **Chiffrement** au repos (OSD Ceph sur LUKS + KMS interne) et en transit, pour les trois familles ; Object Lock pour l'immuabilité ; clés client (CMEK) en phase ultérieure.

**EXG-STO-1801** — **Isolation multi-tenant** : pools/sous-volumes, compartiments et clés cloisonnés ; RBAC OIDC ; admission Kyverno sur les classes/paramètres autorisés.

**EXG-STO-1802** — **Conformité loi 18-07 / ANPDP** : toutes les copies (bloc, fichier, objet, sauvegardes, réplicas) résident exclusivement à Alger et Constantine — exigence centrale du CDC.

**EXG-STO-1803** — **Audit** : opérations sur les trois familles + sauvegarde/transfert journalisées (acteur, horodatage), inviolables, consultables par le tenant.

**EXG-STO-1804** — **Observabilité unifiée** : capacité, performance, occupation des pools, santé Ceph, fraîcheur de réplication PRA, état des sauvegardes — exposés en console et API (exporter Ceph → LGTM), avec alertes (saturation, dérive RPO, échec de sauvegarde).

**EXG-STO-1805** — **Facturation à l'usage** unifiée : Go-mois par famille et par classe, opérations objet, snapshots, sauvegardes, transferts — exportée vers le moteur de facturation.

---

## 10. Alignement au cahier des charges initial (CDC-PCA-PRA-K8S)

**EXG-STO-1900** — Ce volet est traçable vers les lots du CDC. Correspondance :

| Lot / exigence du CDC initial | Couverture dans le portefeuille stockage |
|---|---|
| Lot **Stockage** (Ceph stretch, classes, snapshots) | Ch. 3 (bloc), 4 (fichier), 5 (objet) + SPEC-KubeCenter-Storage |
| Lot **PRA** (RBD mirroring 15 min, DR orchestration, RPO/RTO) | Ch. 6 (sauvegarde & PRA), tiers T0–T3, cockpit PRA |
| Lot **Sécurité** (chiffrement, isolation, audit, 18-07) | Ch. 9 (transversal sécurité/conformité) |
| Lot **Sauvegarde** (Velero + RGW Object Lock) | Ch. 6 (service de sauvegarde centralisé) |
| Lot **Console self-service** | Ch. 1.2, 2 (arbre de décision), API/console unifiées |
| Lot **Réseau** (réseau de stockage isolé) | Ch. 9 (chiffrement en transit), renvoi SPEC-KubeCenter-Network |
| Exigences **multi-AZ Alger + témoin** | Ch. 6 (T0 multi-AZ RPO 0), Ceph stretch + arbitre |
| Exigences **Constantine = PRA** | Ch. 6/7 (réplication + transfert vers Constantine) |

**EXG-STO-1901** — Toute évolution du portefeuille stockage doit rester cohérente avec les décisions d'architecture du CDC (Rook-Ceph, stretch multi-AZ, mirroring vers Constantine, tiers de continuité, localisation 18-07) ; aucune brique ne contredit le CDC.

---

## 11. Options GCP écartées (et justification)

| Élément du domaine Storage GCP non retenu | Raison |
|---|---|
| **NetApp Volumes** (service managé propriétaire NetApp) | Service tiers propriétaire ; CephFS couvre le besoin de fichier managé souverain |
| **Managed Lustre** (FS parallèle managé) | CephFS hautes performances par défaut ; Lustre reste une option dédiée hors backend mutualisé pour HPC spécifique |
| **Global edge caching / CDN** de Cloud Storage | Pas de backbone mondial ; mise en cache de bordure éventuelle ultérieure, à l'échelle régionale |
| **Cloud Storage for Firebase / Google Drive** | Hors périmètre (services applicatifs grand public Google) |
| **SMB** sur le fichier partagé | NFS (CephNFS) en phase 1 ; SMB via Samba/CephFS possible ultérieurement |
| **CSEK** (clés fournies par requête) | CMEK (KMS client) prévu ultérieurement ; LUKS + KMS interne assure la souveraineté |
| **Transfer Appliance** managé Google | Remplacé par une procédure souveraine d'ingestion par support physique chiffré |
| **Chiffres de performance / paliers Google** | Remplacés par les paliers mesurés sur le matériel KubeCenter |

---

## 12. Exigences — récapitulatif de traçabilité

Les exigences `EXG-STO-1000` à `EXG-STO-1901` constituent le référentiel traçable de ce volet (niveau portefeuille). Le détail bloc relève de `EXG-ST-xxxx` (SPEC-KubeCenter-Storage). Priorisation `MUST` (phase 1) sauf : fichier parallèle Lustre dédié (1305), classes objet multiples avancées (1401), transfert par support physique (1603), CMEK — `SHOULD`/phase ultérieure.

---

## 13. Tests d'acceptation (niveau portefeuille)

| ID | Objet | Critère de réussite |
|---|---|---|
| T-STO-01 | Arbre de décision | La console recommande la bonne brique (bloc/fichier/objet) selon le besoin et le tier |
| T-STO-02 | Fichier RWX | Partage CephFS monté en lecture/écriture par 3 instances ; cohérence ; quota appliqué |
| T-STO-03 | Export NFS | Partage exposé en NFSv4 ; montage par un client externe autorisé |
| T-STO-04 | Partages multiples | Plusieurs sous-volumes alloués dynamiquement dans une même capacité |
| T-STO-05 | Objet S3 | Création de compartiment, dépôt/lecture via aws-cli ; versioning actif |
| T-STO-06 | Cycle de vie objet | Transition standard→archive et expiration appliquées par politique |
| T-STO-07 | Object Lock | Objet sous rétention non supprimable avant échéance |
| T-STO-08 | Rapport d'inventaire | Rapport de métadonnées d'objets généré (volumétrie, âge, classe) |
| T-STO-09 | Plan de sauvegarde | Sauvegarde application-cohérente d'une VM + PVC vers RGW (Object Lock) |
| T-STO-10 | Sauvegarde charge K8s | Sauvegarde/restauration d'un namespace tenant (manifestes + PVC) |
| T-STO-11 | Réglage par défaut | Nouvelle ressource T2 protégée automatiquement selon le plan par défaut |
| T-STO-12 | PRA bascule | Bascule d'un service vers Constantine ; RPO/RTO du tier respectés ; rapport produit |
| T-STO-13 | Conformité sauvegarde | Tableau de bord de couverture/fraîcheur exact ; export d'audit |
| T-STO-14 | Ingestion objet | Import depuis une source S3 externe avec contrôle d'intégrité et reprise |
| T-STO-15 | Transfert physique | Procédure d'ingestion par support chiffré : custody, déchiffrement, effacement certifié |
| T-STO-16 | Stockage K8s | Classes RBD (RWO) et CephFS (RWX) consommées par des conteneurs ; expansion et snapshot OK |
| T-STO-17 | Chiffrement | Chiffrement au repos vérifié sur les trois familles ; transit chiffré |
| T-STO-18 | Isolation multi-tenant | Aucun accès croisé bloc/fichier/objet entre deux tenants |
| T-STO-19 | Observabilité unifiée | Capacité/perf/occupation/fraîcheur PRA/état sauvegardes visibles par famille |
| T-STO-20 | Facturation unifiée | Go-mois, opérations objet, snapshots, sauvegardes, transferts mesurés par tenant |
| T-STO-21 | Conformité 18-07 | Aucune copie (bloc/fichier/objet/sauvegarde/réplica) hors Alger/Constantine |
| T-STO-22 | Alignement CDC | Chaque brique tracée vers un lot du CDC ; aucune contradiction avec l'architecture actée |

---

## Annexe A — Correspondance domaine Storage GCP ↔ KubeCenter

| Domaine Storage GCP | KubeCenter | Implémentation |
|---|---|---|
| Cloud Storage (objet) | Objet KubeCenter (S3) | Ceph RGW + Object Lock + lifecycle |
| Filestore (NFS managé) | Fichier partagé | CephFS + CephNFS |
| NetApp Volumes | (écarté) | CephFS couvre le besoin |
| Managed Lustre | Fichier HPC (option) | CephFS hautes perf. / Lustre dédié |
| Persistent Disk / Hyperdisk (bloc) | Disques KubeCenter | Ceph RBD (cf. SPEC-KubeCenter-Storage) |
| Local SSD | Bloc local éphémère | TopoLVM / LocalPV |
| Backup and DR Service | Sauvegarde centralisée | Velero + snapshots + RGW Object Lock |
| Backup for GKE | Sauvegarde charges K8s | Velero (objets + PVC du namespace) |
| Default backup setting | Réglage de sauvegarde par défaut | plan par défaut par tier |
| Data backup compliance | Conformité & rapports | tableau de bord de protection |
| Storage Transfer Service | Transfert/ingestion | tâches S3 (rclone) + import CDI |
| Transfer Appliance | Transfert physique | support chiffré + custody souveraine |
| Storage Insights inventory | Rapports d'inventaire objet | rapports RGW |
| Storage for GKE | Stockage pour conteneurs | CSI RBD/CephFS + classes |
| CMEK / CSEK | Chiffrement clés client | KMS interne ; CMEK ultérieur |

---

*Fin du document — SPEC-KubeCenter-Storage-Portfolio v1.0. À lire conjointement avec SPEC-KubeCenter-Storage (bloc), SPEC-KubeCenter-VM, SPEC-KubeCenter-Network, SPEC-KubeCenter-GPU et le CDC-PCA-PRA-K8S (lots Stockage, PRA, Sécurité, Sauvegarde, Console).*
