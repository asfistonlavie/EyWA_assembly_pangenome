#!/bin/bash
# setup, checks conda envs, tool paths, disk space, and saves tool
# versions before running anything (see run_setup() at the bottom)

# Function to initialize conda so "conda activate" works inside a script
init_conda() {
  # Checks if the conda startup script exists
  if [[ ! -f "${CONDA_INIT}" ]]; then
    log_error "Could not find the conda startup script at: ${CONDA_INIT}"
    log_error "Fix: set CONDA_BASE to your conda root folder in your config file."
    log_error "     To find it, run:  conda info --base"
    exit 1
  fi
  # Loads conda's shell functions into this script
  source "${CONDA_INIT}"
  log_info "Conda initialized from: ${CONDA_INIT}"
}
# Function to check if a conda environment exists
env_exists() {
  local env_name="$1"
  # Looks for the environment name at the start of a line in "conda env list"
  conda env list | grep -q "^${env_name} "  # exact match at start of line
}
# Function to check if a specific tool is available inside a given environment
tool_in_env() {
  local env_name="$1"
  local tool="$2"
  # Tries to locate the tool's binary inside the environment
  conda run -n "${env_name}" which "${tool}" &>/dev/null
}
# Function to install one of the pipeline's conda environments from scratch
install_env() {
  local env_name="$1"
  log_warn "Installing environment '${env_name}', this may take several minutes..."
  # Picks which packages to install depending on which environment this is
  case "${env_name}" in

    "${ENV_MAIN}")
      conda create -n "${env_name}" -c bioconda -c conda-forge \
        minimap2 samtools ragtag ntsynt mash bwa \
        seqkit seqtk porechop nanoplot flye -y
      ;;

    "${ENV_BUSCO}")
      # Tries python=3.10 first, some python versions cause dependency
      # conflicts with BUSCO 5.8.3, falls back to default python if it fails
      conda create -n "${env_name}" -c bioconda -c conda-forge \
        python=3.10 busco=5.8.3 -y || \
      conda create -n "${env_name}" -c bioconda -c conda-forge \
        busco=5.8.3 -y
      ;;

    "${ENV_QUAST}")
      conda create -n "${env_name}" -c bioconda -c conda-forge \
        python=3.11 quast -y
      ;;

    "${ENV_PILON}")
      conda create -n "${env_name}" -c bioconda -c conda-forge pilon -y
      ;;
    # Unknown environment name, nothing to install
    *)
      log_error "I don't know how to install environment '${env_name}'."
      log_error "Please install it manually and try again."
      exit 1
      ;;
  esac

  log_success "Environment '${env_name}' installed successfully."
}
# Function to check that every conda environment the pipeline needs is
# present and has the right tools installed inside it
check_environments() {
  log_info "Checking conda environments..."
  # The list of command-line tools expected inside each environment
  local env_main_tools="minimap2 samtools ragtag.py ntSynt mash seqkit seqtk NanoPlot flye"
  local env_busco_tools="busco"
  local env_quast_tools="quast"
  # Checks each environment one by one
  check_one_env "${ENV_MAIN}"     "${env_main_tools}"
  check_one_env "${ENV_BUSCO}"    "${env_busco_tools}"
  check_one_env "${ENV_QUAST}"    "${env_quast_tools}"
  check_one_env "${ENV_PORECHOP}" "porechop"   # separate env, see check_porechop_deps
  # bwa and pilon are only needed for the optional Illumina polishing step
  if [[ "${RUN_PILON}" == "true" ]]; then
    check_one_env "${ENV_PILON}" "pilon"
    check_one_env "${ENV_MAIN}" "bwa"
  fi
}

