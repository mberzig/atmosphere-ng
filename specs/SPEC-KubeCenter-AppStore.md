# KubeCenter AppStore — Spécifications techniques du module catalogue d'applications

**Version :** 1.0 — Juin 2026
**Statut :** Spécification d'ingénierie (destinée au développement assisté, type Claude Code)
**Référence amont :** CDC-PCA-PRA-K8S ; s'appuie sur **Console** (surface unifiée), **VM**, **Storage**, **Network**, **GPU/LLMaaS** (selon les apps).
**Modèle fonctionnel de référence :** Google Cloud Marketplace — *Kubernetes apps* (grille de complétude).
**Décisions structurantes (actées dans ce projet) :** soft multi-tenancy (Capsule) ; **catalogue central, instances par namespace** ; **sourcing de charts officiels uniquement** ; **mirroring Harbor obligatoire** ; admission **Kyverno zéro-privilège cluster-wide par défaut**. Phase 1 = **catalogue first-party open source** ; les apps tierces propriétaires sont écartées (chapitre 15).

---

## 0. Préambule

### 0.1 Objet

KubeCenter AppStore est le catalogue d'applications managées de la plateforme : il permet à un tenant de déployer en libre-service, en quelques clics, des applications open source populaires et bien maintenues (WordPress, Odoo, bases de données, outils…) dans son propre projet (namespace), avec persistance, exposition réseau, sauvegarde et facturation intégrées — sans connaître Helm ni Kubernetes.

### 0.2 Principe directeur

Comme Cloud Marketplace, une « app » n'est pas qu'une image : c'est un **package** (chart Helm curé + images + métadonnées + paramètres + plan tarifaire). Le **catalogue est central** (vitrine + métadonnées + curation), mais chaque **instance déployée atterrit dans le namespace du tenant** et y est gérée comme un groupe d'objets unique — exactement le pattern « cloud-native par namespace » retenu pour les surfaces de charge.

### 0.3 Socle technique retenu

| Capacité | Composant |
|---|---|
| Registre d'images & charts | **Harbor** (mirroring obligatoire des images et charts OCI ; scan Trivy ; signature cosign ; SBOM) |
| Packaging | **chart Helm curé** (ou Kustomize) versionné, paramétrable |
| Déploiement & cycle de vie | **ArgoCD** — une `Application` ArgoCD par instance (regroupement, suivi, mise à jour, suppression d'un bloc) |
| Garde-fous | **Kyverno** (admission : zéro privilège cluster-wide par défaut, images signées, registre Harbor uniquement) |
| Multi-tenancy / IAM | **Capsule** (Tenant/namespace) + **Keycloak** (OIDC) |
| Persistance | PVC **Ceph RBD/CephFS** (renvoi Storage) + sauvegarde **Velero** |
| Exposition | ingress + **cert-manager** (TLS) + DNS (renvoi Network) |
| Facturation | comptage des ressources de l'instance → **Odoo** (à l'usage) |
| Surface utilisateur | **Console KubeCenter** (catalogue, déploiement guidé, gestion) |

### 0.4 Synthèse des correspondances (détaillée en Annexe A)

| Concept Cloud Marketplace | KubeCenter AppStore | Implémentation |
|---|---|---|
| Catalogue / vitrine | Catalogue d'apps | métadonnées curées + Console |
| Kubernetes app (images + chart) | Package d'app | chart Helm curé + images (Harbor) |
| Application resource (CRD) | Instance gérée comme un groupe | `Application` ArgoCD |
| Déploiement vers cluster + namespace | Déploiement dans le namespace tenant | rendu ArgoCD dans le namespace |
| Instance name (unique dans le namespace) | Nom d'instance | nom unique par namespace |
| Plan tarifaire / abonnement | Plan tarifaire | plan + comptage → Odoo |
| Licence injectée | Licence/paramètres | secrets/values de l'instance |
| ClusterRole nettoyés par la console | Privilèges contrôlés | refus/validation Kyverno |
| Portabilité (on-prem / autres clouds) | Portabilité | charts/images standard, pas de lock-in |

