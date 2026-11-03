## ---------------------------
## Script name: r/config.R
## Purpose:
## Settings shared by the three targets projects (pipelines/gfw.R,
## pipelines/sst.R, and pipelines/analysis.R): analysis parameters, data paths,
## and the files the projects hand off to each other. Everything here is plain
## R, so targets tracks these values, and a change reruns the targets that use
## them.
## ---------------------------

# Analysis parameters ----
# First and last dates of the analysis, for the AIS, SST, and ONI data
analysis_date_start <- "2016-01-01"
analysis_date_end <- "2025-12-31"
# Spatial pixel size, in degrees lat/lon
spatial_resolution <- 0.25
# Temporal resolution: DAY, MONTH, or YEAR
temporal_resolution <- "MONTH"
# Analysis scope bounding box. Pixels are identified by their lower-left corner
# (lon_bin, lat_bin), and a pixel is in scope when its corner is inside these
# ranges, inclusive
analysis_scope_lon <- c(-130, -70)
analysis_scope_lat <- c(-40, 10)

# GFW BigQuery settings ----
bq_project <- "emlab-gcp"
bq_dataset <- "squid_climate_change"
billing_project <- "emlab-gcp"
# Version suffix for the AIS tables written to BigQuery. Versioned tables are
# never overwritten (see create_bq_table() in r/gfw.R); bump this to rebuild
# them. v20261102: GFW pipeline 5 (V5), 2016-2025
ais_table_version <- "v20261102"
# GFW pipeline 5 (V5) vessel identity table, one row per vessel (ssvid)
gfw_vessel_info_table <- "global-fishing-watch.pipe_ais_identity_v5_partners_published.vi_ssvid"
# GFW pipeline 5 (V5) AIS positions, one row per message
gfw_messages_table <- "global-fishing-watch.pipe_ais_v5_published.messages"
# Most bytes any one query may bill. BigQuery fails a query that would bill
# more, at no cost. 15 TiB; the effort query scans ~13.5 TiB
gfw_max_bytes_billed <- 15 * 1024^4

# ONI snapshot ----
# NOAA revises past ONI values (e.g., when ERSST is updated), so the pipeline
# saves a dated copy of the ONI file and never re-downloads it. To take a new
# snapshot, set this to the current date
oni_snapshot_date <- "2026-11-02"

# CMIP6 SST projections ----
# Monthly CMIP6 SST from the IPCC AR6 Interactive Atlas Dataset (Instituto de
# Fisica de Cantabria, 2022, Version 2 final, CC-BY 4.0,
# https://digital.csic.es/handle/10261/280324), read by OPeNDAP from its
# THREDDS mirror. The Atlas interpolates each model to a common 1 degree grid.
# The pipeline computes the multi-model mean of 20-year monthly climatologies
# the way the Atlas code does (IPCC-WG1/Atlas, datasets-interactive-atlas/
# 04_map_figures.R; Iturbide et al. 2021, doi:10.5281/zenodo.3691645): each
# model's mean over the years it has, then the mean across the models with SST
# in each cell. This reproduces the Interactive Atlas values to within 0.02 C
cmip6_atlas_opendap <- "https://data.meteo.unican.es/thredds/dodsC/IPCC/AR6/IA-monthly/raw/CMIP6"
# Scenario labels, their Atlas experiment names, and the number of models the
# Atlas uses for each. The pipeline stops if the source has a different number
cmip6_experiments <- data.frame(
  scenario = c("SSP1-2.6", "SSP2-4.5", "SSP3-7.0", "SSP5-8.5", "historical"),
  experiment = c("ssp126", "ssp245", "ssp370", "ssp585", "historical"),
  file_dates = c(rep("201501-210012", 4), "185001-201412"),
  n_models = c(26L, 28L, 24L, 27L, 28L)
)
# Future periods, as in the Atlas
cmip6_periods <- data.frame(
  time_period = c(
    "Near Term (2021-2040)",
    "Medium Term (2041-2060)",
    "Long Term (2081-2100)"
  ),
  year_start = c(2021L, 2041L, 2081L),
  year_end = c(2040L, 2060L, 2100L)
)
# Baseline period from the historical runs, for computing projected changes:
# the AR6 "recent past" reference period
cmip6_baseline_years <- c(1995L, 2014L)