# Function to fix a Porechop dependency that goes missing on newer Python
# versions, pkg_resources (from setuptools) is not shipped by default in
# Python 3.13 anymore, and Porechop needs it to run
check_porechop_deps() {
  local env_name="$1"
  # porechop_env itself uses Python 3.11, so this check is not needed there
  if [[ "${env_name}" == "${ENV_PORECHOP}" ]]; then
    return 0
  fi
  # Tries importing pkg_resources inside the environment
  if ! conda run -n "${env_name}" python -c "import pkg_resources" &>/dev/null; then
    log_warn "    Porechop dependency missing: pkg_resources"
    log_warn "    Fix: conda activate ${env_name} && pip install setuptools --upgrade"
    log_warn "    Installing automatically..."
    # Installs setuptools automatically instead of stopping the pipeline
    conda run -n "${env_name}" pip install setuptools --upgrade --quiet
    # Checks again after installing, to confirm the fix actually worked
    if conda run -n "${env_name}" python -c "import pkg_resources" &>/dev/null; then
      log_success "  pkg_resources installed successfully"
    else
      log_error "  Could not install pkg_resources automatically"
      log_error "  Run manually: conda activate ${env_name} && pip install setuptools"
      exit 1
    fi
  fi
}
# Function to check one conda environment: does it exist, and does it have
# every tool it's supposed to have, offering to install what's missing
check_one_env() {
  local env_name="$1"
  local tools="$2"
  # Checks if the environment exists at all
  if env_exists "${env_name}"; then
    log_info "  Check, environment exists: ${env_name}"
    # Checks every tool in the list one by one
    for tool in ${tools}; do
      if tool_in_env "${env_name}" "${tool}"; then
        log_info "      Check ${tool}"
      else
        log_warn "      Fail, ${tool} not found in ${env_name}"
        log_warn "        To install it: conda activate ${env_name} && conda install -c bioconda ${tool}"
      fi
    done
    # If this environment is supposed to have Porechop, also checks its
    # specific pkg_resources dependency
    if echo "${tools}" | grep -q "porechop"; then
      check_porechop_deps "${env_name}"
    fi

  else
    # The environment does not exist at all, asks before installing it
    log_warn "  Fail, environment not found: ${env_name}"
    echo ""
    read -rp "    Install '${env_name}' automatically? [y/N] " reply
    echo ""
    # Only installs if the user answers yes
    if [[ "${reply}" =~ ^[Yy]$ ]]; then
      install_env "${env_name}"
    else
      log_error "Cannot continue without '${env_name}'."
      log_error "Please install it manually and re-run the pipeline."
      exit 1
    fi
  fi
}

