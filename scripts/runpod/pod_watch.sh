#!/usr/bin/env bash
# Watch a bertopic-runpod pod's process + GPU state every N seconds.
#
# Reads SSH host/port/user/key from scripts/runpod/hosts.generated.yaml
# (written by create_pods.sh), so you don't have to retype the connection
# details every time the pod is redeployed. Note this can drift from
# whatever you've pasted into your own project's config if you paste the
# printed values in late, or edit ssh_host/port there by hand — this
# script always reflects the most recently created pod, not whatever is
# currently configured for your pipeline.
#
# What the loop reports:
#   - elapsed CPU time and resource usage of the python script process
#   - current GPU utilization and memory usage
#
# Usage:
#   ./scripts/runpod/pod_watch.sh           # poll every 5 seconds (default)
#   ./scripts/runpod/pod_watch.sh 10        # poll every 10 seconds
#
# Output is shown on stdout AND tee'd to a timestamped local log file
# under output/pod_logs/ (relative to wherever you run this from). Logs
# survive even if the pod is evicted or SSH disconnects — useful for
# postmortem when the persistent pod-side log is lost with the volume.
#
# Also renders a live 4-panel PNG (pod_mem%, cpu%, rss GB, gpu_mem GB) next
# to the log file, re-rendered every PLOT_INTERVAL seconds by
# plot_pod_watch.R running in the background — open it once in macOS
# Preview (open output/pod_logs/*.png) and it auto-refreshes as the file
# changes. On macOS a self-refreshing browser tab (pod_watch_*.monitor.html)
# is also opened automatically, polling the PNG every PLOT_INTERVAL seconds —
# useful when Preview's own file-watch reload lags. Set PLOT_INTERVAL=0 to
# disable both.
set -euo pipefail

PLOT_INTERVAL="${PLOT_INTERVAL:-10}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_YAML="${SCRIPT_DIR}/hosts.generated.yaml"
if [[ ! -f "${HOSTS_YAML}" ]]; then
    echo "${HOSTS_YAML} not found." >&2
    echo "Create a bertopic pod first: scripts/runpod/create_pods.sh -n 1 -c scripts/runpod/config/pods.conf.bertopic.example" >&2
    exit 1
fi

eval "$(Rscript -e "
y <- yaml::read_yaml('${HOSTS_YAML}')
cat(sprintf('SSH_HOST=%s\nSSH_PORT=%s\nSSH_USER=%s\nSSH_KEY=%s\n',
            shQuote(y\$ssh_host), shQuote(y\$ssh_port),
            shQuote(y\$ssh_user), shQuote(path.expand(y\$ssh_key_path))))
" | grep '^SSH_')"

INTERVAL="${1:-5}"

# Set up local logging, relative to the current working directory (your
# project repo), not this script's location — logs belong with whichever
# project is running the watch.
LOG_DIR="output/pod_logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/pod_watch_$(date +%Y-%m-%d_%H%M%S).log"
touch "${LOG_FILE}"

echo "→ watching ${SSH_USER}@${SSH_HOST}:${SSH_PORT} every ${INTERVAL}s (Ctrl-C to exit)"
echo "→ logging to ${LOG_FILE}"

PLOT_PID=""
if [[ "${PLOT_INTERVAL}" -gt 0 ]]; then
    Rscript "${SCRIPT_DIR}/plot_pod_watch.R" "${LOG_FILE}" --watch --interval "${PLOT_INTERVAL}" \
        > "${LOG_FILE%.log}.plot.log" 2>&1 &
    PLOT_PID="$!"
    trap '[[ -n "${PLOT_PID}" ]] && kill "${PLOT_PID}" 2>/dev/null' EXIT INT TERM
    echo "→ live plot: ${LOG_FILE%.log}.png (refreshes every ${PLOT_INTERVAL}s; open it in Preview)"

    # Also open a self-refreshing browser tab on macOS, so the plot updates
    # live without needing Preview's own (sometimes laggy) file-watch reload.
    # Cache-busted via a Date.now() query string since file:// URLs are
    # otherwise aggressively cached by the browser.
    if [[ "$(uname -s)" == "Darwin" ]]; then
        PNG_PATH="$(cd "${LOG_DIR}" && pwd)/$(basename "${LOG_FILE%.log}.png")"
        MONITOR_HTML="${LOG_FILE%.log}.monitor.html"
        REFRESH_MS=$(( PLOT_INTERVAL * 1000 ))
        cat > "${MONITOR_HTML}" << EOF
