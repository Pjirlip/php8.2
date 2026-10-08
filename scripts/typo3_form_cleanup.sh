#!/usr/bin/env bash

# typo3_form_cleanup.sh
# Deletes orphaned TYPO3 form upload directories (form_*) older than N days.
# Runs as a Kubernetes CronJob (see cron-jobs/), not inside the web container.
# Concurrency is handled by the CronJob (concurrencyPolicy: Forbid).

set -eu
IFS=$'\n\t'

# --- Configuration ---
DOCUMENT_ROOT="${DOCUMENT_ROOT:-/var/www/html}"
DOCUMENT_ROOT="$(realpath -m "$DOCUMENT_ROOT")"
PROJECT_ROOT="$(dirname "${DOCUMENT_ROOT%/}")"
COMPOSER_JSON="$PROJECT_ROOT/composer.json"

# Upload directory of the form framework relative to DOCUMENT_ROOT (TYPO3 default: 1:/user_upload/)
CLEANUP_FORM_UPLOAD_DIR="${CLEANUP_FORM_UPLOAD_DIR:-fileadmin/user_upload}"
CLEANUP_FORM_KEEP_DAYS="${CLEANUP_FORM_KEEP_DAYS:-2}"
CLEANUP_FORM_DRY_RUN="${CLEANUP_FORM_DRY_RUN:-0}"
LOG_PREFIX="[Cleanup-Typo3]"

# --- Utils ---
log()  { printf "%s %s\n" "$LOG_PREFIX" "$*" ; }
err()  { printf "%s ERROR: %s\n" "$LOG_PREFIX" "$*" >&2 ; }
die()  { err "$*"; exit 1; }

# --- Pre-Checks ---
command -v jq >/dev/null 2>&1 || die "Requirement jq is missing"
[[ -d "$DOCUMENT_ROOT" ]] || die "DOCUMENT_ROOT '$DOCUMENT_ROOT' doesn't exist."
[[ -f "$COMPOSER_JSON" ]] || die "Can't find composer.json in '$PROJECT_ROOT'."
[[ "$CLEANUP_FORM_KEEP_DAYS" =~ ^[0-9]+$ ]] || die "CLEANUP_FORM_KEEP_DAYS must be a positive integer."

if ! jq -e '.require | keys[] | select(startswith("typo3/cms-"))' "$COMPOSER_JSON" >/dev/null; then
  die "Not a TYPO3 project (no typo3/cms-* found in composer.json). Exit Script"
fi

UPLOAD_PATH="$DOCUMENT_ROOT/${CLEANUP_FORM_UPLOAD_DIR#/}"
[[ -d "$UPLOAD_PATH" ]] || die "Upload directory '$UPLOAD_PATH' doesn't exist."

# --- Start ---
log "Start. UPLOAD_PATH=$UPLOAD_PATH, CLEANUP_FORM_KEEP_DAYS=$CLEANUP_FORM_KEEP_DAYS, CLEANUP_FORM_DRY_RUN=$CLEANUP_FORM_DRY_RUN"

deleted=0

# Scoped to the upload directory with a depth limit: never walks the whole DocumentRoot on NFS
while IFS= read -r -d '' upload; do
  if [[ "$CLEANUP_FORM_DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] Would delete: $upload"
  else
    log "Delete: $upload"
    rm -rf -- "$upload" || { err "Failed to delete: $upload"; continue; }
  fi
  ((++deleted))
done < <(
  find "$UPLOAD_PATH" \
    -mindepth 1 -maxdepth 2 \
    -type d -name 'form_*' \
    -mtime +"$CLEANUP_FORM_KEEP_DAYS" \
    -print0 2>/dev/null || true
)

if [[ "$CLEANUP_FORM_DRY_RUN" -eq 1 ]]; then
  log "Dry-Run completed. Amount of directories marked for deletion: $deleted"
else
  log "Finished. Deleted folders: $deleted"
fi
