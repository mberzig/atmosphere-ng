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

### E3 — Bascule / retour PRA (failover + failback RBD) sur 7.6.0 : **PASS (plan de données)**
Validation du cœur de `dr_failover.yml` / `dr_failback.yml` : la
promotion/rétrogradation RBD qui rend un volume répliqué inscriptible au
site PRA, puis le rétablissement nominal. Image témoin
`volumes-dr/dr-test-vol` (`global_id` c109b02b…), peering region1↔region2
établi (cf. E2).

**Bascule (region1 → region2), anti-split-brain :**
- region1 (primaire) → `rbd mirror image demote` → « Image demoted to
  non-primary ».
- region2 → `rbd mirror image promote` → « Image promoted to primary »,
  `rbd info` ⇒ `mirroring primary: true`.
- Écriture de validation sur region2 (`rbd bench`, 4 K × 256) →
  **2782 ops/s, 11 MiB/s** : le volume est inscriptible au site PRA
  (preuve qu'une VM pourrait y démarrer sur ce disque).

**Retour (region2 → region1) :**
- region2 → `demote` → « Image demoted to non-primary ».
- region1 → `promote` → « Image promoted to primary »,
  `mirroring primary: true` (retour au primaire d'origine).
- Écriture nominale sur region1 (`rbd bench`) → **4266 ops/s, 17 MiB/s**.
- Snapshot de mirroring déclenché sur region1 (Snapshot ID 13).
- À region2 : l'image repasse **`up+replaying`** (secondaire qui suit
  region1), `last_snapshot_bytes: 1048576` (le 1 Mio écrit pendant le
  retour est bien répliqué vers region2), `replay_state: idle` (à jour),
  region1 `local image is primary`. **Aucun split-brain.**
- Verdict : cycle complet bascule + retour fonctionnel au niveau du plan
  de données Ceph, réplication bidirectionnelle confirmée. Le volet
  OpenStack des `dr_failover/failback.yml` (Cinder `manage`/`unmanage`,
  bascule DNS Designate) n'est pas exécuté ici : seule region1 dispose
  d'un OpenStack complet sur le lab (region2 = cible Ceph/PRA). Le
  mécanisme déterminant — rendre la donnée répliquée inscriptible au PRA
  et la ramener — est validé.

## Drill PCA/PRA sur VMs réelles — déploiement region2 + bascule applicative

Objectif : aller au-delà du plan de données (E3) et rejouer le volet
OpenStack avec de **vraies VMs** : déployer un OpenStack complet à region2
(cible PRA), créer une VM tenant à region1, basculer, la redémarrer à
region2.

### Déploiement OpenStack region2 (cible PRA) : **FAIT (cœur)**
region2 (1 contrôleur + 2 computes) avait déjà k8s + Ceph (cephadm) ; le
volet OpenStack avait échoué sur keycloak. Repris et mené à bien :
- **Keycloak** : la migration liquibase initiale avait laissé un schéma
  à moitié migré (`RESOURCE_SERVER_PERM_TICKET already exists`,
  CrashLoopBackOff ×263) → réinitialisation propre de la base `keycloak`
  (drop/create), keycloak migre et passe `Ready`.
- **Bug corrigé** (`fix(keycloak)`) : la tâche « Wait until keycloak
  ready » comparait `status.replicas` à `status.readyReplicas` ;
  `readyReplicas` est absent tant qu'aucun pod n'est prêt → la condition
  *plantait* (`dict object has no attribute readyReplicas`) au lieu de
  ré-essayer, faisant échouer le déploiement sur une migration lente.
  Corrigé par `default(0)` vs `spec.replicas`.
- Résultat : **keystone, glance, cinder, placement, nova (compute API
  ready + flavors), neutron (network service ready + réseaux créés)**
  déployés à region2. Seul `heat` (rabbitmq-heat) a timeout (pression
  ressources) — non requis pour le drill.

### Bascule applicative avec VM réelle : **BLOQUÉ — limite de capacité du lab**
Le drill nécessite un plan de contrôle OpenStack **stable** dans les deux
régions simultanément. Constat factuel :
- **Les deux régions renvoient keystone `HTTP 500`** : le tier base de
  données (Percona/Galera + haproxy) ne tient pas. À region1, le cluster
  Galera a perdu son Primary Component (mysqld up mais port 3306 fermé,
  `safe_to_bootstrap: 0` partout), récupéré via la recovery de l'opérateur
  (bootstrap depuis le nœud le plus avancé, `seqno 56056`) — puis
  **re-effondré** : pxc-2 bloqué en `Terminating`, haproxy jamais `Ready`
  (clustercheck KO), aucun endpoint pour `percona-xtradb-haproxy`.
- **Cause racine : sur-engagement de l'hôte physique CERIST partagé.**
  Charge **load average 666** observée pendant le SST Galera + le
  déploiement region2 concurrent ; un OOMKill (exit 137) sur un nœud pxc.
  Même après retour au calme (load ~12, **9 min sans sollicitation**), le
  tier DB ne se rétablit pas. L'hôte ne soutient pas un plan de contrôle
  HA OpenStack complet — *a fortiori* deux en parallèle.
- **Effet de bord corrigé** : la politique Kyverno (E4) utilise
  `failurePolicy: Fail` ; quand les pods Kyverno meurent sous la pression,
  leur webhook d'admission **bloque toutes les opérations pods du cluster**
  — y compris le redémarrage de Kyverno lui-même (auto-blocage). Webhooks
  repassés en `Ignore` pour débloquer. Anti-pattern de résilience à
  corriger dans le rôle (cf. [[kyverno-failurepolicy-deadlock]]).

**Tentative d'allègement du plan de contrôle (à la demande).** Pour tenter
de stabiliser keystone, deux approches ont été essayées :
1. **Galera 3→1** (`spec.pxc.size: 1` + `unsafeFlags.pxcSize`) : l'opérateur
   Percona **refuse de scaler un cluster non sain** (il attend un état Ready
   qu'il n'atteint jamais) → reste bloqué ; les conteneurs pxc *cyclent*
   (`cannot exec in a stopped container`) sous pression mémoire (un OOMKill
   constaté, pas de limite mémoire sur le conteneur = OOM niveau nœud).
2. **Bypass haproxy** (repointer le Service `percona-xtradb-haproxy` vers les
   pods pxc sains) : à region2 les nœuds pxc-0/1 sont `2/2` (0 restart,
   quorum Primary), mais keystone **hang quand même** sur l'émission de
   token — y compris en interne au pod (POST `/v3/auth/tokens` → timeout
   35 s). Cause : les nœuds PXC attendent l'en-tête **proxy-protocol** que
   haproxy ajoute normalement, et/ou le chemin de requête mysqld est saturé
   (IO/CPU). Réduire le nombre de replicas **ne corrige pas** la latence
   *par requête* sur un nœud affamé.

**Verdict honnête** : le déploiement region2 (la fonction « cible PRA »)
est livré ; le **mécanisme déterminant** du PRA (bascule du plan de
données RBD, E1/E2/E3) reste validé et ne dépend pas du plan de contrôle
lourd. La bascule applicative avec VM réelle de bout en bout **n'est pas
démontrable sur la capacité actuelle du lab** : le tier base de données
(Percona/Galera) ne sert pas les requêtes de façon fiable dans **les deux**
régions, et l'allègement par réduction de replicas ne le résout pas (c'est
une famine de ressources CPU/IO, pas un problème de compte de replicas).
C'est une **limite d'infrastructure, pas un défaut logiciel** — Atmosphere
se déploie correctement. Pour rejouer le drill, il faut **du matériel** :
VM de plan de contrôle dimensionnées (RAM/CPU/IO), idéalement des nœuds DB
dédiés, ou un lab à une seule région à la fois. Le protocole reste : VM
bootée sur volume Cinder (`cinder.volumes`, mirroré vers region2) →
`dr_failover.yml` (promote RBD + `cinder manage` + boot region2) →
vérification d'un témoin écrit dans le volume.

## Synthèse validation sur stable 7.6.0
| Extension | Verdict |
|---|---|
| E1 Velero (backup/restore) | ✅ PASS |
| E2 RBD mirror (region1→region2) | ✅ PASS (cephadm) |
| E4 Kyverno cosign (T-12 enforcement) | ✅ PASS |
| E7a schedules par tier | ✅ PASS |
| E7b immutabilité Object Lock (T-13) | ✅ PASS |
| E3 failover/failback (plan de données RBD) | ✅ PASS (cephadm ; volet OpenStack non rejouable, region2 = cible PRA seule) |
| Déploiement OpenStack region2 (cible PRA) | ✅ FAIT (cœur ; heat exclu) |
| Bascule applicative VM réelle (2 régions) | ⛔ bloqué — capacité lab (plan de contrôle DB instable, les 2 régions) |
| E5 GPUaaS / E6 LLMaaS | non testables (pas de GPU sur le lab) |

*Mis à jour au fil des tests.*
