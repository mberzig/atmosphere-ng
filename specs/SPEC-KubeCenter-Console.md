# KubeCenter Console — Spécifications techniques de la console self-service & de l'API unifiée

**Version :** 1.0 — Juin 2026
**Statut :** Spécification d'ingénierie (destinée au développement assisté, type Claude Code)
**Référence amont :** CDC-PCA-PRA-K8S (Lot 15, `EXG-1701…1710`) ; surface unifiée par-dessus les modules **VM**, **Storage**, **Network**, **GPU**, **LLMaaS** et dépendance amont de l'**AppStore**.
**Modèle fonctionnel de référence :** Google Cloud Console (UI web) + Cloud APIs (Resource Manager, IAM) + `gcloud` (CLI) — utilisés comme grille de complétude.
**Contrainte de périmètre (explicite) :** ne sont spécifiées que les capacités réalisables avec le socle souverain retenu — **SPA Angular** + **API Python (Django-Ninja)** en **passthrough OIDC Keycloak**, s'appuyant sur les **API Kubernetes/Capsule** et les API des modules. Aucune dépendance à un service de console propriétaire étranger. Les options écartées sont justifiées au chapitre 14.

---

## 0. Préambule

### 0.1 Objet

KubeCenter Console est la **surface unique de libre-service** de la plateforme : un portail web et une API REST par lesquels les tenants gèrent leurs ressources (VM, disques, réseaux VPC, instantanés, sauvegardes, GPU, modèles LLM, applications) et par lesquels les opérateurs pilotent l'infrastructure, la continuité (PCA) et la reprise (PRA). Elle est **extensible par modules** et conçue pour rester **disponible précisément quand une région tombe** (classée T3).

### 0.2 Principe directeur

La console **agit avec l'identité de l'utilisateur connecté** : elle relaie son jeton OIDC aux API Kubernetes/Capsule/modules (**passthrough**). Il n'existe **aucun compte de service omnipotent** : un tenant ne peut jamais faire via la console ce que son RBAC lui interdit (`EXG-1701`). C'est l'inverse d'un portail qui appellerait l'API avec ses propres super-droits.

### 0.3 Socle technique retenu

| Couche | Composant |
|---|---|
| Frontend | **Angular** (SPA standalone, esbuild), design system maison cloud-console (responsive) |
| Backend / API | **Python Django-Ninja** (routage typé façon FastAPI, `HttpBearer`), sous **uvicorn/ASGI** (WebSocket VNC), **sans état** (pas d'ORM/DB) |
| Identité | **Keycloak** OIDC (Code/PKCE côté SPA ; jeton porté à chaque appel), **MFA** pour l'espace opérateur |
| Accès ressources | **client Kubernetes officiel** construit avec le **jeton de l'utilisateur** ; API server + Capsule + Kyverno appliquent le RBAC |
| Modules | registre extensible backend (`api/modules`) miroir du registre frontend (`modules/registry.ts`) |
| Console série/graphique | relais **WebSocket** noVNC ↔ subresource VNC KubeVirt (jeton utilisateur) |
| Packaging / déploiement | **chart Helm** + **ArgoCD**, classé **T3** (déployé sur Alger et Constantine) |
| Observabilité/audit | middleware d'audit (qui/quoi/quand) corrélé à l'audit API server ; liens Grafana/Hubble |

### 0.4 Synthèse des correspondances (détaillée en Annexe A)

| Concept Google Cloud | KubeCenter Console | Implémentation |
|---|---|---|
| Cloud Console (UI web) | Portail self-service | SPA Angular (espaces tenant/opérateur) |
| Sélecteur de projet | Sélecteur de projet (namespace) | `NamespaceService` (filtre listes + défaut formulaires) |
| Cloud APIs (REST) | API unifiée | Django-Ninja `/api/*`, ressources par module |
| Cloud IAM (identités/rôles) | Identité & accès | OIDC Keycloak + RBAC Kubernetes (lecture via le token) |
| gcloud (CLI) | CLI `kubecenter` | client de l'API unifiée (phase ultérieure) |
| Cloud Shell / SSH-in-browser | Console VNC/série navigateur | relais WebSocket ↔ VNC KubeVirt |
| Roles/permissions par produit | Modules par service | registre de modules (Calcul/Stockage/Réseau/…) |
| Audit Logs | Journal d'audit | middleware + audit API server |
| Disponibilité multi-région du portail | Console T3 | un déploiement ArgoCD par cluster (Alger + Constantine) |

---

## 1. Modèle de ressources & architecture

**EXG-CON-1000** — La console est organisée en **modules** ; chaque module expose des ressources d'un domaine (VM, disques, réseaux, etc.) via un **routeur backend** et un **composant frontend** enregistrés dans un registre commun. Ajouter un module = enregistrer une entrée, **sans refonte du cœur** (`EXG-1706`).

**EXG-CON-1001** — **Deux espaces strictement séparés** (`EXG-1707`) : **tenant** (libre-service) et **opérateur** (administration, MFA imposée). Le routage et la navigation ne présentent à l'opérateur que les modules autorisés à son groupe.

**EXG-CON-1002** — Toute ressource manipulée appartient à un **projet (namespace)** sélectionnable dans la barre supérieure ; les listes sont filtrées par projet et les formulaires pré-remplis avec le projet courant.

**EXG-CON-1003** — La console est **sans état** : l'état réside dans les API Kubernetes ; les sessions sont portées par OIDC. Aucune donnée tenant n'est stockée dans la console.

---

## 2. Authentification & sessions

**EXG-CON-1100** — **OIDC Keycloak** unique source d'identité. Le SPA s'authentifie en **Authorization Code + PKCE** (issuer Keycloak, scope `openid`) ; le **jeton d'accès est envoyé sur chaque appel** API. L'OIDC est initialisé avant le routage (APP_INITIALIZER) et les gardes (`authGuard`/`adminGuard`) déclenchent la connexion automatique.

**EXG-CON-1101** — Le backend valide le jeton (signature via le **JWKS** du realm, préchauffé au démarrage de chaque worker pour fiabiliser le 1ᵉʳ accès, dont le VNC), l'audience et l'émetteur. Jeton invalide/absent ⇒ `401`.

**EXG-CON-1102** — **MFA imposée** pour l'espace opérateur (`EXG-1506`) ; appliquée par Keycloak (politique d'authentification du groupe admin).

