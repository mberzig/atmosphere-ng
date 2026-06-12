# KubeCenter Storage — Spécifications techniques du module de stockage

**Version :** 1.0 — Juin 2026
**Statut :** Spécification d'ingénierie (destinée au développement assisté, type Claude Code)
**Référence amont :** CDC-PCA-PRA-K8S (Lot Stockage) ; complément du module **KubeCenter VM** (les disques décrits ici sont ceux attachés aux instances).
**Modèle fonctionnel de référence :** Google Compute Engine — *block storage / disks* (utilisé comme grille de complétude).
**Contrainte de périmètre (explicite) :** ne sont spécifiées QUE les capacités réalisables avec **Rook-Ceph** (RBD bloc, CephFS fichier, RGW objet) ou avec le **stockage local** des nœuds. Les options GCP sans équivalent souverain réaliste sont listées et écartées au chapitre 13.

---

## 0. Préambule

### 0.1 Objet

KubeCenter Storage fournit le stockage des instances et des charges de la plateforme : volumes bloc (disques de démarrage et de données), systèmes de fichiers partagés et stockage objet — avec snapshots, clones, chiffrement, réplication multi-AZ et réplication inter-régions pour le PRA, le tout exposé en libre-service par tenant.

### 0.2 Principe directeur

Compute Engine distingue **stockage bloc temporaire** (Local SSD — éphémère) et **durable** (Persistent Disk / Hyperdisk — persistant, portable, chiffré, répliquable). KubeCenter reprend cette distinction :

