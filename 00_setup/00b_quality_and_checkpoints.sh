#!/bin/bash
# quality_and_checkpoints, three things: config validation, a checkpoint system
# to resume after a crash, and the quality report after each evaluation
# (informational only, the pipeline never stops on a quality note, see below)

declare -A QUALITY_WARNINGS  # ej: QUALITY_WARNINGS["ABY5"]="BUSCO_C=72% (min: 80%)"

# 1. config validation
# Check required configuration values
validate_config() {
  log_info "=== CHECKING YOUR CONFIG FILE ==="
  local error_count=0
  
  # Check for empty or default template values
  check_required() {
    local setting_name="$1"
    local setting_value="$2"
    local how_to_fix="$3"
    # Empty values and template placeholders are not accepted
    if [[ -z "${setting_value}" ]] || \
       [[ "${setting_value}" == *"/path/to/"* ]] || \
       [[ "${setting_value}" == *"SAMPLE1"* ]]; then
      log_error "Missing required setting: ${setting_name}"
      log_error "  How to fix: ${how_to_fix}"
      error_count=$((error_count + 1))
    fi
  }
  
  # Check of required parameters
  check_required "SAMPLES" \
    "${SAMPLES[*]}" \
    "Set SAMPLES=(\"PopA\" \"PopB\") to the names of your samples, matching the read files in READS_DIR"

  check_required "READS_DIR" \
    "${READS_DIR}" \
    "Set READS_DIR to the folder containing your ONT reads"

  check_required "REF_GENOME" \
    "${REF_GENOME}" \
    "Set REF_GENOME to the full path of your reference .fna file"

  check_required "OUTPUT_DIR" \
    "${OUTPUT_DIR}" \
    "Set OUTPUT_DIR to where you want results saved"

  check_required "CONDA_BASE" \
    "${CONDA_BASE}" \
    "Run 'conda info --base' to find your conda folder, then set CONDA_BASE"

  check_required "KRAKEN2_DB" \
    "${KRAKEN2_DB}" \
    "Set KRAKEN2_DB to the folder containing your Kraken2 database files"

  # ILLUMINA_DIR is only required if Pilon polishing is turned on
  if [[ "${RUN_PILON}" == "true" ]]; then
    if [[ -z "${ILLUMINA_DIR}" ]]; then
      log_error "Missing required setting: ILLUMINA_DIR (needed because RUN_PILON=true)"
      log_error "  How to fix: set ILLUMINA_DIR to the folder with your Illumina reads"
      error_count=$((error_count + 1))
    fi
  fi
  
  # BLAST_DB is only required if the optional BLAST step is turned on
  if [[ "${RUN_BLAST}" == "true" ]]; then
    if [[ -z "${BLAST_DB}" ]] || [[ "${BLAST_DB}" == *"/path/to/"* ]]; then
      log_error "Missing required setting: BLAST_DB (needed because RUN_BLAST=true)"
      log_error "  How to fix: set BLAST_DB to the path prefix of your BLAST nt database"
      error_count=$((error_count + 1))
    fi
  fi
  
  # Checks that QUALITY_MODE has a valid value
  if [[ "${QUALITY_MODE}" != "report" ]]; then
    log_error "Invalid value for QUALITY_MODE: '${QUALITY_MODE}'"
    log_error "  How to fix: set it to \"report\" (the only mode implemented)"
    error_count=$((error_count + 1))
  fi

  # Keep track of completed stages for START_FROM to allow the pipeline to resume
  # after an interruption
  local valid_stages=("preprocessing" "assembly" "purge" "pilon" "ragtag" "synteny" "mapping")
  local found=false
  for stage in "${valid_stages[@]}"; do
    if [[ "${START_FROM}" == "${stage}" ]]; then
      found=true
    fi
  done
  if [[ "${found}" == "false" ]]; then
    log_error "Invalid value for START_FROM: '${START_FROM}'"
    log_error "  How to fix: choose one of: ${valid_stages[*]}"
    error_count=$((error_count + 1))
  fi
  
  # Stops the pipeline here if any problem was found above
  if [[ "${error_count}" -gt 0 ]]; then
    echo ""
    log_error "Found ${error_count} problem(s) in your config file: ${CONFIG_FILE}"
    log_error "Please fix the issues above, then re-run the pipeline."
    exit 1
  fi

  log_success "Config file looks good."
  log_info "  Samples       : ${SAMPLES[*]}"
  log_info "  Output folder : ${OUTPUT_DIR}"
  log_info "  Starting from : ${START_FROM}"
  log_info "  Quality mode  : ${QUALITY_MODE}"
}