**EXG-CON-1103** — Déconnexion propre (révocation de session OIDC) ; durée de vie courte des jetons ; pas de secret long-vivant côté navigateur.

---

## 3. Autorisation

**EXG-CON-1200** — **Passthrough strict** (`EXG-1701`) : tout appel aux API (Kubernetes, Capsule, modules) est fait **avec le jeton de l'utilisateur**. Le ServiceAccount du pod console n'a **quasiment aucun droit** (servir HTTP + TokenReview). Un `403` renvoyé est celui du RBAC de l'utilisateur.

**EXG-CON-1201** — Les **rôles** proviennent des groupes Keycloak (`k8s-platform-admins`, `t-<tenant>-owners/devs/viewers`) mappés au RBAC Kubernetes/Capsule. La console **n'invente pas** de droits.

**EXG-CON-1202** — **Isolation inter-tenant** : un tenant ne voit/agit que sur ses namespaces (Capsule + RBAC). Vérifiée par le test T-14 du CDC.

---

## 4. Espace tenant (libre-service)

**EXG-CON-1300** — **Tableau de bord** : synthèse des ressources du tenant (compteurs VM/images/volumes/réseaux/namespaces) et liens (Grafana).

**EXG-CON-1301** — **Calcul** : gestion complète des **VM** (KubeVirt) — création par **assistant multi-étapes** (configuration machine / système & stockage / réseau / sécurité), cycle de vie (démarrer/arrêter/redémarrer/réinitialiser/suspendre/reprendre), **console VNC** navigateur, cloud-init, protection contre la suppression, redimensionnement, HA, tier PCA/PRA, placement par AZ, **disques additionnels à chaud**, **VM blindée**, **export qcow2**, **multi-NIC**, instantanés, clonage ; **catalogue de flavors** et **images OS**.

**EXG-CON-1302** — **Stockage** : volumes (PVC, classes, clone, protection, RWX, resize), **instantanés** (disque CSI et VM), **compartiments objet S3**.

**EXG-CON-1303** — **Réseau** : **réseaux VPC** (routeur virtuel + sous-réseaux CIDR/passerelle/NAT), **NAT & IP flottantes** (passerelle NAT, EIP, IP flottante, SNAT), **pare-feu** (groupes de sécurité), réseaux VM (NAD).

**EXG-CON-1304** — **Sauvegarde/restauration** self-service (`EXG-1708`) : déclenchement et restauration des sauvegardes Velero ; **suppression de sauvegarde impossible** (Object Lock, `EXG-1507`).

**EXG-CON-1305** — **Quotas** : visualisation des quotas du projet (capacité, objets) ; dépassement signalé.

**EXG-CON-1306** — **(Phase 2)** modules **ML/Notebooks/Inférence** (`EXG-2006`) et **AppStore** (`EXG-2104`) : mêmes conventions d'enregistrement de module.