- **temporaire** → **stockage local** des nœuds (NVMe local, non répliqué, perdu à l'arrêt/migration) ;
- **durable** → **Rook-Ceph RBD** (réseau, persistant, portable, chiffré, répliqué).

Les alternatives bloc de GCP (serveur de fichiers/NFS, disque RAM) sont couvertes respectivement par **CephFS** (+ export NFS) et par un **volume en mémoire** (tmpfs).

### 0.3 Socle technique retenu

| Capacité | Composant |
|---|---|
| Bloc durable (RWO) | Ceph RBD via `csi-rbd` (Rook) — `CephBlockPool` + `StorageClass` |
| Fichier partagé (RWX) | CephFS via `csi-cephfs` (Rook) — `CephFilesystem` ; export NFS via `CephNFS` (nfs-ganesha) |
| Objet (S3) | Ceph RGW via `CephObjectStore` (Rook) + `ObjectBucketClaim` |
| Bloc temporaire | Stockage local : TopoLVM (LVM dynamique) ou OpenEBS LocalPV / `local` PV statique sur NVMe |
| Volume en mémoire | `emptyDir{medium: Memory}` (tmpfs) |
| Snapshots / clones | CSI `VolumeSnapshot`/`VolumeSnapshotClass` (snap RBD/CephFS) ; clones CSI (`dataSource` PVC) |
| Chiffrement au repos | OSD Ceph sur LUKS (`encryptedDevice: true`) ; clés au KMS interne |
| Réplication multi-AZ | `CephCluster` en **mode stretch** (Alger AZ-1/AZ-2 + moniteur arbitre sur site témoin) |
| Réplication inter-régions | **RBD mirroring** (mode snapshot) Alger → Constantine + groupes de cohérence |
| Sauvegarde | Velero (PVC + VolumeSnapshot) vers RGW avec **Object Lock** (immutabilité) |
| Observabilité | exporter Ceph (mgr/Prometheus) → pile LGTM ; santé disque, état des réplicas, métriques de pool |

### 0.4 Synthèse des correspondances (détaillée en Annexe A)

| Concept GCP | KubeCenter Storage | Implémentation |
|---|---|---|
| Local SSD (temporaire) | Disque local éphémère | TopoLVM / LocalPV (NVMe) |
| Persistent Disk / Hyperdisk (durable) | Disque persistant | PVC Ceph RBD |
| Disk type (standard/balanced/ssd/extreme) | Classe de disque | `StorageClass` sur pool Ceph (device class hdd/ssd/nvme) |
| Hyperdisk tunable IOPS/débit | Performance provisionnée | QoS RBD par image (IOPS/débit) |
| Storage Pools | Pool de stockage | `CephBlockPool` / CRUSH rule / device class |
| Regional disk (sync 2 zones) | Disque multi-AZ | Ceph stretch (réplication synchrone AZ-1/AZ-2) |
| Asynchronous Replication (cross-region) | Réplication PRA | RBD mirroring (snapshot) → Constantine |
| Consistency group | Groupe de cohérence | RBD mirror group / consistency group |
| Standard snapshot (DR) | Instantané de sauvegarde | VolumeSnapshot exporté + Velero/RGW |
| Instant snapshot (in-place) | Instantané rapide | snapshot RBD natif (CoW) |
| Snapshot schedule | Instantanés programmés | planificateur + opérateur de snapshot |
| Disk clone | Clone de disque | clone CSI (RBD/CephFS) |
| App-consistent snapshot (fsfreeze/VSS) | Instantané cohérent | `qemu-guest-agent` fs-freeze |
| Resize (increase) | Redimensionnement | expansion CSI (`allowVolumeExpansion`) |
| Share disk (multi-writer) | Partage de disque | RBD RO multi-attach ; RWX via CephFS |
| File server / NFS-SMB | Fichier partagé | CephFS (+ export NFS via CephNFS) |
| RAM disk | Volume mémoire | tmpfs (`emptyDir` Memory) |
| Cloud Storage (objet) | Stockage objet | Ceph RGW (S3) + Object Lock |
| Disk encryption (Google-managed/CMEK) | Chiffrement | LUKS OSD + KMS interne (CMEK ultérieur) |

---

## 1. Modèle de ressources

**EXG-ST-1000** — L'API expose, sous chaque projet (tenant) : `Disques` (bloc), `Instantanés`, `Politiques d'instantané`, `Clones`, `Classes de disque` (catalogue, lecture seule tenant), `Pools de stockage` (administrés), `Systèmes de fichiers partagés`, `Compartiments objet`. Chaque ressource possède identifiant stable, nom RFC 1123, libellés, horodatages.

**EXG-ST-1001** — Chaque volume durable est un PVC isolé dans le namespace du tenant ; aucun accès croisé entre tenants (RBAC + Kyverno + quotas).

**EXG-ST-1002** — Chaque volume porte le libellé `kubecenter.dz/dr-tier` (T0–T3) déterminant son régime de réplication/sauvegarde (chapitre 9).

**EXG-ST-1003** — **Portabilité** (équiv. *portability* PD/Hyperdisk) : un disque durable est indépendant de l'instance ; il peut être détaché d'une instance en marche et rattaché à une autre, et survit à la suppression de l'instance.

---

## 2. Classes de disque (types de bloc)

### 2.1 Bloc durable (Ceph RBD)

**EXG-ST-1100** — Trois classes durables, alignées sur la logique GCP « standard / balanced / SSD-extreme » :

| Classe KubeCenter | Inspiration GCP | Support physique (device class Ceph) | Profil |
|---|---|---|---|
| `ku-disk-std` | pd-standard | HDD | capacitif, économique |
| `ku-disk-bal` | pd-balanced / Hyperdisk Balanced | SSD | équilibré (**défaut**) |
| `ku-disk-perf` | pd-ssd / pd-extreme / Hyperdisk Extreme | NVMe | haute performance |

Chaque classe est une `StorageClass` adossée à un `CephBlockPool` (réplication 3, CRUSH rule sur la device class correspondante).

**EXG-ST-1101** — **Performance provisionnée indépendante de la taille** (inspirée de Hyperdisk) : pour `ku-disk-perf`, les IOPS et le débit peuvent être plafonnés/garantis **par volume** via la QoS RBD (`rbd_qos_iops_limit`, `rbd_qos_bps_limit`), indépendamment de la capacité. Pour les classes std/bal, des plafonds par défaut s'appliquent.

**EXG-ST-1102** — **QoS et isolation** : des limites IOPS/débit par volume préviennent l'effet *noisy neighbor* entre tenants ; les plages publiées par classe sont mesurées sur la plateforme (pas de reprise des chiffres GCP).

### 2.2 Bloc temporaire (stockage local)

**EXG-ST-1110** — Classe `ku-disk-local` (équiv. *Local SSD*) : volume **éphémère** sur NVMe local du nœud, **non répliqué**, performances maximales. **Contrainte explicite et signalée au tenant** : les données sont **perdues** si l'instance est arrêtée, suspendue, redémarrée à froid, migrée, ou en cas de panne du nœud. Usage : scratch, cache, `tempdb`, espaces temporaires de calcul. **Ne peut pas servir de disque de démarrage.**

**EXG-ST-1111** — Provisionnement : TopoLVM (allocation LVM dynamique sur les NVMe locaux) ou LocalPV statique ; l'ordonnancement épingle l'instance au nœud détenant le volume local.

### 2.3 Volume en mémoire

**EXG-ST-1120** — Volume `tmpfs` en mémoire (équiv. *RAM disk*) optionnel pour très haut débit / très faible latence, dimension plafonnée, volatil par nature.

---

## 3. Pools de stockage

**EXG-ST-1200** — **Pools de stockage** (équiv. *Hyperdisk Storage Pools*) : capacité et performance regroupées et administrées par device class via `CephBlockPool` + règles CRUSH. Les administrateurs définissent les pools ; les tenants consomment via les classes de disque. Le surprovisionnement (thin provisioning RBD) est supporté et supervisé.

**EXG-ST-1201** — La capacité et le taux d'occupation des pools sont exposés en supervision (alertes nearfull/backfillfull) afin de prévenir la saturation (cf. retour d'expérience Ceph : seuils nearfull, réduction de réplica en urgence proscrite hors procédure).

---

## 4. Cycle de vie et opérations sur disque

**EXG-ST-1300** — **Création** d'un disque vide ou à partir d'une image/instantané/clone ; **attachement/détachement à chaud** à une instance (hotplug KubeVirt) sans interruption.

**EXG-ST-1301** — **Redimensionnement** (équiv. *resize* — augmentation uniquement) en ligne : expansion CSI (`allowVolumeExpansion: true`) + croissance du système de fichiers invité via guest agent.

**EXG-ST-1302** — **Changement de classe** (équiv. *change disk type* / migrate to Hyperdisk) : réalisé par **copie/clonage** vers un volume de la classe cible (opération gérée, fenêtre planifiée), la modification en place du device class n'étant pas garantie sans recopie.

**EXG-ST-1303** — **Partage entre instances** (équiv. *share disk / multi-writer*) : RBD en lecture seule multi-attachée ; accès **lecture/écriture partagé réservé à CephFS** (RWX). Le RBD bloc en RWX multi-écrivain n'est pas exposé (risque de corruption sans système de fichiers en cluster).

**EXG-ST-1304** — **Protection contre la suppression** (équiv. *prevent accidental deletion*) : drapeau `deletionProtection` + finaliseur ; un disque protégé ou encore attaché ne peut être supprimé.

**EXG-ST-1305** — **Facturation à l'usage** : capacité provisionnée (Go-mois) facturée de la création à la suppression, y compris pour un disque détaché ou rattaché à une instance arrêtée ; la performance provisionnée (classe perf/QoS) est facturée en sus.

---

## 5. Instantanés (snapshots)

**EXG-ST-1400** — **Instantané rapide** (équiv. *instant snapshot*) : snapshot RBD/CephFS natif (copy-on-write), quasi instantané, conservé dans le même cluster, pour restauration rapide ou clonage.

**EXG-ST-1401** — **Instantané de sauvegarde** (équiv. *standard snapshot* pour DR) : snapshot exporté/sauvegardé (via Velero) vers le stockage objet RGW, conservé hors du cluster source, incrémental, restaurable y compris en région PRA.

**EXG-ST-1402** — **Instantanés programmés** (équiv. *snapshot schedules*) : politiques par disque/projet (fréquence, fenêtre, rétention, génération N) ; alertes en cas d'échec de planification.

**EXG-ST-1403** — **Instantané cohérent applicatif** (équiv. *application-consistent snapshot* — fsfreeze Linux / VSS Windows) : gel des E/S via `qemu-guest-agent` avant capture ; mode *crash-consistent* à défaut, clairement étiqueté.

**EXG-ST-1404** — **Restauration** : création d'un nouveau disque (ou d'une instance) à partir d'un instantané ; restauration possible vers une autre AZ ou vers la région PRA.

---

## 6. Clones

**EXG-ST-1500** — **Clone de disque** (équiv. *disk clone*) : duplication d'un volume via clone CSI (`dataSource` PVC, clone RBD/CephFS), rapide et économe (copy-on-write), pour environnements de test/dev ou réplication de modèles.

**EXG-ST-1501** — Les clones et instantanés héritent par défaut de la classe et du chiffrement du volume source ; la classe cible peut être modifiée à la création (recopie).

---

## 7. Stockage de fichiers partagé (CephFS)

**EXG-ST-1600** — **Système de fichiers partagé** (équiv. *file server / distributed file system* GCP) : volumes **RWX** servis par CephFS (`CephFilesystem` + `csi-cephfs`), montables simultanément en lecture/écriture par plusieurs instances/conteneurs.

**EXG-ST-1601** — **Export NFS** : exposition de partages via `CephNFS` (nfs-ganesha) pour les clients NFSv4 (charges legacy, postes de calcul). SMB non retenu en phase 1 (cf. chapitre 13).

**EXG-ST-1602** — Quotas, snapshots et chiffrement s'appliquent aux volumes CephFS comme aux volumes bloc.

---

## 8. Stockage objet (RGW / S3)

**EXG-ST-1700** — **Stockage objet souverain** (complément du périmètre bloc) : Ceph RGW (`CephObjectStore`) expose une **API compatible S3** ; les tenants créent des compartiments via `ObjectBucketClaim`, avec clés d'accès dédiées.

**EXG-ST-1701** — **Immutabilité (Object Lock / WORM)** : rétention verrouillée anti-rançongiciel sur les compartiments de sauvegarde et d'archive ; utilisée comme cible des sauvegardes Velero (chapitre 9).

**EXG-ST-1702** — Versioning d'objets, politiques de cycle de vie (transition/expiration) et quotas par compartiment.

---

## 9. Haute disponibilité, réplication et PRA

### 9.1 Réplication synchrone multi-AZ (équiv. regional disks)

**EXG-ST-1800** — Les volumes durables des charges **T0** sont protégés contre la perte d'une zone par la **réplication synchrone Ceph en mode stretch** entre AZ-1 et AZ-2 d'Alger (4 copies, CRUSH par zone), avec **moniteur arbitre** sur le site témoin. La perte d'une AZ complète est absorbée sans perte de données (RPO 0).

**EXG-ST-1801** — L'état des réplicas et la santé du quorum sont supervisés (équiv. *monitor replica states of regional disks*) ; toute dégradation déclenche une alerte.

### 9.2 Réplication asynchrone inter-régions (équiv. async PD)

**EXG-ST-1810** — Pour les tiers **T2/T3**, les images RBD sont répliquées vers la région **Constantine** par **RBD mirroring en mode snapshot**, intervalle ≤ 15 min (RPO contractuel T2).

**EXG-ST-1811** — **Groupes de cohérence** (équiv. *consistency groups*) : un ensemble de volumes d'une même application est répliqué de façon cohérente dans le temps (mirror group), garantissant un point de reprise applicatif unique.

**EXG-ST-1812** — **Bascule et retour** (équiv. *failover/failback*) : promotion des images répliquées côté Constantine lors d'un sinistre, et resynchronisation/retour ultérieur, orchestrés par le cockpit PRA (point de décision go/no-go, journal de preuve).

### 9.3 Tiers de protection

**EXG-ST-1820** — Régime de protection par tier du volume :

| Tier | Protection du stockage | RPO | RTO (du volume) |
|---|---|---|---|
| T0 | multi-AZ synchrone (stretch Alger) | 0 | automatique |
| T1 | instantanés programmés + sauvegarde quotidienne répliquée à Constantine | 24 h | 8 h |
| T2 | RBD mirroring continu (≤ 15 min) vers Constantine | 15 min | 4 h |
| T3 | réplication + disponibilité actif-actif | ≈ 0 | < 15 min |

---

## 10. Sauvegarde et protection des données

**EXG-ST-1900** — **Options de protection** (équiv. *data protection options / default backup*) : par projet, un réglage de sauvegarde par défaut applique automatiquement instantanés programmés et/ou sauvegarde Velero aux nouveaux volumes selon leur tier.

**EXG-ST-1901** — **Sauvegarde** : Velero sauvegarde PVC + VolumeSnapshots + métadonnées vers RGW (Object Lock) ; rétention configurable, restauration granulaire (un volume) ou complète.

**EXG-ST-1902** — **Restauration testée** : restauration vérifiée périodiquement (exercices) ; rapport conservé. Les tests de restauration en région PRA sont isolés de la production.

---

## 11. Chiffrement et sécurité

**EXG-ST-2000** — **Chiffrement au repos** systématique : OSD Ceph sur LUKS (`encryptedDevice: true`), clés gérées par le KMS interne (PKI + cert-manager). **Chiffrement en transit** sur le réseau de stockage (msgr2 chiffré / réseau dédié isolé).

**EXG-ST-2001** — **Clés gérées par le client** (équiv. CMEK) : intégration d'un KMS client en **phase ultérieure**. Les clés fournies par requête (CSEK) ne sont **pas** retenues (chapitre 13).

**EXG-ST-2002** — **Isolation tenant** : pools/sous-volumes et clés d'accès objet cloisonnés par tenant ; RBAC OIDC ; admission Kyverno sur les `StorageClass`/paramètres autorisés.

**EXG-ST-2003** — **Immutabilité anti-rançongiciel** : Object Lock (RGW) sur les sauvegardes/archives ; instantanés non modifiables.

**EXG-ST-2004** — **Audit** : toute opération de stockage (création, attachement, snapshot, clone, restauration, suppression, bascule) journalisée (acteur, horodatage), conservée de façon inviolable, consultable par le tenant pour ses ressources.

**EXG-ST-2005** — **Conformité loi 18-07 / ANPDP** : toutes les copies (primaires, réplicas, instantanés, sauvegardes, objets) résident exclusivement à Alger et Constantine ; aucune donnée hors du territoire.

---

## 12. Observabilité, quotas, API et réversibilité

**EXG-ST-2100** — **Supervision** (équiv. *monitor disk health / disks / pools*) : santé des disques, état des réplicas (stretch et mirroring), IOPS/débit/latence par volume, occupation et performance des pools ; exposés à la console et à l'API (exporter Ceph → Prometheus/Grafana).

**EXG-ST-2101** — **Alertes** : saturation de pool (nearfull/backfillfull), dérive de RPO (retard de mirroring), échec d'instantané programmé, OSD/PG dégradés.

**EXG-ST-2102** — **Quotas** par projet : capacité totale (bloc + fichier + objet), nombre de volumes, d'instantanés, de compartiments ; dépassement bloqué à l'admission (`ResourceQuota`) avec message explicite ; relèvement tracé.

**EXG-ST-2103** — **API REST** (modelée sur le resource model GCP disks) : ressources `disks`, `snapshots`, `snapshotSchedules`, `diskClones`, `diskTypes`, `storagePools`, `fileShares`, `buckets` ; verbes CRUD + actions (`attach`, `detach`, `resize`, `createSnapshot`, `clone`, `startReplication`, `failover`, `failback`) ; opérations asynchrones (`Operation`), idempotence, pagination, débit limité (429).

**EXG-ST-2104** — **CLI `kubecenter`** et **console self-service** couvrent l'ensemble des opérations (création/attachement de disques, classes, snapshots/programmation, clones, partages CephFS, compartiments objet, supervision, bascule PRA).

**EXG-ST-2105** — **Réversibilité** (anti-verrouillage) : export d'un volume au format ouvert (`qcow2`/`raw`) et des objets via l'API S3 standard, pour migration hors plateforme ; procédure documentée et testée.

---

## 13. Options GCP écartées (et justification)

| Option GCP non retenue | Raison |
|---|---|
| **Hyperdisk ML** (débit en lecture partagée, spécialisé poids de modèles) | Niveau de performance propriétaire Google ; le besoin multi-lecteurs est couvert par CephFS (RWX) en lecture partagée |
| **Hyperdisk Exapools** (mise en pool à l'échelle exaoctet) | Spécifique à l'hyperscale ; les `CephBlockPool` couvrent la mise en pool à notre échelle |
| **Hyperdisk Balanced HA** (volume HA managé propriétaire) | Couvert différemment par le mode **stretch** Ceph (réplication synchrone multi-AZ) |
| **Clés fournies par le client par requête (CSEK)** | Complexité opérationnelle ; le chiffrement LUKS + KMS interne assure la souveraineté ; **CMEK** (KMS client) prévu en phase ultérieure |
| **Confidential disks / Confidential VM** (chiffrement mémoire SEV) | Fonction de calcul (CPU), hors périmètre du module stockage |
| **Export SMB des partages** | NFS (CephNFS) couvre le besoin en phase 1 ; SMB possible ultérieurement via Samba sur CephFS si demande |
| **Chiffres de performance/incréments GCP** (Local SSD 375 Gio, limites Hyperdisk) | Remplacés par les plages **mesurées** sur notre matériel et publiées par classe |
| **Réservations / remises d'engagement de capacité** | Relèvent du modèle commercial KubeCenter (UC / Go-mois), pas d'un calque des CUD GCP |

---

## 14. Exigences — récapitulatif de traçabilité

Les exigences `EXG-ST-1000` à `EXG-ST-2105` constituent le référentiel traçable du module. Chacune est vérifiable (chapitre 15), rattachée à un composant (§0.3) et priorisée `MUST` (phase 1) sauf mention « phase ultérieure » = `SHOULD` (CMEK 2001, export SMB, performance ML/Exapool exclues).

---

## 15. Tests d'acceptation

| ID | Objet | Critère de réussite |
|---|---|---|
| T-ST-01 | Classes de disque | Création d'un volume dans chaque classe (std/bal/perf) ; IOPS mesurées dans les plages publiées |
| T-ST-02 | QoS / isolation | Deux tenants sur la même classe : la charge de l'un ne dégrade pas les IOPS garanties de l'autre |
| T-ST-03 | Disque local éphémère | Volume `ku-disk-local` performant ; donnée confirmée perdue après arrêt de l'instance ; refus comme disque de démarrage |
| T-ST-04 | Portabilité | Détachement à chaud d'un disque durable puis rattachement à une autre instance ; données intactes ; survie à la suppression de l'instance |
| T-ST-05 | Redimensionnement | Extension en ligne d'un volume + FS étendu dans l'invité, sans interruption |
| T-ST-06 | Changement de classe | Migration bal → perf par recopie ; intégrité vérifiée |
| T-ST-07 | Partage CephFS (RWX) | Montage simultané lecture/écriture par 3 instances ; cohérence ; refus du RWX bloc RBD |
| T-ST-08 | Export NFS | Partage CephFS exposé en NFSv4 ; montage par un client externe autorisé |
| T-ST-09 | Instantané rapide | Snapshot RBD quasi instantané ; restauration vers nouveau disque |
| T-ST-10 | Instantané cohérent | Snapshot avec fs-freeze (guest agent) ; base de données cohérente après restauration |
| T-ST-11 | Snapshots programmés | Politique horaire respectée ; rétention N appliquée ; alerte en cas d'échec simulé |
| T-ST-12 | Sauvegarde Velero | Sauvegarde PVC vers RGW (Object Lock) ; objet non supprimable avant échéance ; restauration intégrale |
| T-ST-13 | Clone | Clone CoW d'un volume de 1 Tio créé en quelques secondes ; indépendance vis-à-vis de la source |
| T-ST-14 | Multi-AZ T0 (stretch) | Arrêt d'une AZ d'Alger → volumes T0 disponibles, RPO 0 vérifié ; quorum maintenu par l'arbitre |
| T-ST-15 | Mirroring inter-régions | RBD mirroring T2 vers Constantine ; retard de réplication ≤ 15 min mesuré |
| T-ST-16 | Groupe de cohérence | Réplication cohérente d'un ensemble de volumes ; point de reprise applicatif unique vérifié |
| T-ST-17 | Bascule / retour PRA | Promotion à Constantine puis failback ; intégrité et resynchronisation vérifiées ; rapport produit |
| T-ST-18 | Stockage objet S3 | Création de compartiment, dépôt/lecture S3, versioning ; quota appliqué |
| T-ST-19 | Object Lock | Objet sous rétention non supprimable/modifiable avant expiration |
| T-ST-20 | Chiffrement au repos | OSD chiffré LUKS vérifié ; disque retiré illisible hors plateforme |
| T-ST-21 | Quotas | Dépassement de quota capacité bloqué à l'admission avec message explicite |
| T-ST-22 | Supervision/alertes | Saturation de pool et dérive de RPO génèrent les alertes attendues |
| T-ST-23 | API asynchrone | `createSnapshot` via API renvoie `Operation` ; suivi jusqu'à `DONE` |
| T-ST-24 | Réversibilité | Export d'un volume en `qcow2` + objets via S3 standard ; réimport hors plateforme réussi |
| T-ST-25 | Audit & 18-07 | Opérations journalisées (acteur/horodatage) ; aucune copie (réplica/snapshot/sauvegarde) hors Alger/Constantine |

---

## Annexe A — Correspondance complète GCP ↔ KubeCenter ↔ Rook-Ceph / local

| Capacité Compute Engine (disks) | KubeCenter Storage | Implémentation |
|---|---|---|
| Temporary block storage (Local SSD) | Disque local éphémère `ku-disk-local` | TopoLVM / LocalPV sur NVMe (non répliqué) |
| RAM disk | Volume mémoire | tmpfs (`emptyDir{medium: Memory}`) |
| Durable block (Persistent Disk / Hyperdisk) | Disque persistant | PVC Ceph RBD (`csi-rbd`) |
| Disk types (standard/balanced/ssd/extreme) | `ku-disk-std/bal/perf` | `StorageClass` + `CephBlockPool` (device class hdd/ssd/nvme) |
| Hyperdisk tunable IOPS/throughput | Performance provisionnée | QoS RBD par image |
| Storage Pools | Pools de stockage | `CephBlockPool` / CRUSH rules / device classes |
| Portability (attach/detach, survive VM) | Portabilité | PVC indépendant + hotplug KubeVirt |
| Resize (increase) | Redimensionnement | expansion CSI (`allowVolumeExpansion`) |
| Change disk type | Changement de classe | recopie/clone vers la classe cible |
| Share disk / multi-writer | Partage | RBD RO multi-attach ; RWX via CephFS |
| Regional disk (sync 2 zones) | Multi-AZ synchrone | `CephCluster` stretch + moniteur arbitre |
| Asynchronous Replication (cross-region) | Réplication PRA | RBD mirroring (mode snapshot) → Constantine |
| Consistency groups | Groupes de cohérence | RBD mirror/consistency groups |
| Failover / failback | Bascule / retour | promotion/demotion RBD + cockpit PRA |
| Instant snapshot | Instantané rapide | snapshot RBD/CephFS natif (CoW) |
| Standard snapshot (DR) | Instantané de sauvegarde | VolumeSnapshot exporté + Velero → RGW |
| Snapshot schedules | Instantanés programmés | planificateur + opérateur snapshot |
| App-consistent snapshot (fsfreeze/VSS) | Instantané cohérent | `qemu-guest-agent` fs-freeze |
| Disk clone | Clone | clone CSI (`dataSource` PVC) |
| File server / distributed FS (NFS/SMB) | Fichier partagé | CephFS (`csi-cephfs`) + export NFS (`CephNFS`) |
| Cloud Storage (objet, adjacent) | Stockage objet | Ceph RGW (S3) + Object Lock |
| Disk encryption (Google-managed) | Chiffrement au repos | OSD LUKS + KMS interne |
| CMEK (Cloud KMS) | Clés gérées client | KMS client (phase ultérieure) |
| Data protection options / default backup | Options de protection | réglage par défaut + Velero + schedules |
| Monitor disk health / replica / pools | Supervision | exporter Ceph → LGTM ; alertes |
| Deletion protection | Protection suppression | finaliseur + admission |
| Billing (provisioned capacity + perf) | Facturation à l'usage | Go-mois + performance provisionnée |

---

*Fin du document — SPEC-KubeCenter-Storage v1.0. À lire conjointement avec SPEC-KubeCenter-VM et le CDC-PCA-PRA-K8S (lots Sécurité, Console self-service, PRA, Réseau underlay).*
