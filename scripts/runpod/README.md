# RunPod pod-pool scripts

Create and start RunPod pods programmatically via the RunPod REST API
directly — no local `runpodctl` install needed. Works with any of this
repo's images:

| Config template | Pod | Image | Exposure |
|---|---|---|---|
| `config/pods.conf.tei.example` | SPECTER2/TEI embedding server | `docker/tei-runpod/` | HTTP (RunPod proxy) |
| `config/pods.conf.bertopic.example` | BERTopic GPU (cuml UMAP+HDBSCAN) | `docker/bertopic-runpod/` | TCP/22 (SSH) |
| `config/pods.conf.nli.example` | Zero-shot NLI classifier | `docker/nli-runpod/` | HTTP (RunPod proxy) |
| `config/pods.conf.example` | Generic HTTP-pool template | (any HTTP image) | HTTP (RunPod proxy) |

## Usage

```bash
export RUNPOD_API_KEY=...          # your RunPod account API key

cp scripts/runpod/config/pods.conf.tei.example scripts/runpod/config/pods.conf
$EDITOR scripts/runpod/config/pods.conf         # tweak GPU_TYPE_ID / disk sizing / IMAGE tag

scripts/runpod/create_pods.sh -n 1
```

`create_pods.sh` branches on `POD_KIND` in the config:

- **`POD_KIND=http`** — polls
  `https://<pod-id>-<PORT>.proxy.runpod.net<HEALTH_PATH>` until the server
  responds, then prints a ready-to-paste `host:` line for your project's
  config.
- **`POD_KIND=tcp`** — polls `GET /pods/{id}` until RunPod assigns a
  `publicIp` + `portMappings["<PORT>"]` (the TCP port mapping RunPod uses
  for SSH), then prints a ready-to-paste `ssh_host:`/`ssh_port:` block.

In both cases **the script does not edit any project config itself** —
paste the printed block into your own project's config yourself. It also
writes `hosts.generated.csv` (id, name, host, port) for later teardown via
`stop_pods.sh`.

Extra per-pod environment variables (e.g. `PUBLIC_KEY` for SSH access,
object-storage credentials for the bertopic pod's reads) are set via an
`EXTRA_ENV=("KEY=VALUE" ...)` bash array in the config file — see
`config/pods.conf.bertopic.example` for a commented illustration.

## Keeping the API key out of the payload

By default, the local `RUNPOD_API_KEY` you export is also injected as each
created pod's own `RUNPOD_API_KEY` env var (needed by its idle watchdog). That
means the raw key ends up in the pod-creation request body and in
`hosts.generated.csv`.

To avoid that, store the key as a [RunPod
Secret](https://docs.runpod.io/pods/templates/secrets) (console -> Secrets),
then set in `pods.conf`:

```bash
POD_ENV_RUNPOD_API_KEY='{{ RUNPOD_SECRET_runpod_api_key }}'
```

RunPod substitutes the real value only when the pod boots — the literal
template string is what gets sent in the API request, never the key itself.
The `RUNPOD_API_KEY` you export locally is still required as-is; it
authenticates the pod-creation call itself, which happens before any pod (and
thus any Secret substitution) exists.

## Finding a valid GPU type id

`GPU_TYPE_ID` in `pods.conf` must match RunPod's id exactly. List available
ids and current availability:

```bash
curl -s https://rest.runpod.io/v1/gpuTypes \
  -H "Authorization: Bearer $RUNPOD_API_KEY" | jq -r '.[].id'
```

## Tearing down

Each pod created this way still has an idle watchdog baked into the image
(e.g. `docker/tei-runpod/tei_idle_watchdog.sh`,
`docker/bertopic-runpod/bertopic_idle_watchdog.sh`,
`docker/nli-runpod/nli_idle_watchdog.sh`), so it self-stops after `IDLE_MIN`
minutes of inactivity. To act immediately, use `stop_pods.sh`:

```bash
export RUNPOD_API_KEY=...

scripts/runpod/stop_pods.sh                      # stop every pod in hosts.generated.csv
scripts/runpod/stop_pods.sh -d                    # permanently delete them instead
scripts/runpod/stop_pods.sh -i <pod-id>           # target a specific pod id
```

**Stop** (`POST /pods/{id}/stop`, the default) halts the pod — GPU billing
stops, but the pod stays allocated and can be resumed later (RunPod console,
or `POST /pods/{id}/start`). **Delete** (`-d`/`--delete`, `DELETE /pods/{id}`)
removes the pod permanently — stops all billing including storage, but it
cannot be resumed afterward.

When run against the generated inventory (the default — not `-i <pod-id>`),
`hosts.generated.csv` and `hosts.generated.yaml` are deleted once every pod is
successfully actioned, since they'd otherwise reference pods that no longer
exist or are stopped.

## Watching the bertopic pod

`pod_watch.sh` and `pod_log_tail.sh` connect over SSH using the connection
details in `hosts.generated.yaml` (written by `create_pods.sh` — always
reflects the most recently created pod, independent of whatever is currently
pasted into your project's own config):

```bash
scripts/runpod/pod_watch.sh              # poll process CPU/mem + nvidia-smi every 5s
scripts/runpod/pod_watch.sh 10           # ...every 10s instead

scripts/runpod/pod_log_tail.sh           # tail /work/bertopic-current.log (boot/watchdog)
scripts/runpod/pod_log_tail.sh python    # tail /work/python.log (GPU script progress — use this one)
```

Both tee their output to a timestamped file under `output/pod_logs/`
(relative to wherever you run them from) so a session survives even if the
pod is evicted or SSH drops. These two scripts are specific to the SSH-based
bertopic pod; the NLI and TEI pods are HTTP services with no SSH access, so
their idle activity is instead visible via each pod's own `/metrics`
endpoint.

## Watching HTTP-based pods (TEI, NLI)

`http-pool/watch_gpu.sh` and `http-pool/keep_alive.sh` work with any
HTTP-based image in this repo, driven entirely by the URLs you pass in
(not tied to any project's config format):

```bash
scripts/runpod/http-pool/watch_gpu.sh -u https://<host>       # nli-runpod (default metric)
scripts/runpod/http-pool/watch_gpu.sh -u https://<host> --metric te_request_count --unit embeds/s  # tei-runpod

scripts/runpod/http-pool/keep_alive.sh -u https://<host> --loop 240                       # nli-runpod (default path/body)
scripts/runpod/http-pool/keep_alive.sh -u https://<host> --path /embed --body '{"inputs":"keepalive"}'  # tei-runpod
```

See each script's `-h` for the full flag set.

## Notes / things to verify against current RunPod docs

RunPod's API has changed shape before (e.g. from an older GraphQL API to
`rest.runpod.io/v1`). If `create_pods.sh` fails with a validation error on a
field like `cloudType`, check the current request body schema at
`https://docs.runpod.io/api-reference/pods/POST/pods` and adjust
`pods.conf`/the script accordingly.