---

## 5. Espace opérateur

**EXG-CON-1400** — **Infrastructure** : inventaire des **régions** (Alger primaire 2 AZ / Constantine PRA) et **zones (AZ)**, dérivé du topology des nœuds.

**EXG-CON-1401** — **Supervision** : KPIs cluster via **PromQL** (CPU/mémoire/pods/nœuds/PVC) ; liens Grafana ; journaux (Loki) à exposer.

**EXG-CON-1402** — **Identité & accès** : identité courante (claims OIDC) + attributions RBAC (bindings/rôles, sujet→rôle→portée).

**EXG-CON-1403** — **Protection des données** : sauvegardes/planifications/BSL Velero + sauvegarde à la demande.

**EXG-CON-1404** — **Module PRA** (`EXG-1709`) : (a) **tableau de bord DR-readiness** (lag mirroring RBD, fraîcheur export PVC↔RBD, état des réplications, dernier test PRA) ; (b) **configuration** (tier par tenant, ordre de démarrage `kubecenter.dz/start-order`, TTL DNS) ; (c) **déclenchement orchestré** du failover/failback **étape par étape**, chaque étape destructive exigeant une **confirmation go/no-go**, avec **main courante** générée automatiquement. **Règle absolue : la console est une interface de l'orchestrateur, jamais le seul chemin** — le bastion hors régions (`EXG-905`) reste autoritaire et testé à chaque exercice.

