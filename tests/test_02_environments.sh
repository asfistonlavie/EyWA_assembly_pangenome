#!/bin/bash
# ==============================================================================
# TEST 02: Conda environment verification
#
# HOW TO RUN:
#   bash tests/test_02_environments.sh config/config_test.sh
# ==============================================================================

CONFIG="${1:-config/config_test.sh}"
if [[ ! -f "${CONFIG}" ]]; then
  echo "Config file not found: ${CONFIG}"
  exit 1
fi
source "${CONFIG}"

# Initialize conda so we can use 'conda activate' and 'conda run'
# Without this, conda commands fail in non-interactive scripts
source "${CONDA_INIT}"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  TEST 02: Conda environment verification                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Conda base : ${CONDA_BASE}"
echo ""

total_problems=0


# ==============================================================================
# Helper functions
# ==============================================================================

# Check if a conda environment exists
# Returns 0 (success) if found, 1 (failure) if not
env_exists() {
  local env_name="$1"
  conda env list | grep -q "^${env_name} "
}

# Check if a tool is available inside a conda environment
# Uses 'conda run' to execute the 'which' command inside the environment
# without needing to activate it first
tool_exists() {
  local env_name="$1"
  local tool="$2"
  conda run -n "${env_name}" which "${tool}" &>/dev/null
}

# Get the version of a tool inside a conda environment
get_version() {
  local env_name="$1"
  local tool="$2"
  local version_flag="${3:---version}"  # default is --version

  # Try to get the version, suppress errors if it fails
  conda run -n "${env_name}" "${tool}" "${version_flag}" 2>&1 | head -1 \
    || echo "version unknown"
}

# Check one environment and its required tools
# Arguments: env_name  tool1 tool2 tool3 ...
check_environment() {
  local env_name="$1"
  shift  # Remove env_name from arguments, leaving only the tools
  local tools=("$@")

  echo "────────────────────────────────────────────────────────────"
  echo "  Environment: ${env_name}"
  echo "────────────────────────────────────────────────────────────"

  # Check if the environment exists
  if ! env_exists "${env_name}"; then
    echo "  FAIL: Environment does not exist"
    echo ""
    echo "    To install it, run:"
    echo "      CONDA_SUBDIR=osx-64 conda create -n ${env_name} -c bioconda -c conda-forge \\"
    echo "        ${tools[*]} -y"
    echo ""
    total_problems=$((total_problems + 1))
    return 1
  fi

  echo "  CHECK: Environment exists"
  echo ""

  # Check each required tool inside the environment
  local env_problems=0
  for tool in "${tools[@]}"; do
    if tool_exists "${env_name}" "${tool}"; then
      version=$(get_version "${env_name}" "${tool}")
      echo "    CHECK: ${tool}"
      echo "      Version: ${version}"
    else
      echo "    FAIL: ${tool} , NOT FOUND"
      echo "      To install: conda activate ${env_name} && conda install -c bioconda ${tool}"
      env_problems=$((env_problems + 1))
      total_problems=$((total_problems + 1))
    fi
    echo ""
  done

  if [[ "${env_problems}" -eq 0 ]]; then
    echo "  All tools found in ${env_name} CHECKED"
  else
    echo "  ${env_problems} tool(s) missing from ${env_name} FAILED"
  fi
  echo ""
}


# ==============================================================================
# Check each environment
# ==============================================================================

# ENV_MAIN , the main environment with most tools
# These are the tools used in preprocessing, assembly, purging, scaffolding,
# synteny analysis, and mapping
check_environment "${ENV_MAIN}" \
  NanoPlot seqtk porechop kraken2 flye \
  minimap2 samtools ragtag.py mash seqkit ntSynt

# ENV_BUSCO , isolated because BUSCO needs specific Python version
# BUSCO searches for conserved genes to evaluate genome completeness
check_environment "${ENV_BUSCO}" busco

# ENV_QUAST , isolated due to dependency conflicts with other tools
# QUAST calculates assembly statistics (N50, genome fraction, misassemblies)
check_environment "${ENV_QUAST}" quast

# ENV_PILON , only checked if Pilon polishing is enabled
# Pilon uses Illumina reads to correct errors in the ONT assembly
if [[ "${RUN_PILON}" == "true" ]]; then
  check_environment "${ENV_PILON}" pilon

  # Also check for Java, Pilon is a Java application
  # We check for the SYSTEM Java (not conda Java) because
  # the conda Java version has a memory management bug that crashes Pilon
  # on large genomes
  echo "────────────────────────────────────────────────────────────"
  echo "  Java for Pilon (must be system Java, NOT conda Java)"
  echo "────────────────────────────────────────────────────────────"

  if [[ -n "${JAVA_BIN}" && -f "${JAVA_BIN}" ]]; then
    java_version=$("${JAVA_BIN}" -version 2>&1 | head -1)
    echo "  CHECK: Java found: ${JAVA_BIN}"
    echo "    Version: ${java_version}"
  else
    echo "  FAIL: Java not found at: ${JAVA_BIN:-not set}"
    echo ""
    echo "    Fix: Set JAVA_BIN in your config to the system Java path"
    echo "    To find it:"
    echo "      ls ~/.sdkman/candidates/java/current/bin/java"
    echo "    WARNING: Do NOT use the conda Java, it has a memory bug"
    echo "    that causes Pilon to crash on large genomes"
    total_problems=$((total_problems + 1))
  fi
  echo ""
fi


# ==============================================================================
# Check BUSCO lineage database
# ==============================================================================
echo "────────────────────────────────────────────────────────────"
echo "  BUSCO lineage database: ${BUSCO_LINEAGE}"
echo "────────────────────────────────────────────────────────────"
echo ""

# BUSCO downloads the lineage database automatically if not present,
# but only if there is internet access. We check if it is already cached.
busco_db_path="${HOME}/.cache/BUSCO/busco_downloads/lineages/${BUSCO_LINEAGE}"
if [[ -d "${busco_db_path}" ]]; then
  echo "  CHECK: Lineage database already downloaded: ${busco_db_path}"
  n_genes=$(ls "${busco_db_path}/hmms/" 2>/dev/null | wc -l)
  echo "    Genes: ${n_genes}"
else
  echo "  FAIL: Lineage database not found locally: ${busco_db_path}"
  echo "    BUSCO will download it automatically on first run"
  echo "    Make sure the server has internet access"
  echo "    Or pre-download with:"
  echo "      busco --download ${BUSCO_LINEAGE}"
fi
echo ""


# ==============================================================================
# SUMMARY
# ==============================================================================
echo "════════════════════════════════════════════════════════════"
if [[ "${total_problems}" -eq 0 ]]; then
  echo "  CHECK: TEST 02 PASSED, All environments and tools are ready"
else
  echo "  FAIL: TEST 02 FAILED, Found ${total_problems} problem(s)"
  echo "    Fix the missing tools before running the pipeline"
fi
echo "════════════════════════════════════════════════════════════"
echo ""
