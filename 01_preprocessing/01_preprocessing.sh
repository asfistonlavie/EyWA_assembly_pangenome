#!/bin/bash
# preprocessing, NanoPlot then seqtk then Porechop then Kraken2 then NanoPlot
# I run NanoPlot after every filter to see each step's effect, not just the final result

declare -A CLEAN_READS # each sample's clean reads path, used by assembly

# Function to run NanoPlot on a fastq file and save the QC report to a folder
run_nanoplot() {
  local input_file="$1"
  local output_dir="$2"
  local label="$3"

  mkdir -p "${output_dir}"

  log_info "  NanoPlot QC: ${label}"
  source "${CONDA_BASE}/etc/profile.d/conda.sh"
  conda activate "${ENV_MAIN}"
  export PATH="${CONDA_BASE}/envs/${ENV_MAIN}/bin:${PATH}"

  NanoPlot \
    --fastq "${input_file}" \
    --outdir "${output_dir}" \
    --prefix "${label}" \
    --threads "${THREADS}" \
    --N50 \
    > "${output_dir}/${label}_nanoplot.log" 2>&1

  log_success "    NanoPlot done: ${output_dir}"
}
# Function to run the full preprocessing chain for every sample
run_preprocessing() {
  log_info "=== PREPROCESSING ==="

  conda activate "${ENV_MAIN}"
  export PATH="${CONDA_BASE}/envs/${ENV_MAIN}/bin:${PATH}"
  # Runs the whole chain one sample at a time
  for sample in "${SAMPLES[@]}"; do
    log_info "Processing sample: ${sample}"
    
    local raw_reads="${READS_DIR}/${READS_PATTERN//\{SAMPLE\}/${sample}}"
    local sample_dir="${OUTPUT_DIR}/02-FILTER/${sample}"
    mkdir -p "${sample_dir}"
    # Step 0: check the raw reads before touching anything
    run_nanoplot "${raw_reads}" \
      "${OUTPUT_DIR}/QC/${sample}/00_raw" \
      "${sample}_00_raw"

    # Step 1: length filter, threshold is set in the config (SEQTK_MIN_LENGTH)
    log_info "  seqtk filtering >${SEQTK_MIN_LENGTH}bp"
    local seqtk_out="${sample_dir}/${sample}_seqtk_filtered.fastq.gz"

    seqtk seq -L "${SEQTK_MIN_LENGTH}" "${raw_reads}" | gzip -c > "${seqtk_out}"
    log_success "    seqtk done: ${seqtk_out}"

    run_nanoplot "${seqtk_out}" \
      "${OUTPUT_DIR}/QC/${sample}/01_seqtk" \
      "${sample}_01_seqtk"

    # Step 2: adapter trimming, Porechop needs its own conda env because
    # with Python 3.13 (the main env) pkg_resources no longer exists in
    # setuptools and Porechop crashes on import

    log_info "  Porechop adapter trimming"
    local porechop_out="${sample_dir}/${sample}_porechop.fastq.gz"

    conda activate "${ENV_PORECHOP}"
    export PATH="${CONDA_BASE}/envs/${ENV_PORECHOP}/bin:${PATH}"

    porechop \
      -i "${seqtk_out}" \
      -o "${porechop_out}" \
      --threads "${THREADS}" \
      > "${sample_dir}/${sample}_porechop.log" 2>&1
    
    # Switches back to the main env for the rest of the steps
    conda activate "${ENV_MAIN}"
    export PATH="${CONDA_BASE}/envs/${ENV_MAIN}/bin:${PATH}"

    log_success "    Porechop done: ${porechop_out}"

    run_nanoplot "${porechop_out}" \
      "${OUTPUT_DIR}/QC/${sample}/02_porechop" \
      "${sample}_02_porechop"

    # Step 3: viral decontamination, reads that do NOT match the viral
    # database (the "unclassified" ones) are kept as the clean reads
    log_info "  Kraken2 viral decontamination"
    local kraken_dir="${sample_dir}/kraken2"
    mkdir -p "${kraken_dir}"

    kraken2 \
      --db "${KRAKEN2_DB}" \
      --threads "${THREADS}" \
      --classified-out "${kraken_dir}/${sample}_classified.fq" \
      --unclassified-out "${kraken_dir}/${sample}_unclassified.fq" \
      --report "${kraken_dir}/${sample}.report" \
      "${porechop_out}" \
      > "${kraken_dir}/${sample}_kraken2.log" 2>&1

    gzip -f "${kraken_dir}/${sample}_classified.fq"
    gzip -f "${kraken_dir}/${sample}_unclassified.fq"

    log_success "    Kraken2 done: ${kraken_dir}"
    
    # Step 4: check the final clean reads, after all 3 filters
    run_nanoplot "${kraken_dir}/${sample}_unclassified.fq.gz" \
      "${OUTPUT_DIR}/QC/${sample}/03_kraken2" \
      "${sample}_03_kraken2"

    CLEAN_READS["${sample}"]="${kraken_dir}/${sample}_unclassified.fq.gz"

    log_success "  Sample ${sample} preprocessing complete"
    log_info "  Clean reads: ${CLEAN_READS[${sample}]}"
  done

  log_success "All samples preprocessed"
}