**EXG-CON-1405** — **Module PCA** (`EXG-1710`) : bascule actif-actif T3 (commit de l'`ApplicationSet`) + rapport de conformité multi-AZ.

---

## 6. Architecture extensible (modules)

**EXG-CON-1500** — **Registre de modules** : chaque module déclare `nom`, `titre`, `scope` (tenant/opérateur), `groupe`, `icône`, `composant`. La **navigation** (sidebar groupée par service) et les **routes** sont **dérivées du registre** ; les modules opérateur ne s'affichent qu'aux admins.

**EXG-CON-1501** — **Symétrie backend/frontend** : un module = un routeur backend (monté sous `/tenant` ou `/operator`) + un composant frontend. Le cœur (shell, auth, routage) ne change pas quand on ajoute un module.

**EXG-CON-1502** — **Phasage par MVP** (`EXG-1705`) : un module peut livrer en lecture seule puis ajouter les actions.

---

## 7. API unifiée

**EXG-CON-1600** — **API REST** sous `/api`, deux espaces : `/api/tenant/*` (tout utilisateur authentifié) et `/api/operator/*` (groupe admin). Ressources nommées par module (`vms`, `volumes`, `vpc`, `nat`, `firewall`, `snapshots`, `images`, `flavors`, `buckets`, `disk-snapshots`, …).

**EXG-CON-1601** — Verbes CRUD + **actions** explicites (`start`, `stop`, `resize`, `clone`, `attach/detach`, `export`, `snapshot`, `restore`, `failover`…). Les opérations longues s'appuient sur la réconciliation des contrôleurs (statut lu à la demande).

**EXG-CON-1602** — **Cohérence du modèle** : nom RFC 1123, libellés, statut ; erreurs renvoyées avec le code et le message du RBAC/API server (transparence des `403`/`409`).

**EXG-CON-1603** — **(SHOULD)** pagination, idempotence/ETag et objets `Operation` asynchrones à la GCE, à généraliser au fil des modules.

---

## 8. CLI & IaC

**EXG-CON-1700** — **CLI `kubecenter`** (phase ultérieure) : client de l'API unifiée, mêmes droits que l'utilisateur (jeton OIDC), couvrant les opérations self-service.

**EXG-CON-1701** — **GitOps comme source de vérité** : la console **n'est pas** un chemin parallèle non tracé — les ressources de plateforme restent décrites en Git (ArgoCD). La console agit sur les ressources tenant (CRD) avec le RBAC de l'utilisateur ; les opérations opérateur sensibles (PRA/PCA) pilotent l'orchestrateur, pas un état hors-Git.

---

## 9. Observabilité & audit

**EXG-CON-1800** — **Journal d'audit** (`EXG-1704`) : chaque action (qui/quoi/quand) est journalisée et **corrélée à l'audit de l'API server** (`EXG-1505`) ; consultable par le tenant pour ses ressources.

**EXG-CON-1801** — **Limitation de débit** et protection contre l'abus ; aucune action ne peut escalader au-delà du RBAC de l'utilisateur.

**EXG-CON-1802** — Liens vers la **supervision** (Grafana multi-tenant via `X-Scope-OrgID`) et les **flux réseau** (Hubble) sans exposer d'autres tenants.

---

## 10. Sécurité

**EXG-CON-1900** — **Aucun SA omnipotent** (rappel `EXG-1701`) ; le pod console tourne en `readOnlyRootFilesystem` (emptyDir `/tmp`), non-root.

**EXG-CON-1901** — **En-têtes de sécurité** (CSP, HSTS…), TLS par l'ingress (PKI interne / cert-manager), pas de secret en clair côté client.

**EXG-CON-1902** — **Chaîne d'approvisionnement** : images scannées (Trivy) et signées (cosign), tirées du registre interne (Harbor) ; build reproductible.

**EXG-CON-1903** — **Conformité loi 18-07 / ANPDP** : aucune donnée ni résolution hors Alger/Constantine ; la console n'appelle aucun service étranger.

---

## 11. Déploiement & disponibilité (T3)

**EXG-CON-2000** — **Sans état, 2 répliques réparties sur les AZ**, packagée en **chart Helm**, déployée par **ArgoCD**, classée **T3** : **un déploiement par région** (Alger et Constantine), de sorte que la console **fonctionne précisément lorsque Alger est perdue** (`EXG-1703`, espace opérateur **pleinement fonctionnel depuis Constantine**).

**EXG-CON-2001** — **GSLB** (DNS T3) pour l'hostname de la console ; bascule transparente inter-régions.

**EXG-CON-2002** — Mises à jour par GitOps (bump d'image dans les values → réconciliation ArgoCD) ; pas d'action manuelle de déploiement.

---

## 12. Expérience utilisateur

**EXG-CON-2100** — **UX cloud-console** (inspirée Horizon/GCP/AWS) : topbar sombre, **sidebar gauche groupée par service**, sélecteur de projet, cartes de synthèse, tableaux + badges d'état, **assistants multi-étapes** pour les créations riches (VM), **cockpit PRA** étape par étape.

**EXG-CON-2101** — **Responsive** : sidebar off-canvas (hamburger) + tableaux scrollables + formulaires empilés sur mobile/tablette.

**EXG-CON-2102** — Formulaires de création en **modale**, actions consolidées en **menus contextuels** (pas de surcharge de boutons) ; messages d'erreur explicites (transparence du RBAC).

---

## 13. Réversibilité & portabilité

**EXG-CON-2200** — **Réversibilité** : la console n'enferme aucune donnée (état = API Kubernetes, déclaratif/GitOps) ; export des configurations via les API standard des modules (qcow2 pour les VM, S3 pour l'objet, déclaratif pour le réseau).

**EXG-CON-2201** — La console reste **optionnelle** au fonctionnement : `kubectl`/GitOps/le bastion PRA restent des chemins autoritaires ; perdre la console ne bloque ni l'exploitation ni la reprise.

---

## 14. Options écartées (et justification)

| Option non retenue | Raison |
|---|---|
| **Console générique K8s (Lens / Headlamp / Rancher)** | Expose le cluster, pas un libre-service multi-tenant par identité ; pas d'espaces tenant/opérateur ni de modèle « jamais de SA omnipotent » |
| **OpenStack Horizon** | Lié au modèle OpenStack, pas Kubernetes/KubeVirt ; réécriture plus coûteuse qu'une SPA dédiée |
| **Backstage (portail développeur)** | Orienté catalogue/IDP, pas gestion d'instances/VM/réseau en libre-service ; lourdeur de plugins |
| **Dashboard Kubernetes officiel** | Vue cluster, pas multi-tenant souverain ; modèle de jeton/SA inadapté |
| **Backend Go + React** | **Choix client révisé** : Angular + Python/Django-Ninja (passthrough OIDC simple, client K8s officiel) |
| **Compte de service unique côté portail** | Brise l'isolation (`EXG-1701`) ; rejeté par conception |
| **Base de données/état applicatif** | La console reste **sans état** (état = API K8s) → portabilité, T3, pas de réplication d'une DB console |

---

## 15. Exigences — récapitulatif de traçabilité

Les exigences `EXG-CON-1000` à `EXG-CON-2201` constituent le référentiel traçable du module, rattachées au Lot 15 du CDC (`EXG-1701…1710`) et au socle §0.3. Priorité `MUST` (phase 1) sauf mention « phase ultérieure » = `SHOULD` (CLI `EXG-CON-1700`, modules ML/AppStore `EXG-CON-1306`, `Operation` async/ETag `EXG-CON-1603`).

Correspondance avec le CDC : `1701`→1200/1900 · `1702`→1301 · `1703`→0.3/2000 · `1704`→1800 · `1705`→1502 · `1706`→1500 · `1707`→1001 · `1708`→1304 · `1709`→1404 · `1710`→1405.

---

## 16. Tests d'acceptation

| ID | Objet | Critère de réussite |
|---|---|---|
| T-CON-01 | Connexion OIDC | Code/PKCE Keycloak ; jeton porté ; sans jeton `/api/*` = 401 |
| T-CON-02 | Passthrough RBAC | Une action interdite renvoie le `403` du RBAC de l'utilisateur (pas via un SA) |
| T-CON-03 | Isolation tenant | Un tenant ne voit/agit que sur ses namespaces ; aucun accès croisé (T-14) |
| T-CON-04 | MFA opérateur | L'espace opérateur exige la MFA (Keycloak) |
| T-CON-05 | Sélecteur de projet | Changer de projet filtre les listes et pré-remplit les formulaires |
| T-CON-06 | Assistant VM | Création multi-étapes → VM démarrée, branchée sur le sous-réseau choisi |
| T-CON-07 | Console VNC | Relais WebSocket ↔ VNC KubeVirt avec le jeton utilisateur ; greeting RFB |
| T-CON-08 | Cycle de vie | start/stop/restart/suspend/resume/reset appliqués via subresources |
| T-CON-09 | Stockage | Création/clone/snapshot/redimensionnement d'un volume ; compartiment S3 |
| T-CON-10 | Réseau VPC | Création VPC + sous-réseau + routeur ; pare-feu (règle entrée 443) |
| T-CON-11 | Sauvegarde | Restauration self-service ; suppression de sauvegarde impossible (Object Lock) |
| T-CON-12 | Module ajouté | Ajout d'un module = 1 routeur + 1 composant + 1 entrée registre, sans refonte |
| T-CON-13 | Cockpit PRA | Étapes go/no-go, main courante générée ; le bastion reste le chemin autoritaire |
| T-CON-14 | PCA actif-actif | Bascule T3 commitée via l'`ApplicationSet` ; rapport multi-AZ |
| T-CON-15 | Audit | Chaque action journalisée (acteur/horodatage), corrélée à l'audit API server |
| T-CON-16 | Disponibilité T3 | La console (et l'espace opérateur) fonctionne depuis Constantine quand Alger est perdue |
| T-CON-17 | Responsive | Navigation off-canvas + tableaux scrollables sur mobile |
| T-CON-18 | Sans état / réversibilité | Perte/redéploiement de la console sans perte d'état (état = API K8s) ; `kubectl`/GitOps inchangés |
| T-CON-19 | Supply chain | Images scannées + signées, tirées de Harbor ; pod non-root, FS lecture seule |
| T-CON-20 | Conformité 18-07 | Aucun appel/résolution hors Alger/Constantine |

---

## Annexe A — Correspondance Google Cloud Console / Cloud APIs ↔ KubeCenter Console ↔ implémentation

| Capacité Google Cloud | KubeCenter Console | Implémentation |
|---|---|---|
| Cloud Console (UI web) | Portail self-service | SPA Angular (tenant/opérateur) |
| Project selector | Sélecteur de projet | `NamespaceService` |
| Cloud IAM | Identité & accès | OIDC Keycloak + RBAC (lecture via le token) |
| Cloud APIs (REST) | API unifiée | Django-Ninja `/api/tenant` + `/api/operator` |
| gcloud (CLI) | CLI `kubecenter` | client de l'API (phase ultérieure) |
| Cloud Shell / SSH-in-browser | Console VNC/série | relais WebSocket ↔ VNC KubeVirt |
| Compute / Disks / VPC consoles | Modules Calcul/Stockage/Réseau | KubeVirt / Rook-Ceph / Kube-OVN via le token |
| Backup and DR | Protection des données + Cockpit PRA | Velero + orchestrateur PRA (interface, pas seul chemin) |
| Monitoring (Cloud Monitoring) | Supervision | PromQL → kube-prometheus + liens Grafana |
| Audit Logs | Journal d'audit | middleware + audit API server |
| Multi-region console availability | Console T3 | un déploiement ArgoCD par région (Alger+Constantine) + GSLB |
| Service accounts (portail) | — (écarté) | passthrough du jeton utilisateur, jamais de SA omnipotent |
| Resource Manager (hiérarchie) | Projets = namespaces, org = tenants Capsule | Capsule + RBAC |

---

*Fin du document — SPEC-KubeCenter-Console v1.0. Dernier module du corpus. À lire conjointement avec le CDC-PCA-PRA-K8S (Lot 15) et les specs VM/Storage/Network/GPU/LLMaaS/AppStore — la console est leur surface unifiée et la dépendance amont de l'AppStore.*