# 2. checkpoints
# a small text file records every finished stage, when resuming, this
# file is read to skip whatever is already done

# Function to build the path of the checkpoint file for this run
get_checkpoint_file() {
  echo "${OUTPUT_DIR}/.pipeline_progress"
}

# Function to record that a stage finished successfully
mark_stage_done() {
  local stage_name="$1"
  echo "${stage_name}" >> "$(get_checkpoint_file)"
}

# Function to check if a stage was already completed in a previous run
stage_is_done() {
  local stage_name="$1"
  local checkpoint_file
  checkpoint_file="$(get_checkpoint_file)"
  
  # No checkpoint file at all means nothing has run yet
  if [[ ! -f "${checkpoint_file}" ]]; then
    return 1
  fi
  
  # Looks for the exact stage name as its own line in the checkpoint file
  grep -q "^${stage_name}$" "${checkpoint_file}"
}

# Function to run a stage, or skip it if the checkpoint says it's already done
# usage: run_or_skip "stage_name" function_name

run_or_skip() {
  local stage_name="$1"
  local function_name="$2"
  
  # Skips the stage entirely if it was already completed before
  if stage_is_done "${stage_name}"; then
    log_warn "Stage '${stage_name}' was already completed, skipping."
    log_warn "  (To re-run it: delete ${OUTPUT_DIR}/.pipeline_progress)"
  else
    ${function_name}
    mark_stage_done "${stage_name}"
  fi
}

# run this stage only if it comes at or after START_FROM
should_run() {
  local this_stage="$1"

  local all_stages=("preprocessing" "assembly" "purge" "pilon" "ragtag" "synteny" "mapping")

  local start_index=0
  local this_index=0
  local i=0
  
  # Finds the position of START_FROM and of this stage in the stage order
  for stage in "${all_stages[@]}"; do
    if [[ "${stage}" == "${START_FROM}" ]]; then
      start_index=${i}
    fi
    if [[ "${stage}" == "${this_stage}" ]]; then
      this_index=${i}
    fi
    i=$((i + 1))
  done
  
  # A stage runs only if it comes at or after START_FROM in the order
  [[ "${this_index}" -ge "${start_index}" ]]
}

# 3. quality report

# Function to flag a sample with a note, this NEVER removes it from the
# pipeline, never pauses execution, and never decides anything for you,
# it is only recorded for you to review later

flag_sample() {
  local sample="$1"
  local reason="$2"

  # Appends to any existing note for this sample, or creates the first one
  if [[ -n "${QUALITY_WARNINGS[${sample}]+x}" ]]; then
    QUALITY_WARNINGS["${sample}"]="${QUALITY_WARNINGS[${sample}]} | ${reason}"
  else
    QUALITY_WARNINGS["${sample}"]="${reason}"
  fi
}

