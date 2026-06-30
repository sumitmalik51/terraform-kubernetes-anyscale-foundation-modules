#!/usr/bin/env bash
# =============================================================================
# Anyscale Teardown — Multi-Model Content Pipeline
# =============================================================================
#
# Tears down the demo end-to-end and then removes itself, leaving the repo
# clean. Run order is bottom-up so each step's dependents are already gone:
#
#   1. Terminate the Ray Serve service
#   2. Terminate the workspace (frees the cluster)
#   3. Delete the Anyscale cloud (frees the registered infra)
#   4. Self-delete this script
#
# Usage:
#   ./cleanup.sh                          # interactive, defaults from project
#   ./cleanup.sh -y                       # non-interactive (skip prompts)
#   ./cleanup.sh --keep                   # run teardown but don't self-delete
#   ./cleanup.sh --dry-run                # print commands, change nothing
#
#   SERVICE=foo WORKSPACE=bar CLOUD=baz ./cleanup.sh
#
# Flags override env vars; env vars override the project defaults below.
# Each step is idempotent: an already-gone resource is treated as success.
# =============================================================================

set -uo pipefail

# -- Defaults pulled from this project's configs -----------------------------
SERVICE="${SERVICE:-multi-model-content-pipeline}"
WORKSPACE="${WORKSPACE:-multi-model-pipeline}"
CLOUD="${CLOUD:-odl_user_2298227_cloud}"

ASSUME_YES=0
DRY_RUN=0
KEEP_SCRIPT=0

# -- CLI parsing -------------------------------------------------------------
usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)        ASSUME_YES=1; shift ;;
    --dry-run)       DRY_RUN=1;    shift ;;
    --keep)          KEEP_SCRIPT=1; shift ;;
    --service)       SERVICE="$2";   shift 2 ;;
    --workspace)     WORKSPACE="$2"; shift 2 ;;
    --cloud)         CLOUD="$2";     shift 2 ;;
    -h|--help)       usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

# -- Output helpers ----------------------------------------------------------
c_red()    { printf '\033[31m%s\033[0m' "$*"; }
c_green()  { printf '\033[32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m'  "$*"; }

step() {
  echo
  echo "$(c_bold "──") $(c_bold "$*")"
}

run() {
  echo "  $ $*"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  "$@"
}

confirm() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  local prompt="$1"
  read -r -p "$(c_yellow "$prompt") [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# -- Sanity check ------------------------------------------------------------
if ! command -v anyscale >/dev/null 2>&1; then
  echo "$(c_red "ERROR:") 'anyscale' CLI not found. Install with: pip install anyscale" >&2
  exit 1
fi

cat <<EOF

$(c_bold "Anyscale teardown plan")

  Service    : $SERVICE
  Workspace  : $WORKSPACE
  Cloud      : $CLOUD
  Dry-run    : $([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)
  Self-delete: $([[ $KEEP_SCRIPT -eq 1 ]] && echo no || echo yes)

$(c_red "This will permanently terminate the above resources.")
EOF

if ! confirm "Proceed with teardown?"; then
  echo "Aborted."
  exit 0
fi

# Track failures but keep going so partial teardown doesn't strand resources.
FAILED_STEPS=()

# -- 1. Terminate the service ------------------------------------------------
step "1/3  Terminating service '$SERVICE'"
if run anyscale service terminate --name "$SERVICE"; then
  echo "  $(c_green "✓") service terminate requested"
else
  rc=$?
  echo "  $(c_yellow "!") service terminate returned $rc (already gone? continuing)"
  FAILED_STEPS+=("service:$rc")
fi

# -- 2. Terminate the workspace ----------------------------------------------
step "2/3  Terminating workspace '$WORKSPACE'"
# `workspace_v2` is the current command; fall back to `workspace` for old CLIs.
if run anyscale workspace_v2 terminate --name "$WORKSPACE" 2>/dev/null \
   || run anyscale workspace terminate --name "$WORKSPACE"; then
  echo "  $(c_green "✓") workspace terminate requested"
else
  rc=$?
  echo "  $(c_yellow "!") workspace terminate returned $rc (already gone? continuing)"
  FAILED_STEPS+=("workspace:$rc")
fi

# -- 3. Delete the Anyscale cloud --------------------------------------------
step "3/3  Deleting cloud '$CLOUD'"
echo "  $(c_yellow "!") cloud deletion removes the registered infra binding."
if [[ "$ASSUME_YES" -eq 1 ]]; then
  CLOUD_YES_FLAG="--yes"
else
  CLOUD_YES_FLAG=""
fi
if run anyscale cloud delete --name "$CLOUD" $CLOUD_YES_FLAG; then
  echo "  $(c_green "✓") cloud delete requested"
else
  rc=$?
  echo "  $(c_yellow "!") cloud delete returned $rc (already gone? continuing)"
  FAILED_STEPS+=("cloud:$rc")
fi

# -- Summary -----------------------------------------------------------------
echo
if [[ ${#FAILED_STEPS[@]} -eq 0 ]]; then
  echo "$(c_green "All teardown steps completed.")"
else
  echo "$(c_yellow "Completed with warnings:") ${FAILED_STEPS[*]}"
  echo "Verify in the Anyscale console before re-running."
fi

# -- 4. Self-delete ----------------------------------------------------------
if [[ "$KEEP_SCRIPT" -eq 1 ]]; then
  echo "Leaving script in place (--keep)."
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry-run: would remove $0"
  exit 0
fi

if confirm "Remove this cleanup script ($0)?"; then
  # Resolve the real path before deleting in case we were invoked via symlink.
  SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  rm -f -- "$SCRIPT_PATH" && echo "$(c_green "✓") removed $SCRIPT_PATH"
else
  echo "Script kept at $0."
fi
