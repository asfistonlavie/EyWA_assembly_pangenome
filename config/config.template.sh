#!/bin/bash
# config, copy to config.sh and edit. [REQUIRED] means you must change it,
# everything else already has the values I used for Aedes aegypti / ONT pool-of-10
#   cp config/config.template.sh config/config.sh && nano config/config.sh


# ==============================================================================
# [REQUIRED] YOUR SAMPLES
# ==============================================================================

# The names of your samples, one word each, no spaces, no special characters.
# These names will be used to name all output files, so keep them short and clear.
#
# Example with 4 samples:
#   SAMPLES=("ABY5" "SF2" "StC4" "TB5")
SAMPLES=("SAMPLE1" "SAMPLE2")

# The folder that contains your ONT reads (one file per sample).
# All reads files must be in the same folder.
#
# Example:
#   READS_DIR="/newvol/project/01-READS"
READS_DIR="/path/to/reads"

# The naming pattern of your reads files.
# Use {SAMPLE} as a placeholder, the pipeline will replace it with each sample name.
#
# Example: if your files are named "ABY5_pool10_reads.fq.gz",
#          set this to "{SAMPLE}_pool10_reads.fq.gz"
READS_PATTERN="{SAMPLE}_reads.fastq.gz"


# ==============================================================================
# [REQUIRED] REFERENCE GENOME
# ==============================================================================

# Full path to the reference genome file (in .fna or .fasta format).
# For Aedes aegypti: this is usually AaegL5 (GCF_002204515.2)
#
# Example:
#   REF_GENOME="/newvol/project/GENOMES/GCF_002204515.2_AaegL5.0_genomic.fna"
REF_GENOME="/path/to/reference.fna"

# How to recognize the main chromosomes in the reference genome.
# The pipeline uses this to separate "real" chromosomes from small unplaced fragments.
#
# Look at the chromosome names in your reference .fna file, they usually start
# with a pattern like "NC_035" (AaegL5), "CM046" (Rockefeller), or "chr" (human).
# Set this to whatever prefix your chromosomes start with.
#
# Example for AaegL5:   CHROM_PATTERN="NC_035"
# Example for human:    CHROM_PATTERN="chr"
CHROM_PATTERN="NC_035"

# How many main chromosomes does your organism have?
# For Aedes aegypti: 3
N_CHROMOSOMES=3

# External reference genomes to include in divergence (MASH) and synteny
# (ntSynt, after-ragtag stage only) comparisons, alongside your own samples.
# Optional, leave empty to skip. Useful to see how your populations diverge
# from published assemblies.
# Example:
#   EXTERNAL_REFERENCES=(
#     "/path/to/AaegL5.fna"
#     "/path/to/Rockefeller.fna"
#     "/path/to/formosus.fna"
#   )
EXTERNAL_REFERENCES=()

# ==============================================================================
# [REQUIRED] WHERE TO SAVE RESULTS
# ==============================================================================

# The main output folder. All results will be organized inside this folder.
# The pipeline will create it if it doesn't exist.
#
# Example:
#   OUTPUT_DIR="/newvol/shared_Aedes_Alondra/work"
OUTPUT_DIR="/path/to/output"


# ==============================================================================
# [REQUIRED] COMPUTING RESOURCES
# ==============================================================================

# How many CPU cores to use. More = faster, but check what your server allows.
# A safe default for a shared server is 16.
THREADS=16

# Maximum memory to give to Java (needed for Pilon polishing).
# Only matters if RUN_PILON="true". Needs to be large for big genomes.
# Example: "100G" means 100 gigabytes.
MAX_MEMORY="100G"


# ==============================================================================
# [REQUIRED] CONDA, your software manager
# ==============================================================================

# The root folder of your conda installation.
# Not sure where it is? Run this command:  conda info --base
#
# Example:
#   CONDA_BASE="/bigvol/alondra/miniconda3"
CONDA_BASE="/path/to/miniconda3"

