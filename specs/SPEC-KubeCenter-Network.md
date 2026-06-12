# KubeCenter Network — Spécifications techniques du module réseau

**Version :** 1.0 — Juin 2026
**Statut :** Spécification d'ingénierie (destinée au développement assisté, type Claude Code)
**Référence amont :** CDC-PCA-PRA-K8S (Lots Réseau underlay & Sécurité) ; complément des modules **KubeCenter VM** et **KubeCenter Storage**.
**Modèle fonctionnel de référence :** Google Cloud Virtual Private Cloud (VPC) — utilisé comme grille de complétude.
**Contrainte de périmètre :** ne sont spécifiées que les capacités réalisables avec le socle réseau souverain retenu (Multus + OVN-Kubernetes, Cilium, MetalLB/OVN, PowerDNS/BIND9, pare-feu/VPN OPNsense) au-dessus du fabric **spine/leaf SONiC (eBGP + EVPN-VXLAN, MC-LAG)**. Les fonctions VPC propres à l'infrastructure mondiale de Google sont écartées et justifiées au chapitre 16.

---

## 0. Préambule

### 0.1 Objet

KubeCenter Network fournit la connectivité des instances, conteneurs et services de la plateforme : réseaux privés multi-tenant isolés, sous-réseaux, routage, pare-feu distribué, NAT, équilibrage de charge, DNS interne, accès privé aux services de la plateforme, et connectivité hybride (VPN) vers les sites des clients — le tout cloisonné par tenant et conforme à la loi 18-07.

### 0.2 Principe directeur

Un « VPC » GCP est un réseau privé global et logiciel. KubeCenter en reprend la sémantique (réseaux, sous-réseaux, routes, pare-feu, IP, DNS, appairage, accès privé) mais à l'échelle **régionale** (Alger, Constantine) sur un overlay OVN porté par un underlay physique EVPN-VXLAN. La différence majeure assumée : KubeCenter est **régional**, pas mondial (chapitre 16).

### 0.3 Socle technique retenu

| Couche | Composant |
|---|---|
| Réseaux/sous-réseaux tenant (overlay) | OVN-Kubernetes via Multus — `NetworkAttachmentDefinition`, logical switches/routers OVN (Geneve) |
| Politique réseau L3/L4 (et L7) | Cilium — `CiliumNetworkPolicy` / `CiliumClusterwideNetworkPolicy` ; observabilité Hubble |
| IP flottantes / équilibrage L4 | MetalLB (BGP) ou OVN LB ; annonce vers le fabric |
| Ingress L7 (HTTP/S) | contrôleur d'ingress mutualisé (Envoy/Ingress-NGINX) + cert-manager |
| Routage dynamique | eBGP entre OVN gateways et le fabric ; EVPN-VXLAN dans l'underlay |
| Pare-feu périmétrique & VPN | OPNsense (IPsec site-à-site, filtrage de bordure) |
| DNS interne & GSLB | PowerDNS/BIND9 ; bascule inter-régions par GSLB |
| Underlay physique | fabric spine/leaf **SONiC** : eBGP, EVPN-VXLAN, MC-LAG, OOB/BMC isolé (cf. Lot underlay) |
| Multi-tenancy / IAM | Capsule (Tenant) + Kyverno (admission) + Keycloak (OIDC) |
| Observabilité | flow logs OVN/Hubble → pile LGTM ; tests de connectivité |

### 0.4 Synthèse des correspondances (détaillée en Annexe A)

