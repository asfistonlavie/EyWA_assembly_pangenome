#!/bin/bash
# ==============================================================================
# TEST 00: Pipeline startup check
#
# HOW TO RUN:
#   bash tests/test_00_startup.sh config/config_test.sh
#
# ==============================================================================

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  TEST 00: Pipeline startup check                         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# The config file to use, the default is config/config_test.sh
CONFIG="${1:-config/config_test.sh}"

# Step 1: Check the config file exists
# Without a config file the pipeline cannot start at all
if [[ ! -f "${CONFIG}" ]]; then
  echo "  FAIL: Config file not found: ${CONFIG}"
  echo ""
  echo "  To create a test config:"
  echo "    cp config/config.template.sh config/config_test.sh"
  echo "    nano config/config_test.sh"
  exit 1
fi
echo "  CHECK: Config file found: ${CONFIG}"

# Step 2: Check the main pipeline script has no syntax errors
# bash -n = dry run, checks syntax without executing anything
if bash -n run_pipeline.sh 2>/dev/null; then
  echo "  CHECK: run_pipeline.sh has no syntax errors"
else
  echo "  FAIL: run_pipeline.sh has syntax errors:"
  bash -n run_pipeline.sh
  exit 1
fi

# Step 3: Check all module files for syntax errors
echo ""
echo "  Checking module syntax..."
all_ok=true
for module in ../0*/[0-9]*.sh; do
  if bash -n "${module}" 2>/dev/null; then
    echo "  CHECK: ${module} has no syntax errors"
  else
    echo "  FAIL: ${module} has syntax errors:"
    bash -n "${module}"
    all_ok=false
  fi
done

if [[ "${all_ok}" == "false" ]]; then
  echo ""
  echo "  One or more modules have syntax errors, fix them before continuing."
  exit 1
fi

# Step 4: Try to start the pipeline (it will stop at validation, that is expected)
# We only look at the first 20 lines of output to see if it starts correctly
echo ""
echo "  Attempting pipeline startup (will stop at validation)..."
echo "  ─────────────────────────────────────────────────────"
bash run_pipeline.sh "${CONFIG}" 2>&1 | head -20
echo "  ─────────────────────────────────────────────────────"

echo ""
echo "  TEST 00 COMPLETE"
echo "  If you see the ONA banner above and no 'command not found' errors,"
echo "  the pipeline can start correctly."
echo ""
