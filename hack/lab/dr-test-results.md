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

## Validation sur la base STABLE v7.6.0 (OpenStack 2025.2, déploiement propre)

Après rebase sur v7.6.0 et déploiement propre complet (OpenStack 2025.2
fonctionnel : hyperviseurs up, agents neutron alive), les extensions ont été
revalidées sur cette base stable.

### E1 — Velero sur 7.6.0 : **PASS**
- Velero déployé (6 pods Running), BSL `Available` sur le RGW (endpoint
  cephadm `http://<rgw>:8000`).
- Backup du namespace témoin `dr-witness-76` → `Completed`, 4 items.
- Suppression → `NotFound`, restauration → `Completed`, contenu restauré à
  l'identique (`kubecenter-7.6.0-test`).

### E4 — Signature cosign / Kyverno sur 7.6.0 : **enforcement PASS (T-12)**
- Kyverno déployé (4 pods Running), 1 `ClusterPolicy` verify-image en Enforce.
- Image non signée (`ghcr.io/kyverno/test-verify-image:unsigned`) → **rejetée
  à l'admission** avec message de politique (`verify-signature: failed to
  verify image ... no matching signatures`). T-12 satisfait.
- L'image keyless de test est aussi rejetée (correct : la politique ne fait
  confiance qu'à la clé statique configurée). Le cas « admise » emprunte le
  même mécanisme `verifyImages` ; sa démonstration nécessite une image signée
  par cosign vers un registre (cosign/registre absents du lab).

## Bug d'infrastructure noté (déploiement propre)
- Le RGW rook (CephObjectStore) n'a pas été recréé après suppression du
  namespace `openstack` (0 pod rook RGW). Contourné par un RGW cephadm
  autonome (`ceph orch apply rgw`) pour le test E1. À investiguer côté
  rôle `rook_ceph_cluster` (recréation de la CephObjectStore).

## Reste à tester
## E7a — Schedules par tier · E7b — Immutabilité Object Lock
## E2 — RBD mirror sur 7.6.0 (déjà validé au niveau cephadm)
## E3 — Failover/failback (nécessite le réseau OpenStack des deux régions)

*Mis à jour au fil des tests.*