| Concept GCP VPC | KubeCenter Network | Implémentation |
|---|---|---|
| VPC network | Réseau tenant | OVN logical router/switch (`NetworkAttachmentDefinition`) |
| Subnet | Sous-réseau | OVN logical switch + CIDR |
| Routes (system/static/dynamic) | Routes | routes OVN + eBGP/EVPN underlay |
| Firewall rules / Cloud NGFW | Groupes de sécurité | `CiliumNetworkPolicy` (L3/L4/L7) |
| Cloud NAT | Passerelle NAT | OVN SNAT / gateway NAT mutualisée |
| Cloud Load Balancing | Équilibrage L4/L7 | MetalLB/OVN LB (L4) + ingress (L7) |
| Cloud DNS (privé) | DNS interne | PowerDNS/BIND9, zones privées par tenant |
| IP addresses (int/ext, static/ephemeral) | Adresses IP | IPAM OVN + IP flottantes annoncées en BGP |
| Alias IP ranges | Plages d'alias | OVN secondary ranges |
| VPC Network Peering | Appairage de réseaux | interconnexion de routeurs logiques OVN |
| Shared VPC | Réseau partagé | réseau d'org partagé entre projets (Capsule) |
| Private Service Connect / Private Google Access | Accès privé aux services | endpoints privés vers API/S3/registre/LLMaaS |
| Cloud Router (BGP) | Routeur dynamique | sessions eBGP OVN ↔ fabric |
| Cloud VPN | VPN site-à-site | IPsec (OPNsense) |
| VPC Flow Logs / Network Intelligence | Observabilité réseau | flow logs OVN + Hubble + tests de connectivité |

---

## 1. Modèle de ressources

**EXG-NET-1000** — L'API expose, par projet (tenant) : `Réseaux`, `Sous-réseaux`, `Routes`, `RèglesPareFeu` (groupes de sécurité), `AdressesIP`, `PasserellesNAT`, `Équilibreurs`, `ZonesDNS`, `Appairages`, `EndpointsPrivés`, `TunnelsVPN`. Identifiant stable, nom RFC 1123, libellés, horodatages.

**EXG-NET-1001** — Isolation stricte inter-tenants : aucun trafic, aucune route et aucune résolution DNS ne traversent la frontière d'un tenant sans appairage explicite. Posture par défaut « deny » (RBAC + Kyverno + politique réseau par défaut).

**EXG-NET-1002** — Chaque réseau/sous-réseau porte le libellé `kubecenter.dz/dr-tier` afin d'aligner sa stratégie de bascule réseau (chapitre 12).

---

## 2. Réseaux et sous-réseaux

**EXG-NET-1100** — **Réseau tenant** (équiv. *VPC network*) : conteneur d'adressage privé isolé (OVN logical router), en **mode personnalisé** uniquement — les sous-réseaux sont créés explicitement par le tenant (pas de mode auto), conformément aux bonnes pratiques.

**EXG-NET-1101** — **Sous-réseaux** (équiv. *subnets*) : chaque sous-réseau possède une plage CIDR primaire et, optionnellement, des **plages secondaires** (équiv. *alias IP ranges*) pour les charges conteneurisées. Un sous-réseau est rattaché à une région ; il peut s'étendre sur les deux AZ d'Alger (cf. chapitre 12).

**EXG-NET-1102** — **IPv4 et IPv6** : sous-réseaux IPv4 (RFC 1918) et, en option, double pile IPv4/IPv6. Validation anti-chevauchement des CIDR à l'admission.

**EXG-NET-1103** — **MTU** configurable par réseau (jusqu'au jumbo), cohérente avec l'encapsulation Geneve/VXLAN de l'underlay (provisionnement MTU underlay supérieur pour absorber l'overhead).

**EXG-NET-1104** — Création/modification déclaratives (GitOps/ArgoCD) ; toute opération est asynchrone (`Operation`) et journalisée.

---

## 3. Adressage IP

**EXG-NET-1200** — **IP interne** : attribuée automatiquement (éphémère) ou réservée (statique) dans le sous-réseau ; IPAM géré par la plateforme.

**EXG-NET-1201** — **IP flottante externe** (équiv. *external IP*) : réservable, statique ou éphémère, ré-attribuable entre instances/équilibreurs ; annoncée vers le fabric via BGP (MetalLB/OVN). Aucune IP externe n'est attribuée par défaut.

**EXG-NET-1202** — **Plages d'alias** (équiv. *alias IP ranges*) : plusieurs plages IP par interface, pour exposer des services/conteneurs distincts sur une même instance.

