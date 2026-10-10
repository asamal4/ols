#!/usr/bin/env bash
set -euo pipefail

REPOS=(
  lightspeed-service
  lightspeed-operator
  lightspeed-console
  lightspeed-rag-content
  lightspeed-agentic-operator
  lightspeed-agentic-console
  lightspeed-agentic-sandbox
  lightspeed-agentic-alerts-adapter
  lightspeed-hub
  lightspeed-hub-ui
  lightspeed-otel-collector
  lightspeed-team-harness
  ols-load-generator
)

ORG="openshift"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [command]

Commands:
  clone          Clone all repos from openshift/ org (default)
  clone-fork     Clone from your fork and add openshift/ as upstream
  pull           Pull --ff-only on all cloned repos
  sync-forks     Sync fork default branches from upstream (safe fast-forward only)
                 Optional repo name limits sync to one repo
  status         Show git status for all cloned repos
  help           Show this help

Options (for clone-fork):
  GITHUB_USER    Set via env var or pass as: clone-fork <user>

Examples:
  ./setup.sh                          # Clone all repos from openshift/
  ./setup.sh clone-fork myuser        # Clone from your fork, add upstream
  GITHUB_USER=myuser ./setup.sh clone-fork
  ./setup.sh pull                     # Fast-forward pull all repos
  ./setup.sh sync-forks               # Sync fork and local default branches
  ./setup.sh sync-forks lightspeed-rag-content  # Sync one repo only
  ./setup.sh status                   # Quick status check across all repos
EOF
}

clone() {
  echo "Cloning repos from ${ORG}/..."
  for repo in "${REPOS[@]}"; do
    if [ -d "${SCRIPT_DIR}/${repo}" ]; then
      echo "  ✓ ${repo} (already exists, skipping)"
    else
      echo "  ⏳ ${repo}"
      git clone --quiet "git@github.com:${ORG}/${repo}.git" "${SCRIPT_DIR}/${repo}"
      echo "  ✓ ${repo}"
    fi
  done
  echo "Done. ${#REPOS[@]} repos ready."
}

clone_fork() {
  local user="${1:-${GITHUB_USER:-}}"
  if [ -z "${user}" ]; then
    echo "Error: GitHub username required."
    echo "  Usage: $(basename "$0") clone-fork <user>"
    echo "  Or:    GITHUB_USER=<user> $(basename "$0") clone-fork"
    exit 1
  fi

  echo "Cloning repos from ${user}/ (upstream: ${ORG}/)..."
  for repo in "${REPOS[@]}"; do
    if [ -d "${SCRIPT_DIR}/${repo}" ]; then
      echo "  ✓ ${repo} (already exists, skipping)"
    else
      echo "  ⏳ ${repo}"
      git clone --quiet "git@github.com:${user}/${repo}.git" "${SCRIPT_DIR}/${repo}"
      git -C "${SCRIPT_DIR}/${repo}" remote add upstream "git@github.com:${ORG}/${repo}.git"
      git -C "${SCRIPT_DIR}/${repo}" fetch --quiet upstream
      echo "  ✓ ${repo} (origin=${user}, upstream=${ORG})"
    fi
  done
  echo "Done. ${#REPOS[@]} repos ready."
}

