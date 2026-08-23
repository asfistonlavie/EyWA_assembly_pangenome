#!/bin/bash
# purge_dups, Flye assembles both haplotypes in a diploid organism, this collapses
# them down to a single representative copy.
# Note to self: use pbcstat (not ngscstat) because the reads are ONT/long-read,
# ngscstat is for Illumina data and produces TX.* instead of PB.*

declare -A PURGED_ASSEMBLIES  # each sample's purged assembly, used by RagTag/QUAST/BUSCO

# Function to run purge_dups on every sample's assembly
run_purge_dups() {
  log_info "=== PURGE HAPLOTYPES (purge_dups) ==="

  # Haploid organisms have nothing to purge, so we use the Flye's output 
  if [[ "${PLOIDY}" == "haploid" ]]; then
    log_warn "PLOIDY=haploid, purge_dups is SKIPPED."
    for sample in "${SAMPLES[@]}"; do
      PURGED_ASSEMBLIES["${sample}"]="${ASSEMBLIES[${sample}]}"
      log_info "  ${sample}: using assembly as-is -> ${ASSEMBLIES[${sample}]}"
    done
    return
  fi

  # Polyploid organisms still run purge_dups, but calcuts' automatic cutoffs
  # were not designed for more than 2 copies, so results may need review
  if [[ "${PLOIDY}" == "polyploid" ]]; then
    log_warn "PLOIDY=polyploid, purge_dups will run, but results may need review."
    log_warn "Consider setting PURGE_DUPS_MODE=manual and defining PURGE_CUTOFFS in your config."
  fi

  # Looks for the purge_dups binaries, either in conda or compiled by hand
  local PURGE_BIN
  PURGE_BIN=$(conda run -n "${ENV_MAIN}" which purge_dups 2>/dev/null | xargs dirname 2>/dev/null || true)

  # Falls back to a couple of likely install locations if conda didn't have it
  if [[ -z "${PURGE_BIN}" ]]; then
    for candidate in \
      "${OUTPUT_DIR}/../SOFTWARE/purge_dups/bin" \
      "${CONDA_BASE}/envs/${ENV_MAIN}/bin"; do
      if [[ -f "${candidate}/purge_dups" ]]; then
        PURGE_BIN="${candidate}"
        break
      fi
    done
  fi

  # Stops here if purge_dups could not be found anywhere
  if [[ -z "${PURGE_BIN}" ]]; then
    log_error "purge_dups executables not found."
    log_error "Install with: conda install -c bioconda purge_dups"
    exit 1
  fi

  log_info "purge_dups found at: ${PURGE_BIN}"

  conda activate "${ENV_MAIN}"
  export PATH="${CONDA_BASE}/envs/${ENV_MAIN}/bin:${PATH}"

  # Purges one sample at a time
  for sample in "${SAMPLES[@]}"; do
    log_info "Purging haplotypes for sample: ${sample}"

    local assembly="${ASSEMBLIES[${sample}]}"
    local purge_dir="${OUTPUT_DIR}/08-PURGE_DUPS/${sample}_auto"
    local purged_out="${purge_dir}/purged.fa"

    mkdir -p "${purge_dir}"
    cd "${purge_dir}"

    # Skips this sample if it was already purged before
    if [[ -f "${purged_out}" ]]; then
      log_warn "  Purged assembly already exists for ${sample}, skipping."
      PURGED_ASSEMBLIES["${sample}"]="${purged_out}"
      continue
    fi

    # 1) maps the ONT reads to the assembly to measure per-contig coverage
    log_info "  1/5: mapping ONT reads to the assembly (coverage)"
    minimap2 \
      -t "${THREADS}" \
      -ax map-ont \
      "${assembly}" \
      "${CLEAN_READS[${sample}]}" \
      | samtools sort -@ "${THREADS}" \
      -o "${purge_dir}/${sample}_coverage.sorted.bam" -

    samtools index "${purge_dir}/${sample}_coverage.sorted.bam"

    # 2) turns the coverage into per-contig stats -> PB.stat / PB.base.cov
    log_info "  2/5: computing per-contig coverage (pbcstat)"
    "${PURGE_BIN}/pbcstat" "${purge_dir}/${sample}_coverage.sorted.bam"

    # 3) turns coverage stats into cutoffs: low=junk/contamination,
    #    mid=~0.5x=duplicate, high=repeat
    log_info "  3/5: calculating coverage cutoffs"
    if [[ "${PURGE_DUPS_MODE}" == "auto" ]]; then
      "${PURGE_BIN}/calcuts" PB.stat > cutoffs 2> calcuts.log
      log_info "  Auto-detected cutoffs: $(cat cutoffs)"
    else
      # Manual mode, reads the cutoffs from config, falls back to a
      # generic default if this sample was not listed
      local manual_cutoffs="${PURGE_CUTOFFS[${sample}]:-5 12 35}"
      local low mid high
      read -r low mid high <<< "${manual_cutoffs}"
      "${PURGE_BIN}/calcuts" -l "${low}" -m "${mid}" -u "${high}" \
        PB.stat > cutoffs 2> calcuts.log
      log_info "  Manual cutoffs for ${sample}: low=${low} mid=${mid} high=${high}"
    fi

    # 4) self-alignment, to find which regions of the assembly are redundant
    log_info "  4/5: self-alignment (split + minimap2 -xasm5)"
    "${PURGE_BIN}/split_fa" "${assembly}" \
      > "${purge_dir}/${sample}_assembly.split.fa"

    minimap2 \
      -t "${THREADS}" \
      -xasm5 \
      -DP \
      "${purge_dir}/${sample}_assembly.split.fa" \
      "${purge_dir}/${sample}_assembly.split.fa" \
      | gzip -c > "${purge_dir}/${sample}_assembly.split.self.paf.gz"

    # 5) removes duplicated contigs using the coverage (2-3) and
    #    self-alignment (4) together
    log_info "  5/5: removing duplicated contigs"
    "${PURGE_BIN}/purge_dups" \
      -2 \
      -T cutoffs \
      -c PB.base.cov \
      "${purge_dir}/${sample}_assembly.split.self.paf.gz" \
      > dups.bed 2> purge_dups.log

    "${PURGE_BIN}/get_seqs" dups.bed "${assembly}" \
      > "${purged_out}"

    # Checks purge_dups actually produced an output before continuing
    if [[ ! -f "${purged_out}" ]]; then
      log_error "  purge_dups failed for ${sample}, purged.fa was not created."
      log_error "  Check the log: ${purge_dir}/purge_dups.log"
      exit 1
    fi

    # ntSynt uses k=24, sequences shorter than 25bp make it fail with
    # "sequence too short", so a filtered copy is made here for it
    log_info "  filtering sequences <25bp (required for ntSynt)"
    seqkit seq -m 25 "${purged_out}" \
      > "${purge_dir}/${sample}_purged_filtered.fa"

    samtools faidx "${purged_out}"
    samtools faidx "${purge_dir}/${sample}_purged_filtered.fa"

    local n_before n_after size_gb
    n_before=$(grep -c "^>" "${assembly}")
    n_after=$(grep -c "^>" "${purged_out}")
    size_gb=$(du -sh "${purged_out}" | cut -f1)

    log_success "  ${sample} purge complete:"
    log_info "    Contigs before purge : ${n_before}"
    log_info "    Contigs after purge  : ${n_after}"
    log_info "    Purged assembly size : ${size_gb}"

    # Deletes the large intermediate files if the config asks for it
    if [[ "${CLEAN_INTERMEDIATES}" == "true" ]]; then
      rm -f "${purge_dir}/${sample}_coverage.sorted.bam" \
            "${purge_dir}/${sample}_coverage.sorted.bam.bai" \
            "${purge_dir}/${sample}_assembly.split.self.paf.gz"
      log_info "    Intermediate files cleaned up."
    fi

    PURGED_ASSEMBLIES["${sample}"]="${purged_out}"
    # purge_dups works with relative paths, so returns to OUTPUT_DIR
    # before moving on to the next sample
    cd "${OUTPUT_DIR}"
  done

  log_success "Purge haplotypes complete for all samples."
}
