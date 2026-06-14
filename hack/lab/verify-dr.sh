#!/usr/bin/env bash
#
# verify-dr.sh — commandes de vérification du travail DR (atmosphere-ng)
#
# Vérifie : l'état git de la branche d'extensions, le verdict E3 enregistré,
# l'état du failover/failback RBD sur le lab 2 régions, et la validation
# statique locale (YAML + en-têtes SPDX) des rôles d'extension.
#
# Usage :
#   ./hack/lab/verify-dr.sh [git|e3|lab|lint|fixes|all]   (défaut : all)
#
# Le bloc "lab" nécessite l'accès SSH au lab via ~/.ssh/kclab-config.

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSH_CONF="${KCLAB_SSH_CONFIG:-$HOME/.ssh/kclab-config}"
R1="ssh -F $SSH_CONF -o LogLevel=ERROR -o ConnectTimeout=10 kclab-r1-ctl-1"
R2="ssh -F $SSH_CONF -o LogLevel=ERROR -o ConnectTimeout=10 kclab-r2-ctl-1"
SEL="${1:-all}"

hr() { printf '\n=== %s ===\n' "$1"; }

check_git() {
  hr "1. État git de la branche d'extensions"
  cd "$REPO" || return 1
  echo "branche : $(git branch --show-current)        (attendu : atmosphere-ng-7.6.0)"
  echo "dernier commit :"; git log --oneline -1
  echo "travail en attente :"; git status --short || echo "  (propre)"
  echo "poussé sur origin :"; git log origin/atmosphere-ng-7.6.0 -1 --oneline 2>/dev/null
  echo
  echo "commits d'extension (origin/main..branche) :"
  git log --oneline origin/main..atmosphere-ng-7.6.0
}

check_e3() {
  hr "2. Verdict E3 et tableau de synthèse enregistrés"
  cd "$REPO" || return 1
  sed -n '/E3 — Bascule/,/Aucun split-brain/p' hack/lab/dr-test-results.md
  echo
  sed -n '/Synthèse validation/,/Mis à jour/p' hack/lab/dr-test-results.md
}

check_lab() {
  hr "3. État failover/failback RBD sur le lab (Ceph)"
  echo "-- region1 doit être le PRIMAIRE (état nominal après retour) :"
  $R1 'sudo cephadm shell -- rbd info volumes-dr/dr-test-vol 2>/dev/null | grep "mirroring primary"'
  echo "   (attendu : mirroring primary: true)"
  echo
  echo "-- region2 doit SUIVRE region1 (secondaire à jour) :"
  $R2 'sudo cephadm shell -- rbd mirror image status volumes-dr/dr-test-vol 2>/dev/null | grep -E "state:|replay_state|local image is primary"'
  echo "   (attendu : up+replaying / replay_state: idle / peer region1 = local image is primary)"
}

check_lint() {
  hr "4. Validation statique locale (YAML + en-têtes SPDX)"
  cd "$REPO" || return 1
  git log --name-only --pretty=format: origin/main..atmosphere-ng-7.6.0 \
    | grep -E '^(roles|playbooks)/.*\.(ya?ml)$' | sort -u > /tmp/ng_files.txt
  python3 - <<'PY'
import yaml
bad=[]; nohdr=[]; n=0
for f in [l.strip() for l in open('/tmp/ng_files.txt') if l.strip()]:
    try: t=open(f).read()
    except FileNotFoundError: continue
    n+=1
    try: list(yaml.safe_load_all(t))
    except Exception as e: bad.append((f,str(e).splitlines()[0]))
    if 'SPDX-License-Identifier' not in t[:600] and 'Licensed under the Apache' not in t[:600]:
        nohdr.append(f)
print(f"fichiers vérifiés : {n}")
print(f"YAML invalides    : {len(bad)}")
for f,e in bad: print("   !", f, "->", e)
print(f"sans en-tête      : {len(nohdr)} (attendu : uniquement .../jsonnet/vendor ou amont inchangés)")
PY
  echo
  echo "-- en-têtes présents sur les 9 rôles d'extension (attendu : 9) :"
  grep -lE "SPDX-License-Identifier|Licensed under the Apache" \
    roles/{velero,ceph_rbd_mirror,ceph_rgw_multisite,argocd,harbor,kyverno,gpu_operator,vllm,litellm}/tasks/main.yml 2>/dev/null | wc -l
}

check_fixes() {
  hr "5. Correctifs clés (relecture rapide)"
  cd "$REPO" || return 1
  echo "-- neutron (deadlock helm hook) :"
  grep -n "helm3_hook" roles/neutron/vars/main.yml
  echo "-- velero Object Lock (env en string) :"
  grep -n "object_lock_days | string" roles/velero/tasks/main.yml
  echo "-- ceph_rbd_mirror (token base64 + ceph orch apply direct) :"
  grep -nE "grep -E|orch apply rbd-mirror" roles/ceph_rbd_mirror/tasks/main.yml
  echo "-- keycloak (timeout helm configurable) :"
  grep -n "keycloak_helm_timeout" roles/keycloak/tasks/main.yml
}

case "$SEL" in
  git)   check_git ;;
  e3)    check_e3 ;;
  lab)   check_lab ;;
  lint)  check_lint ;;
  fixes) check_fixes ;;
  all)   check_git; check_e3; check_lab; check_lint; check_fixes ;;
  *) echo "usage: $0 [git|e3|lab|lint|fixes|all]"; exit 2 ;;
esac
