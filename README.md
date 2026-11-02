# squid-climate-change

The live quarto notebook detailing the analysis can be found [here](https://emlab-ucsb.github.io/squid-climate-change).

This analysis is for the analysis: "Toward sustainable and resilient fisheries management for the Humboldt squid deep-water fishery", a project for Environmental Defense Fund

# Reproducibility  

## Package management  

To manage package dependencies, we use the `renv` package. When you first clone this repo onto your machine, run `renv::restore()` to ensure you have all correct package versions installed in the project. Please see the [renv website](https://rstudio.github.io/renv/articles/renv.html) for more information. Also, ensure that you have R Studio set up to use the Posit Public Package Manager (see [here](https://packagemanager.posit.co/client/#/repos/cran/setup) for instructions, and [here](https://www.pipinghotdata.com/posts/2024-09-16-ease-renvrestore-by-updating-your-repositories-to-p3m/) for why this is important).

## Data processing and analysis pipeline

To ensure reproducibility in the data processing and analysis pipeline, we use the `targets` package. Targets is a Make-like pipeline tool. Using targets means that anytime an upstream change is made to the data or models, all downstream components of the data processing and analysis will be re-run automatically when the `targets::tar_make()` command is run. It also means that once components of the analysis have already been run and are up-to-date, they will not need to be re-run. All objects are cached in the `_targets` directory. Please see the [targets website](https://github.com/ropensci/targets) for more information. The `_targets` cache directory, and all other data, are stored on emLab's internal GRIT/Nextcloud data storage space.


In order to see what the targets pipeline looks like, you can run `targets::tar_manifest()` or `targets::tar_visnetwork()`, which also shows which targets are current or out-of-date.

# Repository Structure 

The repository uses the following basic structure:  
```
squid-climate-change
  |__ docs
  |__ qmd
  |__ r
  |__ renv
  |__ sql
```

# Data sources

AIS-based squid jigger fishing effort and vessel info come from the [V5 version](https://docs.google.com/document/d/1wFtKu_6ixCGCfmTk3j6UPbKBgFrQdJ_BtrGiooC0yDQ/edit?tab=t.0) of the Global Fishing Watch AIS data processing pipeline. AIS, SST, and Oceanic Niño Index (ONI) data all run from 2016 through 2025 (`analysis_date_start` and `analysis_date_end` in `_targets.R`). See `qmd/data.qmd` for details.

The AIS tables the pipeline writes to BigQuery (`emlab-gcp.squid_climate_change`) carry a version suffix (`ais_table_version` in `_targets.R`), so a rebuild writes new tables next to the old ones instead of overwriting them:

| Version | GFW pipeline | Years | Notes |
|---|---|---|---|
| no suffix | V3 | 2016 through August 2024 | Superseded. Squid jiggers from `best.best_vessel_class`, with noisy vessels dropped at any name overlap |
| `v20261102` | V5 | 2016–2025 | Current version. Squid jiggers from the pipeline 5 random forest, with GFW's noisy vessel definition |

# Use of generative AI

Claude (Anthropic), model Opus 5.5, was used as a coding assistant through Claude Code in November 2026 to move the AIS data pull from GFW's V3 to V5 pipeline, extend the AIS, SST, and ONI data through 2025, and version the AIS tables in BigQuery. It drafted the SQL, `_targets.R`, and `r/functions.R` changes and the matching text in `qmd/data.qmd` and `qmd/eda.qmd`. Gavin McDonald reviewed the changes. Commits made with AI assistance carry a `Co-Authored-By: Claude` trailer.
