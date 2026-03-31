#!/bin/bash
### COMMON SETUP; DO NOT MODIFY ###
set -e

# --- CONFIGURE THIS SECTION ---
# Replace this with your command to run all tests
run_all_tests() {
  echo "Running all tests..."
  # Symlink backend into eval_assets so conftest.py path resolution works
  ln -sf /app/backend /eval_assets/backend 2>/dev/null || true
  # Install any additional deps if requirements file exists
  pip install -r /app/backend/requirements.txt 2>/dev/null || true
  # Run pytest from eval_assets where tests are extracted
  cd /eval_assets
  python -m pytest tests/ -v --tb=short > /eval_assets/_pytest_stdout.txt 2> /eval_assets/_pytest_stderr.txt || true

  # Print captured output to console (verification.sh captures externally)
  cat /eval_assets/_pytest_stdout.txt
  cat /eval_assets/_pytest_stderr.txt >&2

  # Locate parsing.py and generate results.json in the codebase directory
  PARSE_SCRIPT=""
  if [ -f /eval_assets/parse_results ]; then
    PARSE_SCRIPT="/eval_assets/parse_results"
  elif [ -f /eval_assets/parsing.py ]; then
    PARSE_SCRIPT="/eval_assets/parsing.py"
  elif [ -f /app/parsing.py ]; then
    PARSE_SCRIPT="/app/parsing.py"
  fi

  if [ -n "$PARSE_SCRIPT" ]; then
    python "$PARSE_SCRIPT" /eval_assets/_pytest_stdout.txt /eval_assets/_pytest_stderr.txt /app/results.json
    echo "Generated /app/results.json"
  else
    echo "WARNING: parsing.py not found, skipping results.json generation" >&2
  fi
}
# --- END CONFIGURATION SECTION ---

### COMMON EXECUTION; DO NOT MODIFY ###
run_all_tests