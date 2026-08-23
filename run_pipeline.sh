#!/bin/bash
# ==============================================================================
#   ONA GENOME ASSEMBLY PIPELINE
#   De novo assembly genome for ONT long reads
#   Alondra Gonzalez, M1 Bioinformatique, Universite de Montpellier 
#
#   usage:
#     cp config/config.template.sh config/config.sh   # copy and edit your config
#     nano config/config.sh
#     bash run_pipeline.sh
#
#   to resume from a specific stage: set START_FROM="ragtag" (or any other
#   stage) in your config
# ==============================================================================

set -euo pipefail  # stops on any error, does not continue with corrupted data
# Absolute path of this folder, works no matter where it's called from
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" 
# Default config path, or whatever config file is passed as an argument
CONFIG_FILE="${1:-${PIPELINE_DIR}/config/config.sh}"       

# Each stage lives in its own folder (00_setup, 01_preprocessing, ...)
# instead of one flat "modules/" folder, matches the actual execution order

STAGE_DIRS=(
  "00_setup"
  "01_preprocessing"
  "02_assembly"
  "03_evaluation"
  "04_purge_dups"
  "05_pilon"
  "06_ragtag"
  "07_synteny"
  "08_mapping"
  "09_blast"
)

LOG_DIR="${PIPELINE_DIR}/logs"

# terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# log functions: timestamp + color, and save to MAIN_LOG at the same time 
log_info()    { echo -e "${GREEN}[$(date '+%H:%M:%S')] INFO   ${NC} $*" | tee -a "${MAIN_LOG:-/dev/null}"; }
log_warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN   ${NC} $*" | tee -a "${MAIN_LOG:-/dev/null}"; }
log_error()   { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR  ${NC} $*" | tee -a "${MAIN_LOG:-/dev/null}"; }
log_step()    { echo -e "${CYAN}[$(date '+%H:%M:%S')] ══════ $* ══════${NC}" | tee -a "${MAIN_LOG:-/dev/null}"; }
log_success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] DONE   ${NC} $*" | tee -a "${MAIN_LOG:-/dev/null}"; }

