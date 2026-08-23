#!/bin/bash
# synteny, MASH for divergence between populations plus ntSynt for synteny
# MASH's % divergence is used directly as ntSynt's -d parameter

# Function to compute pairwise genetic distance between all samples with MASH
run_mash() {
  log_info "=== DIVERGENCE ESTIMATION (MASH) ==="

  conda activate "${ENV_MAIN}"
  export PATH="${CONDA_BASE}/envs/${ENV_MAIN}/bin:${PATH}"

  local mash_dir="${OUTPUT_DIR}/10-MASH"
  mkdir -p "${mash_dir}"

  # Builds the list of assemblies to compare, one per sample
  local assembly_list=()
  for sample in "${SAMPLES[@]}"; do
    assembly_list+=("${RAGTAG_FILTERED_ASSEMBLIES[${sample}]}")
  done

  # Adds external reference genomes to the comparison, if any were given
  for ref in "${EXTERNAL_REFERENCES[@]}"; do
    assembly_list+=("${ref}")
  done

  log_info "  Sketching ${#assembly_list[@]} assemblies"
  mash sketch "${assembly_list[@]}" \
    -o "${mash_dir}/all_samples" \
    > "${mash_dir}/mash_sketch.log" 2>&1

  log_info "  Computing pairwise distances"
  mash dist \
    "${mash_dir}/all_samples.msh" \
    "${mash_dir}/all_samples.msh" \
    > "${mash_dir}/mash_distances.txt" 2>&1

  log_info "  MASH distances:"
  awk '$1 != $2 {printf "  %s vs %s: %.4f (%.2f%%)\n", \
    $1, $2, $3, $3*100}' "${mash_dir}/mash_distances.txt"

  # NTSYNT_DIVERGENCE is the variable ntSynt actually reads, further down,
  # picks the largest pairwise distance found across all samples
  NTSYNT_DIVERGENCE=$(awk 'NF && $1 != $2 {print $3}' "${mash_dir}/mash_distances.txt" \
    | sort -n | tail -1 \
    | awk '{printf "%.0f", $1 * 100 + 0.5}')

  log_info "  Maximum divergence: ${NTSYNT_DIVERGENCE}%"
  log_success "MASH complete, divergence for ntSynt: ${NTSYNT_DIVERGENCE}"
}

# Function to run ntSynt twice: before and after scaffolding
run_ntsynt() {
  log_info "=== SYNTENY (ntSynt) ==="
  # Last-resort fallback: 2% divergence, only used if mash_distances.txt
  # doesn't exist yet anywhere (mash never ran, not even in a past session)
  NTSYNT_DIVERGENCE="${NTSYNT_DIVERGENCE:-2}"
  log_info "  Divergence parameter: ${NTSYNT_DIVERGENCE}"

  conda activate "${ENV_MAIN}"
  export PATH="${CONDA_BASE}/envs/${ENV_MAIN}/bin:${PATH}"

  # Adds ntSynt-viz to PATH only if it was actually found during setup
  if [[ "${NTSYNT_VIZ_AVAILABLE}" == "true" ]]; then
    export PATH="${NTSYNT_VIZ}:${PATH}"
  fi

  local ntsynt_dir="${OUTPUT_DIR}/12-NTSYNT"

  _run_ntsynt_stage "avant_ragtag" "purged"      # before scaffolding, on the purged assemblies
  _run_ntsynt_stage "apres_ragtag" "scaffolded"  # after, on the final scaffolds

  log_success "ntSynt complete"
}

