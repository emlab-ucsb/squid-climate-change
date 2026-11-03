## ---------------------------
## Script name: r/sst.R
## Purpose:
## Functions for pipelines/sst.R: download daily NOAA OISST v2.1 sea surface
## temperature from NCEI, aggregate it to monthly pixels, and snapshot the
## Oceanic Nino Index (ONI) from NOAA PSL.
## ---------------------------

#' NCEI URL of a daily NOAA OISST v2.1 file
#'
#' @description NCEI's archive is the source of the OISST data that ERDDAP
#'   mirrors. These are the final files; the last ~2 weeks are only available
#'   as "_preliminary" files, which these URLs deliberately don't match.
#' @param date Date.
#' @return Character URL.
oisst_url <- function(date) {
  sprintf("https://www.ncei.noaa.gov/data/sea-surface-temperature-optimum-interpolation/v2.1/access/avhrr/%s/oisst-avhrr-v02r01.%s.nc",
          format(date, "%Y%m"), format(date, "%Y%m%d"))
}

#' Local path of a daily NOAA OISST v2.1 file
#'
#' @param date Date.
#' @param directory Directory for the raw files. Files go in YYYYMM
#'   subdirectories, as on NCEI.
#' @return Character path.
oisst_path <- function(date, directory) {
  file.path(directory, format(date, "%Y%m"), basename(oisst_url(date)))
}

#' Check a daily NOAA OISST v2.1 file
#'
#' @description Checks the file opens as netCDF, is the final (not
#'   preliminary) global 0.25 degree product, and holds the expected date.
#' @param path Path of the file.
#' @param date Date the file should hold.
#' @return NULL if the file is valid; otherwise a character string saying why
#'   not.
oisst_file_problem <- function(path, date) {
  nc <- tryCatch(ncdf4::nc_open(path), error = function(e) NULL)
  if (is.null(nc)) return("not a readable netCDF file")
  on.exit(ncdf4::nc_close(nc))
  if (!"sst" %in% names(nc$var)) return("no sst variable")
  if (nc$dim$lon$len != 1440 || nc$dim$lat$len != 720) return("not a 1440 x 720 grid")
  title <- ncdf4::ncatt_get(nc, 0, "title")$value
  if (!grepl("Final$", title)) return(paste0("not the final product (title: ", title, ")"))
  # time is days since 1978-01-01 12:00:00
  file_date <- as.character(as.Date("1978-01-01") + ncdf4::ncvar_get(nc, "time"))
  if (!identical(file_date, as.character(date))) return(paste0("holds ", file_date, ", not ", date))
  NULL
}

#' Download and check daily NOAA OISST v2.1 files from NCEI
#'
#' @description Downloads the files for dates that aren't already saved,
#'   in parallel, resuming partial downloads. Each file downloads to a
#'   ".part" file and is renamed into place only after it passes
#'   oisst_file_problem(), so a saved file is always complete and correct.
#'   Retries with backoff, and stops if any file still fails, so a monthly
#'   mean never quietly misses days. Saved files are checked again on every
#'   run, and a bad one stops the pipeline instead of being replaced
#'   silently.
#' @param dates Dates to download.
#' @param directory Directory for the raw files.
#' @param max_attempts Download attempts per file.
#' @return Character vector of file paths, one per date, for format = "file"
#'   targets.
download_oisst <- function(dates, directory, max_attempts = 6) {
  dates <- as.Date(dates)
  paths <- oisst_path(dates, directory)

  # Files already saved must still be valid
  saved <- file.exists(paths)
  problems <- Map(oisst_file_problem, paths[saved], as.character(dates[saved]))
  bad <- !vapply(problems, is.null, logical(1))
  if (any(bad)) {
    stop("Saved OISST files are invalid: ",
         paste0(names(problems)[bad], " (", unlist(problems[bad]), ")", collapse = "; "),
         ". Check them, and delete them to re-download.")
  }

  todo <- which(!saved)
  attempt <- 0
  failures <- character(0)
  while (length(todo) > 0 && attempt < max_attempts) {
    attempt <- attempt + 1
    if (attempt > 1) Sys.sleep(min(300, 10 * 2^(attempt - 2)))
    for (dir in unique(dirname(paths[todo]))) dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    parts <- paste0(paths[todo], ".part")
    result <- curl::multi_download(oisst_url(dates[todo]), parts,
                                   resume = TRUE, progress = FALSE)
    failures <- character(0)
    for (i in seq_along(todo)) {
      j <- todo[i]
      status <- result$status_code[i]
      if (!isTRUE(result$success[i]) || !status %in% c(200, 206, 416)) {
        failures[as.character(dates[j])] <- if (is.na(result$error[i])) {
          paste0("HTTP ", status)
        } else {
          paste0("HTTP ", status, ": ", result$error[i])
        }
        # A 404 or other error page isn't a partial download, so don't resume it
        if (!is.na(status) && status >= 400 && status != 416) unlink(parts[i])
        next
      }
      problem <- oisst_file_problem(parts[i], dates[j])
      if (!is.null(problem)) {
        failures[as.character(dates[j])] <- problem
        unlink(parts[i])
        next
      }
      if (!file.rename(parts[i], paths[j])) stop("Could not move ", parts[i], " to ", paths[j])
    }
    todo <- which(!file.exists(paths))
    if (length(todo) > 0) {
      message("OISST attempt ", attempt, ": ", length(todo), " files still missing")
    }
  }
  if (length(todo) > 0) {
    stop("Could not download ", length(todo), " OISST files after ", max_attempts,
         " attempts: ", paste0(names(failures), " (", failures, ")", collapse = "; "))
  }
  paths
}