<html><body style="margin:0;background:#000">
<img id="i" src="file://${PNG_PATH}" style="max-width:100vw;max-height:100vh">
<script>setInterval(()=>{document.getElementById('i').src='file://${PNG_PATH}?'+Date.now()},${REFRESH_MS})</script>
</body></html>
EOF
        open "${MONITOR_HTML}"
        echo "→ live monitor tab: ${MONITOR_HTML}"
    fi
fi

# tee captures stdout to the log while still showing in the terminal.
# The leading metadata block records pod identity + start time so a
# later postmortem can correlate to the right pod.
{
    echo "# pod_watch.sh session"
    echo "# started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# pod:     ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
    echo "# interval: ${INTERVAL}s"
    echo "#"

    ssh -i "${SSH_KEY}" -p "${SSH_PORT}" \
        -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=60 \
        "${SSH_USER}@${SSH_HOST}" \
        "
        # Read the pod's cgroup memory limit once. RunPod uses cgroups v2
        # (memory.max under /sys/fs/cgroup/). ps's pmem reads the host's
        # total (~1 TB on shared hosts) so it underreports the pod-level
        # pressure. We use the cgroup limit to compute pod_mem% which
        # matches the RunPod dashboard.
        #
        # cgroup files report BYTES. ps reports rss in KB. We normalise
        # to KB everywhere for the awk arithmetic.
        POD_RAM_BYTES=
        if [ -f /sys/fs/cgroup/memory.max ]; then
            POD_RAM_BYTES=\$(cat /sys/fs/cgroup/memory.max)
        elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
            POD_RAM_BYTES=\$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
        fi
        if [ \"\$POD_RAM_BYTES\" = max ] || [ -z \"\$POD_RAM_BYTES\" ]; then
            # cgroup says unlimited; fall back to /proc/meminfo MemTotal
            # (already in KB).
            POD_RAM_KB=\$(awk '/MemTotal/{print \$2}' /proc/meminfo)
        else
            POD_RAM_KB=\$((POD_RAM_BYTES / 1024))
        fi
        echo \"# pod RAM limit: \$((POD_RAM_KB / 1024 / 1024)) GB\"
        echo

        while sleep ${INTERVAL}; do
            echo '--- '\$(date +%T)' ---'
            # Match the python process specifically. Plain pgrep -f also
            # matches:
            #   * the wrapper's bash shell that exec'd python
            #   * the entrypoint's heartbeat-keeper bash loop, whose argv
            #     literally contains '/opt/run_bertopic_gpu.py'
            # Both look like 0%/0 GB processes and mask the real numbers.
            # Filter ps -eo so command starts with 'python' and contains
            # the script path.
            pid=\$(ps -eo pid,comm,args --no-headers | \
                   awk '\$2 ~ /^python/ && /\\/opt\\/run_bertopic_gpu\\.py/ {print \$1; exit}')
            if [ -n \"\$pid\" ]; then
                # ps prints vsz / rss in KB. awk converts to GB and also
                # computes pod_mem% = rss_bytes / cgroup_limit_bytes.
                ps -o etime,pcpu,vsz,rss --pid \$pid --no-headers | \
                    awk -v pod_ram=\$POD_RAM_KB '{
                        pod_pct = (\$4 * 100.0) / pod_ram
                        printf \"  etime=%-8s cpu=%5.1f%%  pod_mem=%5.1f%%  vsz=%6.1fGB  rss=%6.1fGB\\n\", \
                               \$1, \$2, pod_pct, \$3/1024/1024, \$4/1024/1024
                    }'
            else
                echo 'no python /opt/run_bertopic_gpu.py process running'
            fi
            nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader
        done"

    echo "#"
    echo "# ended: $(date '+%Y-%m-%d %H:%M:%S')"
} | tee "${LOG_FILE}"