**EXG-NET-1203** — **Pools d'adresses** : pools publics (routables vers l'extérieur via l'opérateur) et privés gérés et quotás par tenant.

---

## 4. Routage

**EXG-NET-1300** — **Routes système** : routes implicites de sous-réseau (connectivité intra-réseau) créées automatiquement.

**EXG-NET-1301** — **Routes statiques personnalisées** (équiv. *custom static routes*) : destination CIDR → saut suivant (instance, passerelle, tunnel VPN), avec priorité (métrique) et étiquettes d'application.

**EXG-NET-1302** — **Route par défaut** vers la passerelle Internet/NAT, supprimable pour des sous-réseaux totalement privés (air-gap logique).

**EXG-NET-1303** — **Routage dynamique** (équiv. *Cloud Router*) : sessions **eBGP** entre les gateways OVN et le fabric SONiC ; l'underlay diffuse les préfixes via **EVPN-VXLAN**. Le mode de routage régional (annonce intra-région) est le défaut ; l'inter-région (Alger↔Constantine) emprunte les liens DCI.

**EXG-NET-1304** — Résolution des conflits par longueur de préfixe puis priorité ; prévention des boucles (l'incident de boucle L2 par MAC anycast bouclée diagnostiqué côté SONiC est explicitement adressé par la conception EVPN et les protections de l'underlay — cf. Lot underlay).

---

## 5. Pare-feu et sécurité réseau

**EXG-NET-1400** — **Groupes de sécurité / règles de pare-feu** (équiv. *firewall rules / Cloud NGFW*) : règles d'entrée et de sortie par étiquettes, par plage source/destination, par port/protocole, avec **priorités** ; implémentation `CiliumNetworkPolicy`. Posture par défaut : entrée « deny », sortie contrôlée.

**EXG-NET-1401** — **Politique hiérarchique** (équiv. *firewall policies* org/dossier) : règles globales de plateforme (non contournables par le tenant) + règles tenant ; les premières priment (admission Kyverno).

**EXG-NET-1402** — **Micro-segmentation** : isolation par charge/étiquette à l'intérieur d'un même sous-réseau (est-ouest), au-delà du simple périmètre.

**EXG-NET-1403** — **Filtrage L7** (équiv. capacités NGFW applicatives) : règles applicatives HTTP/gRPC via Cilium L7 (méthodes, chemins) pour les charges qui le requièrent.

**EXG-NET-1404** — **Journalisation des règles** (équiv. *firewall rules logging*) : activable par règle, exportée vers la pile d'observabilité.

**EXG-NET-1405** — **Protection de bordure** : filtrage périmétrique et anti-usurpation (RPF) sur OPNsense / bordure du fabric ; option WAF/anti-DDoS L7 en phase ultérieure (chapitre 16).

---

## 6. NAT et accès Internet

**EXG-NET-1500** — **Passerelle NAT mutualisée** (équiv. *Cloud NAT*) : accès sortant Internet pour les instances sans IP externe, par tenant, avec journalisation des traductions. SNAT géré par les gateways OVN / la bordure.

**EXG-NET-1501** — Aucune exposition entrante depuis Internet sans **IP flottante + règle de pare-feu explicite** ; les sous-réseaux privés peuvent être totalement coupés d'Internet.

---

## 7. Équilibrage de charge

**EXG-NET-1600** — **Équilibrage L4** (équiv. *internal/external TCP-UDP LB*) : service `LoadBalancer` (MetalLB/OVN) devant un groupe d'instances/pods ; interne (au réseau tenant) ou externe (IP flottante) ; vérifications de santé et persistance de session.

**EXG-NET-1601** — **Équilibrage L7** (équiv. *HTTP(S) LB*) : ingress mutualisé (Envoy/NGINX) avec routage par hôte/chemin, terminaison TLS (cert-manager/PKI interne), redirections, en-têtes. Phase 1 pour les services internes ; exposition externe via IP flottante.

