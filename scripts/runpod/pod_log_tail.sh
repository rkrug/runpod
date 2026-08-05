#!/usr/bin/env bash
# Tail one of a bertopic-runpod pod's persistent logs.
#
# Reads SSH host/port/user/key from scripts/runpod/hosts.generated.yaml
# (written by create_pods.sh), so you don't have to retype the connection
# details every time the pod is redeployed. Note this can drift from
# whatever you've pasted into your own project's config if you paste the
# printed values in late, or edit ssh_host/port there by hand — this
# script always reflects the most recently created pod, not whatever is
# currently configured for your pipeline.
#
# Three log selectors:
#   current   /work/bertopic-current.log   — entrypoint + idle-watchdog
#   previous  /work/bertopic-previous.log  — same but rotated from prior boot
#   python    /work/python.log             — the GPU script's stdout/stderr,
#                                            if your orchestrator tees it there
#                                            independently of block-buffered
#                                            SSH stdout
#
# Use 'python' for "is the workload making progress?". Use 'current'
# only for boot / watchdog state.
#
# Usage:
#   ./scripts/runpod/pod_log_tail.sh           # tail bertopic-current.log
#   ./scripts/runpod/pod_log_tail.sh previous  # tail bertopic-previous.log
#   ./scripts/runpod/pod_log_tail.sh python    # tail python.log (GPU script output)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_YAML="${SCRIPT_DIR}/hosts.generated.yaml"
if [[ ! -f "${HOSTS_YAML}" ]]; then
    echo "${HOSTS_YAML} not found." >&2
    echo "Create a bertopic pod first: scripts/runpod/create_pods.sh -n 1 -c scripts/runpod/config/pods.conf.bertopic.example" >&2
    exit 1
fi

# Pull SSH details out of hosts.generated.yaml via Rscript — keeps a
# single source of truth and survives ssh_host/port churn between pod
# redeployments.
eval "$(Rscript -e "
y <- yaml::read_yaml('${HOSTS_YAML}')
cat(sprintf('SSH_HOST=%s\nSSH_PORT=%s\nSSH_USER=%s\nSSH_KEY=%s\n',
            shQuote(y\$ssh_host), shQuote(y\$ssh_port),
            shQuote(y\$ssh_user), shQuote(path.expand(y\$ssh_key_path))))
" | grep '^SSH_')"

WHICH="${1:-current}"
case "${WHICH}" in
    current)  LOG="/work/bertopic-current.log"  ;;
    previous) LOG="/work/bertopic-previous.log" ;;
    python)   LOG="/work/python.log"            ;;
    *) echo "Unknown log selector '${WHICH}' (expected 'current', 'previous', or 'python')." >&2; exit 2 ;;
esac

LOG_DIR="output/pod_logs"
mkdir -p "${LOG_DIR}"
LOCAL_LOG="${LOG_DIR}/pod_log_${WHICH}_$(date +%Y-%m-%d_%H%M%S).log"

echo "→ tailing ${LOG} on ${SSH_USER}@${SSH_HOST}:${SSH_PORT} (Ctrl-C to exit)"
echo "→ logging to ${LOCAL_LOG}"

{
    echo "# pod_log_tail.sh session"
    echo "# started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# pod:     ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
    echo "# remote log: ${LOG}"
    echo "#"

    ssh -i "${SSH_KEY}" -p "${SSH_PORT}" \
        -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=60 \
        "${SSH_USER}@${SSH_HOST}" "tail -f ${LOG}"

    echo "#"
    echo "# ended: $(date '+%Y-%m-%d %H:%M:%S')"
} | tee "${LOCAL_LOG}"