---

## 1. Modèle de ressources

**EXG-APP-1000** — L'API expose : `Apps` (entrées de catalogue), `AppVersions` (versions publiées), `Plans` (tarifaires), `AppInstances` (déploiements dans un namespace), `Categories`. Identifiant stable, nom RFC 1123, libellés, horodatages.

**EXG-APP-1001** — Le **catalogue** est une ressource de plateforme (curée par l'opérateur), visible par les tenants selon leur politique ; les **instances** sont des ressources du tenant, isolées dans son namespace.

**EXG-APP-1002** — Chaque instance porte le libellé `kubecenter.dz/dr-tier` (T0–T3), hérité du projet ou choisi au déploiement, déterminant sa protection (chapitre 11).

---

## 2. Catalogue et curation

**EXG-APP-1100** — **Carte d'app** : chaque entrée publie nom, description, éditeur/communauté source, licence (open source), logo, catégorie, versions disponibles, ressources requises (UC, stockage, éventuellement UC-GPU), dépendances (ex. base de données), et plan tarifaire.

**EXG-APP-1101** — **Règle de sourcing (critique)** : seuls sont admis au catalogue les packages dont le **chart Helm est officiel et activement maintenu** par le projet ou son éditeur, OU un chart **curé et maintenu en propre par KubeCenter**. Les charts d'agrégateurs fragilisés ou non maintenus sont **proscrits** — en particulier les charts/images Bitnami du tier gratuit (dépréciés/figés depuis septembre 2025, sans mises à jour de sécurité).

**EXG-APP-1102** — **Versions** : chaque app publie plusieurs versions avec un **alias de version stable** ; les versions obsolètes/vulnérables sont dépubliées (retrait du catalogue) sans casser les instances existantes (fenêtre de migration annoncée).

**EXG-APP-1103** — **Catégories** (≈ catégories Marketplace) : au minimum CMS/web, ERP/gestion, bases de données, stockage/objet, outils/DevOps, data/IA.

**EXG-APP-1104** — **Catalogue first-party uniquement (phase 1)** : apps open source curées par l'opérateur ; le catalogue tiers/éditeurs (apps commerciales) est une évolution ultérieure (chapitre 15).

---

## 3. Chaîne d'approvisionnement (sourcing & sécurité)

**EXG-APP-1200** — **Mirroring Harbor obligatoire** : toutes les images et tous les charts OCI servis par l'AppStore sont **mirrorés dans Harbor** ; aucune instance ne tire directement depuis Docker Hub ou un registre externe (protection contre disparition de dépôt, rate-limiting, et exigence air-gap).

**EXG-APP-1201** — **Analyse de vulnérabilités** : chaque image est scannée (Trivy/Harbor) avant publication ; une app dont les images dépassent un seuil de CVE critiques n'est pas publiée (ou est marquée à corriger).

**EXG-APP-1202** — **Signature & provenance** : images et charts signés (cosign) et vérifiés à l'admission (Kyverno `verifyImages`) ; **SBOM** associé à chaque version.

**EXG-APP-1203** — **Reproductibilité** : la définition d'une version d'app (chart + images épinglées par digest + valeurs par défaut) est versionnée en Git (GitOps) ; toute publication est traçable.

---

## 4. Packaging des apps

**EXG-APP-1300** — **Format** : une app est packagée en **chart Helm** (par défaut) ou Kustomize, avec un schéma de **valeurs paramétrables** exposées au tenant (taille, identifiants, options) et des valeurs sûres par défaut.

**EXG-APP-1301** — **Instance gérée comme un groupe** (≈ *Application resource* GCP) : chaque déploiement est matérialisé par une **`Application` ArgoCD** qui regroupe tous les objets (Deployment, Service, PVC, Secret, Ingress…), permettant de les voir, mettre à jour et supprimer comme un tout.

**EXG-APP-1302** — **Dépendances** : une app peut déclarer des dépendances (ex. PostgreSQL pour Odoo, MariaDB pour WordPress) déployées **dans le même namespace** comme sous-composants de l'instance (pas de service partagé inter-tenants par défaut).

**EXG-APP-1303** — **Apps à base d'image VM** (secondaire) : une app peut, en option, être livrée comme **image VM** (golden image KubeVirt) plutôt que conteneur — pour les logiciels non conteneurisables ; même mécanisme de catalogue/instance.

---

## 5. Déploiement

**EXG-APP-1400** — **Déploiement guidé** : depuis la Console, le tenant choisit une app, une version, un **plan**, le **namespace** cible (un de ses projets), un **nom d'instance unique dans le namespace**, et renseigne les paramètres exposés ; un récapitulatif (ressources, coût estimé) précède la confirmation.

**EXG-APP-1401** — **Rendu** : la plateforme crée une `Application` ArgoCD ciblant le namespace ; ArgoCD synchronise les objets ; l'opération est **asynchrone** (`Operation`) avec suivi d'état jusqu'à « déployée et saine ».

**EXG-APP-1402** — **Pré-vérifications** : quotas du namespace suffisants (UC/stockage), conformité de l'app à la politique du tenant, et validation d'admission (chapitre 7) avant tout déploiement ; échec motivé sinon.

**EXG-APP-1403** — **Idempotence** : un même nom d'instance dans un namespace ne peut être déployé deux fois ; reprise propre en cas d'échec partiel.

---

## 6. Cycle de vie des instances

**EXG-APP-1500** — **Mise à jour** : passage d'une instance à une version supérieure de l'app (mise à jour du chart/images), avec stratégie maîtrisée (sauvegarde préalable recommandée pour les apps stateful) et possibilité de **rollback** (révision ArgoCD).

**EXG-APP-1501** — **Reconfiguration** : modification des paramètres exposés (taille, options) d'une instance en place.

**EXG-APP-1502** — **Suppression d'un bloc** : suppression de l'instance supprimant proprement tous ses objets (et, sur option explicite, ses volumes), via la suppression de l'`Application` ArgoCD ; les éventuels droits élevés associés sont retirés (chapitre 7).

**EXG-APP-1503** — **État & santé** : chaque instance expose son état agrégé (synchronisée, saine, dégradée) et celui de ses composants, consultable en Console et via l'API.

---

## 7. Sécurité et privilèges

**EXG-APP-1600** — **Zéro privilège cluster-wide par défaut** : Kyverno **refuse** à l'admission tout objet d'une instance demandant des droits cluster-wide (`ClusterRole`/`ClusterRoleBinding`, `hostPath`, `hostNetwork`, privilèges conteneur). Les apps du catalogue first-party sont conçues pour fonctionner **confinées au namespace**.

**EXG-APP-1601** — **Privilège exceptionnel gouverné** : une app nécessitant un droit particulier doit le **déclarer explicitement** dans sa carte ; un tel package fait l'objet d'une **revue et d'une validation administrateur** avant publication, et les droits accordés sont tracés et révoqués à la suppression de l'instance. (Là où Google nettoie a posteriori, KubeCenter contrôle a priori.)

**EXG-APP-1602** — **Confinement** : chaque instance s'exécute sous un compte de service à privilèges minimaux, dans le namespace du tenant, soumise aux NetworkPolicy « deny » par défaut (renvoi Network) et aux quotas du projet.

**EXG-APP-1603** — **Secrets** : identifiants et secrets d'instance gérés via le coffre/PKI interne ; jamais en clair dans les valeurs ; rotation possible.

**EXG-APP-1604** — **Isolation inter-tenants** : aucune instance d'un tenant n'est visible, joignable ou modifiable par un autre ; dépendances (bases de données) internes à l'instance.

**EXG-APP-1605** — **Audit** : déploiement, mise à jour, reconfiguration, suppression et octroi de privilège journalisés (acteur, horodatage), consultables par le tenant.

---

## 8. Persistance et données

**EXG-APP-1700** — **Stockage** : les apps stateful provisionnent des volumes **Ceph RBD** (RWO) ou **CephFS** (RWX) via les classes du module Storage ; redimensionnables, snapshotables.

**EXG-APP-1701** — **Sauvegarde** : intégration **Velero** — sauvegarde application-cohérente de l'instance (objets + PVC) vers RGW (Object Lock), selon le plan du tier ; restauration au niveau instance.

**EXG-APP-1702** — **Cohérence** : pour les apps à base de données (Odoo/PostgreSQL, WordPress/MariaDB), gel/quiescence applicative recommandé avant snapshot (hooks de sauvegarde) pour garantir la cohérence.

---

## 9. Réseau et exposition

**EXG-APP-1800** — **Exposition web** : une app exposable obtient une route ingress avec **TLS** (cert-manager/PKI interne) et un nom DNS (zone du tenant) ; exposition interne (réseau tenant) par défaut, externe (IP flottante) sur demande explicite (renvoi Network).

**EXG-APP-1801** — **Connectivité** : les instances respectent la micro-segmentation du tenant ; accès aux services de plateforme (S3 RGW, LLMaaS) via **endpoints privés** lorsque l'app le requiert.

---

## 10. Facturation et licences

**EXG-APP-1900** — **Modèle de coût (apps open source)** : l'app elle-même est gratuite ; le tenant paie les **ressources consommées** par l'instance (UC, stockage Go-mois, IP flottante, UC-GPU le cas échéant), mesurées dans son namespace et exportées vers **Odoo**.

**EXG-APP-1901** — **Plans tarifaires** : une app peut proposer plusieurs plans (tailles prédéfinies → packs de ressources) ; le coût estimé est affiché avant déploiement.

**EXG-APP-1902** — **Découplage licence** (≈ Marketplace) : pour une future app commerciale, le mécanisme prévoit l'injection d'une licence/abonnement distincte de la facturation des ressources — non activé en phase 1 (catalogue open source).

---

## 11. Multi-AZ, continuité et PRA

**EXG-APP-2000** — Les instances héritent du **tier** : sauvegarde/réplication et bascule conformes (T0 multi-AZ ; T2 réplication vers Constantine ; etc.), réutilisant les mécanismes Storage/PRA.

**EXG-APP-2001** — **Reconstruction PRA** : la définition d'une instance (Application ArgoCD + valeurs) étant en GitOps et ses données répliquées, l'instance est reconstructible à l'identique en région PRA lors d'un sinistre ; testée lors des exercices de bascule.

---

## 12. Observabilité

**EXG-APP-2100** — **Tableau de bord d'instances** : liste des apps déployées par projet, état/santé, version, ressources consommées, coût ; alertes (déploiement échoué, instance dégradée, sauvegarde manquée, version vulnérable).

**EXG-APP-2101** — **Logs & métriques** : accès aux journaux et métriques des composants d'une instance (Loki/Prometheus → LGTM), filtrés par tenant.

---

## 13. Catalogue initial priorisé

**EXG-APP-2200** — Ordre d'intégration recommandé (du plus simple au plus engageant) :

| Priorité | App | Rôle dans la montée en charge |
|---|---|---|
| 1 | **WordPress** | « hello world » du pipeline AppStore (catalogue → instance namespace → ingress/TLS → sauvegarde → facturation) ; app web légère, ultra-documentée |
| 2 | **Odoo** (Community) | 1ʳᵉ app stateful sérieuse (ERP) ; valide PostgreSQL persistant, sauvegarde cohérente, tiers de continuité ; déjà maîtrisée (moteur de facturation interne) |
| 3 | **Briques de soutien** | PostgreSQL, MariaDB, Redis, MinIO/objet, Nextcloud… (dépendances réutilisables), chacune sur chart officiel/communautaire actif |
| 4+ | Élargissement | outils data/DevOps, autres CMS, selon demande |

**EXG-APP-2201** — Pour chaque app intégrée : chart officiel/curé, images mirrorées Harbor + scannées + signées, valeurs par défaut sûres, dépendances confinées au namespace, hooks de sauvegarde, carte d'app complète, et passage des tests d'acceptation.

---

## 14. Alignement au cahier des charges initial (CDC-PCA-PRA-K8S)

**EXG-APP-2300** — Traçabilité :

| Élément du CDC / décisions projet | Couverture AppStore |
|---|---|
| Soft multi-tenancy (Capsule) | Ch. 0.2, 7 (confinement namespace) |
| GitOps ArgoCD | Ch. 4–6 (Application ArgoCD) |
| Registre Harbor + sécurité supply chain | Ch. 3 (mirroring, scan, signature) |
| Stockage Ceph + sauvegarde Velero | Ch. 8 |
| Réseau (ingress, endpoints privés, segmentation) | Ch. 9 |
| Facturation Odoo | Ch. 10 |
| PRA / tiers | Ch. 11 |
| Console self-service | Ch. 5 (déploiement guidé) |

**EXG-APP-2301** — Aucune brique AppStore ne contredit les décisions actées (soft multi-tenancy, catalogue central/instances per-namespace, sourcing officiel, mirroring Harbor, Kyverno zéro-privilège, 18-07).

---

## 15. Options écartées (et justification)

| Élément (Cloud Marketplace) non retenu | Raison |
|---|---|
| **Apps tierces commerciales / éditeurs (ISV)** | Phase ultérieure ; complexité contractuelle/licence ; phase 1 = first-party open source |
| **Charts/images Bitnami du tier gratuit** | Dépréciés/figés (sept. 2025), sans mises à jour de sécurité → risque supply chain inacceptable |
| **Pull direct depuis Docker Hub / registres externes** | Interdit ; mirroring Harbor obligatoire (résilience, air-gap, scan) |
| **Apps SaaS tierces (hébergées hors plateforme)** | Contraire à la souveraineté ; tout s'exécute sur KubeCenter |
| **Déploiement vers d'autres clouds (type Anthos)** | Hors périmètre souverain (mono-plateforme Alger/Constantine) |
| **Octroi automatique de privilèges cluster-wide** | Remplacé par refus/validation gouvernée (Kyverno) |
| **Place de marché de revente / monétisation tierce** | Hors phase 1 |

---

## 16. Exigences — récapitulatif de traçabilité

Les exigences `EXG-APP-1000` à `EXG-APP-2301` constituent le référentiel traçable du module. Chacune est vérifiable (chapitre 17), rattachée à un composant (§0.3) et priorisée `MUST` (phase 1) sauf : apps à base d'image VM (1303), découplage licence commerciale (1902), catalogue tiers/ISV — `SHOULD`/phase ultérieure.

---

## 17. Tests d'acceptation

| ID | Objet | Critère de réussite |
|---|---|---|
| T-APP-01 | Catalogue | Le catalogue liste les apps autorisées au tenant avec cartes complètes (licence, ressources, plan) |
| T-APP-02 | Sourcing | Aucune app publiée ne référence un chart/image Bitnami gratuit déprécié ; toutes les images proviennent de Harbor |
| T-APP-03 | Supply chain | Image avec CVE critique au-dessus du seuil → publication bloquée ; signature vérifiée à l'admission |
| T-APP-04 | Déploiement WordPress | WordPress déployé dans le namespace tenant, accessible en HTTPS (cert interne) en quelques minutes |
| T-APP-05 | Instance = groupe | Tous les objets de l'instance regroupés sous une `Application` ArgoCD ; état agrégé visible |
| T-APP-06 | Nom unique | Deux instances de même nom dans un namespace refusées ; noms identiques tolérés dans des namespaces distincts |
| T-APP-07 | Déploiement Odoo | Odoo Community + PostgreSQL déployés dans le namespace ; persistance sur Ceph ; UI accessible |
| T-APP-08 | Dépendances confinées | La base de données d'Odoo/WordPress est interne au namespace de l'instance, non partagée |
| T-APP-09 | Zéro privilège | Une app demandant ClusterRole/hostPath est refusée à l'admission (Kyverno) avec message |
| T-APP-10 | Privilège gouverné | Une app à privilège déclaré nécessite validation admin ; droits retirés à la suppression |
| T-APP-11 | Quotas | Déploiement bloqué si quotas namespace insuffisants ; message explicite |
| T-APP-12 | Mise à jour | Montée de version d'une instance avec sauvegarde préalable ; rollback fonctionnel |
| T-APP-13 | Reconfiguration | Changement de taille/option d'une instance appliqué en place |
| T-APP-14 | Suppression | Suppression de l'instance retirant tous les objets (et volumes sur option) proprement |
| T-APP-15 | Persistance & sauvegarde | Sauvegarde Velero cohérente d'Odoo (objets + PVC) vers RGW ; restauration intégrale |
| T-APP-16 | Cohérence DB | Snapshot avec quiescence applicative → base cohérente après restauration |
| T-APP-17 | Exposition | Ingress + TLS interne par défaut ; exposition externe seulement sur IP flottante explicite |
| T-APP-18 | Endpoints privés | Une app accède au S3 RGW via endpoint privé sans IP externe |
| T-APP-19 | Facturation | Ressources consommées par l'instance mesurées dans le namespace et exportées vers Odoo |
| T-APP-20 | Coût estimé | Estimation de coût affichée avant déploiement, cohérente avec le plan choisi |
| T-APP-21 | Isolation | Aucune instance visible/joignable entre deux tenants |
| T-APP-22 | PRA | Instance T2 reconstruite à Constantine après sinistre ; données restaurées ; RPO/RTO respectés |
| T-APP-23 | Observabilité | Tableau de bord d'instances (état/version/coût) exact ; alerte sur instance dégradée |
| T-APP-24 | Version vulnérable | App marquée vulnérable dépubliée du catalogue sans casser les instances existantes |
| T-APP-25 | Audit & 18-07 | Opérations journalisées ; toutes les données d'instance résident à Alger/Constantine |

---

## Annexe A — Correspondance Cloud Marketplace ↔ KubeCenter AppStore ↔ implémentation

| Capacité Cloud Marketplace | KubeCenter AppStore | Implémentation |
|---|---|---|
| Catalogue / vitrine | Catalogue d'apps | métadonnées curées + Console |
| Kubernetes app (images + chart) | Package d'app | chart Helm curé + images Harbor |
| Application resource (CRD, groupe) | Instance gérée comme un groupe | `Application` ArgoCD |
| Deploy to cluster + select namespace | Déploiement dans le namespace | rendu ArgoCD ciblant le namespace |
| Instance name (unique/namespace) | Nom d'instance | unicité par namespace |
| Helm packaging | Packaging | Helm (ou Kustomize) |
| Billing plan / subscription | Plan tarifaire | plan + comptage → Odoo |
| License file injection | Licence/paramètres | secrets/values (commercial ultérieur) |
| Elevated privileges → ClusterRole (nettoyés) | Privilèges contrôlés | refus/validation Kyverno (a priori) |
| Deploy on-prem / other clouds | (écarté) | mono-plateforme souveraine |
| Commercial ISV apps | (écarté phase 1) | catalogue first-party open source |
| Image/chart registry | Registre | Harbor (mirroring + scan + signature) |

---

*Fin du document — SPEC-KubeCenter-AppStore v1.0. À lire conjointement avec SPEC-KubeCenter-Console (à venir), VM, Storage, Network, GPU, LLMaaS et le CDC-PCA-PRA-K8S (lots Stockage, Sécurité, PRA, Console, GitOps/Registre).*
