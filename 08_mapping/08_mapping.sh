#!/bin/bash
# mapping, control mapping with minimap2: full BAM (IGV), primary BAM
# (statistics) and extracts unmapped reads (for BLAST later)

# Function to map every sample's clean reads back onto its own final assembly
run_mapping() {
  log_info "=== READ MAPPING CONTROL (minimap2) ==="

  conda activate "${ENV_MAIN}"
  export PATH="${CONDA_BASE}/envs/${ENV_MAIN}/bin:${PATH}"

  local map_dir="${OUTPUT_DIR}/14-MAPPING"
  mkdir -p "${map_dir}"

  # Maps one sample at a time
  for sample in "${SAMPLES[@]}"; do
    log_info "Mapping reads for sample: ${sample}"

    local assembly="${RAGTAG_ASSEMBLIES[${sample}]}"
    local reads="${CLEAN_READS[${sample}]}"
    local sample_dir="${map_dir}/${sample}${SAMPLE_SUFFIX:-}"
    mkdir -p "${sample_dir}"

    log_info "  1/4: minimap2 alignment (map-ont)"
    minimap2 \
      -t "${THREADS}" \
      -ax map-ont \
      "${assembly}" \
      "${reads}" \
      -o "${sample_dir}/${sample}_onAssembly.sam" \
      > "${sample_dir}/minimap2.log" 2>&1

    log_info "  2/4: full BAM with secondary alignments (for IGV)"
    samtools view -hb \
      "${sample_dir}/${sample}_onAssembly.sam" \
      -o "${sample_dir}/${sample}_all.bam"

    samtools sort -@ "${THREADS}" \
      "${sample_dir}/${sample}_all.bam" \
      -o "${sample_dir}/${sample}_all_sort.bam"

    samtools index "${sample_dir}/${sample}_all_sort.bam"

    log_info "  3/4: filtered BAM, primary only (for statistics)"
    samtools view -hbF 256 \
      "${sample_dir}/${sample}_onAssembly.sam" \
      | samtools sort -@ "${THREADS}" \
      -o "${sample_dir}/${sample}_primary_sort.bam"

    samtools index "${sample_dir}/${sample}_primary_sort.bam"

    # The SAM and the unsorted BAM are no longer needed after this point
    rm -f "${sample_dir}/${sample}_onAssembly.sam" \
          "${sample_dir}/${sample}_all.bam"

    log_info "  4/4: statistics and unmapped reads"

    samtools flagstat \
      "${sample_dir}/${sample}_primary_sort.bam" \
      > "${sample_dir}/${sample}_flagstat.txt"

    log_info "  Mapping statistics:"
    grep -E "mapped|primary" "${sample_dir}/${sample}_flagstat.txt" | \
      awk '{printf "    %s\n", $0}'

    # Extracts reads that did NOT map, used later as input for BLAST
    samtools fasta -f 4 \
      "${sample_dir}/${sample}_primary_sort.bam" \
      > "${sample_dir}/${sample}_unmapped.fasta"

    local n_unmapped
    n_unmapped=$(grep -c "^>" "${sample_dir}/${sample}_unmapped.fasta" 2>/dev/null || echo 0)
    log_info "  Unmapped reads: ${n_unmapped}"

    # Extracts reads that DID map, kept separately for reference
    samtools fasta -F 4 \
      "${sample_dir}/${sample}_primary_sort.bam" \
      > "${sample_dir}/${sample}_mapped.fasta"

    log_info "  Extracting chromosomes for IGV"

    # CHROM_PATTERN from config, not hardcoded (used to be a fixed "NC_035|CM04")
    local chrom_names
    chrom_names=$(grep -E "${CHROM_PATTERN}" "${assembly}.fai" | \
      head -"${N_CHROMOSOMES}" | awk '{print $1}')

    # Pulls out a small per-chromosome BAM for each chromosome, easier to
    # load individually in IGV than the full genome BAM
    for chrom in ${chrom_names}; do
      local chrom_safe
      chrom_safe="${chrom//\//_}"
      samtools view -hb \
        "${sample_dir}/${sample}_all_sort.bam" \
        "${chrom}" \
        -o "${sample_dir}/${sample}_${chrom_safe}_all.bam"
      samtools index "${sample_dir}/${sample}_${chrom_safe}_all.bam"
      log_info "    Extracted: ${chrom}"
    done

    log_success "  ${sample} mapping complete"
  done

  # Prints the mapping percentage for every sample, one final overview
  log_info "Mapping summary:"
  for sample in "${SAMPLES[@]}"; do
    local flagstat="${map_dir}/${sample}${SAMPLE_SUFFIX:-}/${sample}_flagstat.txt"
    if [[ -f "${flagstat}" ]]; then
      local pct_mapped
      pct_mapped=$(grep "primary mapped" "${flagstat}" | \
        grep -oP '\(\K[0-9.]+(?=%)' | head -1)
      log_info "  ${sample}: ${pct_mapped}% reads mapped"
    fi
  done

  log_success "Mapping control complete"
}