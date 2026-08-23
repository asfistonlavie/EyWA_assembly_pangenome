#!/bin/bash
# ==============================================================================
# RUN ALL TESTS
#
#   If any test fails, fix the problem before moving to the next test.
#   There is no point checking disk space if the input files are missing.
#
# HOW TO RUN:
#   bash tests/run_all_tests.sh config/config_test.sh
#
# OUTPUT:
#   All test results saved to: tests/test_results_YYYYMMDD_HHMMSS.txt
# ==============================================================================

CONFIG="${1:-config/config_test.sh}"
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_FILE="${TESTS_DIR}/test_results_$(date '+%Y%m%d_%H%M%S').txt"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ONA PIPELINE: Running all pre-flight tests             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Config file  : ${CONFIG}"
echo "  Results file : ${RESULTS_FILE}"
echo ""

# Run all tests and save output to file
{
  echo "ONA Pipeline pre-flight test results"
  echo "Generated: $(date)"
  echo "Config: ${CONFIG}"
  echo "════════════════════════════════════════════════════════════"
  echo ""

  for test_script in \
    "${TESTS_DIR}/test_00_startup.sh" \
    "${TESTS_DIR}/test_01_inputs.sh" \
    "${TESTS_DIR}/test_02_environments.sh" \
    "${TESTS_DIR}/test_03_diskspace_dryrun.sh"; do

    if [[ -f "${test_script}" ]]; then
      echo "Running: $(basename ${test_script})"
      echo "────────────────────────────────────────────────────────────"
      bash "${test_script}" "${CONFIG}"
      echo ""
    else
      echo "WARNING Test script not found: ${test_script}"
    fi
  done

} | tee "${RESULTS_FILE}"

echo ""
echo "  All test results saved to: ${RESULTS_FILE}"
echo ""
echo "  If all tests passed, you are ready to launch the pipeline:"
echo "    nohup caffeinate -s bash run_pipeline.sh ${CONFIG} \\"
echo "      > logs/run_\$(date '+%Y%m%d').log 2>&1 &"
echo ""