# Paths ----
# emLab servers, and any GRIT HPC node (e.g., a Slurm job), mount emLab's data
# at /home/emlab
data_directory_base <- if (
  Sys.info()[["nodename"]] %in%
    c("quebracho", "sequoia") ||
    dir.exists("/home/emlab/data")
) {
  "/home/emlab"
} else if (Sys.info()[["sysname"]] == "Darwin") {
  "/Users/Shared/nextcloud/emLab"
} else if (Sys.info()[["sysname"]] == "Windows") {
  "G:/Shared drives/nextcloud/emLab"
} else {
  # Other Linux machines: replace your_username with your user name
  "/home/your_username/Nextcloud"
}
project_directory <- file.path(
  data_directory_base,
  "projects",
  "archived-projects",
  "squid-climate-change"
)
# Raw daily NOAA OISST v2.1 netCDF files from NCEI, shared with other projects
sst_raw_directory <- file.path(
  data_directory_base,
  "data",
  "sst-noaa-oisst-v2-1-ncei"
)
# Files each project writes for the analysis project to read. The analysis
# project only reads these, so it runs without GFW credentials or internet
handoff_directory <- file.path(project_directory, "data", "pipeline-outputs")
handoff_files <- list(
  # From pipelines/gfw.R
  squid_vessel_list = file.path(
    handoff_directory,
    "gfw",
    paste0("squid_vessel_list_", ais_table_version, ".parquet")
  ),
  gridded_time_effort_by_flag = file.path(
    handoff_directory,
    "gfw",
    paste0("gridded_time_effort_by_flag_", ais_table_version, ".parquet")
  ),
  gridded_viirs_detections = file.path(
    handoff_directory,
    "gfw",
    "gridded_viirs_detections_v20241007.parquet"
  ),
  # From pipelines/sst.R
  sst_monthly = file.path(
    handoff_directory,
    "sst",
    "sst_noaa_oisst_v2_1_monthly.parquet"
  ),
  oni_raw = file.path(
    handoff_directory,
    "sst",
    paste0("oni_noaa_psl_", oni_snapshot_date, ".data")
  ),
  oni_monthly = file.path(handoff_directory, "sst", "oni_monthly.parquet"),
  # CMIP6 multi-model mean monthly SST for each future scenario and period,
  # and for the 1995-2014 baseline with each scenario's models
  sst_cc_forecast = file.path(
    handoff_directory,
    "sst",
    "cmip6_sst_forecast_monthly.parquet"
  ),
  sst_cc_baseline = file.path(
    handoff_directory,
    "sst",
    "cmip6_sst_baseline_monthly.parquet"
  ),
  # Which models each CMIP6 mean uses, and how many years of each
  cmip6_models = file.path(handoff_directory, "sst", "cmip6_models_used.csv")
)

# targets projects ----
targets_projects <- c("gfw", "sst", "analysis")

#' Write _targets.yaml for the three targets projects
#'
#' @description Points each project at its script in pipelines/ and its store
#'   in the project data directory. run.R calls this before every build, so
#'   _targets.yaml (gitignored, since stores differ between machines) is never
#'   stale.
#' @return Nothing; writes _targets.yaml in the working directory.
write_targets_config <- function() {
  # Start fresh, so no project from an older layout lingers
  unlink("_targets.yaml")
  for (project in targets_projects) {
    targets::tar_config_set(
      script = file.path("pipelines", paste0(project, ".R")),
      store = file.path(
        project_directory,
        "data",
        paste0("_targets_", project)
      ),
      project = project
    )
  }
  invisible()
}