sync_forks() {
  local selected_repo="${1:-}"
  local repos_to_sync=("${REPOS[@]}")
  if [ -n "${selected_repo}" ]; then
    local found=0 known_repo
    for known_repo in "${REPOS[@]}"; do
      if [ "${known_repo}" = "${selected_repo}" ]; then
        found=1
        break
      fi
    done
    if [ "${found}" -eq 0 ]; then
      echo "Error: unknown repo '${selected_repo}'."
      return 2
    fi
    repos_to_sync=("${selected_repo}")
  fi

  echo "Syncing fork default branches from upstream..."
  local ok=0 fail=0 skip=0

  for repo in "${repos_to_sync[@]}"; do
    local path="${SCRIPT_DIR}/${repo}"
    if [ ! -d "${path}/.git" ]; then
      echo "  - ${repo} (not cloned; skipping)"
      skip=$((skip + 1))
      continue
    fi
    echo "  ⏳ ${repo} (checking)"

    local upstream_branch origin_branch current_branch local_exists
    upstream_branch=$(git -C "${path}" ls-remote --symref upstream HEAD 2>/dev/null \
      | awk '$1 == "ref:" && $3 == "HEAD" { sub("refs/heads/", "", $2); print $2; exit }' || true)
    if [ -z "${upstream_branch}" ]; then
      echo "  ✗ ${repo} (cannot detect upstream default branch; check upstream remote)"
      fail=$((fail + 1))
      continue
    fi
    origin_branch=$(git -C "${path}" ls-remote --symref origin HEAD 2>/dev/null \
      | awk '$1 == "ref:" && $3 == "HEAD" { sub("refs/heads/", "", $2); print $2; exit }' || true)
    if [ -z "${origin_branch}" ] || [ "${origin_branch}" != "${upstream_branch}" ]; then
      echo "  ✗ ${repo} (fork default branch '${origin_branch:-unknown}' differs from upstream '${upstream_branch}')"
      fail=$((fail + 1))
      continue
    fi

    echo "    Fetching upstream/${upstream_branch}..."
    if ! git -C "${path}" fetch --quiet upstream \
      "+refs/heads/${upstream_branch}:refs/remotes/upstream/${upstream_branch}"; then
      echo "  ✗ ${repo} (failed to fetch upstream/${upstream_branch})"
      fail=$((fail + 1))
      continue
    fi

    if git -C "${path}" ls-remote --exit-code --heads origin "${upstream_branch}" >/dev/null 2>&1; then
      if ! git -C "${path}" fetch --quiet origin \
        "+refs/heads/${upstream_branch}:refs/remotes/origin/${upstream_branch}"; then
        echo "  ✗ ${repo} (failed to fetch origin/${upstream_branch})"
        fail=$((fail + 1))
        continue
      fi
      if ! git -C "${path}" merge-base --is-ancestor \
        "origin/${upstream_branch}" "upstream/${upstream_branch}"; then
        echo "  ✗ ${repo} (origin/${upstream_branch} has commits not in upstream; refusing non-fast-forward update)"
        fail=$((fail + 1))
        continue
      fi
    fi

    current_branch=$(git -C "${path}" branch --show-current 2>/dev/null || true)
    local_exists=0
    if git -C "${path}" show-ref --verify --quiet "refs/heads/${upstream_branch}"; then
      local_exists=1
      if [ "${current_branch}" = "${upstream_branch}" ]; then
        if [ -n "$(git -C "${path}" status --porcelain)" ]; then
          echo "  ✗ ${repo} (on ${upstream_branch} with working-tree changes; refusing update)"
          fail=$((fail + 1))
          continue
        fi
      else
        if git -C "${path}" worktree list --porcelain \
          | grep -Fqx "branch refs/heads/${upstream_branch}"; then
          echo "  ✗ ${repo} (${upstream_branch} checked out in another worktree; refusing update)"
          fail=$((fail + 1))
          continue
        fi
      fi

      if ! git -C "${path}" merge-base --is-ancestor \
        "${upstream_branch}" "upstream/${upstream_branch}"; then
        echo "  ✗ ${repo} (local ${upstream_branch} has commits not in upstream; refusing update)"
        fail=$((fail + 1))
        continue
      fi
    fi

    if [ "${current_branch}" = "${upstream_branch}" ] \
      && [ "$(git -C "${path}" rev-parse "${upstream_branch}")" != "$(git -C "${path}" rev-parse "upstream/${upstream_branch}")" ] \
      && git -C "${path}" config --get-regexp '^filter\.lfs\.(process|smudge|clean)$' >/dev/null 2>&1; then
      if ! command -v git-lfs >/dev/null 2>&1; then
        echo "  ✗ ${repo} (Git LFS is configured but git-lfs is missing; install Git LFS before updating ${upstream_branch})"
        fail=$((fail + 1))
        continue
      fi
      echo "    Pre-fetching Git LFS objects..."
      if ! git -C "${path}" lfs fetch upstream "upstream/${upstream_branch}"; then
        echo "  ✗ ${repo} (Git LFS fetch failed; local branch and fork unchanged)"
        fail=$((fail + 1))
        continue
      fi
    fi

    if [ "${current_branch}" = "${upstream_branch}" ]; then
      if ! git -C "${path}" merge --ff-only "upstream/${upstream_branch}" >/dev/null; then
        echo "  ✗ ${repo} (failed to fast-forward checked-out ${upstream_branch}; fork not updated)"
        fail=$((fail + 1))
        continue
      fi
    elif [ "${local_exists}" -eq 1 ]; then
      if ! git -C "${path}" branch -f "${upstream_branch}" "upstream/${upstream_branch}"; then
        echo "  ✗ ${repo} (failed to update local ${upstream_branch}; fork not updated)"
        fail=$((fail + 1))
        continue
      fi
    else
      if ! git -C "${path}" branch "${upstream_branch}" "upstream/${upstream_branch}"; then
        echo "  ✗ ${repo} (failed to create local ${upstream_branch}; fork not updated)"
        fail=$((fail + 1))
        continue
      fi
    fi

    if ! git -C "${path}" push --quiet origin \
      "refs/remotes/upstream/${upstream_branch}:refs/heads/${upstream_branch}"; then
      echo "  ✗ ${repo} (local ${upstream_branch} updated; could not fast-forward fork)"
      fail=$((fail + 1))
      continue
    fi

    echo "  ✓ ${repo} (${upstream_branch} synced)"
    ok=$((ok + 1))
  done

  echo "Done. ${ok} synced, ${fail} failed, ${skip} not cloned."
  [ "${fail}" -eq 0 ]
}

