# Targets setup ----
# Load packages required to define the pipeline:
library(targets)
library(tarchetypes) # Load other packages as needed.

data_directory_base <-  ifelse(Sys.info()["nodename"] == "quebracho" | Sys.info()["nodename"] == "sequoia",
                               "/home/emlab",
                               # Otherwise, set the directory for local machines based on the OS
                               # If using Mac OS, the directory will be automatically set as follows
                               ifelse(Sys.info()["sysname"]=="Darwin",
                                      "/Users/Shared/nextcloud/emLab",
                                      # If using Windows, the directory will be automatically set as follows
                                      ifelse(Sys.info()["sysname"]=="Windows",
                                             "G:/Shared\ drives/nextcloud/emLab",
                                             # If using Linux, will need to manually modify the following directory path based on their user name
                                             # Replace your_username with your local machine user name
                                             "/home/your_username/Nextcloud")))
# Automatically set cores, based on emLab best practices
n_cores <-  ifelse(Sys.info()["nodename"] == "quebracho" | Sys.info()["nodename"] == "sequoia",
                   20,
                   parallelly::availableCores()-1)

project_directory <- glue::glue("{data_directory_base}/projects/current-projects/squid-climate-change")

# Set targets store to appropriate GRIT/Nextcloud directory
tar_config_set(store = glue::glue("{project_directory}/data/_targets"))

# Run the R scripts in the R/ folder with your custom functions:
tar_source("r/functions.R")

# Set BigQuery project, billing project, and dataset
bq_dataset <- "squid_climate_change"
bq_project <- "emlab-gcp"
billing_project <- "emlab-gcp"
# Do this to help with BigQuery downloading
options(scipen = 20)


