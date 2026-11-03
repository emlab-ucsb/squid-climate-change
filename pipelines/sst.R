# SST targets project ----
# Downloads daily NOAA OISST v2.1 sea surface temperature from NCEI, aggregates
# it to monthly pixels in the analysis scope, and snapshots NOAA's Oceanic Nino
# Index (ONI). Writes parquet files for the analysis project (handoff_files in
# r/config.R). Needs internet, but no credentials. Run with:
# Rscript run.R sst
library(targets)

tar_source(c("r/config.R", "r/functions.R", "r/sst.R"))
tar_option_set(packages = character(0))

list(
  # SST data ----
  # One branch per month, so a failed or changed month only reruns itself
  tar_target(
    name = sst_months,
    seq(as.Date(analysis_date_start), as.Date(analysis_date_end), by = "month")
  ),
  # Daily files from NCEI for each month, checked and tracked by content. A
  # file that changes on disk reruns its month
  tar_target(
    name = sst_daily_files,
    download_oisst(
      dates = seq(
        sst_months,
        min(
          lubridate::ceiling_date(sst_months, "month") - 1,
          as.Date(analysis_date_end)
        ),
        by = "day"
      ),
      directory = sst_raw_directory
    ),
    pattern = map(sst_months),
    format = "file"
  ),
  # Monthly mean, SD, min, and max SST for each pixel in the analysis scope
  tar_target(
    name = sst_monthly_by_month,
    aggregate_oisst(
      files = sst_daily_files,
      spatial_resolution = spatial_resolution,
      temporal_resolution = temporal_resolution,
      lon_range = analysis_scope_lon,
      lat_range = analysis_scope_lat
    ),
    pattern = map(sst_daily_files)
  ),
  tar_target(
    name = sst_monthly_file,
    check_sst_monthly(
      sst_monthly_by_month,
      date_start = analysis_date_start,
      date_end = analysis_date_end
    ) |>
      write_parquet_atomic(path = handoff_files$sst_monthly),
    format = "file"
  ),
  # CMIP6 SST projections ----
  # One request per Atlas experiment and period: each future scenario for each
  # future period, plus the historical runs for the baseline period
  tar_target(
    name = cmip6_requests,
    dplyr::bind_rows(
      tidyr::crossing(
        dplyr::filter(cmip6_experiments, experiment != "historical"),
        cmip6_periods
      ),
      dplyr::filter(cmip6_experiments, experiment == "historical") |>
        dplyr::mutate(
          time_period = "Baseline",
          year_start = cmip6_baseline_years[1],
          year_end = cmip6_baseline_years[2]
        )
    )
  ),
  # Each model's monthly SST climatology for one request, in the analysis
  # scope. Reads only that subset from the Atlas server
  tar_target(
    name = cmip6_climatology,
    read_cmip6_climatology(
      experiment = cmip6_requests$experiment,
      file_dates = cmip6_requests$file_dates,
      years = c(cmip6_requests$year_start, cmip6_requests$year_end),
      n_models = cmip6_requests$n_models,
      lon_range = analysis_scope_lon,
      lat_range = analysis_scope_lat,
      base_url = cmip6_atlas_opendap
    ) |>
      dplyr::mutate(
        scenario = cmip6_requests$scenario,
        time_period = cmip6_requests$time_period
      ),
    pattern = map(cmip6_requests)
  ),
  # Multi-model mean for each future scenario, period, and month, as on the
  # Interactive Atlas maps
  tar_target(
    name = sst_cc_forecast_file,
    cmip6_climatology |>
      dplyr::filter(scenario != "historical") |>
      dplyr::group_split(scenario, time_period) |>
      lapply(function(x) {
        cmip6_ensemble_mean(x) |>
          dplyr::mutate(
            scenario = x$scenario[1],
            time_period = x$time_period[1]
          )
      }) |>
      dplyr::bind_rows() |>
      check_cmip6_forecast(
        scenarios = setdiff(cmip6_experiments$scenario, "historical"),
        time_periods = cmip6_periods$time_period
      ) |>
      write_parquet_atomic(path = handoff_files$sst_cc_forecast),
    format = "file"
  ),
  # Baseline (1995-2014) multi-model mean from the historical runs, for each
  # scenario and period, using the same models as that future mean, so future
  # minus baseline is a like-for-like change. The Atlas also only uses models
  # common to the historical and scenario runs for changes (04_map_figures.R,
  # lines 84-90)
  tar_target(
    name = sst_cc_baseline_file,
    {
      historical <- dplyr::filter(cmip6_climatology, scenario == "historical")
      cmip6_climatology |>
        dplyr::filter(scenario != "historical") |>
        dplyr::distinct(scenario, time_period, member_id) |>
        dplyr::group_split(scenario, time_period) |>
        lapply(function(x) {
          missing_models <- setdiff(x$member_id, historical$member_id)
          if (length(missing_models) > 0) {
            stop(
              "Historical runs missing for ",
              x$scenario[1],
              " models: ",
              paste(missing_models, collapse = ", ")
            )
          }
          historical |>
            dplyr::filter(member_id %in% x$member_id) |>
            cmip6_ensemble_mean() |>
            dplyr::mutate(
              scenario = x$scenario[1],
              time_period = x$time_period[1]
            )
        }) |>
        dplyr::bind_rows() |>
        dplyr::arrange(scenario, time_period, month_number, lon_bin, lat_bin) |>
        write_parquet_atomic(path = handoff_files$sst_cc_baseline)
    },
    format = "file"
  ),
  # Which models each mean uses, and the fewest years of data each has for a
  # calendar month
  tar_target(
    name = cmip6_models_file,
    cmip6_climatology |>
      dplyr::group_by(scenario, time_period, member_id) |>
      dplyr::summarize(min_years = min(n_years), .groups = "drop") |>
      dplyr::arrange(scenario, time_period, member_id) |>
      write_csv_atomic(path = handoff_files$cmip6_models),
    format = "file"
  ),
  # ONI data ----
  # Dated snapshot of NOAA PSL's ONI file, downloaded once
  tar_target(
    name = oni_raw_file,
    snapshot_oni(
      path = handoff_files$oni_raw,
      snapshot_date = oni_snapshot_date,
      date_end = analysis_date_end
    ),
    format = "file"
  ),
  tar_target(
    name = oni_monthly_file,
    read_oni(oni_raw_file, date_end = analysis_date_end) |>
      write_parquet_atomic(path = handoff_files$oni_monthly),
    format = "file"
  )
)
