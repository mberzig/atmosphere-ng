# Plan de test des extensions DR sur le lab 2 régions

Exécuté après convergence des deux régions (region1 = primaire 2 AZ, region2 = PRA).
Chaque test mappe une extension du fork et une exigence/test du CDC.

## Pré-requis (récupérés post-convergence)
- Endpoints RGW des deux régions (`openstack catalog show object-store`).
- Identifiants S3 d'un utilisateur dédié `velero` (créé via `radosgw-admin`).
- FSID Ceph des deux clusters (pour les peers de mirroring).

## E1 — Backup plateforme (Velero) → EXG-801..805
1. Créer l'utilisateur S3 `velero` + bucket sur le RGW de region1.
2. Activer `atmosphere_velero_enabled: true` + identifiants, re-run `backup.yml`.
3. Vérifier : pod `velero` Running, BSL `Available`, `velero backup-location get`.
4. `velero backup create test-ns --include-namespaces <ns>` → `Completed`.
5. Restaurer dans un namespace témoin → données présentes.

## E7a — Schedules par tier → EXG-020/803
1. Définir `velero_tier_schedules` (t1 720h / t2 336h), re-run.
2. Labelliser un namespace `kubecenter.dz/dr-tier=t1`.
3. Attendre le CronJob réconciliateur → le Schedule `velero-tier-t1` cible le namespace, non paused.
4. Retirer le label → schedule repasse `paused` (pas de fallback "tout sauvegarder").

## E7b — Immutabilité Object Lock → EXG-1507 / T-13
1. `velero_storage_create_bucket: true`, `velero_storage_object_lock_days: 1`, re-run.
2. Vérifier le bucket créé avec Object Lock (mode COMPLIANCE).
3. Tenter de supprimer un objet de backup verrouillé → refusé.

## E2 — Réplication PRA (RBD mirroring) → EXG-301..307
1. Créer un pool `volumes-dr` sur les deux clusters Ceph.
2. region1 : `atmosphere_rbd_mirror_enabled`, `ceph_rbd_mirror_pools=[{name: volumes-dr, interval: 15m}]`, `bootstrap_create: true`, run `dr.yml`.
3. Récupérer le token `/etc/ceph/rbd-mirror-peer-volumes-dr.token`.
4. region2 : même config + `ceph_rbd_mirror_peers` avec le token, run `dr.yml`.
5. Créer une image RBD dans `volumes-dr` à region1, écrire des données.
6. Vérifier : `rbd-mirror-health volumes-dr` OK, image visible (non-primary) à region2.

## E2 — RGW multisite → EXG-307
1. region1 (master zone) : `atmosphere_rgw_multisite_enabled`, endpoints, run `dr.yml`.
2. Récupérer les clés du realm (`<realm>-keys`).
3. region2 (secondary) : `master: false`, pull endpoint + clés, run `dr.yml`.
4. Écrire un objet dans un bucket à region1 → lisible à region2 (`radosgw-admin sync status`).

## E3 — Failover / Failback → EXG-901/902, T-09/T-10
1. Écrire un jeu de données horodaté en continu sur une image mirrorée (témoin RPO).
2. Simuler la perte de region1 (arrêt des écritures).
3. `ansible-playbook dr_failover.yml` ciblant region2 (confirmation `failover`).
4. Vérifier : images promues primary à region2, données du témoin présentes, RPO mesuré ≤ 15 min.
5. Réparer region1, `dr_failback.yml` → resync, vérifier non-divergence.

## E4 — Signature cosign à l'admission (Kyverno) → EXG-1504 / T-12
1. `atmosphere_kyverno_enabled`, run `appstore.yml` (kyverno seul).
2. Signer une image de test avec cosign, la pousser.
3. Définir `kyverno_verify_images` (clé publique), run.
4. Déployer un pod avec l'image signée → admis ; avec une image non signée → **rejeté**.

## Rapport
Pour chaque test : commande exacte, sortie observée, verdict PASS/FAIL, exigence couverte.
Consigné dans `hack/lab/dr-test-results.md`.
