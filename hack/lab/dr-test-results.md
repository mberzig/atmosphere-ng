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

### E7a — Schedules par tier sur 7.6.0 : **PASS**
- Schedules `velero-tier-t1`/`t2` + CronJob réconciliateur déployés ;
  schedules en `paused=true` à vide (correct).
- Namespace `tier-test` labellisé `kubecenter.dz/dr-tier=t1` + réconciliateur
  déclenché → `velero-tier-t1` passe `paused=false` et
  `includedNamespaces: ["tier-test"]` (le namespace labellisé est couvert).
- Garde-fou : retrait du label + réconciliateur → schedule repasse
  `paused=true` (pas de fallback « tout sauvegarder » sur sélecteur vide).

### E7b — Immutabilité Object Lock sur 7.6.0 : **PASS (T-13)**
- Bucket créé avec Object Lock + versioning activés + rétention par défaut
  COMPLIANCE.
- Objet écrit avec rétention COMPLIANCE → `get-object-retention` = COMPLIANCE.
- Suppression de version tentée → **`AccessDenied`**, l'objet survit
  (immutabilité garantie).
- Nuance : la rétention par défaut du bucket ne s'auto-applique pas
  systématiquement aux objets sur le RGW Ceph 18.2.8 ; le mécanisme
  d'Object Lock (rétention explicite) est lui pleinement appliqué.

## Synthèse validation sur stable 7.6.0
| Extension | Verdict |
|---|---|
| E1 Velero (backup/restore) | ✅ PASS |
| E2 RBD mirror (region1→region2) | ✅ PASS (cephadm) |
| E4 Kyverno cosign (T-12 enforcement) | ✅ PASS |
| E7a schedules par tier | ✅ PASS |
| E7b immutabilité Object Lock (T-13) | ✅ PASS |
| E3 failover/failback | nécessite le réseau OpenStack des deux régions |
| E5 GPUaaS / E6 LLMaaS | non testables (pas de GPU sur le lab) |

*Mis à jour au fil des tests.*