# Function to print and save the quality report for one pipeline stage
# usage: print_stage_report "after_purge" rows...
print_stage_report() {
  local stage="$1"
  shift

  local report_dir="${OUTPUT_DIR}/stage_reports"
  mkdir -p "${report_dir}"
  local report_file="${report_dir}/${stage}_report.txt"

  echo ""
  echo -e "${BLUE}  ╔══════════════════════════════════════════════════════════╗${NC}"
  printf "${BLUE}  ║  Stage report: %-42s║${NC}\n" "${stage}"
  echo -e "${BLUE}  ╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  
  # Prints every metric row passed in by the caller
  for row in "$@"; do
    echo -e "  ${row}"
  done

  # Prints a note for every sample that got flagged, if any
  local any_flagged=false
  for sample in "${SAMPLES[@]}"; do
    if [[ -n "${QUALITY_WARNINGS[${sample}]+x}" ]]; then
      any_flagged=true
      echo ""
      echo -e "  ${YELLOW}WARNING  ${sample} is flagged:${NC}"
      echo "     ${QUALITY_WARNINGS[${sample}]}" | tr '|' '\n' | \
        awk '{printf "     - %s\n", $0}'
    fi
  done

  echo ""
  echo -e "  ${YELLOW}[INFO]  Pipeline always continues, notes above are informational.${NC}"
  echo -e "     Review the metric evolution across stages in the reports, interpretation is up to you."
  echo ""

  # Saves the same report to a text file for later
  {
    echo "Stage report: ${stage}"
    echo "Generated: $(date)"
    echo "Quality mode: ${QUALITY_MODE}"
    for row in "$@"; do
      echo "${row}"
    done
    for sample in "${SAMPLES[@]}"; do
      if [[ -n "${QUALITY_WARNINGS[${sample}]+x}" ]]; then
        echo "FLAGGED ${sample}: ${QUALITY_WARNINGS[${sample}]}"
      fi
    done
  } > "${report_file}"

  # Pauses here if the config asks for a pause after every stage
  if [[ "${PAUSE_AFTER_EACH_STAGE}" == "true" ]]; then
    echo ""
    if [[ "${AUTO_CONTINUE_TIMEOUT}" -eq 0 ]]; then
      read -rp "  Press ENTER to continue to the next stage..."
    else
      echo "  Auto-continuing in ${AUTO_CONTINUE_TIMEOUT} seconds... (press ENTER to continue now)"
      read -rt "${AUTO_CONTINUE_TIMEOUT}" || true
    fi
    echo ""
  fi
}

# final summary 

# Function to print the final summary once the whole pipeline is done
print_final_summary() {
  echo ""
  echo -e "${BLUE}  ╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}  ║                  PIPELINE COMPLETE                       ║${NC}"
  echo -e "${BLUE}  ╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Finished : $(date)"
  echo -e "  Results  : ${OUTPUT_DIR}"
  echo -e "  Versions : ${OUTPUT_DIR}/pipeline_versions.txt"
  echo -e "  Reports  : ${OUTPUT_DIR}/stage_reports/"
  echo ""

  # Lists every sample that got flagged at some point during the run
  local any_flagged=false
  for sample in "${SAMPLES[@]}"; do
    if [[ -n "${QUALITY_WARNINGS[${sample}]+x}" ]]; then
      any_flagged=true
      echo -e "  ${YELLOW}WARNING  ${sample} was flagged during the pipeline:${NC}"
      echo "     ${QUALITY_WARNINGS[${sample}]}" | tr '|' '\n' | \
        awk '{printf "     - %s\n", $0}'
      echo ""
    fi
  done
  # Prints a clean confirmation if nothing was ever flagged
  if [[ "${any_flagged}" == "false" ]]; then
    echo -e "  ${GREEN}✓  No quality notes were raised for any sample.${NC}"
    echo -e "     Review the stage reports to see the full metric evolution."
  fi

  echo ""
  echo "  All stage reports are saved in: ${OUTPUT_DIR}/stage_reports/"
  echo ""
}

# pause between stages if PAUSE_AFTER_EACH_STAGE=true, useful for reviewing
# the quality report before moving to a long next step
maybe_pause() {
  local stage="${1:-}"

  # Does nothing if pausing is turned off
  [[ "${PAUSE_AFTER_EACH_STAGE}" == "true" ]] || return 0

  echo ""
  log_info "Pausing after stage: ${stage}"
  log_info "Review the stage report above before continuing."
  echo ""

  # Waits for ENTER, or auto-continues after a timeout if one is set
  if [[ "${AUTO_CONTINUE_TIMEOUT}" -eq 0 ]]; then
    read -rp "  Press ENTER to continue to the next stage..."
  else
    echo "  Auto-continuing in ${AUTO_CONTINUE_TIMEOUT}s, press ENTER to continue now."
    read -rt "${AUTO_CONTINUE_TIMEOUT}" || true
  fi
  echo ""
}