#' Aggregate daily NOAA OISST v2.1 files to pixels and months
#'
#' @description Bins each day's 0.25 degree cells into spatial_resolution
#'   pixels (identified by their lower-left corner), keeps pixels in the
#'   bounding box, and summarizes SST across the cells and days in each pixel
#'   and month. Land and sea ice cells have no SST and are dropped.
#' @param files Daily files, all from one month.
#' @param spatial_resolution Pixel size in degrees.
#' @param temporal_resolution "DAY", "MONTH", or "YEAR".
#' @param lon_range,lat_range Pixels are kept when lon_bin and lat_bin are
#'   inside these ranges, inclusive.
#' @return data.table with month, lon_bin, lat_bin, sst_deg_c_mean,
#'   sst_deg_c_sd, sst_deg_c_min, and sst_deg_c_max.
aggregate_oisst <- function(files, spatial_resolution, temporal_resolution,
                            lon_range, lat_range) {
  daily <- lapply(files, function(file) {
    nc <- ncdf4::nc_open(file)
    on.exit(ncdf4::nc_close(nc))
    # NCEI longitudes run 0 to 360; convert to -180 to 180
    lon <- as.vector(ncdf4::ncvar_get(nc, "lon"))
    lon <- ifelse(lon > 180, lon - 360, lon)
    lat <- as.vector(ncdf4::ncvar_get(nc, "lat"))
    date <- as.Date("1978-01-01") + ncdf4::ncvar_get(nc, "time")
    lon_bin <- floor(lon / spatial_resolution) * spatial_resolution
    lat_bin <- floor(lat / spatial_resolution) * spatial_resolution
    keep_lon <- which(lon_bin >= lon_range[1] & lon_bin <= lon_range[2])
    keep_lat <- which(lat_bin >= lat_range[1] & lat_bin <= lat_range[2])
    # sst is lon x lat; ncdf4 applies the scale factor and fill value
    sst <- ncdf4::ncvar_get(nc, "sst")[keep_lon, keep_lat, drop = FALSE]
    data.table::data.table(
      date = date,
      lon_bin = rep(lon_bin[keep_lon], times = length(keep_lat)),
      lat_bin = rep(lat_bin[keep_lat], each = length(keep_lon)),
      sst = as.vector(sst)
    )[!is.na(sst)]
  }) |>
    data.table::rbindlist()

  daily[, month := as.Date(lubridate::floor_date(date, stringr::str_to_lower(temporal_resolution)))]
  daily[, .(sst_deg_c_mean = mean(sst),
            sst_deg_c_sd = stats::sd(sst),
            sst_deg_c_min = min(sst),
            sst_deg_c_max = max(sst)),
        by = .(month, lon_bin, lat_bin)]
}

