#!/bin/bash
# evaluation, QUAST + BUSCO after every major stage, to see how the
# metrics evolve instead of only looking at the final result

declare -A BUSCO_C_HISTORY  # per-stage history, to compare before/after purge, ragtag, etc.
declare -A BUSCO_D_HISTORY
declare -A SIZE_HISTORY
declare -A CURRENT_ASSEMBLIES

# Function to run QUAST + BUSCO on every sample, for one specific pipeline stage
run_evaluation() {
  local stage="$1"
  log_info "=== EVALUATION: ${stage} ==="
  # Picks which assembly array to read from, depending on the stage
  case "${stage}" in
    "after_assembly") for s in "${SAMPLES[@]}"; do CURRENT_ASSEMBLIES["${s}"]="${ASSEMBLIES[${s}]}"; done ;;
    "after_purge")    for s in "${SAMPLES[@]}"; do CURRENT_ASSEMBLIES["${s}"]="${PURGED_ASSEMBLIES[${s}]}"; done ;;
    "after_pilon")    for s in "${SAMPLES[@]}"; do CURRENT_ASSEMBLIES["${s}"]="${PILON_ASSEMBLIES[${s}]}"; done ;;
    "after_ragtag")   for s in "${SAMPLES[@]}"; do CURRENT_ASSEMBLIES["${s}"]="${RAGTAG_ASSEMBLIES[${s}]}"; done ;;
    *) log_error "Unknown stage: ${stage}"; exit 1 ;;
  esac

  # Builds the header of the stage report table
  local report_lines=()
  report_lines+=("$(printf '%-10s %-10s %-10s %-8s %-8s %-8s %-8s' 'Sample' 'Size(Gb)' 'N50(kb)' 'Contigs' 'BUSCO_C' 'BUSCO_D' 'Status')")
  report_lines+=("$(printf '%-10s %-10s %-10s %-8s %-8s %-8s %-8s' '------' '--------' '-------' '-------' '-------' '-------' '------')")
  # Evaluates one sample at a time
  for sample in "${SAMPLES[@]}"; do
    local assembly="${CURRENT_ASSEMBLIES[${sample}]}"
    # Skips this sample if its assembly does not exist yet at this stage
    if [[ -z "${assembly}" || ! -f "${assembly}" ]]; then
      log_warn "Assembly not found for ${sample} at stage ${stage}"
      continue
    fi

    # QUAST
    local quast_dir="${OUTPUT_DIR}/06-QUAST/${stage}/${sample}"
    mkdir -p "${quast_dir}"

    conda activate "${ENV_QUAST}"
    export PATH="${CONDA_BASE}/envs/${ENV_QUAST}/bin:${PATH}"

    quast \
      -o "${quast_dir}" \
      -r "${REF_GENOME}" \
      -m "${QUAST_MIN_CONTIG}" \
      --fragmented \
      --threads "${THREADS}" \
      "${assembly}" \
      > "${quast_dir}/quast.log" 2>&1

   # Pulls the 4 metrics I care about out of QUAST's report.txt
        local size_gb n50_kb aligned_pct n_contigs
    size_gb=$(awk '/^Total length/ && !/\(/{printf "%.2f", $NF/1e9}' "${quast_dir}/report.txt" 2>/dev/null || echo "?")
    n50_kb=$(awk '/^N50/{printf "%.1f", $NF/1000}' "${quast_dir}/report.txt" 2>/dev/null || echo "?")
    aligned_pct=$(awk '/^Genome fraction/{printf "%.1f", $NF}' "${quast_dir}/report.txt" 2>/dev/null || echo "?")
    n_contigs=$(awk '/^# contigs/ && !/\(/{print $NF}' "${quast_dir}/report.txt" 2>/dev/null || echo "?")
    
    # BUSCO 
    local busco_dir="${OUTPUT_DIR}/09-BUSCO"
    local busco_name="${sample}_${stage}"
    mkdir -p "${busco_dir}"

    # Finds the BUSCO binary, manual path from config first, otherwise guesses it
    local busco_bin
    if [[ -n "${BUSCO_BIN}" ]]; then
      busco_bin="${BUSCO_BIN}"  # ruta manual desde config.advanced.sh
    elif [[ -n "${CONDA_BASE}" && -n "${ENV_BUSCO}" ]]; then
      busco_bin="${CONDA_BASE}/envs/${ENV_BUSCO}/bin/busco"  # caso normal, autodetectado
    else
      log_error "BUSCO not found: set BUSCO_BIN or CONDA_BASE/ENV_BUSCO in config"
      exit 1
    fi

    log_info "  Using BUSCO: ${busco_bin}"

    conda run -n "${ENV_BUSCO}" "${busco_bin}" \
      -i "${assembly}" \
      -o "${busco_name}" \
      --out_path "${busco_dir}" \
      -l "${BUSCO_LINEAGE}" \
      -m genome \
      -c "${THREADS}" \
      -f \
      > "${busco_dir}/${busco_name}.log" 2>&1

    # Pulls the Complete (C) and Duplicated (D) percentages out of BUSCO's summary
    local summary busco_c busco_d
    summary=$(find "${busco_dir}/${busco_name}" -name "short_summary*.txt" 2>/dev/null | head -1)
    busco_c=$(grep -oP 'C:\K[0-9.]+' "${summary}" 2>/dev/null || echo "?")
    busco_d=$(grep -oP 'D:\K[0-9.]+' "${summary}" 2>/dev/null || echo "?")