# Function to detect absolute paths for tools that aren't always in $PATH
detect_tool_paths() {
  log_info "Detecting tool paths..."
  # Uses the manual path from config if given, otherwise guesses it from
  # the conda environment name
  if [[ -z "${BUSCO_BIN}" ]]; then
    BUSCO_BIN="${CONDA_BASE}/envs/${ENV_BUSCO}/bin/busco"
  fi
  export BUSCO_BIN
  # Checks that the guessed or given path actually exists
  if [[ ! -f "${BUSCO_BIN}" ]]; then
    log_error "BUSCO binary not found at: ${BUSCO_BIN}"
    log_error "Fix: set BUSCO_BIN in your config file, or check that ${ENV_BUSCO} is installed."
    exit 1
  fi
  log_info "  Check, BUSCO: ${BUSCO_BIN}"

  # ntSynt-viz is optional, only needed for the ribbon plot PDF
  NTSYNT_VIZ_AVAILABLE=false
  # Uses the manual path from config if it points to a real install
  if [[ -n "${NTSYNT_VIZ}" && -f "${NTSYNT_VIZ}/ntsynt_viz.py" ]]; then
    NTSYNT_VIZ_AVAILABLE=true  # path given manually in config, trusted as-is
  else 
    # Otherwise searches a couple of likely install locations
    for candidate in \
      "${OUTPUT_DIR}/../SOFTWARE/ntSynt-viz/bin" \
      "${CONDA_BASE}/envs/${ENV_MAIN}/bin"; do
      if [[ -f "${candidate}/ntsynt_viz.py" ]]; then
        NTSYNT_VIZ="${candidate}"
        NTSYNT_VIZ_AVAILABLE=true
        break
      fi
    done
  fi
  # Reports whether ntSynt-viz was found or not, this step is not fatal
  if [[ "${NTSYNT_VIZ_AVAILABLE}" == "true" ]]; then
    log_info "  Check, ntSynt-viz: ${NTSYNT_VIZ}"
  else
    log_warn "  Fail, ntSynt-viz not found, the ribbon plot PDF will not be generated."
    log_warn "    To enable it: git clone https://github.com/BirolLab/ntSynt-viz"
    log_warn "    Then set NTSYNT_VIZ=/path/to/ntSynt-viz/bin in your config."
  fi
  # Pilon needs its own jar file and a specific Java binary, only checked
  # if the optional polishing step is actually turned on
  if [[ "${RUN_PILON}" == "true" ]]; then

    # Finds pilon's jar file inside its conda environment
    if [[ -z "${PILON_JAR}" ]]; then
      PILON_JAR=$(find "${CONDA_BASE}/envs/${ENV_PILON}" -name "pilon*.jar" 2>/dev/null | head -1)
    fi
    # Stops here if the jar could not be found
    if [[ -z "${PILON_JAR}" ]]; then
      log_error "Could not find pilon.jar, set PILON_JAR in your config file."
      exit 1
    fi
    log_info "  Check, Pilon jar: ${PILON_JAR}"

    # note: conda's own Java (25-internal) has a memory bug that crashes
    # Pilon on large genomes, so looks for the system Java (sdkman) first
    if [[ -z "${JAVA_BIN}" ]]; then
      for candidate in \
        "${HOME}/.sdkman/candidates/java/current/bin/java" \
        "/usr/local/bin/java"; do
        if [[ -f "${candidate}" ]]; then
          JAVA_BIN="${candidate}"
          break
        fi
      done
    fi
    # Stops here if no usable Java was found anywhere
    if [[ -z "${JAVA_BIN}" ]]; then
      log_error "Could not find Java, set JAVA_BIN in your config file."
      log_error "To find Java: ls ~/.sdkman/candidates/java/current/bin/java"
      exit 1
    fi
    log_info "  Check, Java: ${JAVA_BIN}"
  fi
}

# Function to patch a bug in ntSynt-viz's R dependencies, some versions of
# tidytree are missing a method that ggtree expects (offspring.tbl_tree_item)
apply_r_fixes() {
  local fix_file="${HOME}/fix_tidytree.R"

  # Only writes the patch file once, no need to recreate it every run
  if [[ ! -f "${fix_file}" ]]; then
    log_info "Creating R compatibility fix for ntSynt-viz..."
    # Writes the R patch itself, it runs automatically every time R starts
    cat > "${fix_file}" << 'EOF'
# tidytree/ggtree patch, loaded automatically when R starts (via R_PROFILE_USER)
try({
  if (requireNamespace("tidytree", quietly = TRUE)) {
    ns <- asNamespace("tidytree")
    if (!exists("offspring.tbl_tree_item", envir = ns, inherits = FALSE) &&
        exists(".offspring.tbl_tree_item", envir = ns, inherits = FALSE)) {
      f <- get(".offspring.tbl_tree_item", envir = ns)
      utils::assignInNamespace("offspring.tbl_tree_item", f, ns = ns)
      base::registerS3method("offspring", "tbl_tree_item", f, envir = ns)
    }
  }
}, silent = TRUE)
EOF

    log_info "  Check, R fix created: ${fix_file}"
  fi
  # Tells R to load the patch on startup
  export R_PROFILE_USER="${fix_file}"
  # Uses a personal library folder, there is no admin access to install
  # R packages system-wide on the server
  mkdir -p "${HOME}/R/library"  # personal library folder, no admin permissions on the server
  export R_LIBS_USER="${HOME}/R/library"
}