**EXG-NET-1602** — **Vérifications de santé** configurables (TCP/HTTP) avec retrait/réintégration automatique des backends défaillants.

---

## 8. DNS interne

**EXG-NET-1700** — **Zones privées par tenant** (équiv. *Cloud DNS private zones*) : résolution automatique des noms d'instances et d'enregistrements personnalisés (A/AAAA/CNAME/SRV/TXT) dans le réseau tenant ; implémentation PowerDNS/BIND9.

**EXG-NET-1701** — **Enregistrements PTR** (reverse) et **vues** par tenant ; pas de fuite de résolution entre tenants.

**EXG-NET-1702** — **GSLB inter-régions** : pour les services T2/T3, la résolution bascule de Alger vers Constantine lors d'un PRA (poids/priorité, contrôle de santé), pilotée par le cockpit PRA.

**EXG-NET-1703** — **Redirecteurs/résolveurs** : politique de forwarding contrôlée vers des résolveurs internes uniquement (pas d'exfiltration DNS).

---

## 9. Connectivité inter-réseaux et hybride

**EXG-NET-1800** — **Appairage de réseaux** (équiv. *VPC Network Peering*) : interconnexion privée de deux réseaux tenant (ou d'un réseau tenant et d'un réseau de services), sans transitivité, avec contrôle d'échange de routes — soumise à autorisation des deux parties.

**EXG-NET-1801** — **Réseau partagé** (équiv. *Shared VPC*) : un réseau d'organisation hébergeant les sous-réseaux de plusieurs projets d'un même client (gouvernance centrale, ressources décentralisées).

**EXG-NET-1802** — **VPN site-à-site** (équiv. *Cloud VPN*) : tunnels **IPsec** redondants (OPNsense) entre un réseau tenant et le site du client, avec routage statique ou BGP. C'est le mode d'**interconnexion hybride** retenu.

**EXG-NET-1803** — **Interconnexion physique** : raccordement direct au fabric via l'opérateur/peering (équivalent fonctionnel de l'interconnexion dédiée), sans dépendance à un partenaire cloud étranger.

---

## 10. Accès privé aux services de la plateforme

**EXG-NET-1900** — **Endpoints privés** (équiv. *Private Service Connect / Private Google Access*) : les services internes de KubeCenter — API de la plateforme, stockage objet **RGW (S3)**, registre d'images, **LLMaaS**, métadonnées — sont accessibles depuis les réseaux tenant via des **adresses privées**, sans transiter par Internet ni nécessiter d'IP externe.

**EXG-NET-1901** — **Publication de services** : un tenant peut publier un de ses services à un autre tenant via un endpoint privé contrôlé (producteur/consommateur), sans appairage complet des réseaux.

**EXG-NET-1902** — **Périmètres de service** (inspiré de *VPC Service Controls*, périmètre partiel) : restriction des endpoints privés accessibles depuis un réseau donné, pour réduire le risque d'exfiltration ; périmètre complet de type VPC-SC non visé en phase 1 (chapitre 16).

---

## 11. Underlay physique (renvoi au Lot underlay)

**EXG-NET-2000** — L'overlay OVN repose sur un fabric **spine/leaf SONiC** : **eBGP** sous-jacent, **EVPN-VXLAN** pour l'extension L2/L3 multi-AZ, **MC-LAG** (ou EVPN-ESI, à justifier) pour la redondance des liens d'accès, réseau **OOB/BMC isolé**, NTP, et MTU jumbo. Une **maquette de validation** de l'underlay est obligatoire avant production (cf. CDC EXG-1607).

**EXG-NET-2001** — Redondance : double rattachement des nœuds, ECMP spine/leaf, convergence BGP rapide (BFD) ; aucune dépendance à un point unique.

---

## 12. Multi-AZ et PRA réseau

**EXG-NET-2100** — **Étirement multi-AZ** : un sous-réseau tenant peut s'étendre sur AZ-1 et AZ-2 d'Alger (L2/L3 via EVPN-VXLAN), permettant la migration à chaud et la résilience T0 sans changement d'adresse.

