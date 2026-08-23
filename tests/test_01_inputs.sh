#!/bin/bash
# ==============================================================================
# TEST 01: Input file verification
#
# HOW TO RUN:
#   bash tests/test_01_inputs.sh config/config_test.sh
# ==============================================================================

# Load the config file to get all the paths and settings
CONFIG="${1:-config/config_test.sh}"
if [[ ! -f "${CONFIG}" ]]; then
  echo "Config file not found: ${CONFIG}"
  exit 1
fi
source "${CONFIG}"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  TEST 01: Input file verification                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Config file : ${CONFIG}"
echo "  Samples     : ${SAMPLES[*]}"
echo ""

# Track overall pass/fail
total_problems=0


# ==============================================================================
# Helper functions
# ==============================================================================

# Get the first character of a file (handles .gz compressed files)
# This lets us check the file format without reading the whole file
get_first_char() {
  local file="$1"
  if [[ "${file}" == *.gz ]]; then
    # Compressed file: use zcat to decompress and read just the first byte
    zcat "${file}" 2>/dev/null | head -c 1
  else
    head -c 1 "${file}"
  fi
}

# Count sequences in a FASTQ file
# In FASTQ format: every 4 lines = 1 read, and line 1 always starts with @
# So counting lines that start with @ gives us the number of reads
count_fastq_reads() {
  local file="$1"
  if [[ "${file}" == *.gz ]]; then
    zcat "${file}" | awk 'NR%4==1' | wc -l
  else
    awk 'NR%4==1' "${file}" | wc -l
  fi
}

# Count sequences in a FASTA file
# In FASTA format: each sequence starts with '>'
# So counting '>' lines gives us the number of sequences
count_fasta_seqs() {
  local file="$1"
  if [[ "${file}" == *.gz ]]; then
    zcat "${file}" | grep -c "^>"
  else
    grep -c "^>" "${file}"
  fi
}

# Check a single file and print a report
# Arguments: file_path  expected_format  label
check_file() {
  local file="$1"
  local expected_format="$2"   # "FASTQ" or "FASTA"
  local label="$3"

  local problems=0

  # Check 1: Does the file exist?
  if [[ ! -e "${file}" ]]; then
    echo "  FAIL: ${label}"
    echo "    Problem : File does not exist"
    echo "    Path    : ${file}"
    echo "    Fix     : Check that the path in your config is correct"
    total_problems=$((total_problems + 1))
    return 1
  fi

  # Check 2: Can we read it?
  if [[ ! -r "${file}" ]]; then
    echo "  FAIL: ${label}"
    echo "    Problem : File exists but cannot be read (permissions issue)"
    echo "    Path    : ${file}"
    echo "    Fix     : chmod +r ${file}"
    total_problems=$((total_problems + 1))
    return 1
  fi

  # Check 3: Is it empty?
  if [[ ! -s "${file}" ]]; then
    echo "  FAIL: ${label}"
    echo "    Problem : File is empty (0 bytes)"
    echo "    Path    : ${file}"
    total_problems=$((total_problems + 1))
    return 1
  fi

  # Get basic file info
  local size
  size=$(du -sh "${file}" | cut -f1)
  local first_char
  first_char=$(get_first_char "${file}")

  # Check 4: Is the format correct?
  local format_ok=true
  local format_detected

  if [[ "${expected_format}" == "FASTQ" ]]; then
    if [[ "${first_char}" == "@" ]]; then
      format_detected="FASTQ CHECKED"
    else
      format_detected="UNEXPECTED (first character: '${first_char}', expected '@')"
      format_ok=false
      problems=$((problems + 1))
      total_problems=$((total_problems + 1))
    fi
  elif [[ "${expected_format}" == "FASTA" ]]; then
    if [[ "${first_char}" == ">" ]]; then
      format_detected="FASTA CHECKED"
    else
      format_detected="UNEXPECTED (first character: '${first_char}', expected '>')"
      format_ok=false
      problems=$((problems + 1))
      total_problems=$((total_problems + 1))
    fi
  fi

  # Count sequences (only if format is correct, otherwise count would be wrong)
  local n_seqs="?"
  if [[ "${format_ok}" == "true" ]]; then
    if [[ "${expected_format}" == "FASTQ" ]]; then
      n_seqs=$(count_fastq_reads "${file}")
      seq_label="reads"
    else
      n_seqs=$(count_fasta_seqs "${file}")
      seq_label="sequences"
    fi
  fi

  # Print result
  if [[ "${problems}" -eq 0 ]]; then
    echo "  CHECK: ${label}"
    echo "    Path    : ${file}"
    echo "    Size    : ${size}"
    echo "    Format  : ${format_detected}"
    echo "    Content : ${n_seqs} ${seq_label}"
  else
    echo "  FAIL: ${label}"
    echo "    Path    : ${file}"
    echo "    Size    : ${size}"
    echo "    Format  : ${format_detected}"
    echo "    Fix     : Make sure the file is a valid ${expected_format} file"
  fi
}