# This line tells the pipeline where the conda startup script is.
# You usually don't need to change this, it's built from CONDA_BASE automatically.
CONDA_INIT="${CONDA_BASE}/etc/profile.d/conda.sh"

# Names of the conda environments the pipeline needs.
# The pipeline will auto-detect if they exist, and offer to install them if not.
# Only change these if you named your environments differently.
ENV_MAIN="ragtagsteps"      # Contains: minimap2, samtools, ragtag, ntSynt, mash, bwa, seqkit, seqtk, NanoPlot, flye
ENV_BUSCO="busco_5.8.3"    # Contains: BUSCO 5.8.3
ENV_QUAST="quast_env"       # Contains: QUAST
ENV_PILON="pilon_env"       # Contains: Pilon (only needed if RUN_PILON="true")
ENV_PORECHOP="porechop_env"  # Contains: Porechop (isolated due to Python 3.13 incompatibility)

# ==============================================================================
# [REQUIRED] DATABASES
# ==============================================================================

# Path to the Kraken2 database for viral decontamination.
# This is a folder containing Kraken2 index files (hash.k2d, opts.k2d, taxo.k2d).
#
# Example:
#   KRAKEN2_DB="/newvol/project/SOFTWARE/kraken2_virus_db"
KRAKEN2_DB="/path/to/kraken2_db"

# Which BUSCO lineage to use for genome completeness evaluation.
# Choose the one closest to your organism.
# See all options at: https://busco-data.ezlab.org/v5/data/lineages/
#
# For Aedes aegypti:  "diptera_odb10"  (most specific, recommended)
# For any insect:     "insecta_odb10"  (less specific but broader)
BUSCO_LINEAGE="diptera_odb10"

# ==============================================================================
# PLOIDY important for purge_dups behavior
# ==============================================================================

# The ploidy of your organism:
#
#   "diploid"   → organism has 2 copies of each chromosome (most common)
#                 Flye will assemble both haplotype copies → assembly is ~2x
#                 the expected genome size → purge_dups is NEEDED
#
#   "haploid"   → organism has only 1 copy of each chromosome
#                 Assembly should already match the genome size estimate
#                 purge_dups is automatically SKIPPED
#
#   "polyploid" → organism has 3 or more copies of each chromosome
#                 Consider setting PURGE_DUPS_MODE="manual"
#              
PLOIDY="diploid"

# ==============================================================================
# SAMPLE TYPE SUFFIX
# ==============================================================================
# Used to name output folders, it helps to distinguish different sample types.
# Leave empty for single individuals (ABY1ind, SF1ind).
# Set to "pool10" for pools of 10 individuals.
# Set to "pool3" for pools of 3 individuals.
#
# Examples:
#   SAMPLE_SUFFIX="pool10"  --> output: 11-RAGTAG/ABY5pool10/
#   SAMPLE_SUFFIX=""        --> output: 11-RAGTAG/ABY1ind/

SAMPLE_SUFFIX=""

# ==============================================================================
# ASSEMBLY PARAMETERS
# These defaults work well for Aedes aegypti ONT pool-of-10 data.
# Only change if you know what you're doing or if you have a different organism.
# ==============================================================================

# Estimated genome size for Flye. This helps Flye plan its memory usage.
# For Aedes aegypti haploid genome: "1.3g" (1.3 gigabases)
GENOME_SIZE="1.3g"

# Type of reads you are assembling. Options:
#   "nano-raw"   --> standard ONT reads (most common)
#   "nano-hq"    --> high-quality ONT reads (newer flowcells, >Q20)
#   "pacbio-raw" --> PacBio CLR reads
#   "pacbio-hifi"--> PacBio HiFi reads
FLYE_READ_TYPE="nano-raw"

