#!/usr/bin/env bash
# Pod entrypoint:
#   1. Inject PUBLIC_KEY env var into /root/.ssh/authorized_keys (if set).
#   2. Bring up sshd so the orchestrator can scp data in and ssh-trigger the script.
#   3. Touch the watchdog heartbeat at boot (so we don't insta-stop).
#   4. Launch the idle watchdog in the background.
#   5. sleep — the pod stays up until someone (or the watchdog) stops it.
#
# Authorized keys: set `PUBLIC_KEY` env var on the pod template to your
# `id_ed25519.pub` content (one line, no quoting). This entrypoint writes
# it to /root/.ssh/authorized_keys at boot so sshd accepts your key
# regardless of RunPod's image-injection cooperation. RunPod's account-
# level SSH-key injection (Settings → SSH Public Keys) also works if it
# writes to that same location.
set -euo pipefail

: "${LOG_DIR:=/work}"                # volume-mounted: logs survive stop/restart

mkdir -p /work "${LOG_DIR}"          # /work always needed (heartbeat / inputs / outputs)
touch /work/.heartbeat               # heartbeat path is fixed; LOG_DIR is independent

# Persist entrypoint+sshd+watchdog logs to the volume so a crashed pod's
# last words survive a restart. Rotate one generation:
# bertopic-current.log → bertopic-previous.log at every boot.
if [ -f "${LOG_DIR}/bertopic-current.log" ]; then
    mv -f "${LOG_DIR}/bertopic-current.log" "${LOG_DIR}/bertopic-previous.log"
fi
BERTOPIC_LOG="${LOG_DIR}/bertopic-current.log"

# Tee this shell's stdout+stderr (and inherited fds of the background
# watchdog) into the persistent log while still streaming to RunPod Logs.
exec > >(tee -a "${BERTOPIC_LOG}") 2>&1
echo "[entrypoint] persisting logs to ${BERTOPIC_LOG} (prior: ${LOG_DIR}/bertopic-previous.log)"

# Inject PUBLIC_KEY → authorized_keys (idempotent; safe to re-boot).
if [ -n "${PUBLIC_KEY:-}" ]; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    echo "${PUBLIC_KEY}" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "[entrypoint] injected PUBLIC_KEY into /root/.ssh/authorized_keys"
else
    echo "[entrypoint] PUBLIC_KEY env var not set — relying on existing /root/.ssh/authorized_keys"
fi

# Configure sshd minimally.
ssh-keygen -A >/dev/null 2>&1 || true   # generate host keys if absent
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/'  /etc/ssh/sshd_config
service ssh start

# External heartbeat keeper — touches /work/.heartbeat every 30 s while
# a /opt/run_bertopic_gpu.py process is running. Lives in entrypoint.sh
# (bash, no GIL) so it's immune to GIL holds inside cuml.UMAP.fit
# (~10-15 min during k-NN graph build) that starve the in-Python
# heartbeat thread. The Python thread is kept as belt-and-braces for
# the object-storage read phase where the GIL is released frequently.
#
# Heartbeat is touched ONLY when the GPU script is alive. When the
# script exits (clean or crash), touches stop and the idle watchdog
# takes over correctly. The pod isn't kept alive past the workload.
#
# NOTE on the pgrep regex: '^python.*/opt/run_bertopic_gpu\.py'.
# Plain pgrep -f '/opt/run_bertopic_gpu.py' matches THIS bash subshell
# itself — its own argv contains the literal string. The loop would
# then touch the heartbeat forever even after python died, defeating
# the watchdog. Anchoring with ^python forces the match to a process
# whose command line STARTS with 'python' (i.e. the actual GPU script
# invocation), excluding any bash shell that just references the
# string.
(
    while true; do
        if pgrep -f '^python.*/opt/run_bertopic_gpu\.py' >/dev/null 2>&1; then
            touch /work/.heartbeat
        fi
        sleep 30
    done
) &
echo "[entrypoint] external heartbeat keeper started (touches /work/.heartbeat every 30 s while a python /opt/run_bertopic_gpu.py process is running)"

# Idle watchdog — auto-stop after IDLE_MIN min of heartbeat inactivity.
# Only meaningful on a real RunPod pod where RUNPOD_POD_ID is set.
if [ -n "${RUNPOD_POD_ID:-}" ]; then
    /usr/local/bin/bertopic_idle_watchdog.sh &
    echo "[entrypoint] idle watchdog started (IDLE_MIN=${IDLE_MIN:-5} min)"
else
    echo "[entrypoint] RUNPOD_POD_ID not set — skipping idle watchdog"
fi

echo "[entrypoint] BERTopic pod ready. SSH in to run /opt/run_bertopic_gpu.py."
echo "[entrypoint] Sleeping forever; pod stops on idle or manual termination."
exec tail -f /dev/null
