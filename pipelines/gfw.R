# GFW targets project ----
# Builds the AIS fishing effort tables in BigQuery from Global Fishing Watch
# data, and exports the AIS and VIIRS tables the analysis uses to parquet
# files (handoff_files in r/config.R). Needs BigQuery access to GFW's tables,
# billed to emlab-gcp. Run with: Rscript run.R gfw
library(targets)

tar_source(c("r/config.R", "r/functions.R", "r/gfw.R"))
tar_option_set(packages = character(0))

list(
  # AIS data ----
  # Squid jiggers from the GFW V5 vessel identity table
  tar_target(
    name = squid_vessel_list_sql_file,
    "sql/squid_vessel_list.sql",
    format = "file"
  ),
  tar_target(
    name = squid_vessel_list_bq,
    create_bq_table(
      sql = readr::read_file(squid_vessel_list_sql_file) |>
        stringr::str_glue(gfw_vessel_info_table = gfw_vessel_info_table),
      table_name = paste0("squid_vessel_list_", ais_table_version),
      bq_dataset = bq_dataset,
      bq_project = bq_project,
      billing_project = billing_project,
      max_bytes_billed = gfw_max_bytes_billed
    )
  ),
  # Daily spatially gridded effort, by vessel, for the squid vessel list. The
  # expensive query: ~13.5 TiB
  tar_target(
    name = gridded_daily_effort_by_vessel_sql_file,
    "sql/gridded_daily_effort_by_vessel.sql",
    format = "file"
  ),
  tar_target(
    name = gridded_daily_effort_by_vessel_bq,
    create_bq_table(
      sql = readr::read_file(gridded_daily_effort_by_vessel_sql_file) |>
        stringr::str_glue(
          ais_date_start = paste0("'", analysis_date_start, "'"),
          ais_date_end = paste0("'", analysis_date_end, "'"),
          spatial_resolution = spatial_resolution,
          gfw_messages_table = gfw_messages_table,
          squid_vessel_list_table = squid_vessel_list_bq$table
        ),
      table_name = paste0("gridded_daily_effort_by_vessel_", ais_table_version),
      bq_dataset = bq_dataset,
      bq_project = bq_project,
      billing_project = billing_project,
      max_bytes_billed = gfw_max_bytes_billed
    )
  ),
  # Spatially gridded effort at temporal_resolution, by flag
  tar_target(
    name = gridded_time_effort_by_flag_sql_file,
    "sql/gridded_time_effort_by_flag.sql",
    format = "file"
  ),
  tar_target(
    name = gridded_time_effort_by_flag_bq,
    create_bq_table(
      sql = readr::read_file(gridded_time_effort_by_flag_sql_file) |>
        stringr::str_glue(
          temporal_resolution = temporal_resolution,
          gridded_daily_effort_by_vessel_table = gridded_daily_effort_by_vessel_bq$table
        ),
      table_name = paste0("gridded_time_effort_by_flag_", ais_table_version),
      bq_dataset = bq_dataset,
      bq_project = bq_project,
      billing_project = billing_project,
      max_bytes_billed = gfw_max_bytes_billed
    )
  ),
  # VIIRS data ----
  # Frozen: built in October 2024 by sql/get_viirs_without_noise.sql, then
  # sql/viirs_smallest_zenith.sql, then sql/gridded_viirs_detections.sql, as
  # unversioned tables. The pipeline reads the gridded table but never re-runs
  # those queries, and stops if the table has changed. They recreate
  # https://github.com/GlobalFishingWatch/paper-global-squid/blob/main/queries/VIIRS/get_viirs_without_noise.sql
  # and
  # https://github.com/GlobalFishingWatch/paper-global-squid/blob/main/queries/VIIRS/02_create_viirs_matching_squid_area_no_overlap_local_night_2017_2021.sql,
  # from Seto et al. (https://www.science.org/doi/10.1126/sciadv.add8125). To
  # rebuild VIIRS, add versioned create_bq_table() targets like the AIS ones
  tar_target(
    name = gridded_viirs_detections_bq,
    frozen_bq_table(
      table_name = "gridded_viirs_detections",
      bq_dataset = bq_dataset,
      bq_project = bq_project,
      # 2024-10-07 21:06:15 UTC
      expected_last_modified_time = "1728335175144"
    ),
    # Check the table hasn't changed on every run (a free metadata read)
    cue = tar_cue(mode = "always")
  ),
  # Export to parquet for the analysis project ----
  tar_target(
    name = squid_vessel_list_file,
    export_bq_table(
      squid_vessel_list_bq,
      key_columns = "ssvid",
      path = handoff_files$squid_vessel_list
    ),
    format = "file"
  ),
  tar_target(
    name = gridded_time_effort_by_flag_file,
    export_bq_table(
      gridded_time_effort_by_flag_bq,
      key_columns = c("month", "flag", "lon_bin", "lat_bin"),
      path = handoff_files$gridded_time_effort_by_flag
    ),
    format = "file"
  ),
  tar_target(
    name = gridded_viirs_detections_file,
    export_bq_table(
      gridded_viirs_detections_bq,
      key_columns = c("month", "lon_bin", "lat_bin"),
      path = handoff_files$gridded_viirs_detections
    ),
    format = "file"
  )
)
