#!/bin/bash
# pilon, hybrid polishing with short Illumina reads, only if RUN_PILON=true

declare -A PILON_ASSEMBLIES

# Function to polish every sample's purged assembly with Illumina reads
run_pilon() {
  log_info "=== PILON POLISHING ==="

  # Polishes one sample at a time
  for sample in "${SAMPLES[@]}"; do
    log_info "Polishing sample: ${sample}"

    local assembly="${PURGED_ASSEMBLIES[${sample}]}"
    local pilon_dir="${OUTPUT_DIR}/PILON/${sample}"
    mkdir -p "${pilon_dir}"

    local r1="${ILLUMINA_DIR}/${ILLUMINA_R1_PATTERN//\{SAMPLE\}/${sample}}"
    local r2="${ILLUMINA_DIR}/${ILLUMINA_R2_PATTERN//\{SAMPLE\}/${sample}}"
    local pilon_out="${pilon_dir}/${sample}_pilon.fasta"

    # Skips this sample if it was already polished before
    if [[ -f "${pilon_out}" ]]; then
      log_warn "  Pilon output exists, skipping: ${pilon_out}"
      PILON_ASSEMBLIES["${sample}"]="${pilon_out}"
      continue
    fi

    # Checks the Illumina reads exist before doing anything else
    if [[ ! -f "${r1}" || ! -f "${r2}" ]]; then
      log_error "  Illumina reads not found for ${sample}"
      log_error "  R1: ${r1}"
      log_error "  R2: ${r2}"
      exit 1
    fi

    log_info "  Step 1/3: BWA index"
    conda activate "${ENV_MAIN}"
    export PATH="${CONDA_BASE}/envs/${ENV_MAIN}/bin:${PATH}"

    bwa index "${assembly}" 2> "${pilon_dir}/bwa_index.log"

    log_info "  Step 2/3: BWA mem mapping"
    bwa mem -t "${THREADS}" \
      "${assembly}" "${r1}" "${r2}" \
      | samtools sort -@ "${THREADS}" \
      -o "${pilon_dir}/${sample}_illumina.sorted.bam" -

    samtools index "${pilon_dir}/${sample}_illumina.sorted.bam"
    log_success "    Mapping done"

    log_info "  Step 3/3: Pilon polishing"
    conda activate "${ENV_PILON}"
    export PATH="${CONDA_BASE}/envs/${ENV_PILON}/bin:${PATH}"
    export JAVA_TOOL_OPTIONS="-Xmx${MAX_MEMORY}"

    "${JAVA_BIN}" -Xmx"${MAX_MEMORY}" -jar "${PILON_JAR}" \
      --genome "${assembly}" \
      --frags "${pilon_dir}/${sample}_illumina.sorted.bam" \
      --output "${sample}_pilon" \
      --outdir "${pilon_dir}" \
      --changes \
      > "${pilon_dir}/pilon.log" 2>&1

    # Checks Pilon actually produced an output before continuing
    if [[ -f "${pilon_dir}/${sample}_pilon.fasta" ]]; then
      local n_changes=0
      if [[ -f "${pilon_dir}/${sample}_pilon.changes" ]]; then
        n_changes=$(wc -l < "${pilon_dir}/${sample}_pilon.changes")
      fi
      log_success "  Pilon complete: ${n_changes} corrections made"
      samtools faidx "${pilon_dir}/${sample}_pilon.fasta"
      PILON_ASSEMBLIES["${sample}"]="${pilon_out}"
    else
      log_error "  Pilon failed for ${sample} , check: ${pilon_dir}/pilon.log"
      exit 1
    fi

    # Deletes the Illumina BAM if the config asks for it, it can be 30-50GB
    # and is not needed anymore once Pilon has finished
    if [[ "${CLEAN_INTERMEDIATES}" == "true" ]]; then
      rm -f "${pilon_dir}/${sample}_illumina.sorted.bam" \
            "${pilon_dir}/${sample}_illumina.sorted.bam.bai"
      log_info "  Intermediate BAM files cleaned up"
    fi

  done
  log_success "Pilon polishing complete"
}
