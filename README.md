# squid-climate-change

The live quarto notebook detailing the analysis can be found [here](https://emlab-ucsb.github.io/squid-climate-change).

This analysis is for the analysis: "Toward sustainable and resilient fisheries management for the Humboldt squid deep-water fishery", a project for Environmental Defense Fund

# Reproducibility  

## Package management  

To manage package dependencies, we use the `renv` package. When you first clone this repo onto your machine, run `renv::restore()` to ensure you have all correct package versions installed in the project. Please see the [renv website](https://rstudio.github.io/renv/articles/renv.html) for more information. Also, ensure that you have R Studio set up to use the Posit Public Package Manager (see [here](https://packagemanager.posit.co/client/#/repos/cran/setup) for instructions, and [here](https://www.pipinghotdata.com/posts/2024-09-16-ease-renvrestore-by-updating-your-repositories-to-p3m/) for why this is important).

The lockfile was last updated in November 2026, for R 4.5.1 on emLab's sequoia server, with packages from the Posit Public Package Manager (`https://packagemanager.posit.co/cran/latest`). The previous lockfile was for R 4.4.2, and some of its package versions (e.g., `bit` 4.0.5) no longer compile on R 4.5. Use R 4.5.1 or later.

Rendering the Quarto book (the `quarto_book` target) also needs the [Quarto CLI](https://quarto.org/docs/get-started/) and a LaTeX installation with `xelatex` for the PDF. The easiest way to get LaTeX is `quarto install tinytex`. The book was last rendered with Quarto 1.11.9 and TinyTeX 2026.11.

## Data processing and analysis pipeline

To ensure reproducibility in the data processing and analysis pipeline, we use the `targets` package. Targets is a Make-like pipeline tool: when an upstream input or step changes, the next build re-runs everything downstream of it, and skips anything already up to date. Please see the [targets website](https://github.com/ropensci/targets) for more information.

The pipeline is split into three `targets` projects, each with its own script in `pipelines/` and its own store. They run in order, and each later project reads the files the earlier ones write:

| Project | Script | What it does | Needs |
|---|---|---|---|
| `gfw` | `pipelines/gfw.R` | Builds the AIS fishing effort tables in BigQuery from Global Fishing Watch data, and exports them and the VIIRS detections to parquet files | Access to GFW's BigQuery tables, billed to `emlab-gcp` |
| `sst` | `pipelines/sst.R` | Downloads daily NOAA OISST v2.1 SST from NCEI and aggregates it to monthly pixels, saves a dated snapshot of NOAA's Oceanic Niño Index (ONI), and reads CMIP6 SST projections from the IPCC AR6 Interactive Atlas Dataset | Internet |
| `analysis` | `pipelines/analysis.R` | Joins effort, VIIRS, SST, ONI, and EEZ data, and renders the Quarto book to `docs/` (published on GitHub Pages) | Only the files the other two projects write, and emLab's EEZ and SPRFMO shapefiles |

Run them from the repo root with `run.R`:

```
Rscript run.R                  # all three, in order
Rscript run.R sst              # one project
Rscript run.R outdated         # list what would rebuild, without building anything
```

`run.R` rewrites `_targets.yaml` (gitignored, since stores differ between machines) before every build, so it always points at the right scripts and stores. To work with a project interactively, run `source("r/config.R"); write_targets_config(); Sys.setenv(TAR_PROJECT = "analysis")`, then use targets as usual, e.g. `targets::tar_read(joined_dataset_ais)`.

Analysis parameters (dates, spatial and temporal resolution, analysis scope, BigQuery table version, ONI snapshot date) and all paths are set in one place, `r/config.R`. The stores (`data/_targets_gfw`, `data/_targets_sst`, `data/_targets_analysis`) and the files the projects hand off to each other (`data/pipeline-outputs/`) are in the project directory on emLab's internal GRIT/Nextcloud data storage space. Raw daily SST files are in emLab's shared data directory (`data/sst-noaa-oisst-v2-1-ncei/`). The `data/_targets` store holds the single pipeline used through October 2026; it is kept as an archive and no longer updated.

### Safeguards

- **BigQuery tables are never overwritten.** Each AIS table carries a version suffix, and its description records a SHA-256 fingerprint of the SQL that built it. If a table already exists and was built from the same SQL, the pipeline uses it without re-running the query. If it exists but was built from different SQL, the pipeline stops; bump `ais_table_version` in `r/config.R` to rebuild.
- **BigQuery costs are capped.** Each query is dry-run first, and runs with BigQuery's maximum-bytes-billed limit (`gfw_max_bytes_billed`, 15 TiB), so a query that would cost more fails without being billed.
- **The VIIRS tables are frozen.** They were built in October 2024, unversioned, by `sql/get_viirs_without_noise.sql`, `sql/viirs_smallest_zenith.sql`, and `sql/gridded_viirs_detections.sql`. The pipeline reads the gridded table but never re-runs those queries, and stops if the table has changed since.
- **SST files are checked.** Each daily file downloads to a temporary file and is saved only after it opens as netCDF and holds the expected date of the final (not preliminary) product. Missing days stop the pipeline rather than being skipped. Each month is a separate branch, tracked by file contents.
- **CMIP6 projections are checked.** The pipeline checks the number of models for each scenario, that every scenario and period has all 12 months, and that no two scenario/period/month fields are identical. The CMIP6 files previously downloaded by hand from the Interactive Atlas website (`data/raw/ipcc_wgi_climate_forecasts/`) failed that check: 63 of 144 were copies of a different scenario or period, and the Near Term files had no February. They are no longer used.
- **The ONI is a dated snapshot.** NOAA revises past ONI values, so the pipeline saves the ONI file once, named for `oni_snapshot_date`, and never re-downloads it.
- **Joined datasets are checked** for duplicate rows, missing SST or ONI values, and missing months before the book uses them.
- **Files are written atomically**, so an interrupted run never leaves a partial file behind.

Because the `analysis` project only reads files, the analysis can be reproduced without GFW credentials or internet, from the files in `data/pipeline-outputs/`.

# Repository Structure 

The repository uses the following basic structure:  
```
squid-climate-change
  |__ docs        Rendered Quarto book (GitHub Pages)
  |__ pipelines   targets scripts: gfw.R, sst.R, analysis.R
  |__ qmd         Quarto book source
  |__ r           Functions (functions.R, gfw.R, sst.R) and settings (config.R)
  |__ renv
  |__ sql         BigQuery SQL
  |__ run.R       Runs the targets projects
```

# Data sources

AIS-based squid jigger fishing effort and vessel info come from the [V5 version](https://docs.google.com/document/d/1wFtKu_6ixCGCfmTk3j6UPbKBgFrQdJ_BtrGiooC0yDQ/edit?tab=t.0) of the Global Fishing Watch AIS data processing pipeline. Sea surface temperature comes from NOAA's daily OISST v2.1, downloaded from [NCEI's archive](https://www.ncei.noaa.gov/data/sea-surface-temperature-optimum-interpolation/v2.1/access/avhrr/) (until November 2026, the pipeline downloaded it from NOAA's CoastWatch ERDDAP server, which is missing some days; the values for the days it has are identical). AIS, SST, and Oceanic Niño Index (ONI) data all run from 2016 through 2025 (`analysis_date_start` and `analysis_date_end` in `r/config.R`). See `qmd/data.qmd` for details.

The AIS tables the pipeline writes to BigQuery (`emlab-gcp.squid_climate_change`) carry a version suffix (`ais_table_version` in `r/config.R`), so a rebuild writes new tables next to the old ones instead of overwriting them:

| Version | GFW pipeline | Years | Notes |
|---|---|---|---|
| no suffix | V3 | 2016 through August 2024 | Superseded. Squid jiggers from `best.best_vessel_class`, with noisy vessels dropped at any name overlap |
| `v20261102` | V5 | 2016–2025 | Current version. Squid jiggers from the pipeline 5 random forest, with GFW's noisy vessel definition |

# Use of generative AI

Claude (Anthropic), model Opus 5.5, was used as a coding assistant through Claude Code in November 2026 to move the AIS data pull from GFW's V3 to V5 pipeline, extend the AIS, SST, and ONI data through 2025, and version the AIS tables in BigQuery. It drafted the SQL, `_targets.R`, and `r/functions.R` changes and the matching text in `qmd/data.qmd` and `qmd/eda.qmd`. It also updated the R packages and `renv.lock` for R 4.5.1; split the pipeline into the `gfw`, `sst`, and `analysis` projects, with the safeguards above; switched the SST download from ERDDAP to NCEI; ran and verified the rebuild; and revised the Quarto book text (an ONI data section, the SST and joined dataset descriptions, and figure captions and axes). Gavin McDonald reviewed the changes. Commits made with AI assistance carry a `Co-Authored-By: Claude` trailer.