# Function to print the ASCII banner shown at the start of every run
print_banner() {
  echo -e "${BLUE}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║          ONA GENOME ASSEMBLY PIPELINE               ║"
  echo "  ║       De novo assembly for ONT long reads            ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# config 
# Checks the config file exists before trying to load it
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo -e "${RED}Config file not found: ${CONFIG_FILE}${NC}"
  echo ""
  echo "  To create your config file, run:"
  echo "    cp ${PIPELINE_DIR}/config/config.template.sh ${CONFIG_FILE}"
  echo "  Then edit it with your settings:"
  echo "    nano ${CONFIG_FILE}"
  exit 1
fi

source "${CONFIG_FILE}"                              # loads SAMPLES, OUTPUT_DIR, etc.
source "${CONDA_BASE}/etc/profile.d/conda.sh"         # needed to be able to use "conda activate" in the rest of the script

# log for this run 
mkdir -p "${LOG_DIR}"
MAIN_LOG="${LOG_DIR}/pipeline_$(date '+%Y%m%d_%H%M%S').log"
log_info "Log file: ${MAIN_LOG}"

# Loads every run_xxx() function from every stage
for stage in "${STAGE_DIRS[@]}"; do
  for module in "${PIPELINE_DIR}/${stage}"/*.sh; do
    source "${module}"
  done
done

# Function to rebuild which assembly each stage should use from what
# already exists on disk, regardless of whether the stage ran in this
# session or was skipped via checkpoint / START_FROM
rebuild_state_from_disk() {
  # Recovers the real MASH divergence from disk if mash already ran in a
  # previous session
  local mash_file="${OUTPUT_DIR}/10-MASH/mash_distances.txt"
  if [[ -f "${mash_file}" ]]; then
    NTSYNT_DIVERGENCE=$(awk 'NF && $1 != $2 {print $3}' "${mash_file}" \
      | sort -n | tail -1 \
      | awk '{printf "%.0f", $1 * 100 + 0.5}')
  fi

  for sample in "${SAMPLES[@]}"; do
    local asm="${OUTPUT_DIR}/05-ASSEMBLY/${sample}/${sample}_assembly.fasta"
    if [[ -f "${asm}" ]]; then
      ASSEMBLIES["${sample}"]="${asm}"
    fi

    local purged="${OUTPUT_DIR}/08-PURGE_DUPS/${sample}_auto/purged.fa"
    if [[ -f "${purged}" ]]; then
      PURGED_ASSEMBLIES["${sample}"]="${purged}"
    elif [[ -f "${asm}" ]]; then
      PURGED_ASSEMBLIES["${sample}"]="${asm}"  # haploid, or purge was skipped
    fi

    local pilon="${OUTPUT_DIR}/PILON/${sample}/${sample}_pilon.fasta"
    if [[ -f "${pilon}" ]]; then
      PILON_ASSEMBLIES["${sample}"]="${pilon}"
    fi

    local ragtag_dir="${OUTPUT_DIR}/11-RAGTAG/${sample}${SAMPLE_SUFFIX:-}"
    local scaffold="${ragtag_dir}/${sample}_ragtag.scaffold.fasta"
    local filtered="${ragtag_dir}/${sample}_ragtag.scaffold.filtered.fasta"
    if [[ -f "${scaffold}" ]]; then
      RAGTAG_ASSEMBLIES["${sample}"]="${scaffold}"
    fi
    if [[ -f "${filtered}" ]]; then
      RAGTAG_FILTERED_ASSEMBLIES["${sample}"]="${filtered}"
    fi
  done
}
rebuild_state_from_disk

# Function that reports which step the pipeline was on if something breaks
on_error() {
  log_error "Pipeline stopped unexpectedly at step: ${CURRENT_STEP:-unknown}"
  log_error "Check the log file for details: ${MAIN_LOG}"
}
trap 'on_error' ERR

CURRENT_STEP="startup"

# ==============================================================================
# START
# ==============================================================================

print_banner

log_info "Config file  : ${CONFIG_FILE}"
log_info "Samples      : ${SAMPLES[*]}"
log_info "Output folder: ${OUTPUT_DIR}"
log_info "Start from   : ${START_FROM}"
log_info "Quality mode : ${QUALITY_MODE}"
echo ""

# 0: pre-flight checks 
CURRENT_STEP="validation"
log_step "STEP 0: Checking everything before we start"

validate_config
check_environments
check_disk_space
check_input_files
log_tool_versions

# 1: preprocessing
if should_run "preprocessing"; then
  CURRENT_STEP="preprocessing"
  log_step "STEP 1: Preprocessing (NanoPlot --> seqtk --> Porechop --> Kraken2)"
  run_or_skip "preprocessing" run_preprocessing
fi

# 2: assembly
if should_run "assembly"; then
  CURRENT_STEP="assembly"
  log_step "STEP 2: De novo assembly (Flye)"
  run_or_skip "assembly" run_assembly

  CURRENT_STEP="eval_after_assembly"
  log_step "STEP 2.5: Quality check after assembly (QUAST + BUSCO)"
  run_or_skip "eval_assembly" "run_evaluation after_assembly"
fi

# 3: purge_dups (only skipped if PLOIDY=haploid) 
if should_run "purge"; then
  CURRENT_STEP="purge"
  log_step "STEP 3: Purge haplotypes (purge_dups)"
  run_or_skip "purge" run_purge_dups

  CURRENT_STEP="eval_after_purge"
  log_step "STEP 3.5: Quality check after purge (QUAST + BUSCO)"
  run_or_skip "eval_purge" "run_evaluation after_purge"
fi

# 4: pilon (opcional, RUN_PILON=true)
if should_run "pilon"; then
  if [[ "${RUN_PILON}" == "true" ]]; then
    CURRENT_STEP="pilon"
    log_step "STEP 4: Pilon polishing with Illumina reads (optional)"
    run_or_skip "pilon" run_pilon

    CURRENT_STEP="eval_after_pilon"
    log_step "STEP 4.5: Quality check after Pilon (QUAST + BUSCO)"
    run_or_skip "eval_pilon" "run_evaluation after_pilon"
  else
    log_warn "Pilon skipped, set RUN_PILON=true in your config to enable it"
  fi
fi

# 5: scaffolding against the reference
if should_run "ragtag"; then
  CURRENT_STEP="ragtag"
  log_step "STEP 5: Scaffolding against reference genome (RagTag)"
  run_or_skip "ragtag" run_ragtag

  CURRENT_STEP="eval_after_ragtag"
  log_step "STEP 5.5: Quality check after scaffolding (QUAST + BUSCO)"
  run_or_skip "eval_ragtag" "run_evaluation after_ragtag"
fi

# 6: divergence (MASH) + macrosynteny (ntSynt)
if should_run "synteny"; then
  CURRENT_STEP="mash"
  log_step "STEP 6: Estimating divergence between samples (MASH)"
  run_or_skip "mash" run_mash

  CURRENT_STEP="ntsynt"
  log_step "STEP 7: Detecting synteny (ntSynt + visualization)"
  run_or_skip "ntsynt" run_ntsynt
fi

# 7: control mapping, do the reads actually support the assembly?
if should_run "mapping"; then
  CURRENT_STEP="mapping"
  log_step "STEP 8: Mapping reads back to assembly (minimap2)"
  run_or_skip "mapping" run_mapping
fi

# 8: BLAST (optional, RUN_BLAST=true) 
if [[ "${RUN_BLAST}" == "true" ]]; then
  CURRENT_STEP="blast"
  log_step "STEP 9: BLAST search on unplaced/unmapped sequences (optional)"
  run_or_skip "blast" run_blast
else
  log_warn "BLAST skipped, set RUN_BLAST=true in your config to enable it"
fi

# ==============================================================================
# DONE: final summary
# ==============================================================================

CURRENT_STEP="done"
print_final_summary
log_success "PIPELINE COMPLETE: the results are in: ${OUTPUT_DIR}"