# quality check
    # there is no fixed pass/fail in de novo assembly, what matters is how
    # metrics evolve between stages (BUSCO_D drops after purge, N50 rises after ragtag, etc.)
    # I only flag "warn" for clear technical errors:
    #   - Assembly WAY too small, Flye likely crashed
    #   - Assembly WAY too big , purge_dups likely did nothing
    #   - BUSCO_D did NOT drop after purge (diploid only)

    local sample_status="ok"

    # Saves this sample's metrics for this stage, so later stages can
    # compare against them (drops between stages, not just raw values)
    BUSCO_C_HISTORY["${sample}_${stage}"]="${busco_c}"
    BUSCO_D_HISTORY["${sample}_${stage}"]="${busco_d}"
    SIZE_HISTORY["${sample}_${stage}"]="${size_gb}"

    # Runs a different set of checks depending on which stage this is
    case "${stage}" in

      "after_assembly")
        # Checks the assembly is not way too small, likely a Flye crash
        if [[ "${size_gb}" != "?" ]]; then
          local too_small
          too_small=$(awk -v s="${size_gb}" -v min="${MIN_ASSEMBLY_SIZE_GB}" 'BEGIN{print (s < min) ? "yes" : "no"}')
          if [[ "${too_small}" == "yes" ]]; then
            flag_sample "${sample}" "Assembly very small (${size_gb} Gb) , check Flye log"
            sample_status="warn"
          fi
        fi

        # Assembly too big: suggesting something unusual
        if [[ "${size_gb}" != "?" ]]; then
          local too_big
          too_big=$(awk -v s="${size_gb}" -v max="${MAX_ASSEMBLY_SIZE_GB}" 'BEGIN{print (s > max) ? "yes" : "no"}')
          if [[ "${too_big}" == "yes" ]]; then
            flag_sample "${sample}" "Assembly unusually large (${size_gb} Gb) , check for contamination"
            sample_status="warn"
          fi
        fi

        # Prints an informational note, higher BUSCO_D is expected here
        # depending on ploidy
        case "${PLOIDY}" in
          "haploid")
            log_info "  Note (${sample}): haploid, BUSCO_D should stay low before purge"
            ;;
          "diploid")
            log_info "  Note (${sample}): diploid, higher BUSCO_D before purge is expected (both haplotypes get assembled)"
            ;;
          "polyploid")
            log_info "  Note (${sample}): polyploid, even higher BUSCO_D before purge is expected"
            ;;
        esac
        ;;

      "after_purge")
        # For diploid: check that BUSCO_D actually dropped after purge
        # If it didn't drop, purge_dups likely did nothing useful
        if [[ "${PLOIDY}" == "diploid" ]]; then
          local d_before="${BUSCO_D_HISTORY[${sample}_after_assembly]:-?}"
          if [[ "${d_before}" != "?" && "${busco_d}" != "?" ]]; then
            local d_dropped
            d_dropped=$(awk -v before="${d_before}" -v after="${busco_d}" \
              'BEGIN{print (after < before - 5) ? "yes" : "no"}')
            if [[ "${d_dropped}" == "no" ]]; then
              flag_sample "${sample}" "BUSCO_D did not drop after purge (${d_before}% to ${busco_d}%) , purge_dups may not have worked well"
              sample_status="warn"
            else
              log_info "  ${sample}: BUSCO_D dropped from ${d_before}% to ${busco_d}% , purge looks good"
            fi
          fi
        fi

        # For haploid: purge was skipped, just note that
        if [[ "${PLOIDY}" == "haploid" ]]; then
          log_info "  Note (${sample}): haploid, purge was skipped, assembly unchanged"
        fi

        # Check BUSCO_C did not drop significantly compared to after_assembly
        local c_before="${BUSCO_C_HISTORY[${sample}_after_assembly]:-?}"
        if [[ "${c_before}" != "?" && "${busco_c}" != "?" ]]; then
          local c_dropped_too_much
          c_dropped_too_much=$(awk -v before="${c_before}" -v after="${busco_c}" \
            'BEGIN{print (before - after > 10) ? "yes" : "no"}')
          if [[ "${c_dropped_too_much}" == "yes" ]]; then
            flag_sample "${sample}" "BUSCO_C dropped more than 10% after purge (${c_before}% to ${busco_c}%) , check purge_dups cutoffs"
            sample_status="warn"
          fi
        fi
        ;;

      "after_ragtag")
        # Check BUSCO_C did not drop compared to after_purge
        local c_before="${BUSCO_C_HISTORY[${sample}_after_purge]:-?}"
        if [[ "${c_before}" != "?" && "${busco_c}" != "?" ]]; then
          local c_dropped_too_much
          c_dropped_too_much=$(awk -v before="${c_before}" -v after="${busco_c}" \
            'BEGIN{print (before - after > 5) ? "yes" : "no"}')
          if [[ "${c_dropped_too_much}" == "yes" ]]; then
            flag_sample "${sample}" "BUSCO_C dropped after RagTag (${c_before}% to ${busco_c}%) , may indicate scaffolding issues"
            sample_status="warn"
          fi
        fi

        # Genome fraction aligned to reference
        if [[ "${aligned_pct}" != "?" ]]; then
          log_info "  ${sample}: ${aligned_pct}% of genome aligned to reference"
        fi
        ;;
    esac

    # Check for any existing warning flags
    if [[ -n "${QUALITY_WARNINGS[${sample}]+x}" ]]; then
      sample_status="warn"
    fi

    # Status display "warn", never "fail" in report mode
    local status_str
    case "${sample_status}" in
      ok)   status_str="${GREEN}✓${NC}" ;;
      warn) status_str="${YELLOW}⚠ see note${NC}" ;;
    esac

    report_lines+=("$(printf "%-10s %-10s %-10s %-8s %-8s %-8s" \
      "${sample}" "${size_gb}" "${n50_kb}" "${n_contigs}" "${busco_c}%" "${busco_d}%") $(echo -e "${status_str}")")
    log_success "  ${sample} BUSCO: C:${busco_c}% D:${busco_d}% | Size: ${size_gb}Gb | N50: ${n50_kb}kb"
  done

  # Print stage report
  print_stage_report "${stage}" "${report_lines[@]}"

  # Pause if configured
  maybe_pause "${stage}"
}
