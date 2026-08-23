#!/bin/bash
# blast, BLASTn against nt of (1) contigs RagTag couldn't place, and
# (2) unmapped reads, to see what they are (contamination, virus, etc.)
# only runs if RUN_BLAST=true

# Function to BLAST unplaced contigs and unmapped reads for every sample
run_blast() {
  log_info "=== BLAST ANALYSIS ==="

  local blast_dir="${OUTPUT_DIR}/16-BLAST"
  mkdir -p "${blast_dir}/contigs_non_places"
  mkdir -p "${blast_dir}/reads_non_mappes"

  # Checks the BLAST database actually exists before doing anything else
  local n_blast_vols
  n_blast_vols=$(ls "${BLAST_DB}"*.nhr 2>/dev/null | wc -l)
  if [[ "${n_blast_vols}" -eq 0 ]]; then
    log_error "BLAST database not found: ${BLAST_DB}"
    log_error "Set BLAST_DB correctly in your config file"
    return 1
  fi
  log_info "BLAST database: ${n_blast_vols} volumes"

  # part 1: unplaced contigs (>=100kb)
  log_info "Part 1: BLASTn on unplaced contigs (>=100kb)"

  for sample in "${SAMPLES[@]}"; do
    local scaffold="${RAGTAG_ASSEMBLIES[${sample}]}"
    local fai="${scaffold}.fai"

    log_info "  Extracting unplaced contigs: ${sample}"
    # CHROM_PATTERN from config, not hardcoded
    grep -v "${CHROM_PATTERN}" "${fai}" \
      | awk -v min=100000 '$2>=min {print $1}' \
      | xargs samtools faidx "${scaffold}" \
      > "${blast_dir}/contigs_non_places/${sample}_unplaced_100kb.fasta" 2>/dev/null

    local n_contigs
    n_contigs=$(grep -c "^>" \
      "${blast_dir}/contigs_non_places/${sample}_unplaced_100kb.fasta" 2>/dev/null || echo 0)
    log_info "  ${sample}: ${n_contigs} unplaced contigs >=100kb"

    # Skips BLAST for this sample if there is nothing unplaced to search
    if [[ "${n_contigs}" -eq 0 ]]; then
      log_warn "  No unplaced contigs >=100kb for ${sample} , skipping BLAST"
      continue
    fi

    log_info "  BLASTn ${sample} contigs"
    blastn \
      -query "${blast_dir}/contigs_non_places/${sample}_unplaced_100kb.fasta" \
      -db "${BLAST_DB}" \
      -num_threads "${THREADS}" \
      -out "${blast_dir}/contigs_non_places/${sample}_blast.txt" \
      -outfmt "6 qseqid sseqid pident length evalue bitscore stitle sscinames" \
      -max_target_seqs 1 \
      -evalue 1e-5 \
      -task megablast \
      > "${blast_dir}/contigs_non_places/${sample}_blast.log" 2>&1

    # Prints the top 5 organisms found
    log_info "  Top organisms (${sample} contigs):"
    cut -f8 "${blast_dir}/contigs_non_places/${sample}_blast.txt" \
      | sort | uniq -c | sort -rn | head -5 | \
      awk '{printf "    %s\n", $0}'
  done

  # part 2: unmapped reads
  log_info "Part 2: BLASTn on unmapped reads"

  for sample in "${SAMPLES[@]}"; do
    local unmapped="${OUTPUT_DIR}/14-MAPPING/${sample}${SAMPLE_SUFFIX:-}/${sample}_unmapped.fasta"

    # Checks the mapping step actually produced this file
    if [[ ! -f "${unmapped}" ]]; then
      log_warn "  Unmapped reads not found for ${sample}: ${unmapped}"
      log_warn "  Run mapping step first"
      continue
    fi

    local n_reads
    n_reads=$(grep -c "^>" "${unmapped}" 2>/dev/null || echo 0)
    log_info "  ${sample}: ${n_reads} unmapped reads"

    # Skips BLAST for this sample if there are no unmapped reads at all
    if [[ "${n_reads}" -eq 0 ]]; then
      log_info "  No unmapped reads for ${sample} , skipping BLAST"
      continue
    fi

    cp "${unmapped}" "${blast_dir}/reads_non_mappes/${sample}_unmapped.fasta"

    log_info "  BLASTn ${sample} unmapped reads"
    blastn \
      -query "${blast_dir}/reads_non_mappes/${sample}_unmapped.fasta" \
      -db "${BLAST_DB}" \
      -num_threads "${THREADS}" \
      -out "${blast_dir}/reads_non_mappes/${sample}_blast.txt" \
      -outfmt "6 qseqid sseqid pident length evalue bitscore stitle sscinames" \
      -max_target_seqs 1 \
      -evalue 1e-5 \
      -task megablast \
      > "${blast_dir}/reads_non_mappes/${sample}_blast.log" 2>&1

    # Prints the top 5 organisms found, quick sanity check
    log_info "  Top organisms (${sample} unmapped reads):"
    cut -f8 "${blast_dir}/reads_non_mappes/${sample}_blast.txt" \
      | sort | uniq -c | sort -rn | head -5 | \
      awk '{printf "    %s\n", $0}'
  done

  # global summary
  log_info "=== BLAST GLOBAL SUMMARY ==="
  for sample in "${SAMPLES[@]}"; do
    echo "--- ${sample} contigs ---"
    if [[ -f "${blast_dir}/contigs_non_places/${sample}_blast.txt" ]]; then
      cut -f8 "${blast_dir}/contigs_non_places/${sample}_blast.txt" \
        | sort | uniq -c | sort -rn | head -5
    fi

    echo "--- ${sample} unmapped reads ---"
    if [[ -f "${blast_dir}/reads_non_mappes/${sample}_blast.txt" ]]; then
      cut -f8 "${blast_dir}/reads_non_mappes/${sample}_blast.txt" \
        | sort | uniq -c | sort -rn | head -5
    fi
  done

  log_success "BLAST analysis complete"
  log_info "Results: ${blast_dir}"
}