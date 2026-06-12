# Analyse d'écart — Corpus KubeCenter ↔ Atmosphere upstream

**Version :** 1.0 — Juin 2026
**Rôle :** croiser les exigences du corpus KubeCenter (`specs/`) avec les capacités existantes d'Atmosphere (upstream VEXXHOST) pour délimiter **les seules extensions à développer** dans le fork atmosphere-ng.
**Principe directeur (acté) :** Atmosphere est conservé **tel quel** — pas de refonte, pas de remplacement de briques existantes. Les fonctions déjà rendues par l'équivalent OpenStack (Nova pour les VM, Neutron/OVN pour le réseau, Keystone pour l'identité…) sont considérées **couvertes par transposition**. Seuls les écarts donnent lieu à du développement.

---

## 1. Méthode

1. Chaque module du corpus (8 specs + lots du CDC) est confronté aux rôles/charts/playbooks d'Atmosphere (`roles/`, `.charts.yml`, `playbooks/`).
2. Verdict par domaine : **Couvert** (rien à faire), **Partiel** (extension ciblée), **Écart** (développement complet).
3. Les extensions suivent strictement les conventions Atmosphere : chart vendoré via `.charts.yml` (+ patches), rôle Ansible (`defaults`/`vars` `_helm_values`/`tasks`/`meta` avec `upload_helm_chart`), wiring playbook avec flag `atmosphere_<rôle>_enabled`, images épinglées dans `roles/defaults/vars/main.yml`, note `reno`, documentation `doc/source/`, commit conventionnel signé DCO.

---

## 2. Tableau de correspondance

| # | Domaine (réf. spec) | Atmosphere upstream | Verdict | Extension atmosphere-ng |
|---|---|---|---|---|
| 1 | **VM / IaaS** (SPEC-VM) | Nova, libvirt, Glance, Placement — live migration, AZ, flavors | **Couvert** (transposition OpenStack ; KubeVirt non requis sur cette base) | — |
| 2 | **Stockage bloc** (SPEC-ST) | Rook-Ceph + ceph-csi-rbd + Cinder | **Partiel** — mono-région ; pas de classes répliquées vers une région PRA | → E2 (mirroring RBD) |
| 3 | **Portfolio stockage** (SPEC-STO) | Manila (fichier), RGW Rook `ceph` ns `openstack` (objet) | **Partiel** — pas de RGW multisite, pas de sauvegarde plateforme | → E1, E2 |
| 4 | **Réseau** (SPEC-NET) | Neutron + OVN, Octavia (LBaaS), Designate (DNS), frr_k8s (BGP) | **Couvert** (le fabric SONiC est hors périmètre logiciel du dépôt) | — |
| 5 | **GPU** (SPEC-GPU) | node_feature_discovery seul ; passthrough Nova par configuration | **Écart** — pas de GPU Operator, MIG, DCGM | → E5 |
| 6 | **LLMaaS** (SPEC-LLM) | rien | **Écart total** | → E6 |
| 7 | **AppStore** (SPEC-APP) | rien (ni registre Harbor, ni ArgoCD, ni catalogue) | **Écart total** | → E4 |
| 8 | **Console** (SPEC-CON) | Horizon (self-service VM/réseau/volumes) | **Couvert** pour le MVP ; modules Backup/PRA en phase ultérieure | → E7 (ultérieur) |
| 9 | **Sauvegarde** (CDC Lot 8) | staffeln (volumes Cinder), backups MariaDB (doc admin) | **Partiel** — pas de sauvegarde plateforme/PVC (Velero), pas de schedules par tier, pas de BSL répliqué | → **E1** |
| 10 | **PCA multi-AZ** (CDC Lot 10) | AZ Nova/Cinder natifs ; Rook stretch possible mais non outillé | **Partiel** | → E2/E3 |
| 11 | **PRA inter-régions** (CDC Lot 9) | rien | **Écart total** — mirroring, bascule, runbooks | → E2 + E3 |
| 12 | **Identité** (CDC Lot 4) | Keystone + Keycloak | **Couvert** | — |
| 13 | **Multi-tenancy** (CDC Lot 5) | Projets/quotas OpenStack | **Couvert** (modèle OpenStack transposé à Capsule) | — |
| 14 | **Observabilité** (CDC Lot 11) | kube-prometheus-stack, Loki, Vector, exporters | **Couvert** ; alertes DR ajoutées avec E2/E3 | — |
| 15 | **Sécurité plateforme** (CDC Lot 13) | cert-manager, Barbican | **Partiel** — scan/signature d'images livrés avec Harbor | → E4 |
| 16 | **Day-2 / AIOps** (CDC Lot 19) | Renovate, CI | **Ultérieur** (après stabilisation des extensions) | → E7 |

---

## 3. Feuille de route des extensions (ordre de dépendance)

| ID | Extension | Contenu | Exigences couvertes (princ.) |
|---|---|---|---|
| **E1** | **Backup plateforme — Velero** | Chart `velero` vendoré, rôle `velero` (node-agent, CSI, BSL S3/RGW), schedules par tier DR, playbook `backup.yml`, doc admin | EXG-801..805 (transposé), EXG-STO-sauvegarde |
| **E2** | **PRA données — réplication** | Mirroring RBD (CephRBDMirror Rook, pools `*-dr`), RGW multisite (realm/zonegroup/zones), métriques + alertes de lag | EXG-301..307, EXG-ST-#### DR |
| **E3** | **PRA orchestration** | Playbooks failover/failback semi-automatiques (go/no-go), runbooks markdown, bascule DNS Designate, export volumes↔images RBD | EXG-901..906, T-09/T-10 |
| **E4** | **AppStore** | Harbor (registre + scan Trivy + signature), ArgoCD, catalogue curé de charts, flux 100 % GitOps | EXG-2101..2107, EXG-APP-#### |
| **E5** | **GPUaaS** | Rôle `gpu_operator` (driver, MIG manager, DCGM, toolkit), intégration NFD existant, flavors Nova passthrough documentés | EXG-1901..1912, EXG-GPU-#### |
| **E6** | **LLMaaS** | vLLM (serving), LiteLLM (passerelle multi-tenant, clés, quotas tokens), catalogue de modèles | EXG-2001..2011, EXG-LLM-#### |
| **E7** | **Phase ultérieure** | Modules console (backup/PRA self-service), Day-2/AIOps | EXG-17xx, EXG-22xx |

Chaque extension livre : rôle(s) + chart(s) vendoré(s), wiring playbook, note de version, documentation, et la mise à jour de la **traçabilité** (exigence `EXG` ↔ livrable ↔ test) dans ce document ou en annexe.

---

## 4. Écarts assumés (non développés)

- **KubeVirt, Capsule, Kyverno, Kubespray** : la base Atmosphere (OpenStack sur Kubernetes via Kolla/openstack-helm) rend les services équivalents ; le corpus KubeCenter décrivait un socle greenfield — la transposition sur Atmosphere est actée par le porteur (juin 2026).
- **Fabric SONiC** (SPEC-NET §fabric, CDC Lot 14) : configurations switch hors périmètre de ce dépôt (voir projets `Icosnet/`, `icosnet-net/`).
- **Maquette** (EXG-1607) : les scénarios molecule + AIO d'Atmosphere en tiennent lieu pour les extensions.

---

*Document vivant — mis à jour à chaque extension livrée. Voir `specs/KubeCenter-INDEX.md` pour le corpus complet.*
