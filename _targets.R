# Created by use_targets().
# Follow the comments below to fill in this target script.
# Then follow the manual to check and run the pipeline:
#   https://books.ropensci.org/targets/walkthrough.html#inspect-the-pipeline

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
                   parellely::availableCores()-1)

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


# Replace the target list below with your own:
list(
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
    0.5
  ),
  # Set temporal resolution - can be DAY, MONTH, or YEAR
  tar_target(
    name = temporal_resolution,
    'MONTH'
  ),
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
  # Summarize data for quarto notebook
  tar_target(
    name = gridded_time_effort_by_flag_summary,
    skimr::skim(gridded_time_effort_by_flag)
  ),
  # Download SST data from NOAA - Daily, 0.25x0.25 degree resolution from OI V2.1
  # And save to emLab shared data directory
  tar_target(
    name = sst_data_download,
    download_erddap_wrapper(dataset_name = "ncdcOisst21Agg_LonPM180",
                            date_start = "2016-01-01",
                            date_end = "2024-08-31",
                            download_path_base = glue::glue("{data_directory_base}/data/sst-noaa-daily-optimum-interpolation-v2-1/"))
  ),
  # Now aggregate SST data to our spatiotemporal resolution
  tar_target(
    name = sst_data_aggregated,
    spatio_temporal_aggregate(file_list = list.files(glue::glue("{data_directory_base}/data/sst-noaa-daily-optimum-interpolation-v2-1/"),
                                                     full.names = TRUE),
                              spatial_resolution = spatial_resolution,
                              temporal_resolution = temporal_resolution,
                              n_cores = n_cores)|>
      tibble::as_tibble()
  ),
  # Now aggregate SST data by time, to make time series
  tar_target(
    name = sst_data_aggregated_time_series,
    sst_data_aggregated |>
      collapse::collap(FUN = list(mean_sst = collapse::fmean),
                       by = ~ time,
                       cols = "mean_sst",
                       give.names = FALSE,
                       parallel = TRUE,
                       mc.cores = n_cores)
  ),
  # Summarize data for quarto notebook
  tar_target(
    name = sst_data_aggregated_summary,
    skimr::skim(sst_data_aggregated)
  ),
  # Subset to one month of SST data for making an exploratory data analysis map
  tar_target(
    name = sst_data_aggregated_one_month_subset,
    sst_data_aggregated |>
      collapse::fsubset(time == as.POSIXct("2024-08-01",tz="UTC")) |>
      collapse::fselect(lon_bin, lat_bin, mean_sst)
  ),
  # Make quarto notebook -----
  tar_quarto(
    name = quarto_book,
    path = "qmd",
    quiet = FALSE
  )
)
