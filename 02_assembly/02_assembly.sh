#!/bin/bash
# assembly (Flye), one assembly per sample from the cleaned reads

declare -A ASSEMBLIES  # path to each sample's final assembly, used by the next modules

# Function to run Flye on every sample's clean reads
run_assembly() {
  log_info "=== DE NOVO ASSEMBLY (Flye) ==="

  conda activate "${ENV_MAIN}"
  export PATH="${CONDA_BASE}/envs/${ENV_MAIN}/bin:${PATH}"

  # Assembles one sample at a time
  for sample in "${SAMPLES[@]}"; do
    log_info "Assembling sample: ${sample}"

    local assembly_dir="${OUTPUT_DIR}/05-ASSEMBLY/${sample}"
    mkdir -p "${assembly_dir}"

    local assembly_out="${assembly_dir}/${sample}_assembly.fasta"
    # Skips Flye entirely if this sample was already assembled before,
    # this step can take hours so there's no reason to redo it
    if [[ -f "${assembly_out}" ]]; then
      log_warn "  Assembly already exists, skipping: ${assembly_out}" 
      ASSEMBLIES["${sample}"]="${assembly_out}"
      continue
    fi

    # Gets the clean reads produced by preprocessing
    local reads="${CLEAN_READS[${sample}]}"  
    if [[ -z "${reads}" || ! -f "${reads}" ]]; then
      log_error "Clean reads not found for sample ${sample}"
      log_error "Make sure preprocessing ran successfully"
      exit 1
    fi

    flye \
      --${FLYE_READ_TYPE} "${reads}" \
      --genome-size "${GENOME_SIZE}" \
      --out-dir "${assembly_dir}" \
      --threads "${THREADS}" \
      > "${assembly_dir}/${sample}_flye.log" 2>&1

    # Checks Flye actually produced an assembly before continuing
    if [[ -f "${assembly_dir}/assembly.fasta" ]]; then
      # Flye always names its output "assembly.fasta", renames it per sample
      cp "${assembly_dir}/assembly.fasta" "${assembly_out}" 
      samtools faidx "${assembly_out}"
      log_success "  Assembly complete: ${assembly_out}"
      log_info "  Stats: $(grep -c '>' ${assembly_out}) contigs"
    else
      log_error "  Flye assembly failed for ${sample}"
      log_error "  Check log: ${assembly_dir}/${sample}_flye.log"
      exit 1
    fi

    ASSEMBLIES["${sample}"]="${assembly_out}"
  done

  log_success "All assemblies complete"
}
