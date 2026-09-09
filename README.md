# ONA Genome Assembly Pipeline

De novo genome assembly for ONT long reads.

**Author:** Alondra GONZALEZ, M1 Bioinformatique, Université de Montpellier 

---

## Pipeline Overview

```
ONT reads
    │
    ├── QC (NanoPlot)
    ├── Length filtering (seqtk)
    ├── QC (NanoPlot)
    ├── Adapter trimming (Porechop)
    ├── QC (NanoPlot)
    ├── Decontamination (Kraken2)
    ├── QC (NanoPlot)
    │
    ├── De novo assembly (Flye)
    ├── Evaluation (QUAST + BUSCO)
    │
    ├── Purge haplotypes (purge_dups)
    ├── Evaluation (QUAST + BUSCO)
    │
    ├── [Optional] Pilon polishing (Illumina reads)
    ├── [Optional] Evaluation (QUAST + BUSCO)
    │
    ├── Scaffolding (RagTag vs reference)
    ├── Evaluation (QUAST + BUSCO)
    │
    ├── Divergence estimation (MASH)
    ├── Synteny (ntSynt + ntSynt-viz)
    │
    ├── Read mapping control (minimap2)
    │   ├── ALL BAM (for IGV visualization)
    │   ├── Filtered BAM (primary only, for statistics)
    │   └── Chromosome extraction (for IGV)
    │
    └── [Optional] BLAST (unplaced contigs + unmapped reads vs nt)
```

---

## Repository structure

Each stage of the pipeline lives in its own folder, in execution order

```
assembly_pipeline_ONA/
├── config/                config.template.sh (copy to config.sh), config.advanced.sh
├── 00_setup/               conda/tool checks, input validation, checkpoints
├── 01_preprocessing/       NanoPlot / seqtk / Porechop / Kraken2
├── 02_assembly/            Flye
├── 03_evaluation/          QUAST + BUSCO
├── 04_purge_dups/          haplotig purging
├── 05_pilon/               [optional] Illumina polishing
├── 06_ragtag/              scaffolding vs reference
├── 07_synteny/             MASH + ntSynt
├── 08_mapping/             minimap2 read mapping control
├── 09_blast/               [optional] BLAST vs nt
├── tests/                  pre-flight checks (see "Run the pre-flight tests")
└── run_pipeline.sh         sources every stage in order
```

---

## Requirements

### Conda environments

| Environment | Tools |
|---|---|
| `ragtagsteps` | minimap2, samtools, ragtag, ntSynt, mash, bwa, seqkit, seqtk, porechop |
| `busco_5.8.3` | BUSCO 5.8.3 |
| `quast_env` | QUAST |
| `pilon_env` | Pilon (optional) |

The pipeline checks every environment and tool before running anything. If a single tool is missing inside an environment that does exist, it only warns and gives you the install command, it does not install it automatically.

### External tools
- **ntSynt-viz**: clone from https://github.com/BirolLab/ntSynt-viz
- **Java** (for Pilon): OpenJDK 17+ recommended (not conda Java)
- **BLAST nt database** (optional)

---

## Before your first run

### 1. Build the Kraken2 database depending on your decontamination process
```bash
mkdir -p ~/kraken2_viral_db
conda activate ragtagsteps
k2 download-taxonomy --db ~/kraken2_viral_db
k2 download-library --library viral --db ~/kraken2_viral_db --resume
k2 build --db ~/kraken2_viral_db --threads 8
```

### 2. Pre-download the BUSCO lineage depending on your project
```bash
conda activate busco_5.8.3
busco --download insecta_odb10
```

### 3. Run the pre-flight tests
```bash
bash tests/run_all_tests.sh config/config_test.sh
```

## Quick Start

### 1. Clone or copy the pipeline

```bash
cp -r assembly_pipeline_ONA/ /path/to/your/project/
cd /path/to/your/project/assembly_pipeline_ONA/
```

### 2. Edit the configuration file

```bash
cp config/config.template.sh config/config_test.sh
nano config/config_test.sh
```

**Minimum required settings:**
```bash
SAMPLES=("SAMPLE1" "SAMPLE2")          # Your sample names
READS_DIR="/path/to/reads"              # Directory with ONT reads
READS_PATTERN="{SAMPLE}_reads.fq.gz"   # Reads filename pattern
REF_GENOME="/path/to/reference.fna"    # Reference genome
OUTPUT_DIR="/path/to/output"            # Where results go
CONDA_BASE="/path/to/miniconda3"        # Your conda installation
KRAKEN2_DB="/path/to/kraken2_db"        # Kraken2 database
GENOME_SIZE="1.3g"                      # Estimated genome size
```