**EXG-NET-2101** — **Bascule réseau PRA** : lors d'un sinistre, le GSLB DNS redirige les services T2/T3 vers Constantine, les IP flottantes y sont ré-annoncées en BGP, et les politiques de pare-feu/segmentation y sont déjà répliquées par GitOps — la reprise réseau est testée lors des exercices de bascule.

**EXG-NET-2102** — Les définitions réseau (réseaux, sous-réseaux, règles, zones DNS) sont gérées en GitOps et donc reconstruites à l'identique en région PRA.

---

## 13. Observabilité réseau

**EXG-NET-2200** — **Flow logs** (équiv. *VPC Flow Logs*) : journalisation des flux (5-uplet, verdict, volumétrie) via OVN/Cilium Hubble, exportée vers la pile LGTM, filtrable par tenant.

**EXG-NET-2201** — **Tests de connectivité et topologie** (inspiré de *Network Intelligence Center*) : outil de diagnostic de joignabilité entre deux points (avec verdict de la politique appliquée) et visualisation de la topologie réseau du tenant.

**EXG-NET-2202** — **Métriques** : débit, paquets, erreurs, latence, état des sessions BGP et des tunnels VPN ; alertes (flap BGP, tunnel down, dérive GSLB).

---

## 14. Sécurité et conformité

**EXG-NET-2300** — **Isolation tenant** de bout en bout : overlay par tenant, politique « deny » par défaut, segmentation est-ouest, endpoints privés ; aucune communication implicite.

**EXG-NET-2301** — **Chiffrement** : trafic overlay chiffrable (IPsec/WireGuard via Cilium ou chiffrement OVN) pour les charges sensibles ; VPN hybride en IPsec.

**EXG-NET-2302** — **Audit** : toute opération réseau (création de réseau/règle/route/IP/tunnel, modification de pare-feu) journalisée (acteur, horodatage), inviolable, consultable par le tenant pour ses ressources.

**EXG-NET-2303** — **Conformité loi 18-07 / ANPDP** : tout le plan de données et de contrôle réside à Alger et Constantine ; aucune route, aucun résolveur, aucun endpoint ne dirige des données hors du territoire ; les sorties Internet sont maîtrisées et journalisées.

**EXG-NET-2304** — **Protection L7/anti-DDoS** (équiv. *Cloud Armor*) : WAF et limitation de débit en bordure pour les services exposés — phase ultérieure (chapitre 16).

---

## 15. Quotas, API/CLI/console et réversibilité

**EXG-NET-2400** — **Quotas** par projet : nombre de réseaux, sous-réseaux, règles de pare-feu, IP statiques/flottantes, équilibreurs, zones DNS, tunnels VPN ; dépassement bloqué à l'admission avec message ; relèvement tracé.

**EXG-NET-2401** — **API REST** (modelée sur le resource model VPC) : `networks`, `subnetworks`, `routes`, `firewalls`/`securityPolicies`, `addresses`, `natGateways`, `forwardingRules`/`loadBalancers`, `dnsZones`, `peerings`, `privateEndpoints`, `vpnTunnels` ; verbes CRUD + actions ; opérations asynchrones, idempotence, pagination, débit limité (429).

**EXG-NET-2402** — **CLI `kubecenter`** et **console self-service** couvrent l'ensemble (création de réseaux/sous-réseaux, règles, IP flottantes, équilibreurs, zones DNS, appairage, endpoints privés, VPN, diagnostics de connectivité).

**EXG-NET-2403** — **Réversibilité** : export de la configuration réseau complète (réseaux, sous-réseaux, routes, règles, zones DNS) au format déclaratif ouvert, pour audit ou migration.

---

## 16. Options GCP écartées (et justification)