# ==============================================================================
# CHECK 1: ONT reads for each sample
# ==============================================================================
echo "────────────────────────────────────────────────────────────"
echo "  ONT reads (one file per sample)"
echo "────────────────────────────────────────────────────────────"
echo ""

for sample in "${SAMPLES[@]}"; do
  # Build the full path by replacing {SAMPLE} with the actual sample name
  # This is the same substitution used in the pipeline itself
  reads_file="${READS_DIR}/${READS_PATTERN//\{SAMPLE\}/${sample}}"
  check_file "${reads_file}" "FASTQ" "Sample ${sample} ONT reads"
  echo ""
done


# ==============================================================================
# CHECK 2: Reference genome
# ==============================================================================
echo "────────────────────────────────────────────────────────────"
echo "  Reference genome (AaegL5.0)"
echo "────────────────────────────────────────────────────────────"
echo ""
check_file "${REF_GENOME}" "FASTA" "Reference genome"
echo ""


# ==============================================================================
# CHECK 3: Kraken2 database
# ==============================================================================
echo "────────────────────────────────────────────────────────────"
echo "  Kraken2 viral database"
echo "────────────────────────────────────────────────────────────"
echo ""

if [[ ! -d "${KRAKEN2_DB}" ]]; then
  echo "  FAIL: Kraken2 database folder not found: ${KRAKEN2_DB}"
  echo "    Fix: Set KRAKEN2_DB to the folder containing your Kraken2 index files"
  total_problems=$((total_problems + 1))
elif [[ ! -f "${KRAKEN2_DB}/hash.k2d" ]]; then
  echo "  FAIL: Kraken2 database looks incomplete"
  echo "    Folder   : ${KRAKEN2_DB}"
  echo "    Missing  : hash.k2d (the main index file)"
  echo "    Present  :"
  ls "${KRAKEN2_DB}/" | sed 's/^/      /'
  total_problems=$((total_problems + 1))
else
  echo "  CHECK: Kraken2 database"
  echo "    Path     : ${KRAKEN2_DB}"
  echo "    hash.k2d : $(du -sh ${KRAKEN2_DB}/hash.k2d 2>/dev/null | cut -f1)"
  echo "    taxo.k2d : $(du -sh ${KRAKEN2_DB}/taxo.k2d 2>/dev/null | cut -f1)"
  echo "    opts.k2d : $(du -sh ${KRAKEN2_DB}/opts.k2d 2>/dev/null | cut -f1)"
fi
echo ""


# ==============================================================================
# CHECK 4: Illumina reads (only if Pilon is enabled)
# ==============================================================================
if [[ "${RUN_PILON}" == "true" ]]; then
  echo "────────────────────────────────────────────────────────────"
  echo "  Illumina reads for Pilon polishing (RUN_PILON=true)"
  echo "────────────────────────────────────────────────────────────"
  echo ""

  for sample in "${SAMPLES[@]}"; do
    r1="${ILLUMINA_DIR}/${ILLUMINA_R1_PATTERN//\{SAMPLE\}/${sample}}"
    r2="${ILLUMINA_DIR}/${ILLUMINA_R2_PATTERN//\{SAMPLE\}/${sample}}"
    check_file "${r1}" "FASTQ" "Sample ${sample} Illumina R1"
    echo ""
    check_file "${r2}" "FASTQ" "Sample ${sample} Illumina R2"
    echo ""
  done
fi


# ==============================================================================
# CHECK 5: BLAST database (only if BLAST is enabled)
# ==============================================================================
if [[ "${RUN_BLAST}" == "true" ]]; then
  echo "────────────────────────────────────────────────────────────"
  echo "  BLAST nt database (RUN_BLAST=true)"
  echo "────────────────────────────────────────────────────────────"
  echo ""

  n_blast_files=$(ls "${BLAST_DB}"*.nhr 2>/dev/null | wc -l)
  if [[ "${n_blast_files}" -eq 0 ]]; then
    echo "  FAIL: BLAST nt database not found at: ${BLAST_DB}"
    echo "    Fix: Set BLAST_DB to the correct path prefix (e.g. /path/to/nt)"
    total_problems=$((total_problems + 1))
  else
    echo "  CHECK: BLAST nt database"
    echo "    Path     : ${BLAST_DB}"
    echo "    Volumes  : ${n_blast_files} .nhr files found"
  fi
  echo ""
fi


# ==============================================================================
# SUMMARY
# ==============================================================================
echo "════════════════════════════════════════════════════════════"
if [[ "${total_problems}" -eq 0 ]]; then
  echo "  CHECK: TEST 01 PASSED, All input files look good"
else
  echo "  FAIL: TEST 01 FAILED, Found ${total_problems} problem(s)"
  echo "    Fix the issues above before running the pipeline"
fi
echo "════════════════════════════════════════════════════════════"
echo ""
