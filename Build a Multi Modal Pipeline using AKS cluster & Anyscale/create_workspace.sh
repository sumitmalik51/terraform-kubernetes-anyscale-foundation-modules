#!/usr/bin/env bash
# Create an Anyscale workspace pre-loaded with the Multi-Modal-Template folder.
#
# Defaults are pulled from service.yaml so the new workspace matches the deploy
# environment (same image, same named compute config, same requirements).
#
# Usage:
#   ./create_workspace.sh [-n NAME] [--cloud CLOUD] [--project PROJECT]
#                         [--image IMAGE] [--compute-config CC]
#                         [--no-push] [--no-wait] [--dry-run] [-h]
#
# Overrides via env vars (CLI flags win):
#   WORKSPACE_NAME, ANYSCALE_CLOUD, ANYSCALE_PROJECT,
#   IMAGE_URI, COMPUTE_CONFIG, REQUIREMENTS_FILE
#
# Examples:
#   ./create_workspace.sh
#   ./create_workspace.sh -n my-mm-ws --cloud odl_user_2298227_cloud
#   ./create_workspace.sh --dry-run

set -euo pipefail

# Resolve script dir so this works no matter where it's called from. The
# Multi-Modal-Template/ folder we push is always the script's own directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Defaults (match service.yaml) ─────────────────────────────────────────────
WORKSPACE_NAME="${WORKSPACE_NAME:-multi-model-pipeline}"
IMAGE_URI="${IMAGE_URI:-anyscale/ray-llm:2.56.0-py312-cu130}"
COMPUTE_CONFIG="${COMPUTE_CONFIG:-multi-modal-2298227:2}"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-requirements.txt}"
CLOUD="${ANYSCALE_CLOUD:-}"
PROJECT="${ANYSCALE_PROJECT:-}"

PUSH=1
WAIT=1
DRY_RUN=0

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)            WORKSPACE_NAME="$2"; shift 2 ;;
    --cloud)              CLOUD="$2"; shift 2 ;;
    --project)            PROJECT="$2"; shift 2 ;;
    --image|--image-uri)  IMAGE_URI="$2"; shift 2 ;;
    --compute-config)     COMPUTE_CONFIG="$2"; shift 2 ;;
    --requirements)       REQUIREMENTS_FILE="$2"; shift 2 ;;
    --no-push)            PUSH=0; shift ;;
    --no-wait)            WAIT=0; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    -h|--help)            usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

# ── Preflight ─────────────────────────────────────────────────────────────────
command -v anyscale >/dev/null || { echo "!! anyscale CLI not found" >&2; exit 1; }
if [[ $PUSH -eq 1 ]]; then
  command -v rsync >/dev/null || { echo "!! rsync not found (required by 'anyscale workspace_v2 push')" >&2; exit 1; }
fi
[[ -f "$REQUIREMENTS_FILE" ]] || { echo "!! requirements file not found: $REQUIREMENTS_FILE" >&2; exit 1; }

run() {
  echo "   \$ $*"
  if [[ $DRY_RUN -eq 0 ]]; then "$@"; fi
}

# ── 1. Create ─────────────────────────────────────────────────────────────────
echo ">> Creating workspace '$WORKSPACE_NAME'"
echo "   image:          $IMAGE_URI"
echo "   compute-config: $COMPUTE_CONFIG"
echo "   requirements:   $REQUIREMENTS_FILE"
[[ -n "$CLOUD"   ]] && echo "   cloud:          $CLOUD"
[[ -n "$PROJECT" ]] && echo "   project:        $PROJECT"
echo

create_args=(
  workspace_v2 create
  --name "$WORKSPACE_NAME"
  --image-uri "$IMAGE_URI"
  --compute-config "$COMPUTE_CONFIG"
  --requirements "$REQUIREMENTS_FILE"
)
[[ -n "$CLOUD"   ]] && create_args+=( --cloud "$CLOUD" )
[[ -n "$PROJECT" ]] && create_args+=( --project "$PROJECT" )

run anyscale "${create_args[@]}"

# ── 2. Wait for RUNNING ───────────────────────────────────────────────────────
if [[ $WAIT -eq 1 ]]; then
  echo
  echo ">> Waiting for workspace to reach RUNNING"
  wait_args=( workspace_v2 wait -n "$WORKSPACE_NAME" --state RUNNING )
  [[ -n "$CLOUD"   ]] && wait_args+=( --cloud "$CLOUD" )
  [[ -n "$PROJECT" ]] && wait_args+=( --project "$PROJECT" )
  run anyscale "${wait_args[@]}"
fi

# ── 3. Push the Multi-Modal-Template folder ───────────────────────────────────
if [[ $PUSH -eq 1 ]]; then
  echo
  echo ">> Pushing $(basename "$SCRIPT_DIR")/ to workspace"
  push_args=( workspace_v2 push -n "$WORKSPACE_NAME" --local-dir "$SCRIPT_DIR" )
  [[ -n "$CLOUD"   ]] && push_args+=( --cloud "$CLOUD" )
  [[ -n "$PROJECT" ]] && push_args+=( --project "$PROJECT" )
  # Skip junk that has no business in a workspace snapshot.
  push_args+=( -- --exclude='.DS_Store' --exclude='__pycache__' --exclude='.ipynb_checkpoints' )
  run anyscale "${push_args[@]}"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo ">> Done."
echo
echo "Next steps:"
echo "   anyscale workspace_v2 ssh -n $WORKSPACE_NAME"
echo "   anyscale workspace_v2 run_command -n $WORKSPACE_NAME -- python client.py"
echo "   anyscale workspace_v2 terminate -n $WORKSPACE_NAME   # when done"
