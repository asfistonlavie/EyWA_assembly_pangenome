#!/bin/bash
# ==============================================================================
# TEST 03: Disk space verification + run
# HOW TO RUN:
#   bash tests/test_03_diskspace_dryrun.sh config/config_test.sh
#
# EXPECTED OUTPUT:
#   Disk space report + complete list of input/output paths
# ==============================================================================

CONFIG="${1:-config/config_test.sh}"
if [[ ! -f "${CONFIG}" ]]; then
  echo "Config file not found: ${CONFIG}"
  exit 1
fi
source "${CONFIG}"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  TEST 03: Disk space + dry run                           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""


# ==============================================================================
# PART 1: Disk space check
# ==============================================================================
echo "────────────────────────────────────────────────────────────"
echo "  PART 1: Disk space verification"
echo "────────────────────────────────────────────────────────────"
echo ""

# Creates the output directory if it doesn't exist yet, so its disk can be checked
mkdir -p "${OUTPUT_DIR}"

# Reads the available space in GB on the output directory's disk
available_gb=$(df -g "${OUTPUT_DIR}" 2>/dev/null | awk 'NR==2{print $4}' || df -h "${OUTPUT_DIR}" | awk 'NR==2{gsub("G","",$4); print $4}')

# Rough estimate: aprox . 200GB per sample (covers Flye output, BAMs, PAFs,
# QUAST, BUSCO), same estimate used in the real pre-flight check (00_setup.sh)
n_samples="${#SAMPLES[@]}"
estimated_gb=$(( n_samples * 200 ))

echo "  Output directory : ${OUTPUT_DIR}"
echo "  Available space  : ${available_gb} GB"
echo "  Samples to run   : ${n_samples} (${SAMPLES[*]})"
echo ""
echo "  Estimated space needed : ~${estimated_gb} GB"
echo "  CLEAN_INTERMEDIATES    : ${CLEAN_INTERMEDIATES}"
echo ""

# Warns if available space looks too small, does not stop the test
if [[ "${available_gb}" -lt "${estimated_gb}" ]]; then
  echo "  ⚠ WARNING: Disk space may be insufficient"
  echo "    Available : ${available_gb} GB"
  echo "    Estimated : ~${estimated_gb} GB"
  echo ""
  if [[ "${CLEAN_INTERMEDIATES}" == "false" ]]; then
    echo "    Tip: Set CLEAN_INTERMEDIATES=true in your config, it deletes"
    echo "    the large coverage BAM and self-alignment PAF from purge_dups"
    echo "    (and the Illumina BAM from Pilon, if RUN_PILON=true) once"
    echo "    they're no longer needed. Exact savings depend on your data."
  fi
else
  echo "  CHECK: Disk space looks sufficient"
  echo "    Available : ${available_gb} GB"
  echo "    Estimated : ~${estimated_gb} GB"
fi

echo ""

# Checks the reads disk too, it might not be the same disk as OUTPUT_DIR
echo "  Input reads disk usage:"
for sample in "${SAMPLES[@]}"; do
  reads_file="${READS_DIR}/${READS_PATTERN//\{SAMPLE\}/${sample}}"
  if [[ -f "${reads_file}" ]]; then
    reads_size=$(du -sh "${reads_file}" | cut -f1)
    echo "    ${sample}: ${reads_size}"
  else
    echo "    ${sample}: file not found"
  fi
done
echo ""

# ==============================================================================
# PART 2: Dry run, print all paths without executing anything
# ==============================================================================
echo "────────────────────────────────────────────────────────────"
echo "  PART 2: Dry run (no tools will be executed)"
echo "────────────────────────────────────────────────────────────"
echo ""
echo "  This shows all the paths the pipeline will use."
echo "  Review them carefully before launching the real run."
echo ""

