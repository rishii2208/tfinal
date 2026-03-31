#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#
#  Real Coder End-to-End Evaluation Script
#
#  PURPOSE:
#    Execute the tests from tests.zip against the code from codebase.zip.
#    The test suite (tests.zip) is the ground truth; the agent's submission
#    (codebase.zip) is the code under test. Tests are NEVER modified or
#    bundled with the codebase â€” they live in a separate directory and are
#    run against the codebase as-is.
#
#  WHAT THIS SCRIPT DOES:
#    1. Extracts tests.zip into /eval_assets (isolated from the codebase).
#    2. Extracts codebase.zip into /app (the code under test).
#    3. Runs the tests.zip test suite BEFORE injecting codebase.zip
#       to capture a baseline ("before" results).
#    4. Runs the tests.zip test suite AFTER injecting codebase.zip
#       to capture the agent's results ("after" results).
#    5. Compares before vs. after to produce fail_to_pass.json and
#       pass_to_pass.json, then validates the results.
#
#  OUTPUTS (8 files, all written to /app/):
#
#    before_stdout.txt   before_stderr.txt   before.json
#    after_stdout.txt    after_stderr.txt    after.json
#    fail_to_pass.json   pass_to_pass.json
#
#  EXPECTED INPUTS (must all exist in /app/ before the script runs):
#
#    /app/
#    |-- Dockerfile          Docker image definition
#    |-- tests.zip           Hidden test suite (the tests to execute)
#    |-- codebase.zip        Agent's submitted code (the code under test)
#    |-- run.sh              Test runner script
#    `-- parsing.py          Parses test output into JSON
#
#  VALIDATION RULES (any violation causes the script to exit non-zero):
#    - Tests must NOT originate from /app â€” they must come from /eval_assets.
#    - No regressions: tests that PASSED before must not FAIL after.
#    - No pass-to-pass: tests must not stay PASSED from before to after.
#    - At least one fail-to-pass test must exist.
#
#  IMPORTANT: The test suite runs entirely from /eval_assets.
#             Nothing from the test suite is ever placed into /app.
#             /app contains ONLY the agent's codebase â€” never the tests.
#
# =============================================================================

# -- Where everything lives on the host --------------------------------------
# Always resolve paths relative to this script's directory (not your shell cwd).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$SCRIPT_DIR"

# Bundle layout: either task_2/app (this repo) or app/ at repo root
if [[ -f "${SCRIPT_DIR}/app/Dockerfile" ]]; then
  APP_DIR="${SCRIPT_DIR}/app"
elif [[ -f "${SCRIPT_DIR}/task_2/app/Dockerfile" ]]; then
  APP_DIR="${SCRIPT_DIR}/task_2/app"
else
  echo "ERROR: Could not find evaluation bundle (Dockerfile, tests.zip, etc.)." >&2
  echo "       Looked for: ${SCRIPT_DIR}/app/Dockerfile" >&2
  echo "                 or ${SCRIPT_DIR}/task_2/app/Dockerfile" >&2
  echo "       Tip: run from repo root:  bash task_2/verification.sh" >&2
  echo "            or from task_2:       cd task_2 && bash verification.sh" >&2
  exit 1
fi

export VERIFY_APP_DIR="$APP_DIR"

# -- Input files (must all exist in APP_DIR) ----------------------------------
DOCKERFILE="${APP_DIR}/Dockerfile"
TESTS_ZIP="${APP_DIR}/tests.zip"
CODEBASE_ZIP="${APP_DIR}/codebase.zip"
RUN_SCRIPT="${APP_DIR}/run.sh"
PARSE_SCRIPT="${APP_DIR}/parsing.py"

# -- Docker image tag ---------------------------------------------------------
IMAGE_TAG="agent-evaluator:latest"

# -- Zip nesting guard --------------------------------------------------------
# Error out if ALL files in a zip are buried deeper than this many levels.
# e.g. 3 allows: file.py, dir/file.py, dir/sub/file.py -- but not deeper.
MAX_ZIP_DEPTH=3

# -- Container ID (populated after docker run) --------------------------------
CONTAINER_ID=""

