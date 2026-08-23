#!/bin/bash
# ragtag, scaffolding against the reference

declare -A RAGTAG_ASSEMBLIES
declare -A RAGTAG_FILTERED_ASSEMBLIES

# Function to scaffold every sample's assembly against the reference genome
run_ragtag() {
  log_info "=== SCAFFOLDING (RagTag) ==="

  conda activate "${ENV_MAIN}"
  export PATH="${CONDA_BASE}/envs/${ENV_MAIN}/bin:${PATH}"

  # Scaffolds one sample at a time
  for sample in "${SAMPLES[@]}"; do
    log_info "Scaffolding sample: ${sample}"

    # Uses the Pilon-polished assembly if it exists, otherwise scaffolds
    # straight from purge_dups
    local input_assembly
    if [[ "${RUN_PILON}" == "true" && -n "${PILON_ASSEMBLIES[${sample}]+x}" ]]; then
      input_assembly="${PILON_ASSEMBLIES[${sample}]}"
      log_info "  Input: Pilon-polished assembly"
    else
      input_assembly="${PURGED_ASSEMBLIES[${sample}]}"
      log_info "  Input: purge_dups assembly"
    fi

    local ragtag_dir="${OUTPUT_DIR}/11-RAGTAG/${sample}${SAMPLE_SUFFIX:-}"
    mkdir -p "${ragtag_dir}"

    local scaffold_out="${ragtag_dir}/${sample}_ragtag.scaffold.fasta"

    # Skips this sample if it was already scaffolded before
    if [[ -f "${scaffold_out}" ]]; then
      log_warn "  RagTag output exists, skipping: ${scaffold_out}"
      RAGTAG_ASSEMBLIES["${sample}"]="${scaffold_out}"
      continue
    fi

    ragtag.py scaffold \
      "${REF_GENOME}" \
      "${input_assembly}" \
      -o "${ragtag_dir}" \
      -t "${THREADS}" \
      > "${ragtag_dir}/ragtag.log" 2>&1

    # Checks RagTag actually produced an output before continuing
    if [[ -f "${ragtag_dir}/ragtag.scaffold.fasta" ]]; then
      # RagTag always names its output "ragtag.scaffold.fasta", renames
      # it per sample, this matters for ntSynt later
      cp "${ragtag_dir}/ragtag.scaffold.fasta" "${scaffold_out}"
      samtools faidx "${scaffold_out}"
      log_success "  RagTag complete: ${scaffold_out}"

      local n_scaffolds
      n_scaffolds=$(grep -c "^>" "${scaffold_out}")
      log_info "  Total scaffolds: ${n_scaffolds}"

      # CHROM_PATTERN comes from config ("NC_035" for example), this
      # way the chromosome prefix is not hardcoded and works with another
      # reference too
      grep -E "${CHROM_PATTERN}" "${scaffold_out}.fai" | \
        awk '{printf "  Chromosome %s: %.1f Mb\n", $1, $2/1e6}'

      # Adds up everything that did NOT match a chromosome name
      local unplaced_bp
      unplaced_bp=$(grep -vE "${CHROM_PATTERN}" "${scaffold_out}.fai" | \
        awk '{sum+=$2} END{printf "%.1f Mb", sum/1e6}')
      log_info "  Unplaced contigs: ${unplaced_bp}"
    else
      log_error "  RagTag failed for ${sample}, check: ${ragtag_dir}/ragtag.log"
      exit 1
    fi

    # Makes two extra versions: filtered (>=25bp, needed for ntSynt) and
    # >100kb 
    local filtered_out="${ragtag_dir}/${sample}_ragtag.scaffold.filtered.fasta"
    seqkit seq -m 25 "${scaffold_out}" > "${filtered_out}"
    samtools faidx "${filtered_out}"
    log_info "  Filtered (>=25bp): ${filtered_out}"

    local more100kb_out="${ragtag_dir}/${sample}_ragtag_more100kb.fasta"
    seqtk seq -L 100000 "${scaffold_out}" > "${more100kb_out}"
    samtools faidx "${more100kb_out}"
    log_info "  more100kb version: ${more100kb_out}"

    RAGTAG_ASSEMBLIES["${sample}"]="${scaffold_out}"
    RAGTAG_FILTERED_ASSEMBLIES["${sample}"]="${filtered_out}"
  done

  log_success "All samples scaffolded"
}