# Minimum read length to keep after seqtk filtering, in base pairs.
# This is not something to guess in advance, decide it after looking at
# your own data:
#   1. Run the pipeline up to (or just) preprocessing
#   2. Open the raw-reads NanoPlot report: OUTPUT_DIR/QC/{sample}/00_raw/
#   3. Check the N50 and length distribution for that specific run
#   4. Pick a threshold that makes sense for what you saw (1000 is a
#      reasonable starting point for ONT, not a rule)
#   5. Set SEQTK_MIN_LENGTH below, then re-run from preprocessing
SEQTK_MIN_LENGTH=1000

# How purge_dups calculates coverage cutoffs.
# "auto"   = let the tool calculate the thresholds automatically (recommended
#            for a first run)
# "manual" = you define the thresholds yourself, same "run, look, decide"
#            workflow as above:
#   1. Run with PURGE_DUPS_MODE="auto" first
#   2. Check the coverage stats: OUTPUT_DIR/08-PURGE_DUPS/{sample}_auto/PB.stat
#      (or plot it with purge_dups' own hist_plot.py script)
#   3. If the automatic cutoffs (in the "cutoffs" file, same folder) look
#      wrong for your coverage histogram, switch to manual
#   4. Set PURGE_DUPS_MODE="manual" and fill in PURGE_CUTOFFS below,
#      per sample, then re-run from the purge stage
PURGE_DUPS_MODE="auto"

# Manual cutoffs per sample, only read when PURGE_DUPS_MODE="manual" above.
# Each value is "low mid high" (see purge_dups docs for what each means).
# Leave empty (the default) when using "auto", any sample not listed here
# falls back to "5 12 35" in manual mode.
# Example:
#   declare -A PURGE_CUTOFFS=(
#     ["ABY5"]="3 15 40"
#     ["ABY6"]="4 14 38"
#   )
declare -A PURGE_CUTOFFS=()

# Minimum contig length for QUAST to analyze (in base pairs).
# Contigs shorter than this are ignored in the QUAST report.
QUAST_MIN_CONTIG=1000

# ntSynt visualization settings (used for the ribbon plot PDF),
# run once with the defaults, look at the PDF, and adjust if the
# plot looks too cluttered or the bands too thin/thick, then re-run synteny

NTSYNT_LENGTH=10000         # Minimum synteny block length to show (bp)
NTSYNT_SEQ_LENGTH=500000    # Minimum sequence length to show (bp), 500kb
NTSYNT_WIDTH=60             # PDF width in cm
NTSYNT_HEIGHT=20            # PDF height in cm
NTSYNT_RIBBON_ADJUST=0.6    # Thickness of the ribbon bands (0=thin, 1=thick)


# ==============================================================================
# PIPELINE FLOW
# ==============================================================================

# Where to start the pipeline.
# If you have already run some steps and just want to continue from a specific
# point (or re-run from a certain stage), change this.
#
# Available stages (in order):
#   "preprocessing"  --> Start from the beginning (NanoPlot, seqtk, Porechop, Kraken2)
#   "assembly"       --> Skip preprocessing, start from Flye assembly
#   "purge"          --> Skip assembly, start from purge_dups
#   "pilon"          --> Skip purge, start from Pilon polishing
#   "ragtag"         --> Skip Pilon, start from RagTag scaffolding
#   "synteny"        --> Skip scaffolding, start from MASH + ntSynt
#   "mapping"        --> Skip synteny, start from read mapping
START_FROM="preprocessing"

# Should the pipeline delete large intermediate files after each step?
# These files (unsorted BAMs, SAMs, Flye internal files) can use 100GB+ per sample.
# "true"  = delete them automatically to save space (recommended)
# "false" = keep everything (useful for debugging)
CLEAN_INTERMEDIATES="true"

# Should the pipeline pause after each stage and ask before continuing?
# "true"  = pipeline stops and waits for you to press ENTER before each new stage
# "false" = pipeline runs all the way through without stopping (recommended for nohup runs)
PAUSE_AFTER_EACH_STAGE="false"

