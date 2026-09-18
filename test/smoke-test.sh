#!/usr/bin/env bash
# Consistent local verification for every image under docker/ and for the
# scripts/runpod/ pod-lifecycle layer. This formalizes the checks that were
# originally run by hand while building this repo, so the same coverage
# applies after any change — and to any new docker/<name>/ image.
#
# What it checks (no RunPod account or GPU required):
#   - shellcheck across every .sh file
#   - each docker/<image>/ builds successfully
#   - an image-specific smoke test where one exists (see the dispatch case
#     below): nli-runpod runs its full /health + /classify + /metrics cycle
#     on CPU; the tei-runpod-<model> embedding images are built against TEI's
#     cpu-* base and run a /health + /embed + /metrics cycle (also asserting
#     the baked-in weights are used rather than re-downloaded);
#     bertopic-runpod's entrypoint (sshd, heartbeat file, baked-in script) is
#     checked via docker exec; tei-runpod is build-only verified (its
#     SPECTER2 stack pins a GPU-only TEI tag, so nothing further runs locally)
#   - scripts/runpod/http-pool/{keep_alive,watch_gpu}.sh against a throwaway
#     local HTTP server, for both the default (nli) and an overridden
#     (tei-style --path/--body / --metric) contract
#   - create_pods.sh / stop_pods.sh argument and env validation, and that
#     every scripts/runpod/config/*.example template sources cleanly
#
# When adding a new docker/<name>/ image: it gets build-only coverage for
# free (the loop below is not hardcoded to specific image names). Add a
# `smoke_<name>` function and a case arm to also exercise its entrypoint —
# see smoke_nli/smoke_bertopic for the pattern.
#
# Usage:
#   test/smoke-test.sh                # everything
#   test/smoke-test.sh --skip-docker  # shellcheck + dry-run validation only (no docker needed)
#   test/smoke-test.sh --skip-build   # smoke-test against already-built runpod-smoketest/* images
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

SKIP_DOCKER=0
SKIP_BUILD=0
for arg in "$@"; do
  case "${arg}" in
    --skip-docker) SKIP_DOCKER=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)
      echo "Usage: $0 [--skip-docker] [--skip-build]"
      exit 0
      ;;
    *) echo "error: unknown argument '${arg}'" >&2; exit 1 ;;
  esac
done

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