#' Check monthly SST covers every month and pixel once
#'
#' @param sst_monthly Output of aggregate_oisst(), all months bound together.
#' @param date_start,date_end First and last dates of the analysis.
#' @return sst_monthly, sorted by month, lon_bin, and lat_bin.
check_sst_monthly <- function(sst_monthly, date_start, date_end) {
  sst_monthly <- data.table::as.data.table(sst_monthly)
  expected_months <- seq(as.Date(date_start), as.Date(date_end), by = "month")
  missing_months <- setdiff(expected_months, unique(sst_monthly$month))
  if (length(missing_months) > 0) {
    stop("Monthly SST is missing months: ", paste(as.Date(missing_months), collapse = ", "))
  }
  if (anyDuplicated(sst_monthly, by = c("month", "lon_bin", "lat_bin"))) {
    stop("Monthly SST is not unique on month, lon_bin, and lat_bin")
  }
  if (any(sst_monthly$sst_deg_c_mean < -2 | sst_monthly$sst_deg_c_mean > 36)) {
    stop("Monthly mean SST outside -2 to 36 degrees C")
  }
  data.table::setorder(sst_monthly, month, lon_bin, lat_bin)[]
}

#' Save a dated snapshot of NOAA's Oceanic Nino Index (ONI) file
#'
#' @description NOAA revises past ONI values, so a re-download on another day
#'   may not reproduce the analysis. This downloads the file once, to a path
#'   named for the snapshot date, and never again. It refuses to take a
#'   snapshot on a different day than the snapshot date it is named for.
#' @param path Destination path, named for the snapshot date.
#' @param snapshot_date Date the snapshot is named for, as "YYYY-MM-DD".
#' @param date_end Last date of the analysis; the file must have ONI values
#'   through this date.
#' @param url Where to download the ONI file.
#' @return path, for format = "file" targets.
snapshot_oni <- function(path, snapshot_date, date_end,
                         url = "https://psl.noaa.gov/data/correlation/oni.data") {
  if (file.exists(path)) return(path)
  if (!identical(as.character(Sys.Date()), snapshot_date)) {
    stop("The ONI snapshot for ", snapshot_date, " (", path, ") is missing. ",
         "NOAA revises the ONI, so downloading it today would not reproduce ",
         "that snapshot. Restore the file, or set oni_snapshot_date in ",
         "r/config.R to today's date to take a new snapshot.")
  }
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp <- paste0(path, ".tmp-", Sys.getpid())
  on.exit(unlink(tmp), add = TRUE)
  curl::curl_download(url, tmp)
  # Make sure the file parses before saving it
  read_oni(tmp, date_end = date_end)
  if (!file.rename(tmp, path)) stop("Could not move ", tmp, " to ", path)
  path
}

#' Read NOAA's Oceanic Nino Index (ONI) file
#'
#' @param path Path of the ONI file from NOAA PSL.
#' @param date_end Months after this date are dropped.
#' @return Tibble with columns month (first day of the month) and
#'   oceanic_nino_index. Stops if any month through date_end isn't published
#'   yet.
read_oni <- function(path, date_end) {
  oni_lines <- readLines(path)
  # The first line gives the first and last years in the file, followed by one
  # row per year. Footer lines after those rows are notes, not data
  file_years <- scan(text = oni_lines[1], quiet = TRUE)
  n_years <- file_years[2] - file_years[1] + 1
  oni_data <- utils::read.table(text = oni_lines[2:(n_years + 1)]) |>
    tibble::as_tibble() |>
    dplyr::rename(year = V1) |>
    tidyr::pivot_longer(-year) |>
    dplyr::mutate(month = as.Date(sprintf("%d-%02d-01", as.integer(year),
                                          as.integer(stringr::str_remove(name, "V")) - 1L))) |>
    dplyr::filter(month <= as.Date(date_end)) |>
    dplyr::select(month, oceanic_nino_index = value)
  # -99.9 marks months NOAA hasn't published yet
  missing_months <- oni_data |>
    dplyr::filter(oceanic_nino_index == -99.9)
  if (nrow(missing_months) > 0) {
    stop("ONI not yet available for ",
         paste(missing_months$month, collapse = ", "))
  }
  oni_data
}