# -- Auto-cleanup: stop the container when the script exits (success or fail) -
trap '[[ -n "$CONTAINER_ID" ]] && docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true' EXIT


# =============================================================================
# PRE-FLIGHT: Make sure all 5 required files exist
# =============================================================================
echo "[*] Checking required files..."
for f in "$DOCKERFILE" "$TESTS_ZIP" "$CODEBASE_ZIP" "$RUN_SCRIPT" "$PARSE_SCRIPT"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: Required file not found: $f" >&2
        exit 1
    fi
    echo "    OK: $(basename "$f")"
done


# =============================================================================
# STEP 1 of 6: Build Docker image
# =============================================================================
echo ""
echo "[STEP 1/6] Building Docker image (${IMAGE_TAG})..."
docker build -f "$DOCKERFILE" -t "$IMAGE_TAG" --rm "$APP_DIR"


# =============================================================================
# STEP 2 of 6: Start a long-running container
#
#   We use "tail -f /dev/null" so the container stays alive while we
#   docker-exec commands into it. The EXIT trap cleans it up at the end.
# =============================================================================
echo ""
echo "[STEP 2/6] Starting container..."
CONTAINER_ID=$(docker run -d --rm "$IMAGE_TAG" tail -f /dev/null)
echo "    Container ID: ${CONTAINER_ID:0:12}"


# =============================================================================
# STEP 3 of 6: Inject test assets into /eval_assets inside the container
#
#   We copy three things in:
#     tests.zip   -> unzipped into /eval_assets/
#     run.sh      -> /eval_assets/run_tests   (+ symlink to /usr/local/bin/)
#     parsing.py  -> /eval_assets/parse_results (+ symlink to /usr/local/bin/)
#
#   After this step, you can run "run_tests" and "parse_results" from anywhere
#   inside the container because they are on the PATH.
# =============================================================================
echo ""
echo "[STEP 3/6] Injecting test assets into /eval_assets..."

# Copy the three files into the container
docker cp "$TESTS_ZIP"    "${CONTAINER_ID}:/eval_assets/tests.zip"
docker cp "$RUN_SCRIPT"   "${CONTAINER_ID}:/eval_assets/run_tests"
docker cp "$PARSE_SCRIPT" "${CONTAINER_ID}:/eval_assets/parse_results"