# Safety factor to account for intermediate and output files
DISK_SPACE_FACTOR=5

# Function to check that there is enough free disk space before starting

check_disk_space() {
  mkdir -p "${OUTPUT_DIR}"
  # Reads the available space in GB on the output disk
  local available_gb
  available_gb=$(df -g "${OUTPUT_DIR}" | awk 'NR==2{print $4}')

  # Estimate required space based on input FASTQ size
  local input_gb=0

  for sample in "${SAMPLES[@]}"; do
    local sample_size
    sample_size=$(du -BG "${INPUT_DIR}/${sample}" 2>/dev/null | tail -1 | awk '{print $1}' | sed 's/G//')
    input_gb=$((input_gb + sample_size))
  done

  # Allow additional space for intermediate and output files
  local estimated_gb=$((input_gb * DISK_SPACE_FACTOR))
  
  log_info "Disk space Available: ${available_gb} GB | Estimated needed: ~${estimated_gb} GB"
  # Warns if the available space looks too small, does not stop the pipeline
  if [[ "${available_gb}" -lt "${estimated_gb}" ]]; then
    log_warn "WARNING: You might not have enough disk space."
    log_warn "  Consider setting CLEAN_INTERMEDIATES=true in your config"
    log_warn "  to automatically delete large intermediate files after each step."
  fi
}
# Function to save the exact tool versions used in this run to a text file,
# so I can cite the exact tool version used, later, in the report
log_tool_versions() {
  local ver_file="${OUTPUT_DIR}/pipeline_versions.txt"
  mkdir -p "${OUTPUT_DIR}"

  log_info "Saving tool versions to: ${ver_file}"
  # Asks each tool for its version, one by one, and writes everything to file
  {
    echo "ONA Pipeline run: $(date)"
    echo "Config file: ${CONFIG_FILE}"
    echo "Samples: ${SAMPLES[*]}"
    echo "Start from: ${START_FROM}"
    echo "Quality mode: ${QUALITY_MODE}"
    echo "────────────────────────────────"

    echo "minimap2:  $(conda run -n "${ENV_MAIN}" minimap2 --version 2>/dev/null || echo 'not found')"
    echo "samtools:  $(conda run -n "${ENV_MAIN}" samtools --version 2>/dev/null | head -1 || echo 'not found')"
    echo "flye:      $(conda run -n "${ENV_MAIN}" flye --version 2>/dev/null | head -1 || echo 'not found')"
    echo "ragtag:    $(conda run -n "${ENV_MAIN}" ragtag.py --version 2>/dev/null || echo 'not found')"
    echo "mash:      $(conda run -n "${ENV_MAIN}" mash --version 2>/dev/null | head -1 || echo 'not found')"
    echo "seqtk:     $(conda run -n "${ENV_MAIN}" seqtk 2>&1 | head -2 | tail -1 || echo 'not found')"
    echo "NanoPlot:  $(conda run -n "${ENV_MAIN}" NanoPlot --version 2>/dev/null || echo 'not found')"
    echo "busco:     $(${BUSCO_BIN} --version 2>/dev/null || echo 'not found')"
    echo "quast:     $(conda run -n "${ENV_QUAST}" quast --version 2>/dev/null | head -1 || echo 'not found')"

    echo "────────────────────────────────"
    echo "Reference genome: ${REF_GENOME}"
    echo "Genome size estimate: ${GENOME_SIZE}"
    echo "Threads: ${THREADS}"

  } > "${ver_file}" 2>&1

  log_success "Tool versions saved."
}
# Function that runs the whole setup check, in order: conda, tool paths,
# the R patch, disk space, and saving tool versions for the report
run_setup() {
  log_info "=== SETUP CHECK ==="
  init_conda
  check_environments
  detect_tool_paths
  apply_r_fixes
  check_disk_space
  log_tool_versions
  log_success "Setup complete, ready to run the pipeline."
}