#' Read CMIP6 monthly SST climatologies for each model from the IPCC Atlas
#'
#' @description Reads monthly SST for every model in one Atlas experiment, for
#'   the 1 degree cells in the bounding box and the years given, over OPeNDAP
#'   (only that subset is transferred). Averages each calendar month across the
#'   years each model has data for, following the Atlas code. Retries if the
#'   server fails. Stops if the source doesn't have the expected number of
#'   models or every month of the period.
#' @param experiment Atlas experiment, e.g. "ssp126" or "historical".
#' @param file_dates Date range in the Atlas file name, e.g. "201501-210012".
#' @param years First and last year of the climatology.
#' @param n_models Number of models the experiment should have.
#' @param lon_range,lat_range Cells are kept when the lower-left corner of the
#'   1 degree cell is inside these ranges, inclusive.
#' @param base_url OPeNDAP base URL of the Atlas CMIP6 files.
#' @param max_attempts Attempts before giving up.
#' @return Tibble with lon_bin, lat_bin (lower-left corner of the 1 degree
#'   cell), member_id, month_number, n_years (years of data the mean uses),
#'   and sst_deg_c_mean (that model's mean SST for the calendar month). Land
#'   cells are dropped.
read_cmip6_climatology <- function(experiment, file_dates, years, n_models,
                                   lon_range, lat_range, base_url,
                                   max_attempts = 5) {
  url <- sprintf("%s/%s/sst_CMIP6_%s_mon_%s.nc", base_url, experiment, experiment, file_dates)
  read_once <- function() {
    nc <- ncdf4::nc_open(url)
    on.exit(ncdf4::nc_close(nc))
    lon <- as.vector(ncdf4::ncvar_get(nc, "lon"))
    lat <- as.vector(ncdf4::ncvar_get(nc, "lat"))
    time_units <- ncdf4::ncatt_get(nc, "time", "units")$value
    if (time_units != "days since 1850-01-01 00:00:00") stop("Unexpected time units: ", time_units)
    dates <- as.Date("1850-01-01") + as.vector(ncdf4::ncvar_get(nc, "time"))
    members <- as.vector(ncdf4::ncvar_get(nc, "member_id"))
    if (length(members) != n_models || anyDuplicated(members)) {
      stop(url, " has ", length(members), " models (", length(unique(members)),
           " unique), not the expected ", n_models)
    }
    ilon <- which(floor(lon) >= lon_range[1] & floor(lon) <= lon_range[2])
    ilat <- which(floor(lat) >= lat_range[1] & floor(lat) <= lat_range[2])
    it <- which(as.integer(format(dates, "%Y")) >= years[1] & as.integer(format(dates, "%Y")) <= years[2])
    expected_months <- 12L * (years[2] - years[1] + 1L)
    if (length(it) != expected_months || any(diff(it) != 1) ||
        !all(table(format(dates[it], "%m")) == years[2] - years[1] + 1L)) {
      stop(url, " does not have every month of ", years[1], "-", years[2])
    }
    # Array dimensions in R order: lon, lat, time, member
    sst <- ncdf4::ncvar_get(nc, "sst",
                            start = c(min(ilon), min(ilat), min(it), 1),
                            count = c(length(ilon), length(ilat), length(it), -1),
                            collapse_degen = FALSE)
    list(sst = sst, lon = lon[ilon], lat = lat[ilat], months = as.integer(format(dates[it], "%m")),
         members = members)
  }
  attempt <- 0
  repeat {
    attempt <- attempt + 1
    x <- tryCatch(read_once(), error = function(e) e)
    if (!inherits(x, "error")) break
    # Wrong contents won't fix themselves; only retry connection problems
    if (grepl("models|every month|time units", conditionMessage(x)) || attempt >= max_attempts) {
      stop("Reading ", url, " failed: ", conditionMessage(x))
    }
    message("Reading ", url, " failed (", conditionMessage(x), "); retrying")
    Sys.sleep(min(300, 15 * 2^(attempt - 1)))
  }

  # Years each model has data for (any cell with SST), recorded for
  # transparency. Some runs end before 2100 (e.g., CAMS-CSM1-0 and IITM-ESM),
  # and EC-Earth3-Veg-LR is listed for SSP5-8.5 but has no SST data at all
  has_data <- apply(!is.na(x$sst), c(3, 4), any)
  n_months_with_data <- colSums(has_data)
  if (all(n_months_with_data == 0)) stop(url, " has no data for ", years[1], "-", years[2])
  message(url, " ", years[1], "-", years[2], ": ", sum(n_months_with_data > 0), " of ",
          length(x$members), " models have data",
          if (any(n_months_with_data == 0)) paste0(" (none for ", paste(x$members[n_months_with_data == 0], collapse = ", "), ")") else "")

  # Each model's mean for each calendar month over the years it has data for:
  # the Atlas computes "the temporal mean for the whole target period" with
  # mean(na.rm = TRUE) (IPCC-WG1/Atlas, datasets-interactive-atlas/
  # 04_map_figures.R, lines 94-98; Iturbide et al. 2021,
  # doi:10.5281/zenodo.3691645)
  lapply(which(n_months_with_data > 0), function(k) {
    lapply(1:12, function(m) {
      use <- x$months == m
      climatology <- apply(x$sst[, , use, k, drop = FALSE], c(1, 2), mean, na.rm = TRUE)
      climatology[is.nan(climatology)] <- NA
      tibble::tibble(
        lon_bin = rep(floor(x$lon), times = length(x$lat)),
        lat_bin = rep(floor(x$lat), each = length(x$lon)),
        member_id = x$members[k],
        month_number = m,
        n_years = sum(has_data[use, k]),
        sst_deg_c_mean = as.vector(climatology)
      )
    }) |>
      dplyr::bind_rows()
  }) |>
    dplyr::bind_rows() |>
    dplyr::filter(!is.na(sst_deg_c_mean))
}