# Unzip tests.zip, validating nesting depth
docker exec -u root -w /eval_assets "$CONTAINER_ID" /bin/bash -c '
    TMPUZ=$(mktemp -d)
    unzip -o /eval_assets/tests.zip -d "$TMPUZ"
    rm -f /eval_assets/tests.zip

    FILE_COUNT=$(find "$TMPUZ" -maxdepth '"$MAX_ZIP_DEPTH"' -type f | wc -l)
    if [ "$FILE_COUNT" -eq 0 ]; then
        echo "ERROR: tests.zip contents are nested too deeply (no files within '"$MAX_ZIP_DEPTH"' levels):" >&2
        find "$TMPUZ" -type f | head -10 >&2
        rm -rf "$TMPUZ"
        exit 1
    fi

    mv "$TMPUZ"/* /eval_assets/ 2>/dev/null || true
    mv "$TMPUZ"/.* /eval_assets/ 2>/dev/null || true
    rm -rf "$TMPUZ"
'

# Make scripts executable and create symlinks so they are on the PATH
docker exec -u root "$CONTAINER_ID" /bin/bash -c '
    chmod +x /eval_assets/run_tests /eval_assets/parse_results
    ln -sf /eval_assets/run_tests    /usr/local/bin/run_tests
    ln -sf /eval_assets/parse_results /usr/local/bin/parse_results
'

echo "    Test suite and scripts ready in /eval_assets."


# =============================================================================
# STEP 4 of 6: Run tests BEFORE injecting the codebase
#
#   At this point /app only has whatever the Dockerfile created (a bare git
#   repo with one initial commit). So this captures the "baseline" test results
#   when the agent's code is NOT present.
#
#   Tests execute from /eval_assets -- nothing touches /app.
# =============================================================================
echo ""
echo "[STEP 4/6] Running tests against empty repo (before)..."

# Run the test suite; capture stdout and stderr separately
docker exec -u root -w /eval_assets "$CONTAINER_ID" \
    /bin/bash -c 'run_tests > stdout.txt 2> stderr.txt' || true

# Parse the raw output into a structured JSON file; fall back to empty test list
docker exec -u root -w /eval_assets "$CONTAINER_ID" \
    /bin/bash -c 'parse_results stdout.txt stderr.txt before.json || echo "{\"tests\": []}" > before.json'

# Copy the three result files back to the host
docker cp "${CONTAINER_ID}:/eval_assets/stdout.txt"  "${APP_DIR}/before_stdout.txt" 2>/dev/null || true
docker cp "${CONTAINER_ID}:/eval_assets/stderr.txt"  "${APP_DIR}/before_stderr.txt" 2>/dev/null || true
docker cp "${CONTAINER_ID}:/eval_assets/before.json" "${APP_DIR}/before.json"

# Remove temp files inside the container so the "after" run starts clean
docker exec -u root -w /eval_assets "$CONTAINER_ID" \
    /bin/bash -c 'rm -f stdout.txt stderr.txt before.json'

echo "    Saved: before_stdout.txt, before_stderr.txt, before.json"


# =============================================================================
# STEP 5 of 6: Inject the agent's codebase into /app
#
#   We unzip codebase.zip into /app, which is the working directory inside
#   the container. After this, /app contains the agent's submitted files.
# =============================================================================
echo ""
echo "[STEP 5/6] Injecting agent's codebase into /app..."

docker cp "$CODEBASE_ZIP" "${CONTAINER_ID}:/tmp/codebase.zip"

# Unzip into /app, validating nesting depth
docker exec -u root -w /app "$CONTAINER_ID" /bin/bash -c '
    TMPUZ=$(mktemp -d)
    unzip -o /tmp/codebase.zip -d "$TMPUZ"
    rm -f /tmp/codebase.zip

    FILE_COUNT=$(find "$TMPUZ" -maxdepth '"$MAX_ZIP_DEPTH"' -type f | wc -l)
    if [ "$FILE_COUNT" -eq 0 ]; then
        echo "ERROR: codebase.zip contents are nested too deeply (no files within '"$MAX_ZIP_DEPTH"' levels):" >&2
        find "$TMPUZ" -type f | head -10 >&2
        rm -rf "$TMPUZ"
        exit 1
    fi

    mv "$TMPUZ"/* /app/ 2>/dev/null || true
    mv "$TMPUZ"/.* /app/ 2>/dev/null || true
    rm -rf "$TMPUZ"
'

echo "    Codebase extracted into /app."


# =============================================================================
# STEP 6 of 6: Run tests AFTER injecting the codebase
#
#   Same process as Step 4, but now /app has the agent's code.
#   Tests still execute from /eval_assets -- they just test whatever is in /app.
# =============================================================================
echo ""
echo "[STEP 6/6] Running tests against agent's codebase (after)..."

# Run the test suite
docker exec -u root -w /eval_assets "$CONTAINER_ID" \
    /bin/bash -c 'run_tests > stdout.txt 2> stderr.txt' || true

# Parse into JSON; fall back to empty test list
docker exec -u root -w /eval_assets "$CONTAINER_ID" \
    /bin/bash -c 'parse_results stdout.txt stderr.txt after.json || echo "{\"tests\": []}" > after.json'

# Copy results back to the host
docker cp "${CONTAINER_ID}:/eval_assets/stdout.txt" "${APP_DIR}/after_stdout.txt" 2>/dev/null || true
docker cp "${CONTAINER_ID}:/eval_assets/stderr.txt" "${APP_DIR}/after_stderr.txt" 2>/dev/null || true
docker cp "${CONTAINER_ID}:/eval_assets/after.json" "${APP_DIR}/after.json"

echo "    Saved: after_stdout.txt, after_stderr.txt, after.json"


# =============================================================================
# STEP 7: Generate fail_to_pass.json and pass_to_pass.json
# =============================================================================
echo ""
echo "[STEP 7] Generating fail_to_pass.json and pass_to_pass.json..."

python3 << 'PYEOF'
import json, sys, os

app_dir = os.environ.get('VERIFY_APP_DIR', 'app')

def load_tests(path):
    try:
        with open(path) as f:
            data = json.load(f)
        tests = data.get('tests', [])
        if not isinstance(tests, list):
            print('WARNING: "tests" in {} is not a list, defaulting to empty.'.format(path), file=sys.stderr)
            return []
        return tests
    except (json.JSONDecodeError, KeyError, TypeError) as e:
        print('WARNING: Failed to parse {}: {}. Defaulting to empty test list.'.format(path, e), file=sys.stderr)
        return []

FAIL_STATUSES = {'FAILED', 'ERROR', 'SKIPPED'}

def normalize(status):
    return 'FAILED' if status in FAIL_STATUSES else status

before_tests = load_tests(os.path.join(app_dir, 'before.json'))
after_tests  = load_tests(os.path.join(app_dir, 'after.json'))

before_map = {t['name']: normalize(t['status']) for t in before_tests}
after_map  = {t['name']: normalize(t['status']) for t in after_tests}

f2p = [name for name, status in before_map.items()
       if status == 'FAILED' and after_map.get(name) == 'PASSED']
new_passes = [name for name, status in after_map.items()
              if name not in before_map and status == 'PASSED']
f2p.extend(new_passes)

p2p = [name for name, status in before_map.items()
       if status == 'PASSED' and after_map.get(name) == 'PASSED']

regressed = [name for name, status in before_map.items()
             if status == 'PASSED' and after_map.get(name) != 'PASSED']

with open(os.path.join(app_dir, 'fail_to_pass.json'), 'w') as f:
    json.dump(f2p, f, indent=2)
with open(os.path.join(app_dir, 'pass_to_pass.json'), 'w') as f:
    json.dump(p2p, f, indent=2)

print('    fail_to_pass.json: {} test(s)'.format(len(f2p)))
print('    pass_to_pass.json: {} test(s)'.format(len(p2p)))

all_test_names = set(before_map.keys()) | set(after_map.keys())
app_tests = [name for name in all_test_names if '/app/' in name or name.startswith('/app')]
if app_tests:
    print('FAILED: {} test(s) originate from /app. Tests must only come from /eval_assets:'.format(len(app_tests)), file=sys.stderr)
    for name in sorted(app_tests):
        print('  - {}'.format(name), file=sys.stderr)
    sys.exit(1)

if regressed:
    print('FAILED: {} test(s) regressed (were PASSED before, not PASSED after):'.format(len(regressed)), file=sys.stderr)
    for name in regressed:
        print('  - {}'.format(name), file=sys.stderr)
    sys.exit(1)

if p2p:
    print('FAILED: {} pass-to-pass test(s) detected. No tests should remain PASSED from before to after:'.format(len(p2p)), file=sys.stderr)
    for name in p2p:
        print('  - {}'.format(name), file=sys.stderr)
    sys.exit(1)

if not f2p:
    print('FAILED: No fail-to-pass tests found.', file=sys.stderr)
    sys.exit(1)
PYEOF


# =============================================================================
# DONE
#
#   The EXIT trap automatically stops the container.
#   All 8 output files are now in /app/:
#
#     before_stdout.txt   -- raw test output (before codebase)
#     before_stderr.txt   -- raw test errors (before codebase)
#     before.json         -- parsed test results (before codebase)
#     after_stdout.txt    -- raw test output (after codebase)
#     after_stderr.txt    -- raw test errors (after codebase)
#     after.json          -- parsed test results (after codebase)
#     fail_to_pass.json   -- tests that went from FAILED to PASSED
#     pass_to_pass.json   -- tests that stayed PASSED
# =============================================================================
echo ""
echo "[*] Done! All outputs saved to ${APP_DIR}/:"
echo "    before_stdout.txt  before_stderr.txt  before.json"
echo "    after_stdout.txt   after_stderr.txt   after.json"
echo "    fail_to_pass.json  pass_to_pass.json"