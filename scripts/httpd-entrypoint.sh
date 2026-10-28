#!/bin/bash
# Entrypoint of the Apache container: run apache2 in the foreground as the only process. Pod termination
# sends SIGWINCH (image STOPSIGNAL), Apache's graceful stop, so in-flight requests finish first (H1).
set -euo pipefail

if (( $# > 0 )); then
    exec "$@"
fi

# DOCUMENT_ROOT without trailing slash: 000-default.conf appends sub paths to it
if [[ "${DOCUMENT_ROOT:-}" != "/" ]]; then
    export DOCUMENT_ROOT="${DOCUMENT_ROOT%/}"
fi

# runtime directories (emptyDir mounts start empty) and a stale pid file from a previous container
mkdir -p "$APACHE_RUN_DIR" "$APACHE_LOCK_DIR"
rm -f "$APACHE_PID_FILE"

exec apache2 -DFOREGROUND