#' Multi-model mean CMIP6 SST climatology
#'
#' @description Averages the models' monthly climatologies across the models
#'   with SST in each cell, as the Atlas does: it takes the multi-model mean
#'   with mean(na.rm = TRUE) (IPCC-WG1/Atlas, datasets-interactive-atlas/
#'   04_map_figures.R, line 146; Iturbide et al. 2021,
#'   doi:10.5281/zenodo.3691645). Coastal cells can have fewer models, where
#'   some models' grids have land.
#' @param climatology Output of read_cmip6_climatology(), for one scenario and
#'   period.
#' @return Tibble with lon_bin, lat_bin, month_number, n_models (models with
#'   SST in the cell), and sst_deg_c_mean.
cmip6_ensemble_mean <- function(climatology) {
  climatology |>
    dplyr::group_by(lon_bin, lat_bin, month_number) |>
    dplyr::summarize(n_models = dplyr::n(), sst_deg_c_mean = mean(sst_deg_c_mean),
                     .groups = "drop")
}

#' Check the CMIP6 SST projections before the analysis uses them
#'
#' @description Guards against the problems found in the files previously
#'   downloaded by hand from the Interactive Atlas: every scenario and period
#'   must have all 12 months, each (scenario, period, month) must be a
#'   different field (identical fields mean one was saved under the wrong
#'   label), and values must be plausible SSTs.
#' @param forecast Tibble with scenario, time_period, month_number, lon_bin,
#'   lat_bin, and sst_deg_c_mean.
#' @param scenarios,time_periods Expected scenarios and periods.
#' @return forecast, sorted.
check_cmip6_forecast <- function(forecast, scenarios, time_periods) {
  combos <- dplyr::distinct(forecast, scenario, time_period, month_number)
  if (nrow(combos) != length(scenarios) * length(time_periods) * 12 ||
      !setequal(combos$scenario, scenarios) || !setequal(combos$time_period, time_periods)) {
    stop("CMIP6 forecast doesn't have all 12 months for every scenario and period")
  }
  if (anyDuplicated(forecast[c("scenario", "time_period", "month_number", "lon_bin", "lat_bin")])) {
    stop("CMIP6 forecast has duplicate cells")
  }
  fields <- forecast |>
    dplyr::arrange(lon_bin, lat_bin) |>
    dplyr::group_by(scenario, time_period, month_number) |>
    dplyr::summarize(hash = secretbase::sha256(paste(round(sst_deg_c_mean, 6), collapse = ",")),
                     .groups = "drop")
  if (anyDuplicated(fields$hash)) {
    stop("Some CMIP6 scenario/period/month fields are identical, so one is likely mislabelled")
  }
  if (any(forecast$sst_deg_c_mean < -3 | forecast$sst_deg_c_mean > 40)) {
    stop("CMIP6 forecast SST outside -3 to 40 degrees C")
  }
  dplyr::arrange(forecast, scenario, time_period, month_number, lon_bin, lat_bin)
}