| Option GCP non retenue | Raison |
|---|---|
| **VPC mondial** (un réseau couvrant toutes les régions du monde) | KubeCenter est **régional** (Alger, Constantine) par conception souveraine ; l'inter-région est géré par DCI/EVPN + GSLB, pas par un backbone mondial |
| **Network Service Tiers** (Premium/Standard via le backbone Google) | Spécifique au réseau mondial de Google ; sans objet sur un fabric souverain |
| **Cloud Interconnect (Dedicated/Partner) vers Google** | Remplacé par l'interconnexion physique via l'opérateur/peering local et le VPN IPsec |
| **Private Service Connect vers les API Google / Private Google Access** | Réorienté vers les **endpoints privés des services KubeCenter** (API, S3 RGW, registre, LLMaaS) — pas d'accès privé à des services étrangers |
| **VPC Service Controls** (périmètres complets anti-exfiltration managés) | Couvert **partiellement** par endpoints privés + périmètres de service + NetworkPolicy ; périmètre complet non visé en phase 1 |
| **Cloud CDN / Media CDN** | Hors périmètre réseau cœur ; mise en cache de bordure éventuelle ultérieurement |
| **Cloud Armor (WAF/anti-DDoS managé mondial)** | Protection L7/anti-DDoS prévue en **phase ultérieure** (WAF de bordure), à l'échelle régionale |
| **IPv6 mondial / appairage transitif** | Appairage non transitif (comme GCP) ; portée régionale |

---

## 17. Exigences — récapitulatif de traçabilité

Les exigences `EXG-NET-1000` à `EXG-NET-2403` constituent le référentiel traçable du module. Chacune est vérifiable (chapitre 18), rattachée à un composant (§0.3) et priorisée `MUST` (phase 1) sauf mention « phase ultérieure » = `SHOULD` (filtrage L7 généralisé 1403, WAF/anti-DDoS 2304/Cloud Armor, périmètres VPC-SC complets, double pile IPv6 généralisée).

---

## 18. Tests d'acceptation

| ID | Objet | Critère de réussite |
|---|---|---|
| T-NET-01 | Réseau & sous-réseaux | Création d'un réseau tenant + 2 sous-réseaux ; rejet d'un CIDR chevauchant avec message |
| T-NET-02 | Isolation inter-tenants | Aucune joignabilité ni résolution DNS entre deux tenants sans appairage |
| T-NET-03 | IP interne statique | Réservation d'une IP interne et attribution déterministe à une instance |
| T-NET-04 | IP flottante | Réservation puis ré-attribution d'une IP flottante entre deux instances ; annonce BGP vérifiée |
| T-NET-05 | Plages d'alias | Exposition de deux services sur une instance via plages secondaires |
| T-NET-06 | Routes statiques | Route personnalisée vers un tunnel VPN appliquée ; priorité respectée |
| T-NET-07 | Routage dynamique | Session eBGP OVN↔fabric établie ; préfixes du tenant diffusés en EVPN |
| T-NET-08 | Pare-feu entrée/sortie | Règle d'entrée autorisant 443 seulement ; tout autre port bloqué ; sortie contrôlée |
| T-NET-09 | Politique hiérarchique | Règle plateforme non contournable par une règle tenant contradictoire |
| T-NET-10 | Micro-segmentation | Deux charges du même sous-réseau isolées par étiquette (est-ouest) |
| T-NET-11 | Filtrage L7 | Règle Cilium autorisant `GET /api` et bloquant `POST /admin` |
| T-NET-12 | NAT sortant | Instance sans IP externe accède à Internet via NAT ; traductions journalisées |
| T-NET-13 | Sous-réseau privé | Sous-réseau sans route par défaut : aucune sortie Internet possible |
| T-NET-14 | Équilibrage L4 | LB interne devant 3 backends ; bascule sur échec de santé d'un backend |
| T-NET-15 | Équilibrage L7 | Ingress routant par hôte/chemin ; terminaison TLS (cert interne) valide |
| T-NET-16 | DNS privé | Résolution d'un nom d'instance et d'un enregistrement personnalisé ; PTR correct ; pas de fuite inter-tenant |
| T-NET-17 | GSLB PRA | Bascule de résolution Alger→Constantine sur santé dégradée vérifiée |
| T-NET-18 | Appairage | Appairage de deux réseaux tenant ; routes échangées ; non-transitivité vérifiée |
| T-NET-19 | Réseau partagé | Sous-réseaux de deux projets dans un réseau d'org partagé ; gouvernance centrale |
| T-NET-20 | VPN IPsec | Tunnel redondant vers un site client ; bascule sur perte d'un tunnel sans coupure de session |
| T-NET-21 | Endpoint privé | Accès au S3 RGW et au LLMaaS via adresse privée, sans IP externe |
| T-NET-22 | Multi-AZ | Sous-réseau étiré AZ-1/AZ-2 ; migration à chaud d'une instance sans changement d'IP |
| T-NET-23 | Flow logs & diagnostic | Flux journalisés ; test de connectivité renvoyant le verdict de la politique |
| T-NET-24 | Quotas | Dépassement du quota de règles de pare-feu bloqué à l'admission avec message |
| T-NET-25 | Audit & 18-07 | Opérations réseau journalisées ; aucune route/résolveur/endpoint dirigeant hors d'Algérie |