# Function that actually runs ntSynt + ntSynt-viz for one stage (before or after ragtag)
_run_ntsynt_stage() {
  local stage="$1"
  local desc="$2"
  local stage_dir="${OUTPUT_DIR}/12-NTSYNT/${stage}"
  mkdir -p "${stage_dir}"
  cd "${stage_dir}"

  local prefix="ONA_${#SAMPLES[@]}pop_${stage}"

  log_info "  Running ntSynt (${desc} assemblies)"

  # Builds the list of fasta files ntSynt will compare, using purged
  # assemblies before ragtag and scaffolds after
  > fasta_list.txt
  for sample in "${SAMPLES[@]}"; do
    if [[ "${stage}" == "avant_ragtag" ]]; then
      local fasta="${OUTPUT_DIR}/08-PURGE_DUPS/${sample}_auto/${sample}_purged_filtered.fa"
    else
      local fasta="${RAGTAG_FILTERED_ASSEMBLIES[${sample}]}"
    fi
    echo "${fasta}" >> fasta_list.txt
    samtools faidx "${fasta}"
  done

  # Adds external reference genomes to the comparison, only after ragtag
  # (comparing final scaffolds to full published assemblies,
  # comparing pre-scaffolding contigs to them does not)
  if [[ "${stage}" == "apres_ragtag" ]]; then
    for ref in "${EXTERNAL_REFERENCES[@]}"; do
      echo "${ref}" >> fasta_list.txt
      samtools faidx "${ref}"
    done
  fi

  ntSynt \
    -d "${NTSYNT_DIVERGENCE}" \
    -t "${THREADS}" \
    -p "${prefix}" \
    --fastas_list fasta_list.txt \
    > ntsynt.log 2>&1

  # Checks ntSynt actually produced synteny blocks before continuing
  if [[ ! -f "${prefix}.synteny_blocks.tsv" ]]; then
    log_error "  ntSynt failed for stage ${stage}, check: ${stage_dir}/ntsynt.log"
    return 1
  fi

  log_success "  ntSynt done: ${prefix}.synteny_blocks.tsv"

  # Builds the matching list of .fai index files, same order as fasta_list.txt
  > fai.tsv
  for sample in "${SAMPLES[@]}"; do
    if [[ "${stage}" == "avant_ragtag" ]]; then
      echo "${OUTPUT_DIR}/08-PURGE_DUPS/${sample}_auto/${sample}_purged_filtered.fa.fai" >> fai.tsv
    else
      echo "${RAGTAG_FILTERED_ASSEMBLIES[${sample}]}.fai" >> fai.tsv
    fi
  done

  if [[ "${stage}" == "apres_ragtag" ]]; then
    for ref in "${EXTERNAL_REFERENCES[@]}"; do
      echo "${ref}.fai" >> fai.tsv
    done
  fi

  # Uses the first sample as the reference the ribbon plot is drawn against
  local target_genome
  target_genome=$(basename "${RAGTAG_FILTERED_ASSEMBLIES[${SAMPLES[0]}]}")

  # Only runs the visualization step if ntSynt-viz was found during setup
  if [[ "${NTSYNT_VIZ_AVAILABLE}" == "true" ]]; then
    log_info "  Running ntSynt-viz"
    python3 "${NTSYNT_VIZ}/ntsynt_viz.py" \
      --blocks "${prefix}.synteny_blocks.tsv" \
      --fais fai.tsv \
      --prefix "${prefix}" \
      --format pdf \
      -f \
      --target-genome "${target_genome}" \
      --length "${NTSYNT_LENGTH}" \
      --seq_length "${NTSYNT_SEQ_LENGTH}" \
      --width "${NTSYNT_WIDTH}" \
      --height "${NTSYNT_HEIGHT}" \
      --normalize \
      --scale 1e6 \
      --ribbon_adjust "${NTSYNT_RIBBON_ADJUST}" \
      > ntsynt_viz.log 2>&1

    # Checks a PDF actually got created before declaring success
    if ls *.pdf &>/dev/null; then
      log_success "  ntSynt-viz PDF generated"
    else
      log_warn "  ntSynt-viz may have failed, check: ${stage_dir}/ntsynt_viz.log"
    fi
  else
    log_warn "  ntSynt-viz skipped (not available)"
  fi

  cd "${OUTPUT_DIR}"
}
