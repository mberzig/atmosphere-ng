# Résultats des tests fonctionnels DR — lab 2 régions

Environnement : lab OpenStack CERIST, region1 (3 ctl + 2 cmp, 2 AZ) + region2
(cible PRA, Ceph). Atmosphere déployé depuis le fork mberzig/atmosphere-ng.
Pools Ceph en `size=1` (lab). Voir `dr-test-plan.md` pour le protocole.

## Bugs trouvés et corrigés pendant les tests
- `fix(harbor)` : `harbor_host` manquant dans le skeleton d'endpoints de
  `generate_workspace` (bloquait la génération d'inventaire).
- `fix(velero)` : la rétention Object Lock était passée comme valeur d'env
  numérique au job de provisioning du bucket → rejet de l'API Kubernetes
  (les valeurs d'env doivent être des chaînes). Corrigé par `| string`.
- `fix(ceph_rbd_mirror)` : `no-changed-when` sur les commandes gardées
  (ansible-lint).

## E1 — Backup plateforme (Velero) → EXG-801..805 : **PASS**
- Velero déployé (serveur + 5 node-agents Running), BSL `Available` sur le
  RGW Ceph (S3, endpoint `rook-ceph-rgw-ceph.openstack.svc`).
- Backup d'un namespace témoin (`dr-witness`, configmap) → `Completed`,
  4 items écrits dans le bucket S3.
- Suppression du namespace → `NotFound`.
- Restauration depuis la sauvegarde → `Completed`, contenu du configmap
  restauré à l'identique (`kubecenter-dr-test-20260613`).
- Verdict : la chaîne backup → S3 → restore fonctionne de bout en bout.

## E7a — Schedules par tier : à tester
## E7b — Immutabilité Object Lock : à tester (bug env corrigé)
## E2 — Mirroring RBD : à tester (niveau cephadm R1↔R2)
## E4 — Signature cosign / Kyverno : à tester
## E3 — Failover/failback : partiellement testable (Nova/Neutron non finalisés sur le lab)

*Mis à jour au fil des tests.*