for sample in "${SAMPLES[@]}"; do
  echo "  ┌─ Sample: ${sample} ─────────────────────────────────────"
  echo "  │"
  echo "  │  INPUT"
  echo "  │    ONT reads : ${READS_DIR}/${READS_PATTERN//\{SAMPLE\}/${sample}}"
  echo "  │    Reference : ${REF_GENOME}"
  echo "  │    Kraken2 DB: ${KRAKEN2_DB}"
  echo "  │"
  echo "  │  PREPROCESSING outputs"
  echo "  │    QC raw       : ${OUTPUT_DIR}/QC/${sample}/00_raw/"
  echo "  │    seqtk filter : ${OUTPUT_DIR}/02-FILTER/${sample}/${sample}_seqtk_filtered.fastq.gz"
  echo "  │    Porechop     : ${OUTPUT_DIR}/02-FILTER/${sample}/${sample}_porechop.fastq.gz"
  echo "  │    Kraken2 clean: ${OUTPUT_DIR}/02-FILTER/${sample}/kraken2/${sample}_unclassified.fq.gz"
  echo "  │    Kraken2 viral: ${OUTPUT_DIR}/02-FILTER/${sample}/kraken2/${sample}_classified.fq.gz"
  echo "  │"
  echo "  │  ASSEMBLY outputs"
  echo "  │    Flye assembly: ${OUTPUT_DIR}/05-ASSEMBLY/${sample}/${sample}_assembly.fasta"
  echo "  │    QUAST after  : ${OUTPUT_DIR}/06-QUAST/after_assembly/${sample}/"
  echo "  │    BUSCO after  : ${OUTPUT_DIR}/09-BUSCO/${sample}_after_assembly/"
  echo "  │"
  echo "  │  PURGE outputs"
  echo "  │    Purged       : ${OUTPUT_DIR}/08-PURGE_DUPS/${sample}${SAMPLE_SUFFIX:-}/purged.fa"
  echo "  │    Filtered     : ${OUTPUT_DIR}/08-PURGE_DUPS/${sample}${SAMPLE_SUFFIX:-}/${sample}_purged_filtered.fa"
  echo "  │    QUAST after  : ${OUTPUT_DIR}/06-QUAST/after_purge/${sample}/"
  echo "  │    BUSCO after  : ${OUTPUT_DIR}/09-BUSCO/${sample}_after_purge/"
  echo "  │"

  if [[ "${RUN_PILON}" == "true" ]]; then
    echo "  │  PILON outputs"
    echo "  │    Pilon FASTA  : ${OUTPUT_DIR}/PILON/${sample}/${sample}_pilon.fasta"
    echo "  │    Changes file : ${OUTPUT_DIR}/PILON/${sample}/${sample}_pilon.changes"
    echo "  │    QUAST after  : ${OUTPUT_DIR}/06-QUAST/after_pilon/${sample}/"
    echo "  │    BUSCO after  : ${OUTPUT_DIR}/09-BUSCO/${sample}_after_pilon/"
    echo "  │"
  fi

  echo "  │  RAGTAG outputs"
  echo "  │    Scaffold      : ${OUTPUT_DIR}/11-RAGTAG/${sample}${SAMPLE_SUFFIX:-}/${sample}_ragtag.scaffold.fasta"
  echo "  │    more100kb     : ${OUTPUT_DIR}/11-RAGTAG/${sample}${SAMPLE_SUFFIX:-}/${sample}_ragtag_more100kb.fasta"
  echo "  │    QUAST after   : ${OUTPUT_DIR}/06-QUAST/after_ragtag/${sample}/"
  echo "  │    BUSCO after   : ${OUTPUT_DIR}/09-BUSCO/${sample}_after_ragtag/"
  echo "  │"
  echo "  │  MAPPING outputs"
  echo "  │    BAM all       : ${OUTPUT_DIR}/14-C_MINIMAP2/${sample}${SAMPLE_SUFFIX:-}/${sample}_all_sort.bam"
  echo "  │    BAM primary   : ${OUTPUT_DIR}/14-C_MINIMAP2/${sample}${SAMPLE_SUFFIX:-}/${sample}_primary_sort.bam"
  echo "  │    Flagstat      : ${OUTPUT_DIR}/14-C_MINIMAP2/${sample}${SAMPLE_SUFFIX:-}/${sample}_flagstat.txt"
  echo "  │    Unmapped FASTA: ${OUTPUT_DIR}/14-C_MINIMAP2/${sample}${SAMPLE_SUFFIX:-}/${sample}_unmapped.fasta"
  echo "  │"

  if [[ "${RUN_BLAST}" == "true" ]]; then
    echo "  │  BLAST outputs"
    echo "  │    Unplaced BLAST: ${OUTPUT_DIR}/16-BLAST/contigs_non_places/${sample}_unplaced_more100kb_blast.txt"
    echo "  │    Unmapped BLAST: ${OUTPUT_DIR}/16-BLAST/reads_non_mappes/${sample}_unmapped_blast.txt"
    echo "  │"
  fi

  echo "  └────────────────────────────────────────────────────────"
  echo ""
done

echo "  SHARED outputs (across all samples)"
echo "    MASH distances : ${OUTPUT_DIR}/10-MASH/mash_distances.txt"
echo "    ntSynt blocks  : ${OUTPUT_DIR}/12-NTSYNT/ONA.synteny_blocks.tsv"
echo "    ntSynt ribbon  : ${OUTPUT_DIR}/12-NTSYNT/ONA_ribbon.pdf"
echo "    Tool versions  : ${OUTPUT_DIR}/pipeline_versions.txt"
echo "    Stage reports  : ${OUTPUT_DIR}/stage_reports/"
echo "    Checkpoint file: ${OUTPUT_DIR}/.pipeline_progress"
echo ""


# ==============================================================================
# PART 3: Config summary
# ==============================================================================
echo "────────────────────────────────────────────────────────────"
echo "  PART 3: Config summary"
echo "────────────────────────────────────────────────────────────"
echo ""
echo "  Samples          : ${SAMPLES[*]}"
echo "  Sample suffix    : '${SAMPLE_SUFFIX:-}' (empty = single individual)"
echo "  Start from       : ${START_FROM}"
echo "  Genome size      : ${GENOME_SIZE}"
echo "  Flye read type   : ${FLYE_READ_TYPE}"
echo "  Ploidy           : ${PLOIDY}"
echo "  Threads          : ${THREADS}"
echo "  Quality mode     : ${QUALITY_MODE}"
echo "  Run Pilon        : ${RUN_PILON}"
echo "  Run BLAST        : ${RUN_BLAST}"
echo "  Clean temp files : ${CLEAN_INTERMEDIATES}"
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  TEST 03 COMPLETE"
echo "  Review the paths and config above before launching the run"
echo "════════════════════════════════════════════════════════════"
echo ""
