# Résultats des tests fonctionnels DR — lab 2 régions

Environnement : lab OpenStack CERIST, region1 (3 ctl + 2 cmp, 2 AZ) + region2
(cible PRA, Ceph). Base : extensions rebasées sur le tag stable **v7.6.0**
(OpenStack 2025.2), branche `kubecenter-7.6.0`. Pools Ceph en `size=1` (lab —
retire l'amplification d'écriture 3x). Voir `dr-test-plan.md` pour le protocole.

## Bugs trouvés et corrigés pendant les tests
- `fix(harbor)` : `harbor_host` manquant dans le skeleton d'endpoints de
  `generate_workspace` (bloquait la génération d'inventaire).
- `fix(velero)` : la rétention Object Lock était passée comme valeur d'env
  numérique au job de provisioning du bucket → rejet de l'API Kubernetes
  (les valeurs d'env doivent être des chaînes). Corrigé par `| string`.
- `fix(ceph_rbd_mirror)` : `no-changed-when` sur les commandes gardées
  (ansible-lint).
- `fix(ceph_rbd_mirror)` : `vexxhost.ceph.orch_apply` exige un `service_id`
  que `rbd-mirror` n'a pas (`KeyError`) → remplacé par un `ceph orch apply`
  direct.
- `fix(ceph_rbd_mirror)` : le fichier token de peering contenait les bannières
  de `cephadm shell` → import du peer en échec (`failed to decode base64`).
  Corrigé en ne gardant que la ligne base64 du token.

## E1 — Backup plateforme (Velero) → EXG-801..805 : **PASS**
- Velero déployé (serveur + 5 node-agents Running), BSL `Available` sur le
  RGW Ceph (S3, endpoint `rook-ceph-rgw-ceph.openstack.svc`).
- Backup d'un namespace témoin (`dr-witness`, configmap) → `Completed`,
  4 items écrits dans le bucket S3.
- Suppression du namespace → `NotFound`.
- Restauration depuis la sauvegarde → `Completed`, contenu du configmap
  restauré à l'identique (`kubecenter-dr-test-20260613`).
- Verdict : la chaîne backup → S3 → restore fonctionne de bout en bout.

## E2 — Mirroring RBD (region1 → region2) → EXG-301..307 : **PASS**
- Pool `volumes-dr` créé sur les deux clusters cephadm, daemon `rbd-mirror`
  déployé via le rôle (après correctifs), peering bootstrap échangé.
- Connectivité inter-régions des mon vérifiée (R1↔R2, port 3300).
- Image `volumes-dr/dr-test-vol` (128 Mio) créée à region1, mirroring snapshot
  activé, 4 Mio écrits, snapshot de mirroring déclenché.
- À region2 : l'image apparaît (`mirroring primary: false`), état
  **`up+replaying`**, `last_snapshot_bytes: 4194304` (les 4 Mio répliqués),
  `replay_state: idle` (à jour).
- Verdict : la réplication RBD snapshot-based inter-régions fonctionne de bout
  en bout, données comprises.

## E7a — Schedules par tier : à tester
## E7b — Immutabilité Object Lock : à tester (bug env corrigé)
## E4 — Signature cosign / Kyverno : à tester
## E3 — Failover/failback : partiellement testable (Nova/Neutron non finalisés sur le lab)

*Mis à jour au fil des tests.*