---

## Annexe A — Correspondance complète GCP VPC ↔ KubeCenter ↔ implémentation

| Capacité GCP VPC | KubeCenter Network | Implémentation |
|---|---|---|
| VPC network (custom mode) | Réseau tenant (mode personnalisé) | OVN logical router (`NetworkAttachmentDefinition`) |
| Subnet (primary range) | Sous-réseau | OVN logical switch + CIDR |
| Alias IP ranges (secondary) | Plages secondaires | OVN secondary ranges |
| System routes | Routes système | routes implicites OVN |
| Custom static routes | Routes statiques | routes OVN (saut suivant, priorité) |
| Dynamic routing (Cloud Router/BGP) | Routage dynamique | eBGP OVN↔fabric + EVPN-VXLAN |
| Firewall rules / Cloud NGFW | Groupes de sécurité | `CiliumNetworkPolicy` L3/L4/L7 |
| Hierarchical firewall policies | Politique hiérarchique | règles plateforme (Kyverno) + tenant |
| Firewall rules logging | Journalisation des règles | logs Cilium/Hubble → LGTM |
| Cloud NAT | Passerelle NAT | SNAT OVN / bordure |
| Internal/External TCP-UDP LB | Équilibrage L4 | MetalLB / OVN LB |
| HTTP(S) Load Balancing | Équilibrage L7 | ingress Envoy/NGINX + cert-manager |
| Cloud DNS (private zones, PTR) | DNS interne | PowerDNS/BIND9, zones privées |
| Internal/External, static/ephemeral IP | Adressage | IPAM OVN + IP flottantes BGP |
| IPv6 (dual-stack) | Double pile (option) | OVN dual-stack |
| VPC Network Peering | Appairage de réseaux | interconnexion routeurs logiques OVN (non transitif) |
| Shared VPC | Réseau partagé | réseau d'org partagé (Capsule) |
| Private Service Connect / Private Google Access | Endpoints privés | accès privé aux services KubeCenter |
| Cloud VPN | VPN site-à-site | IPsec (OPNsense), statique/BGP |
| Cloud Interconnect | Interconnexion physique | raccordement opérateur/peering au fabric |
| VPC Flow Logs | Flow logs | OVN/Cilium Hubble |
| Network Intelligence Center | Tests de connectivité / topologie | outils de diagnostic OVN/Hubble |
| VPC Service Controls | Périmètres de service (partiel) | endpoints privés + restrictions |
| MTU / jumbo | MTU | OVN + underlay jumbo |
| Quotas | Quotas | `ResourceQuota` + admission |

---

*Fin du document — SPEC-KubeCenter-Network v1.0. À lire conjointement avec SPEC-KubeCenter-VM, SPEC-KubeCenter-Storage et le CDC-PCA-PRA-K8S (Lots Réseau underlay SONiC, Sécurité, Console self-service, PRA).*