pull() {
  echo "Pulling all repos..."
  local ok=0 fail=0 skip=0
  for repo in "${REPOS[@]}"; do
    if [ ! -d "${SCRIPT_DIR}/${repo}/.git" ]; then
      skip=$((skip + 1))
      continue
    fi
    if git -C "${SCRIPT_DIR}/${repo}" pull --ff-only --quiet 2>/dev/null; then
      ok=$((ok + 1))
    else
      echo "  ✗ ${repo} (ff-only failed — local changes or diverged)"
      fail=$((fail + 1))
    fi
  done
  echo "Done. ${ok} updated, ${fail} failed, ${skip} not cloned."
}

status() {
  for repo in "${REPOS[@]}"; do
    if [ ! -d "${SCRIPT_DIR}/${repo}/.git" ]; then
      printf "  %-40s %s\n" "${repo}" "(not cloned)"
      continue
    fi
    local branch dirty ahead behind
    branch=$(git -C "${SCRIPT_DIR}/${repo}" branch --show-current 2>/dev/null || echo "detached")
    dirty=$(git -C "${SCRIPT_DIR}/${repo}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    ahead=$(git -C "${SCRIPT_DIR}/${repo}" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")
    behind=$(git -C "${SCRIPT_DIR}/${repo}" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo "?")

    local info="${branch}"
    [ "${dirty}" != "0" ] && info="${info}, ${dirty} dirty"
    [ "${ahead}" != "0" ] && [ "${ahead}" != "?" ] && info="${info}, ${ahead} ahead"
    [ "${behind}" != "0" ] && [ "${behind}" != "?" ] && info="${info}, ${behind} behind"
    printf "  %-40s %s\n" "${repo}" "${info}"
  done
}

cmd="${1:-clone}"
case "${cmd}" in
  clone)      clone ;;
  clone-fork) clone_fork "${2:-}" ;;
  pull)       pull ;;
  sync-forks) sync_forks "${2:-}" ;;
  status)     status ;;
  help|-h|--help) usage ;;
  *)
    echo "Unknown command: ${cmd}"
    usage
    exit 1
    ;;
esac