# If PAUSE_AFTER_EACH_STAGE="true": how many seconds to wait before auto-continuing.
# Set to 0 to wait indefinitely (you must press ENTER manually).
AUTO_CONTINUE_TIMEOUT=60
# ==============================================================================
# OPTIONAL STEP: PILON POLISHING
# Pilon uses Illumina short reads to fix small errors left by ONT sequencing.
# ==============================================================================

# Set to "true" to enable Pilon polishing, "false" to skip it.
RUN_PILON="false"

# [Only needed if RUN_PILON="true"]
# Folder containing your Illumina paired-end reads (R1 and R2 files).
ILLUMINA_DIR=""

# Naming patterns for Illumina reads, use {SAMPLE} as a placeholder.
# Example: if your files are "ABY5_R1.fastq.gz" and "ABY5_R2.fastq.gz"
#          set the patterns to "{SAMPLE}_R1.fastq.gz" and "{SAMPLE}_R2.fastq.gz"
ILLUMINA_R1_PATTERN="{SAMPLE}_R1.fastq.gz"
ILLUMINA_R2_PATTERN="{SAMPLE}_R2.fastq.gz"


# ==============================================================================
# OPTIONAL STEP: BLAST SEARCH
# Searches unplaced contigs and unmapped reads against the NCBI nt database
# to find out what they are (mosquito sequence? viral? bacterial? unknown?).
# ==============================================================================

# Set to "true" to enable BLAST, "false" to skip it.
RUN_BLAST="false"

# [Only needed if RUN_BLAST="true"]
# Path prefix to the BLAST nt database (not a folder, the file prefix).
# Example: "/bigvol/omion/Software/database_blast/nt"
#   This points to files named nt.000.nhd, nt.001.nhd, etc.
BLAST_DB="/path/to/blast/nt"

# The pipeline never stops on its own when it sees an unusual pattern, it
# flags the sample and keeps going. Notes are shown in the stage report and
# saved to stage_reports/ for you to review, nothing is excluded automatically.
# Interpreting what an unusual pattern means is left to you, not automated.
# ==============================================================================
QUALITY_MODE="report"

# ------------------------------------------------------------------------------
# Technical error detection
# These are NOT quality thresholds, they detect clear technical failures.
# The pipeline raises a note if these are exceeded, regardless of QUALITY_MODE.
#
# Values are deliberately loose, they catch obvious problems (Flye crash,
# purge_dups doing nothing) without penalizing biologically diverse datasets.
# ------------------------------------------------------------------------------

# Assembly size bounds, catches Flye crashes or incomplete runs
# For Aedes aegypti diploid: expect ~2-2.5 Gb before purge
# Adjust for your organism: MIN = ~0.3x genome size, MAX = ~4x genome size
MIN_ASSEMBLY_SIZE_GB=0.5     # Below this: Flye likely crashed or had too few reads
MAX_ASSEMBLY_SIZE_GB=4.0     # Above this: something unusual happened (contamination?)

# ==============================================================================
# TOOL PATHS usually auto-detected, only change if auto-detection fails
# ==============================================================================

# Full path to the BUSCO executable.
# Leave empty to auto-detect from the BUSCO conda environment.
export BUSCO_BIN="/opt/anaconda3/envs/busco_mac/bin/busco"

# Full path to the Pilon .jar file (only needed if RUN_PILON="true").
# Leave empty to auto-detect from the Pilon conda environment.
PILON_JAR=""

# Full path to the Java executable (only needed if RUN_PILON="true").
# IMPORTANT: Use the system Java (not the conda Java), conda Java has memory bugs.
# To find it: ls ~/.sdkman/candidates/java/current/bin/java
# Or: which java (but make sure it's NOT from conda)
JAVA_BIN=""

# Full path to the ntSynt-viz bin folder.
# Leave empty to auto-detect. If not found, the visualization step is skipped.
# Clone from: https://github.com/BirolLab/ntSynt-viz
NTSYNT_VIZ=""
NTSYNT_AVAILABLE=false