cleanup() {
  docker rm -f nli-runpod-smoketest bertopic-runpod-smoketest tei-embed-smoketest >/dev/null 2>&1 || true
  [[ -n "${FAKE_SRV_PID:-}" ]] && kill "${FAKE_SRV_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  mapfile -t sh_files < <(find . -name "*.sh")
  if shellcheck -S warning "${sh_files[@]}"; then
    pass "shellcheck"
  else
    fail "shellcheck (see output above)"
  fi
else
  echo "[skip] shellcheck not installed"
fi

echo ""
echo "== nli-runpod / nli-runpod-bge-m3 server.py parity =="
# docker/nli-runpod-bge-m3/server.py is a deliberate COPY of
# docker/nli-runpod/server.py (one-self-contained-directory-per-image), so the
# two silently drift the moment someone edits one and not the other. That is not
# hypothetical: commit 52b263d added the passes:1 direct-classifier mode to
# nli-runpod only, and because ClassifyRequest declared neither `passes` nor
# `hypothesis` -- and pydantic ignores unknown fields by default -- the bge-m3
# image silently DROPPED both for weeks instead of erroring. A passes:1 client
# would have been scored with 3-pass zero-shot against the default
# "This example is {}." template rather than its own hypothesis.
#
# This asserts the copies are byte-identical after reversing the only intended
# per-image differences. Adding a legitimate new difference means adding it to
# EXPECTED below, deliberately, rather than letting the check rot.
if command -v python3 >/dev/null 2>&1; then
  if python3 - <<'PARITY'
import io, sys

A = "docker/nli-runpod/server.py"
B = "docker/nli-runpod-bge-m3/server.py"
a = io.open(A, encoding="utf-8").read()
b = io.open(B, encoding="utf-8").read()

# (bge-m3 text, nli-runpod text) -- the intended per-image differences.
EXPECTED = [
    ('"""Minimal zero-shot NLI inference server (multilingual, long-context variant).\n',
     '"""Minimal zero-shot NLI inference server.\n'),
    ("  NLI_MODEL        model id (default: MoritzLaurer/bge-m3-zeroshot-v2.0-c)",
     "  NLI_MODEL        model id (default: MoritzLaurer/deberta-v3-large-zeroshot-v2.0)"),
    ('    "NLI_MODEL", "MoritzLaurer/bge-m3-zeroshot-v2.0-c"',
     '    "NLI_MODEL", "MoritzLaurer/deberta-v3-large-zeroshot-v2.0"'),
    ('MAX_LENGTH = int(os.environ.get("NLI_MAX_LENGTH", "2048"))',
     'MAX_LENGTH = int(os.environ.get("NLI_MAX_LENGTH", "512"))'),
    ('app = FastAPI(title="nli-runpod-bge-m3", version="0.1.0")',
     'app = FastAPI(title="nli-runpod", version="0.1.0")'),
]
# Two block-level differences, matched by their start/end markers rather than
# verbatim so prose edits inside them do not fail the check.
BLOCKS = [
    ("A deliberate COPY of docker/nli-runpod/server.py",
     "Why not the ``zero-shot-classification`` pipeline?", ""),
    ("  NLI_MAX_LENGTH   tokenizer truncation length (default: 2048",
     "actually sends)",
     "  NLI_MAX_LENGTH   tokenizer truncation length (default: 512)"),
]

problems = []
for src, dst in EXPECTED:
    if src not in b:
        problems.append("expected bge-m3-specific text is missing: %r" % src[:70])
    else:
        b = b.replace(src, dst)
for start, end, repl in BLOCKS:
    if start not in b:
        problems.append("expected bge-m3-specific block is missing: %r" % start[:70])
        continue
    i = b.index(start)
    j = b.index(end, i) + (0 if repl == "" else len(end))
    b = b[:i] + repl + b[j:]

if b != a and not problems:
    import difflib
    d = [l for l in difflib.unified_diff(a.split("\n"), b.split("\n"),
                                         fromfile=A, tofile=B + " (normalised)",
                                         lineterm="", n=1)]
    problems.append("files differ beyond the intended per-image differences:")
    problems.extend(d[:40])

if problems:
    print("\n".join("  " + str(x) for x in problems))
    sys.exit(1)
sys.exit(0)
PARITY
  then
    pass "nli server.py parity (bge-m3 is an exact copy modulo intended diffs)"
  else
    echo "  Fix: re-derive docker/nli-runpod-bge-m3/server.py FROM docker/nli-runpod/server.py"
    echo "       and re-apply only the intended substitutions -- do not hand-port features."
    fail "nli server.py parity"
  fi
else
  echo "[skip] python3 not installed"
fi

echo ""
echo "== idle-watchdog copy parity =="
# Same reasoning as the server.py check above: several images carry a
# deliberate COPY of another image's watchdog, differing only by a provenance
# comment. The originals of all of them shared three bugs (idle timer starting
# before first use, IDLE_MIN=0 stopping immediately, a never-usable pod never
# stopping); fixing one and missing a copy is exactly how that would return.
if command -v python3 >/dev/null 2>&1; then
  if python3 - <<'WDPARITY'
import io, sys

# canonical -> copies that must match it modulo their provenance comment
GROUPS = {
    "docker/nli-runpod/nli_idle_watchdog.sh": [
        "docker/nli-runpod-bge-m3/nli_idle_watchdog.sh",
    ],
    "docker/tei-runpod/tei_idle_watchdog.sh": [
        "docker/tei-runpod-bge-large-en-v1.5/tei_idle_watchdog.sh",
        "docker/tei-runpod-gte-large-en-v1.5/tei_idle_watchdog.sh",
    ],
}

def strip_note(text):
    """Drop the '# Identical to docker/...' provenance paragraph plus the ONE
    '#' separator line that follows it. The note sits between two '#' lines in
    the copy, so removing the note and exactly one separator restores the
    canonical shape -- dropping both separators would under-count by a line and
    report a difference that is not there."""
    lines = text.split("\n")
    out, i = [], 0
    while i < len(lines):
        if lines[i].startswith("# Identical to docker/"):
            while i < len(lines) and lines[i].startswith("#"):
                ended = "not a shared file." in lines[i]
                i += 1
                if ended:
                    break
            if i < len(lines) and lines[i].strip() == "#":
                i += 1
            continue
        out.append(lines[i]); i += 1
    return "\n".join(out)

problems = []
for canon, copies in GROUPS.items():
    a = strip_note(io.open(canon, encoding="utf-8").read())
    for c in copies:
        b = strip_note(io.open(c, encoding="utf-8").read())
        if a != b:
            import difflib
            problems.append("%s differs from %s beyond its provenance comment:" % (c, canon))
            problems.extend(list(difflib.unified_diff(
                a.split("\n"), b.split("\n"), fromfile=canon, tofile=c,
                lineterm="", n=1))[:30])

if problems:
    print("\n".join("  " + str(x) for x in problems))
    sys.exit(1)
sys.exit(0)
WDPARITY
  then
    pass "idle-watchdog copy parity (nli x2, tei x3)"
  else
    echo "  Fix: copy the canonical watchdog over the divergent one and re-add only"
    echo "       its '# Identical to docker/...' provenance comment."
    fail "idle-watchdog copy parity"
  fi
else
  echo "[skip] python3 not installed"
fi

echo ""
echo "== create_pods.sh / stop_pods.sh argument & config validation =="
dryrun_ok=1

unset RUNPOD_API_KEY
scripts/runpod/create_pods.sh -c scripts/runpod/config/pods.conf.tei.example >/tmp/rp_smoketest_out 2>&1
[[ $? -eq 0 ]] && { echo "  create_pods.sh should reject a missing -n"; dryrun_ok=0; }

scripts/runpod/create_pods.sh -n 1 -c scripts/runpod/config/pods.conf.tei.example >/tmp/rp_smoketest_out 2>&1
[[ $? -eq 0 ]] && { echo "  create_pods.sh should reject an unset RUNPOD_API_KEY"; dryrun_ok=0; }

export RUNPOD_API_KEY=dummy
scripts/runpod/create_pods.sh -n 1 -c scripts/runpod/config/does_not_exist.conf >/tmp/rp_smoketest_out 2>&1
[[ $? -eq 0 ]] && { echo "  create_pods.sh should reject a missing config file"; dryrun_ok=0; }

unset RUNPOD_API_KEY
scripts/runpod/stop_pods.sh >/tmp/rp_smoketest_out 2>&1
[[ $? -eq 0 ]] && { echo "  stop_pods.sh should reject an unset RUNPOD_API_KEY"; dryrun_ok=0; }

export RUNPOD_API_KEY=dummy
HAD_HOSTS_CSV=0
if [[ -f scripts/runpod/hosts.generated.csv ]]; then
  HAD_HOSTS_CSV=1
  mv -f scripts/runpod/hosts.generated.csv /tmp/rp_smoketest_hosts_backup.csv
fi
scripts/runpod/stop_pods.sh >/tmp/rp_smoketest_out 2>&1
[[ $? -eq 0 ]] && { echo "  stop_pods.sh should fail with no inventory file and no -i"; dryrun_ok=0; }
[[ "${HAD_HOSTS_CSV}" -eq 1 ]] && mv -f /tmp/rp_smoketest_hosts_backup.csv scripts/runpod/hosts.generated.csv
unset RUNPOD_API_KEY
rm -f /tmp/rp_smoketest_out

for tmpl in scripts/runpod/config/*.example; do
  if ! bash -c "source '${tmpl}'; : \"\${IMAGE:?}\"; : \"\${GPU_TYPE_ID:?}\"" >/dev/null 2>&1; then
    echo "  ${tmpl} does not source cleanly, or is missing IMAGE/GPU_TYPE_ID"
    dryrun_ok=0
  fi
done

if [[ "${dryrun_ok}" -eq 1 ]]; then
  pass "pod-lifecycle argument/config validation"
else
  fail "pod-lifecycle argument/config validation"
fi

echo ""
echo "== scripts/runpod/http-pool/{keep_alive,watch_gpu}.sh functional check =="
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PYEOF' &
import http.server

class H(http.server.BaseHTTPRequestHandler):
    count = 0
    def do_GET(self):
        H.count += 3
        body = f"nli_request_count {H.count}\n".encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")
    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", 8199), H).serve_forever()
PYEOF
  FAKE_SRV_PID=$!
  sleep 1

  httppool_ok=1
  scripts/runpod/http-pool/keep_alive.sh -u http://127.0.0.1:8199 >/tmp/rp_smoketest_out 2>&1
  [[ $? -eq 0 ]] || { echo "  keep_alive.sh (default nli contract) failed:"; cat /tmp/rp_smoketest_out; httppool_ok=0; }

  scripts/runpod/http-pool/keep_alive.sh -u http://127.0.0.1:8199 --path /embed --body '{"inputs":"x"}' >/tmp/rp_smoketest_out 2>&1
  [[ $? -eq 0 ]] || { echo "  keep_alive.sh (--path/--body override) failed:"; cat /tmp/rp_smoketest_out; httppool_ok=0; }

  scripts/runpod/http-pool/watch_gpu.sh -u http://127.0.0.1:8199 -n 1 --no-color >/tmp/rp_smoketest_watch_out 2>&1 &
  watch_pid=$!
  sleep 3
  kill "${watch_pid}" >/dev/null 2>&1 || true
  wait "${watch_pid}" 2>/dev/null || true
  if grep -q "pool" /tmp/rp_smoketest_watch_out && grep -qi "busy" /tmp/rp_smoketest_watch_out; then
    :
  else
    echo "  watch_gpu.sh output did not look right:"; cat /tmp/rp_smoketest_watch_out
    httppool_ok=0
  fi
  rm -f /tmp/rp_smoketest_out /tmp/rp_smoketest_watch_out

  kill "${FAKE_SRV_PID}" >/dev/null 2>&1 || true
  wait "${FAKE_SRV_PID}" 2>/dev/null || true
  unset FAKE_SRV_PID

  if [[ "${httppool_ok}" -eq 1 ]]; then
    pass "http-pool scripts functional check"
  else
    fail "http-pool scripts functional check"
  fi
else
  echo "[skip] python3 not found — skipping http-pool functional check"
fi

# ---------------------------------------------------------------------------
# Per-image smoke tests
# ---------------------------------------------------------------------------

smoke_nli() {
  local tag="$1"
  docker rm -f nli-runpod-smoketest >/dev/null 2>&1 || true
  docker run -d --rm --name nli-runpod-smoketest -p 18080:8080 -e NLI_DEVICE=-1 "${tag}" >/dev/null

  local ready=0
  for _ in $(seq 1 24); do
    if curl -sf http://localhost:18080/health >/dev/null 2>&1; then ready=1; break; fi
    sleep 5
  done
  if [[ "${ready}" -ne 1 ]]; then
    echo "  /health never became ready:"
    docker logs nli-runpod-smoketest 2>&1 | tail -30
    docker rm -f nli-runpod-smoketest >/dev/null 2>&1 || true
    return 1
  fi

  local ok=1
  curl -sf http://localhost:18080/classify -H 'Content-Type: application/json' \
    -d '{"sequences":["test"],"candidate_labels":["a","b"]}' >/dev/null 2>&1 || { echo "  /classify failed"; ok=0; }
  curl -sf http://localhost:18080/metrics 2>/dev/null | grep -q nli_request_count || { echo "  /metrics missing nli_request_count"; ok=0; }

  docker rm -f nli-runpod-smoketest >/dev/null 2>&1 || true
  [[ "${ok}" -eq 1 ]]
}

smoke_bertopic() {
  local tag="$1"
  docker rm -f bertopic-runpod-smoketest >/dev/null 2>&1 || true
  docker run -d --name bertopic-runpod-smoketest -p 12222:22 \
    -e PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA test@smoketest" "${tag}" >/dev/null
  sleep 3

  local ok=1
  docker exec bertopic-runpod-smoketest pgrep -x sshd >/dev/null 2>&1 || { echo "  sshd not running"; ok=0; }
  docker exec bertopic-runpod-smoketest test -f /work/.heartbeat || { echo "  /work/.heartbeat missing"; ok=0; }
  docker exec bertopic-runpod-smoketest test -x /opt/run_bertopic_gpu.py || { echo "  /opt/run_bertopic_gpu.py missing/not executable"; ok=0; }

  docker rm -f bertopic-runpod-smoketest >/dev/null 2>&1 || true
  [[ "${ok}" -eq 1 ]]
}

# TEI embedding images that bake in a plain HuggingFace model
# (docker/tei-runpod-*-en-v1.5/). Unlike docker/tei-runpod/ (SPECTER2), these
# are built here against TEI's cpu-* base so they can actually be RUN locally
# rather than only built — see the build loop's per-image build_args.
#
# $2 is the embedding dimensionality the model must return; passing it in
# rather than just checking "some array came back" is what makes this a real
# check — a wrong-model or wrong-pooling bake still returns a plausible-looking
# array, just the wrong width.
smoke_tei_embedding() {
  local tag="$1" expect_dims="$2"
  docker rm -f tei-embed-smoketest >/dev/null 2>&1 || true
  docker run -d --rm --name tei-embed-smoketest -p 18093:8080 "${tag}" >/dev/null

  local ready=0
  # Generous: these run emulated on arm64 hosts, and ONNX session init for a
  # ~1.3-1.7 GB model is the slow part.
  for _ in $(seq 1 48); do
    if curl -sf http://localhost:18093/health >/dev/null 2>&1; then ready=1; break; fi
    sleep 5
  done
  if [[ "${ready}" -ne 1 ]]; then
    echo "  /health never became ready:"
    docker logs tei-embed-smoketest 2>&1 | tail -30
    docker rm -f tei-embed-smoketest >/dev/null 2>&1 || true
    return 1
  fi

  local ok=1

  local dims
  dims="$(curl -sf http://localhost:18093/embed \
      -H 'Content-Type: application/json' \
      -d '{"inputs":"smoke test"}' 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)[0]))' 2>/dev/null)"
  if [[ "${dims}" != "${expect_dims}" ]]; then
    echo "  /embed returned ${dims:-no} dims, expected ${expect_dims}"
    ok=0
  fi

  # The model must be served from the baked-in /model dir, not re-downloaded
  # from the Hub at boot — that's the whole point of the build-time bake, and
  # a TEI_TAG/MODEL_WEIGHTS mismatch is silent otherwise.
  if docker logs tei-embed-smoketest 2>&1 | grep -qi "downloading.*model\.\(onnx\|safetensors\)"; then
    echo "  weights were downloaded at boot — baked-in weights not used"
    ok=0
  fi

  curl -sf http://localhost:18093/metrics 2>/dev/null | grep -q te_request_count \
    || { echo "  /metrics missing te_request_count (idle watchdog depends on it)"; ok=0; }

  docker rm -f tei-embed-smoketest >/dev/null 2>&1 || true
  [[ "${ok}" -eq 1 ]]
}

echo ""
if [[ "${SKIP_DOCKER}" -eq 1 ]]; then
  echo "[skip] --skip-docker: not building or smoke-testing any image"
elif ! command -v docker >/dev/null 2>&1; then
  echo "[skip] docker not found — not building or smoke-testing any image"
else
  for dir in docker/*/; do
    name="$(basename "${dir}")"
    tag="runpod-smoketest/${name}:test"

    echo "== ${name}: build =="
    if [[ "${SKIP_BUILD}" -eq 0 ]]; then
      build_args=()
      case "${name}" in
        tei-runpod) build_args=(--build-arg ADAPTER=proximity) ;;
        # Build the TEI embedding images against TEI's CPU base instead of
        # their default CUDA one, so they can actually be RUN here and not
        # just built. MODEL_WEIGHTS must follow TEI_TAG: the CPU backend
        # reads onnx/model.onnx, the CUDA backends read model.safetensors.
        # NOTE this means what's smoke-tested is the CPU variant, not the
        # GPU artifact you deploy — see each image's "Verification status".
        tei-runpod-*)
          build_args=(--build-arg TEI_TAG=cpu-1.6 --build-arg MODEL_WEIGHTS=onnx) ;;
      esac
      if ! docker buildx build --platform linux/amd64 "${build_args[@]}" -t "${tag}" -f "docker/${name}/Dockerfile" .; then
        fail "${name}: docker build"
        continue
      fi
    fi

    echo "== ${name}: smoke test =="
    case "${name}" in
      nli-runpod|nli-runpod-bge-m3)
        # Same entrypoint contract (server.py's classify/health/metrics logic
        # is byte-identical between the two images, only the baked-in model
        # differs) — reuse smoke_nli() rather than duplicating it.
        if smoke_nli "${tag}"; then pass "${name}: /health, /classify, /metrics"; else fail "${name}: entrypoint smoke test"; fi
        ;;
      bertopic-runpod)
        if smoke_bertopic "${tag}"; then pass "${name}: sshd, heartbeat, baked-in script"; else fail "${name}: entrypoint smoke test"; fi
        ;;
      tei-runpod)
        pass "${name}: build-only verified (GPU-only image, see docker/tei-runpod/README.md)"
        ;;
      tei-runpod-bge-large-en-v1.5|tei-runpod-gte-large-en-v1.5)
        # Both are 1024-dim; the dimensionality is passed explicitly so a
        # wrong-model bake fails loudly rather than returning a
        # plausible-looking array of the wrong width.
        if smoke_tei_embedding "${tag}" 1024; then
          pass "${name}: /health, /embed (1024 dims), /metrics, baked-in weights"
        else
          fail "${name}: entrypoint smoke test"
        fi
        ;;
      *)
        echo "[skip] no smoke-test function for '${name}' yet — build-only verified."
        echo "       Add a smoke_${name//-/_}() function + case arm to this script."
        ;;
    esac
    echo ""
  done
fi

echo "== summary: ${PASS} passed, ${FAIL} failed =="
[[ "${FAIL}" -eq 0 ]]
