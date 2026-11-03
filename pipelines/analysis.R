# Analysis targets project ----
# Joins AIS-based fishing effort, VIIRS detections, SST, ONI, and EEZ data,
# and renders the Quarto book in docs/ (published on GitHub Pages). Reads only
# local files: the gfw and sst projects' outputs (handoff_files in
# r/config.R) and shapefiles in the emLab data directory. It needs no
# credentials or internet, except rnaturalearth's bundled land shapes. Run
# with: Rscript run.R analysis
library(targets)
library(tarchetypes)

tar_source(c("r/config.R", "r/functions.R"))
tar_option_set(packages = character(0))

list(
  # Inputs from the gfw and sst projects ----
  tar_target(
    name = squid_vessel_list_file,
    handoff_file(handoff_files$squid_vessel_list, project = "gfw"),
    format = "file"
  ),
  tar_target(
    name = squid_vessel_list,
    nanoparquet::read_parquet(squid_vessel_list_file)
  ),
  tar_target(
    name = gridded_time_effort_by_flag_file,
    handoff_file(handoff_files$gridded_time_effort_by_flag, project = "gfw"),
    format = "file"
  ),
  tar_target(
    name = gridded_time_effort_by_flag,
    nanoparquet::read_parquet(gridded_time_effort_by_flag_file)
  ),
  tar_target(
    name = gridded_viirs_detections_file,
    handoff_file(handoff_files$gridded_viirs_detections, project = "gfw"),
    format = "file"
  ),
  tar_target(
    name = gridded_viirs_detections,
    nanoparquet::read_parquet(gridded_viirs_detections_file) |>
      dplyr::filter(lubridate::year(month) < 2022)
  ),
  tar_target(
    name = sst_monthly_file,
    handoff_file(handoff_files$sst_monthly, project = "sst"),
    format = "file"
  ),
  # Monthly SST for each pixel in the analysis scope
  tar_target(
    name = sst_data_aggregated,
    nanoparquet::read_parquet(sst_monthly_file)
  ),
  tar_target(
    name = oni_monthly_file,
    handoff_file(handoff_files$oni_monthly, project = "sst"),
    format = "file"
  ),
  tar_target(
    name = oceanic_nino_index_data,
    nanoparquet::read_parquet(oni_monthly_file)
  ),
  # CMIP6 SST projections (IPCC AR6 Interactive Atlas) ----
  # Multi-model mean monthly SST for each future scenario and period, on 1
  # degree cells identified by their lower-left corner
  tar_target(
    name = sst_cc_forecast_file,
    handoff_file(handoff_files$sst_cc_forecast, project = "sst"),
    format = "file"
  ),
  tar_target(
    name = sst_cc_forecast_data,
    nanoparquet::read_parquet(sst_cc_forecast_file)
  ),
  # Same, for the 1995-2014 baseline of the historical runs, using each
  # scenario's models. Future minus baseline is the projected change
  tar_target(
    name = sst_cc_baseline_file,
    handoff_file(handoff_files$sst_cc_baseline, project = "sst"),
    format = "file"
  ),
  tar_target(
    name = sst_cc_baseline_data,
    nanoparquet::read_parquet(sst_cc_baseline_file)
  ),
  # EEZ data ----
  # Load full resolution Marine Regions V12 EEZ data
  tar_file_read(
    name = eez_full_res,
    file.path(
      data_directory_base,
      "data/marine-regions-eez-v12/World_EEZ_v12_20231025/eez_v12.shp"
    ),
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
    file.path(
      data_directory_base,
      "data/marine-regions-eez-v12/World_EEZ_v12_20231025/eez_boundaries_v12.shp"
    ),
    sf::st_read(!!.x, quiet = TRUE) |>
      dplyr::filter(LINE_TYPE == "200 NM")
  ),
  # Pixels for which we'll want to determine EEZ info - all pixels with SST
  # data, which covers the analysis scope
  tar_target(
    name = pixels_for_eez_calculations,
    sst_data_aggregated |>
      dplyr::distinct(lon_bin, lat_bin) |>
      dplyr::mutate(
        lon_bin_centroid = lon_bin + spatial_resolution / 2,
        lat_bin_centroid = lat_bin + spatial_resolution / 2
      ) |>
      sf::st_as_sf(
        coords = c("lon_bin_centroid", "lat_bin_centroid"),
        crs = 4326
      )
  ),
  # Assign EEZ to centroid of each pixel
  tar_target(
    pixels_with_eez,
    pixels_for_eez_calculations |>
      sf::st_join(
        eez_full_res |>
          dplyr::select(eez_id = MRGID)
      ) |>
      sf::st_set_geometry(NULL) |>
      tibble::as_tibble()
  ),
  # Assign nearest EEZ, and its distance, to each pixel
  tar_target(
    pixels_with_nearest_eez,
    nngeo::st_nn(
      pixels_for_eez_calculations,
      eez_boundaries_high_seas,
      # Only select single nearest eez
      k = 1,
      returnDist = TRUE,
      parallel = n_workers()
    ) |>
      tibble::as_tibble() |>
      tidyr::unnest(c(nn, dist)) |>
      dplyr::mutate(
        nearest_eez_id = eez_boundaries_high_seas$MRGID_SOV1[as.numeric(nn)],
        nearest_eez_distance_m = as.numeric(dist)
      ) |>
      dplyr::select(-c(nn, dist)) |>
      dplyr::bind_cols(
        pixels_for_eez_calculations |>
          dplyr::select(lon_bin, lat_bin) |>
          sf::st_set_geometry(NULL)
      )
  ),
  # Now put together all EEZ info
  tar_target(
    pixels_eez_with_info,
    pixels_for_eez_calculations |>
      dplyr::select(lon_bin, lat_bin) |>
      sf::st_set_geometry(NULL) |>
      tibble::as_tibble() |>
      dplyr::left_join(pixels_with_eez, by = c("lon_bin", "lat_bin")) |>
      dplyr::left_join(pixels_with_nearest_eez, by = c("lon_bin", "lat_bin")) |>
      # Keep the sovereign's MRGID too, so nearest_eez_id is a sovereign
      # MRGID for every pixel (the boundary lines only have sovereign IDs)
      dplyr::left_join(
        eez_full_res |>
          sf::st_set_geometry(NULL) |>
          dplyr::select(
            eez_id = MRGID,
            eez_iso3 = ISO_SOV1,
            eez_sovereign_id = MRGID_SOV1
          ),
        by = "eez_id"
      ) |>
      dplyr::left_join(
        eez_full_res |>
          sf::st_set_geometry(NULL) |>
          dplyr::select(
            nearest_eez_id = MRGID_SOV1,
            nearest_eez_iso3 = ISO_SOV1
          ) |>
          dplyr::distinct(),
        by = "nearest_eez_id"
      ) |>
      dplyr::mutate(eez_id = ifelse(is.na(eez_id), "high_seas", eez_id)) |>
      dplyr::mutate(
        eez_iso3 = ifelse(is.na(eez_iso3), "high_seas", eez_iso3)
      ) |>
      dplyr::mutate(high_seas = ifelse(eez_iso3 == "high_seas", TRUE, FALSE)) |>
      # Make this a character to match eez_id
      dplyr::mutate(nearest_eez_id = as.character(nearest_eez_id)) |>
      # If a pixel is within an EEZ, nearest eez ID and iso3 should match pixel
      dplyr::mutate(
        nearest_eez_id = ifelse(
          !high_seas,
          as.character(eez_sovereign_id),
          nearest_eez_id
        )
      ) |>
      dplyr::mutate(
        nearest_eez_iso3 = ifelse(!high_seas, eez_iso3, nearest_eez_iso3)
      ) |>
      dplyr::select(-eez_sovereign_id)
  ),
  # Analysis scope bounding box shapefile
  tar_target(
    analysis_bounding_box,
    make_bounding_box(analysis_scope_lon, analysis_scope_lat)
  ),
  # Join datasets ----
  # Join together AIS-based effort, SST, ONI, and EEZ datasets
  tar_target(
    name = joined_dataset_ais,
    # Get all unique combinations of month, longitude, and latitude, and flags
    # that operate within the study scope
    sst_data_aggregated |>
      dplyr::distinct(month, lon_bin, lat_bin) |>
      # Only select pixels within analysis scope
      dplyr::filter(
        lon_bin >= analysis_scope_lon[1] &
          lon_bin <= analysis_scope_lon[2] &
          lat_bin >= analysis_scope_lat[1] &
          lat_bin <= analysis_scope_lat[2]
      ) |>
      tidyr::crossing(
        gridded_time_effort_by_flag |>
          # Only select pixels within analysis scope
          dplyr::filter(
            lon_bin >= analysis_scope_lon[1] &
              lon_bin <= analysis_scope_lon[2] &
              lat_bin >= analysis_scope_lat[1] &
              lat_bin <= analysis_scope_lat[2]
          ) |>
          dplyr::distinct(flag)
      ) |>
      # Now add sst data
      dplyr::left_join(
        sst_data_aggregated,
        by = c("month", "lat_bin", "lon_bin")
      ) |>
      # Now add effort data
      dplyr::left_join(
        gridded_time_effort_by_flag,
        by = c("month", "lat_bin", "lon_bin", "flag")
      ) |>
      dplyr::mutate(dplyr::across(
        c(fishing_hours, fishing_kw_hours),
        ~ tidyr::replace_na(., 0)
      )) |>
      # Now add ONI data
      dplyr::left_join(oceanic_nino_index_data, by = "month") |>
      # Now add EEZ info
      dplyr::left_join(pixels_eez_with_info, by = c("lon_bin", "lat_bin")) |>
      check_joined_dataset(
        keys = c("month", "lon_bin", "lat_bin", "flag"),
        no_na = c("sst_deg_c_mean", "oceanic_nino_index", "eez_iso3"),
        months = seq(
          as.Date(analysis_date_start),
          as.Date(analysis_date_end),
          by = "month"
        )
      )
  ),
  # Join together VIIRS, SST, ONI, and EEZ datasets
  tar_target(
    name = joined_dataset_viirs,
    sst_data_aggregated |>
      dplyr::distinct(month, lon_bin, lat_bin) |>
      # Limit this to only those months for which we have VIIRS
      dplyr::inner_join(
        gridded_viirs_detections |>
          dplyr::distinct(month),
        by = "month"
      ) |>
      # Only select pixels within analysis scope
      dplyr::filter(
        lon_bin >= analysis_scope_lon[1] &
          lon_bin <= analysis_scope_lon[2] &
          lat_bin >= analysis_scope_lat[1] &
          lat_bin <= analysis_scope_lat[2]
      ) |>
      # Now add sst data
      dplyr::left_join(
        sst_data_aggregated,
        by = c("month", "lat_bin", "lon_bin")
      ) |>
      # Now add effort data
      dplyr::left_join(
        gridded_viirs_detections,
        by = c("month", "lat_bin", "lon_bin")
      ) |>
      dplyr::mutate(dplyr::across(
        c(viirs_detections),
        ~ tidyr::replace_na(., 0)
      )) |>
      # Now add ONI data
      dplyr::left_join(oceanic_nino_index_data, by = "month") |>
      # Now add EEZ info
      dplyr::left_join(pixels_eez_with_info, by = c("lon_bin", "lat_bin")) |>
      check_joined_dataset(
        keys = c("month", "lon_bin", "lat_bin"),
        no_na = c("sst_deg_c_mean", "oceanic_nino_index", "eez_iso3"),
        months = unique(gridded_viirs_detections$month)
      )
  ),
  # Summarize data for quarto notebook ----
  # AIS data
  tar_target(
    name = joined_dataset_ais_summary,
    # Only select columns we ended up using
    skimr::skim(
      joined_dataset_ais |>
        dplyr::select(
          month,
          lon_bin,
          lat_bin,
          flag,
          sst_deg_c_mean,
          fishing_hours,
          fishing_kw_hours
        )
    )
  ),
  # VIIRS data
  tar_target(
    name = joined_dataset_viirs_summary,
    skimr::skim(joined_dataset_viirs)
  ),
  # EEZ shapefile from Marine Regions v12 EEZ, for plotting
  tar_target(
    name = eez,
    sf::st_read(
      file.path(
        data_directory_base,
        "data/marine-regions-eez-v12/World_EEZ_v12_20231025_LR/eez_v12_lowres.shp"
      ),
      quiet = TRUE
    ) |>
      # Only want 200NM shapes for plots
      dplyr::filter(POL_TYPE == "200NM")
  ),
  # SPRFMO shapefile from FAO, for plotting
  tar_target(
    name = sprfmo,
    sf::st_read(
      file.path(project_directory, "data/raw/sprfmo_shapefile/RFB_SPRFMO.shp"),
      quiet = TRUE
    )
  ),
  # Global land shapefile, for plotting
  tar_target(
    name = land,
    rnaturalearth::ne_countries(returnclass = "sf")
  ),
  # Make quarto notebook -----
  # The chapters source r/config.R and r/functions.R, so track them too
  tar_quarto(
    name = quarto_book,
    path = "qmd",
    extra_files = c("r/config.R", "r/functions.R"),
    quiet = FALSE
  )
)
