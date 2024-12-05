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
  # Process ONI data ----
  # Pull Oceanic Nino Index data from NOAA
  tar_target(
    name = oceanic_nino_index_data,
    pull_oni_data()
  ),
  # Process climate change SST forecast data
  tar_target(
    sst_cc_forecast_data,
    process_sst_cc_forecast_data(project_directory)
  ),
  # Process EEZ data ---
  # Load full resolution Marine Regions V12 EEZ data
  tar_file_read(
    name = eez_full_res,
    glue::glue("{data_directory_base}/data//marine-regions-eez-v12/World_EEZ_v12_20231025/eez_v12.shp"),
    sf::st_read(!!.x, quiet = TRUE) |>
      # Don't include joint regimes or disputed areas
      dplyr::filter(POL_TYPE == "200NM") |>
      # Don't include Antarctica - classify it as high seas instead
      dplyr::filter(ISO_SOV1 != "ATA") |>
      # Make sure all geometries are valid
      sf::st_make_valid() 
  ),
  # Load EEZ boundaries from Marine Regions V12
  # Only want boundaries corresponding to those between an EEZ and high seas
  tar_file_read(
    name = eez_boundaries_high_seas,
    glue::glue("{data_directory_base}/data/marine-regions-eez-v12/World_EEZ_v12_20231025/eez_boundaries_v12.shp"),
    sf::st_read(!!.x, quiet = TRUE) |>
      dplyr::filter(LINE_TYPE == "200 NM")
  ),
  # Determine pixels for which we'll want to determine EEZ info - use all pixels that have SST data
  tar_target(
    name = pixels_for_eez_calculations,
    sst_data_aggregated |>
      dplyr::distinct(lon_bin,lat_bin) |>
      dplyr::mutate(lon_bin_centroid = lon_bin + spatial_resolution/2,
                    lat_bin_centroid = lat_bin + spatial_resolution/2) |>
      sf::st_as_sf(coords = c("lon_bin_centroid", "lat_bin_centroid"), 
                   crs = 4326)
  ),
  # Assign EEZ to centroid of each pixel
  tar_target(
    pixels_with_eez,
    pixels_for_eez_calculations |>
      sf::st_join(eez_full_res |>
                            dplyr::select(eez_id = MRGID)) |>
      sf::st_set_geometry(NULL)|> 
      tibble::as_tibble()
  ),
  # Assign nearest EEZ, and its distance, to each pixel
  tar_target(
    pixels_with_nearest_eez,
    nngeo::st_nn(pixels_for_eez_calculations,
                 eez_boundaries_high_seas, 
                 # Only select single nearest eez
                 k = 1, 
                 returnDist = T,
                 parallel = n_cores) |> 
      tibble::as_tibble() |>
      tidyr::unnest(c(nn,dist)) |>
      dplyr::mutate(nearest_eez_id =  eez_boundaries_high_seas$MRGID_SOV1[as.numeric(nn)], 
                    nearest_eez_distance_m = as.numeric(dist)) |>
      dplyr::select(-c(nn,dist)) |>
      dplyr::bind_cols(pixels_for_eez_calculations |>
                         dplyr::select(lon_bin, lat_bin) |>
                         sf::st_set_geometry(NULL))
  ),
  # Now put together all EEZ info
  tar_target(
    pixels_eez_with_info,
    pixels_for_eez_calculations |>
      dplyr::select(lon_bin, lat_bin) |>
      sf::st_set_geometry(NULL) |>
      tibble::as_tibble() |>
      dplyr::left_join(pixels_with_eez, by = c("lon_bin","lat_bin"))|>
      dplyr::left_join(pixels_with_nearest_eez, by = c("lon_bin","lat_bin")) |>
      dplyr::left_join(eez_full_res |>
                         sf::st_set_geometry(NULL) |>
                         dplyr::select(eez_id = MRGID,
                                       eez_iso3 = ISO_SOV1), by = "eez_id") |>
      dplyr::left_join(eez_full_res |>
                         sf::st_set_geometry(NULL) |>
                         dplyr::select(nearest_eez_id = MRGID_SOV1,
                          nearest_eez_iso3 = ISO_SOV1) |>
                         dplyr::distinct(), by = "nearest_eez_id") |>
      dplyr::mutate(eez_id = ifelse(is.na(eez_id),"high_seas",eez_id)) |>
      dplyr::mutate(eez_iso3 = ifelse(is.na(eez_iso3),"high_seas",eez_iso3)) |>
      dplyr::mutate(high_seas = ifelse(eez_iso3 == "high_seas",TRUE,FALSE)) |>
      # Make this a charcter to match eez_id
      dplyr::mutate(nearest_eez_id = as.character(nearest_eez_id)) |>
      # If a pixel is within an EEZ, nearest eez ID and iso3 should match pixel
      dplyr::mutate(nearest_eez_id = ifelse(!high_seas,eez_id,nearest_eez_id)) |>
      dplyr::mutate(nearest_eez_iso3 = ifelse(!high_seas,eez_iso3,nearest_eez_iso3))
  ),
  # Analysis longitude scope range
  tar_target(
    analysis_scope_lon,
    c(-130,-70)
  ),
  # Analysis latitude scope range
  tar_target(
    analysis_scope_lat,
    c(-40,10)
  ),
  # Now make analysis scope bounding box shapefile
  tar_target(
    analysis_bounding_box,
    make_bounding_box(analysis_scope_lon,
                      analysis_scope_lat)
  ),
  # Join together AIS-based effort, SST, ONI, and EEZ datasets
  tar_target(
    name = joined_dataset_ais,
    # Get all unique combinations of month, longitude, and latitude, and flags that operate within the study scope
    sst_data_aggregated |>
      dplyr::distinct(month,lon_bin,lat_bin) |>
      # Only select pixels within analysis scope
      dplyr::filter(lon_bin >= analysis_scope_lon[1] & lon_bin <= analysis_scope_lon[2] &
                    lat_bin >= analysis_scope_lat[1] & lat_bin <= analysis_scope_lat[2]) |>
      tidyr::crossing(gridded_time_effort_by_flag |>
                        # Only select pixels within analysis scope
                        dplyr::filter(lon_bin >= analysis_scope_lon[1] & lon_bin <= analysis_scope_lon[2] &
                                        lat_bin >= analysis_scope_lat[1] & lat_bin <= analysis_scope_lat[2]) |>
                        dplyr::distinct(flag)) |>
      # Now add sst data
      dplyr::left_join(sst_data_aggregated,
                       by = c("month","lat_bin","lon_bin")) |>
      # Now add effort data
      dplyr::left_join(gridded_time_effort_by_flag |>
                         collapse::fmutate(month = lubridate::ymd(month)),
                        by = c("month","lat_bin","lon_bin","flag")) |>
      dplyr::mutate(across(c(fishing_hours,fishing_kw_hours),~tidyr::replace_na(.,0))) |>
      # Now add ONI data
      dplyr::left_join(oceanic_nino_index_data, 
                       by = "month") |>
      # Now add EEZ info
      dplyr::left_join(pixels_eez_with_info,
                        by = c("lon_bin","lat_bin")) 
  ),
  # Join datasets ----
  # Join together VIIRS, SST, ONI, and EEZ datasets
  tar_target(
    name = joined_dataset_viirs,
    sst_data_aggregated |>
      dplyr::distinct(month,lon_bin,lat_bin) |>
      # Limit this to only those months for which we have VIIRS
      dplyr::inner_join(gridded_viirs_detections |>
                          collapse::fmutate(month = lubridate::ymd(month)) |>
                          dplyr::distinct(month), by = "month") |>
      # Only select pixels within analysis scope
      dplyr::filter(lon_bin >= analysis_scope_lon[1] & lon_bin <= analysis_scope_lon[2] &
                      lat_bin >= analysis_scope_lat[1] & lat_bin <= analysis_scope_lat[2]) |>
      # Now add sst data
      dplyr::left_join(sst_data_aggregated,
                       by = c("month","lat_bin","lon_bin")) |>
      # Now add effort data
      dplyr::left_join(gridded_viirs_detections |>
                         collapse::fmutate(month = lubridate::ymd(month)),
                       by = c("month","lat_bin","lon_bin")) |>
      dplyr::mutate(across(c(viirs_detections),~tidyr::replace_na(.,0))) |>
      # Now add ONI data
      dplyr::left_join(oceanic_nino_index_data, 
                       by = "month") |>
      # Now add EEZ info
      dplyr::left_join(pixels_eez_with_info,
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
  # EEZ shapefile from Marine Regions v12 EEZ, for plotting
  tar_target(
    name = eez,
    sf::st_read(glue::glue("{data_directory_base}/data/marine-regions-eez-v12/World_EEZ_v12_20231025_LR/eez_v12_lowres.shp",quiet = TRUE)) |>
      # Only want 200NM shapes for plots
      dplyr::filter(POL_TYPE == "200NM")
  ),
  # SPRFMO shapefile from FAO, for plotting
  tar_target(
    name = sprfmo,
    sf::st_read(glue::glue("{project_directory}/data/raw/sprfmo_shapefile/RFB_SPRFMO.shp",quiet = TRUE))
  ),
  # Global land shapefile, for plotting
  tar_target(
    name = land,
    rnaturalearth::ne_countries(returnclass = "sf")
  ),
  # Make quarto notebook -----
  tar_quarto(
    name = quarto_book,
    path = "qmd",
    quiet = FALSE
  )
)
