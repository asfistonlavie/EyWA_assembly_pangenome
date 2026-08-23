#!/bin/bash
# file_check, verifies files exist, are readable, aren't empty, and have the
# right format, before starting, better to fail here than 10h into a Flye run

# Function to guess a file's format from its extension
detect_format() {
  local file="$1"
  # If the file is gzipped, the real extension is the one before .gz
  local ext="${file##*.}"
  if [[ "${ext}" == "gz" ]]; then
    local base="${file%.*}"
    ext="${base##*.}"  # if it is .gz, I care about the extension before it (e.g. reads.fastq.gz -> fastq)
  fi
  # Maps the extension to a format name
  case "${ext}" in
    fastq|fq)           echo "FASTQ" ;;
    fasta|fa|fna|fsa)   echo "FASTA" ;;
    bam)                echo "BAM"   ;;
    *)                  echo "UNKNOWN" ;;
  esac
}

# FASTQ starts with @, FASTA starts with >, so I check the first character
check_file_content() {
  local file="$1"
  local expected_first_char="$2"

  local first_char

  # Reads the first character differently depending on whether it's gzipped
  if [[ "${file}" == *.gz ]]; then
    first_char=$(zcat "${file}" 2>/dev/null | head -c 1)
  else
    first_char=$(head -c 1 "${file}")
  fi

  [[ "${first_char}" == "${expected_first_char}" ]]
}

# Function to count how many reads or sequences are in a file
count_sequences() {
  local file="$1"
  local format="$2"

  case "${format}" in
    FASTQ)
      # every 4 lines = 1 read, line 1 starts with @
      if [[ "${file}" == *.gz ]]; then
        zcat "${file}" | awk 'NR%4==1' | wc -l
      else
        awk 'NR%4==1' "${file}" | wc -l
      fi
      ;;
    FASTA)
    # Counts the number of header lines, each starts with >
      if [[ "${file}" == *.gz ]]; then
        zcat "${file}" | grep -c "^>"
      else
        grep -c "^>" "${file}"
      fi
      ;;
    *)
      echo "?"
      ;;
  esac
}

# Function to fully check one file: exists, readable, not empty, right format
# usage: check_file "/path" "expected_format (optional)" "label" -> 0 if OK
check_file() {
  local file="$1"
  local expected_format="${2:-}"
  local label="${3:-${file}}"

  local problems=0
  # Checks the file exists at all
  if [[ ! -e "${file}" ]]; then
    log_error "  File not found: ${file}"
    log_error "    Label: ${label}"
    return 1
  fi
  # Checks the file can actually be read (permissions)
  if [[ ! -r "${file}" ]]; then
    log_error "  Cannot read file (check permissions): ${file}"
    return 1
  fi

  # Checks the file is not empty
  if [[ ! -s "${file}" ]]; then
    log_error "  File is empty: ${file}"
    return 1
  fi

  local format
  format=$(detect_format "${file}")
  local size
  size=$(du -sh "${file}" | cut -f1)

  log_info "  ✓ ${label}"
  log_info "      Path   : ${file}"
  log_info "      Format : ${format}"
  log_info "      Size   : ${size}"
  # If FASTQ, checks that the content actually starts with @
  if [[ "${format}" == "FASTQ" ]]; then
    if ! check_file_content "${file}" "@"; then
      log_error "      This file has a .fastq extension but does not start with '@'"
      log_error "      It may be corrupted or in the wrong format."
      problems=$((problems + 1))
    else
      local n_reads
      n_reads=$(count_sequences "${file}" "FASTQ")
      log_info "      Reads  : ${n_reads}"
    fi
   # If FASTA, checks that the content actually starts with >
  elif [[ "${format}" == "FASTA" ]]; then
    if ! check_file_content "${file}" ">"; then
      log_error "      This file has a .fasta extension but does not start with '>'"
      log_error "      It may be corrupted or in the wrong format."
      problems=$((problems + 1))
    else
      local n_seqs
      n_seqs=$(count_sequences "${file}" "FASTA")
      log_info "      Sequences: ${n_seqs}"
    fi
  # Unknown extension, cannot check the content, just warns about it
  elif [[ "${format}" == "UNKNOWN" ]]; then
    log_warn "      Unknown file format, skipping content check"
  fi
  # If the caller expected a specific format, checks it matches
  if [[ -n "${expected_format}" && "${format}" != "${expected_format}" ]]; then
    log_error "      Expected format: ${expected_format}, but detected: ${format}"
    problems=$((problems + 1))
  fi

  return "${problems}"
}

# Function to check every input file the pipeline needs before starting
check_input_files() {
  log_info "=== CHECKING INPUT FILES ==="
  local total_problems=0

  log_info "Reference genome:"
  check_file "${REF_GENOME}" "FASTA" "Reference genome" || total_problems=$((total_problems + 1))
   # Checks the ONT reads file for every sample
  log_info "ONT reads:"
  for sample in "${SAMPLES[@]}"; do
    local reads_file="${READS_DIR}/${READS_PATTERN//\{SAMPLE\}/${sample}}"
    check_file "${reads_file}" "FASTQ" "Sample ${sample} reads" || total_problems=$((total_problems + 1))
  done
  # Checks that the Kraken2 database folder and its main index file exist
  log_info "Kraken2 database:"
  if [[ ! -d "${KRAKEN2_DB}" ]]; then
    log_error "  Kraken2 database folder not found: ${KRAKEN2_DB}"
    total_problems=$((total_problems + 1))
  elif [[ ! -f "${KRAKEN2_DB}/hash.k2d" ]]; then
    log_error "  Kraken2 database looks incomplete, hash.k2d not found in: ${KRAKEN2_DB}"
    log_error "  Make sure you have a complete Kraken2 database at that path."
    total_problems=$((total_problems + 1))
  else
    log_info "  Correct Kraken2 database: ${KRAKEN2_DB}"
  fi

   # Illumina reads are only required if Pilon polishing is turned on
  if [[ "${RUN_PILON}" == "true" ]]; then
    log_info "Illumina reads for Pilon:"
    for sample in "${SAMPLES[@]}"; do
      local r1="${ILLUMINA_DIR}/${ILLUMINA_R1_PATTERN//\{SAMPLE\}/${sample}}"
      local r2="${ILLUMINA_DIR}/${ILLUMINA_R2_PATTERN//\{SAMPLE\}/${sample}}"
      check_file "${r1}" "FASTQ" "Sample ${sample} Illumina R1" || total_problems=$((total_problems + 1))
      check_file "${r2}" "FASTQ" "Sample ${sample} Illumina R2" || total_problems=$((total_problems + 1))
    done
  fi

   # The BLAST database is only required if the optional BLAST step is on
  if [[ "${RUN_BLAST}" == "true" ]]; then
    log_info "BLAST database:"
    local n_blast_files
    n_blast_files=$(ls "${BLAST_DB}"*.nhr 2>/dev/null | wc -l)
    if [[ "${n_blast_files}" -eq 0 ]]; then
      log_error "  BLAST nt database not found at: ${BLAST_DB}"
      log_error "  Make sure BLAST_DB points to the correct prefix (e.g. /path/to/nt)"
      total_problems=$((total_problems + 1))
    else
      log_info "  Correct BLAST nt database: ${n_blast_files} volume(s) found"
    fi
  fi
  # Stops the pipeline here if any file failed a check above
  if [[ "${total_problems}" -gt 0 ]]; then
    log_error "Found ${total_problems} problem(s) with input files."
    log_error "Please fix the issues above before running the pipeline."
    exit 1
  fi

  log_success "All input files checked successfully."
}