### 3. Run the pipeline

```bash
# Full pipeline
nohup bash run_pipeline.sh > logs/run.log 2>&1 &
echo "PID: $!"

# Custom config file
bash run_pipeline.sh /path/to/my_config.sh
```

---

## Output Structure

```
OUTPUT_DIR/
├── QC/
│   └── {SAMPLE}/
│       ├── 00_raw/          # NanoPlot before filtering
│       ├── 01_seqtk/        # NanoPlot after length filtering
│       ├── 02_porechop/     # NanoPlot after adapter trimming
│       └── 03_kraken2/      # NanoPlot after decontamination
├── 02-FILTER/
│   └── {SAMPLE}/
│       ├── {SAMPLE}_seqtk_filtered.fastq.gz
│       ├── {SAMPLE}_porechop.fastq.gz
│       └── kraken2/
│           ├── {SAMPLE}_unclassified.fq.gz   <-- clean reads
│           └── {SAMPLE}_classified.fq.gz     <-- removed reads
├── 05-ASSEMBLY/
│   └── {SAMPLE}/
│       └── {SAMPLE}_assembly.fasta
├── 06-QUAST/
│   ├── after_assembly/
│   ├── after_purge/
│   ├── after_pilon/          (if RUN_PILON=true)
│   └── after_ragtag/
├── 08-PURGE_DUPS/
│   └── {SAMPLE}_auto/
│       ├── purged.fa
│       └── {SAMPLE}_purged_filtered.fa    <-- for ntSynt
├── 09-BUSCO/
│   ├── {SAMPLE}_after_assembly/
│   ├── {SAMPLE}_after_purge/
│   └── {SAMPLE}_after_ragtag/
├── 10-MASH/
│   └── mash_distances.txt
├── 11-RAGTAG/
│   └── {SAMPLE}{SAMPLE_SUFFIX}/
│       ├── {SAMPLE}_ragtag.scaffold.fasta
│       ├── {SAMPLE}_ragtag.scaffold.filtered.fasta
│       └── {SAMPLE}_ragtag_more100kb.fasta
├── 12-NTSYNT/
│   ├── avant_ragtag/
│   │   ├── ONA_*_avant_ragtag.synteny_blocks.tsv
│   │   └── ONA_*_avant_ragtag_ribbon-plot.pdf
│   └── apres_ragtag/
│       ├── ONA_*_apres_ragtag.synteny_blocks.tsv
│       └── ONA_*_apres_ragtag_ribbon-plot.pdf
├── 14-MAPPING/
│   └── {SAMPLE}{SAMPLE_SUFFIX}/
│       ├── {SAMPLE}_all_sort.bam          <-- for IGV (all alignments)
│       ├── {SAMPLE}_primary_sort.bam      <-- for statistics
│       ├── {SAMPLE}_flagstat.txt          <-- mapping statistics
│       ├── {SAMPLE}_unmapped.fasta        <-- unmapped reads
│       └── {SAMPLE}_{CHROM}_all.bam       <-- per-chromosome BAM for IGV
└── 16-BLAST/                              (if RUN_BLAST=true)
    ├── contigs_non_places/
    └── reads_non_mappes/
```

---

## References

If you use this pipeline, please cite:

- **NanoPlot**: De Coster et al. 2018, Bioinformatics (NanoPack)
- **seqtk**: Li H. https://github.com/lh3/seqtk 
- **Porechop**: Wick R. 2017. https://github.com/rrwick/Porechop 
- **Kraken2**: Wood et al. 2019, Genome Biology
- **Flye**: Kolmogorov et al. 2019, Nature Biotechnology
- **QUAST**: Gurevich et al. 2013, Bioinformatics
- **BUSCO**: Manni et al. 2021, Molecular Biology and Evolution
- **purge_dups**: Guan et al. 2020, Bioinformatics
- **minimap2**: Li H. 2018, Bioinformatics
- **samtools**: Danecek et al. 2021, GigaScience
- **Pilon**: Walker et al. 2014, PLOS ONE 
- **BWA**: Li H, Durbin R. 2009, Bioinformatics 
- **RagTag**: Alonge et al. 2022, Genome Biology
- **MASH**: Ondov et al. 2016, Genome Biology
- **ntSynt**: Coombe et al. 2025, BMC Biology
- **ntSynt-viz**: Coombe, Warren & Birol 2025, bioRxiv
- **BLAST+**: Camacho et al. 2009, BMC Bioinformatics 