list(
  # Specify analysis parameters ----
  # Set the date to start pulling AIS data
  tar_target(
    name = ais_date_start,
    "'2016-01-01'"
  ),
  # Set the date to end pulling AIS data
  tar_target(
    name = ais_date_end,
    "'2024-08-31'"
  ),
  # Set spatial pixel size resolution in degrees lat/lon
  tar_target(
    name = spatial_resolution,
    0.25
  ),
  # Set temporal resolution - can be DAY, MONTH, or YEAR
  tar_target(
    name = temporal_resolution,
    'MONTH'
  ),
  # Pull GFW data from BigQuery ----
  ## AIS data ----
  # Get list of squid vessels
  tar_file_read(
    name = squid_vessel_list_bq,
    "sql/squid_vessel_list.sql",
    run_gfw_query_and_save_table(sql = readr::read_file(!!.x),
                                 bq_table_name = "squid_vessel_list",
                                 bq_dataset = bq_dataset,
                                 billing_project = billing_project,
                                 bq_project = bq_project,
                                 write_disposition = 'WRITE_TRUNCATE')
  ),
  # Pull squid vessel list locally
  tar_target(
    name = squid_vessel_list,
    pull_gfw_data_locally_arbitrary(sql = "SELECT * FROM `emlab-gcp.squid_climate_change.squid_vessel_list`",
                                    billing_project = billing_project,
                                    # Re-run this target if squid_vessel_list_bq changes
                                    squid_vessel_list_bq)
  ),
  # Get daily spatially gridded effort data, by vessel, for all vessels on squid vessel list
  tar_file_read(
    name = gridded_daily_effort_by_vessel_bq,
    "sql/gridded_daily_effort_by_vessel.sql",
    run_gfw_query_and_save_table(sql = readr::read_file(!!.x) |>
                                   stringr::str_glue(ais_date_start = ais_date_start,
                                                     ais_date_end = ais_date_end,
                                                     spatial_resolution = spatial_resolution),
                                 bq_table_name = "gridded_daily_effort_by_vessel",
                                 bq_dataset = bq_dataset,
                                 billing_project = billing_project,
                                 bq_project = bq_project,
                                 write_disposition = 'WRITE_TRUNCATE',
                                 # Re-run this target if squid_vessel_list_bq changes
                                 squid_vessel_list_bq)
  ),
  # Get spatially gridded effort data, at appropriate temporal resolution, by flag
  tar_file_read(
    name = gridded_time_effort_by_flag_bq,
    "sql/gridded_time_effort_by_flag.sql",
    run_gfw_query_and_save_table(sql = readr::read_file(!!.x) |>
                                   stringr::str_glue(temporal_resolution = temporal_resolution),
                                 bq_table_name = "gridded_time_effort_by_flag",
                                 bq_dataset = bq_dataset,
                                 billing_project = billing_project,
                                 bq_project = bq_project,
                                 write_disposition = 'WRITE_TRUNCATE',
                                 # Re-run this target if gridded_daily_effort_by_vessel_bq changes
                                 gridded_daily_effort_by_vessel_bq)
  ),
  # Pull gridded_time_effort_by_flag data locally
  tar_target(
    name = gridded_time_effort_by_flag,
    pull_gfw_data_locally_arbitrary(sql = "SELECT * FROM `emlab-gcp.squid_climate_change.gridded_time_effort_by_flag`",
                                    billing_project = billing_project,
                                    # Re-run this target if gridded_time_effort_by_flag_bq changes
                                    gridded_time_effort_by_flag_bq)
  ),
  ## VIIRS data ----
  # Recreate this query: https://github.com/GlobalFishingWatch/paper-global-squid/blob/main/queries/VIIRS/get_viirs_without_noise.sql
  # Which comes from this paper: https://www.science.org/doi/10.1126/sciadv.add8125
  tar_file_read(
    name = filtered_viirs_bq,
    "sql/get_viirs_without_noise.sql",
    run_gfw_query_and_save_table(sql = readr::read_file(!!.x),
                                 bq_table_name = "filtered_viirs",
                                 bq_dataset = bq_dataset,
                                 billing_project = billing_project,
                                 bq_project = bq_project,
                                 write_disposition = 'WRITE_TRUNCATE')
  ),
  # From Seto et al: "To eliminate double counting, in areas with multiple satellite overpasses on a given night, 
  # we included only observations from the overpass with the smaller satellite zenith angle."
  # Adapted from this query: https://github.com/GlobalFishingWatch/paper-global-squid/blob/main/queries/VIIRS/02_create_viirs_matching_squid_area_no_overlap_local_night_2017_2021.sql
  tar_file_read(
    name = viirs_smallest_zenith_bq,
    "sql/viirs_smallest_zenith.sql",
    run_gfw_query_and_save_table(sql = readr::read_file(!!.x) |>
                                   stringr::str_glue(spatial_resolution = spatial_resolution),
                                 bq_table_name = "viirs_smallest_zenith",
                                 bq_dataset = bq_dataset,
                                 billing_project = billing_project,
                                 bq_project = bq_project,
                                 write_disposition = 'WRITE_TRUNCATE',
                                 # Re-run this target if filtered_viirs_bq changes
                                 filtered_viirs_bq)
  ),
  # Now grid this up to our spatial and temporal resolution
  tar_file_read(
    name = gridded_viirs_detections_bq,
    "sql/gridded_viirs_detections.sql",
    run_gfw_query_and_save_table(sql = readr::read_file(!!.x)|>
                                   stringr::str_glue(temporal_resolution = temporal_resolution),
                                 bq_table_name = "gridded_viirs_detections",
                                 bq_dataset = bq_dataset,
                                 billing_project = billing_project,
                                 bq_project = bq_project,
                                 write_disposition = 'WRITE_TRUNCATE',
                                 # Re-run this target if viirs_smallest_zenith_bq changes
                                 viirs_smallest_zenith_bq)
  ),
  # Pull gridded_viirs_detections data locally
  tar_target(
    name = gridded_viirs_detections,
    pull_gfw_data_locally_arbitrary(sql = "SELECT * FROM `emlab-gcp.squid_climate_change.gridded_viirs_detections`",
                                    billing_project = billing_project,
                                    # Re-run this target if gridded_viirs_detections_bq changes
                                    gridded_viirs_detections_bq) |>
      dplyr::filter(lubridate::year(month) < 2022)
  ),
  # Generate EEZ info table - for each lon_bin/lat_bin pixel, determine: 1) which EEZ it's in (or high seas);
  # 2) For high seas pixels, distance to nearest EEZ; for 3) for high seas pixels, nearest EEZ
  tar_file_read(
    name = eez_info_bq,
    "sql/eez_info.sql",
    run_gfw_query_and_save_table(sql = readr::read_file(!!.x) |>
                                   stringr::str_glue(spatial_resolution = spatial_resolution),
                                 bq_table_name = "eez_info",
                                 bq_dataset = bq_dataset,
                                 billing_project = billing_project,
                                 bq_project = bq_project,
                                 write_disposition = 'WRITE_TRUNCATE')
  ),
  # Pull eez data locally
  tar_file_read(
    name = eez_info,
    "sql/eez_info_with_names.sql",
    pull_gfw_data_locally_arbitrary(sql = readr::read_file(!!.x),
                                    billing_project = billing_project,
                                    # Re-run this target if eez_info_bq changes
                                    eez_info_bq)
  ),
  # Process SST data ----
  # Download SST data from NOAA - Daily, 0.25x0.25 degree resolution from OI V2.1
  # And save to emLab shared data directory
  tar_target(
    name = sst_data_download,
    download_erddap_wrapper(dataset_name = "ncdcOisst21Agg_LonPM180",
                            date_start = "2016-01-01",
                            date_end = "2024-08-31",
                            download_path_base = glue::glue("{data_directory_base}/data/sst-noaa-daily-optimum-interpolation-v2-1/"))
  ),
  tar_target(
    name = sst_data_file_tibble,
    tibble::tibble(file_name = list.files(glue::glue("{data_directory_base}/data/sst-noaa-daily-optimum-interpolation-v2-1"),
                                          full.names = TRUE)) |>
      dplyr::mutate(date = stringr::str_sub(file_name,start = -14, end = -5) |>
                      stringr::str_replace_all("_","-") |>
                      lubridate::ymd(),
                    month = lubridate::floor_date(date, unit = "month"))
  ),
  # Aggregate data temporally/spatially one month at a time, to avoid
  # load all files at once. Then bind them all together once they're aggregated
  tar_target(
    name = sst_data_aggregated,
    unique(sst_data_file_tibble$month) |>
      purrr::map(~{
        print(glue::glue("Starting {.x}"))
        file_list <- sst_data_file_tibble |>
          dplyr::filter(month == .x) |>
          dplyr::pull(file_name)
        spatio_temporal_aggregate(file_list = file_list,
                                  spatial_resolution = spatial_resolution,
                                  temporal_resolution = temporal_resolution)
      }) |>
        data.table::rbindlist()
  ),
  # Now aggregate SST data by time, to make global time series
  tar_target(
    name = sst_data_aggregated_time_series,
    sst_data_aggregated |>
      collapse::collap(FUN = list(sst_deg_c_mean = collapse::fmean),
                       by = ~ month,
                       cols = "sst_deg_c_mean")
  ),
  # Subset to one month of SST data for making an exploratory data analysis map
  tar_target(
    name = sst_data_aggregated_one_month_subset,
    sst_data_aggregated |>
      collapse::fsubset(month == lubridate::ymd("2024-08-01")) |>
      collapse::fselect(-month)
  ),
  # Process ONI data ----
  # Pull Oceanic Nino Index data from NOAA
  tar_target(
    name = oceanic_nino_index_data,
    pull_oni_data()
  ),
  # Join together AIS-based effort, SST, ONI, and EEZ datasets
  tar_target(
    name = joined_dataset_ais,
    gridded_time_effort_by_flag |>
      collapse::fmutate(month = lubridate::ymd(month)) |>
      dplyr::inner_join(sst_data_aggregated,
                        by = c("month","lat_bin","lon_bin")) |>
      dplyr::left_join(oceanic_nino_index_data, 
                       by = "month") |>
      dplyr::inner_join(eez_info,
                       by = c("lon_bin","lat_bin"))
  ),
  # Join datasets ----
  # Join together VIIRS, SST, ONI, and EEZ datasets
  tar_target(
    name = joined_dataset_viirs,
    gridded_viirs_detections |>
      collapse::fmutate(month = lubridate::ymd(month)) |>
      dplyr::inner_join(sst_data_aggregated,
                        by = c("month","lat_bin","lon_bin")) |>
      dplyr::left_join(oceanic_nino_index_data, 
                       by = "month") |>
      dplyr::inner_join(eez_info,
                       by = c("lon_bin","lat_bin"))
  ),
  # Summarize data for quarto notebook ----
  # AIS data
  tar_target(
    name = joined_dataset_ais_summary,
    skimr::skim(joined_dataset_ais)
  ),
  # VIIRS data
  tar_target(
    name = joined_dataset_viirs_summary,
    skimr::skim(joined_dataset_viirs)
  ),
  # Make quarto notebook -----
  tar_quarto(
    name = quarto_book,
    path = "qmd",
    quiet = FALSE
  )
)
