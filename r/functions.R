## ---------------------------
## Script name: r/functions.R
## Author: Gavin McDonald, emLab, UC Santa Barbara
## Date: 2024-079-05
## Purpose:
## All functions that will be used in the targets pipeline
## ---------------------------
## Notes:
##   
## ---------------------------

# This function pulls the necessary GFW data and stores it into a destination table
# This requires special permissions, and is also very expensive to run, so will not be done often
run_gfw_query_and_save_table <- function(sql, 
                                         bq_table_name, 
                                         bq_dataset, 
                                         billing_project, 
                                         bq_project,
                                         # By default:  If the table already exists, BigQuery overwrites the table data
                                         # With "WRITE_APPEND": If the table already exists, BigQuery appends the data to the table.
                                         write_disposition = 'WRITE_TRUNCATE',
                                         ...){
  
  # Specify table where query results will be saved
  bq_table <- bigrquery::bq_table(project = bq_project,
                                  table = bq_table_name,
                                  dataset = bq_dataset)
  
  # Run query and save on BQ. We don't pull this locally yet.
  bigrquery::bq_project_query(billing_project,
                              sql,
                              destination_table = bq_table,
                              use_legacy_sql = FALSE,
                              allowLargeResults = TRUE,
                              write_disposition = write_disposition)
  
  # Return table metadata, for targets to know if something changed
  bigrquery::bq_table_meta(bq_table)
}

# This function pulls GFW data locally using an arbitrary SQL command
pull_gfw_data_locally_arbitrary <- function(sql, billing_project, ...){
  bigrquery::bq_project_query(billing_project, 
                              sql) |>
    bigrquery::bq_table_download(n_max = Inf)
}

# Set consistent theme for maps
# Based loosely off fishwatchr::theme_gfw_map()
# https://github.com/GlobalFishingWatch/fishwatchr/blob/master/R/theme_gfw_map.R
theme_map <- function(){
  ggplot2::theme_minimal() %+replace%
    ggplot2::theme(panel.background = ggplot2::element_rect(fill = "black"),
          legend.position = "bottom",
          legend.direction = "horizontal",
          plot.title = ggplot2::element_text(hjust = 0.5),
          panel.grid.minor = ggplot2::element_line(color = "black"),
          panel.grid.major = ggplot2::element_line(color = "black"),
          axis.text.x = ggplot2::element_blank(),
          axis.ticks.x = ggplot2::element_blank(),
          axis.title.y = ggplot2::element_blank(),
          axis.text.y = ggplot2::element_blank(),
          axis.ticks.y = ggplot2::element_blank(),
          strip.background = ggplot2::element_rect(fill=NA,color=NA),
          plot.margin = unit(c(0.25,0,0,0), "cm"))
}

# Set consistent theme for all other plots
theme_plot <- function(){
  ggplot2::theme_minimal() %+replace%
    ggplot2::theme(axis.title.x = ggplot2::element_text(face = "bold"),
          axis.title.y = ggplot2::element_text(angle = 90,
                                      face = "bold",
                                      vjust = 3),
          strip.text.x = ggplot2::element_text(angle = 0,
                                      face = "bold"),
          strip.text.y = ggplot2::element_text(angle = 0,
                                      face = "bold"))} 

# Wrapper for downloading and saving ERDDAP data from NOAA
download_erddap_wrapper <- function(dataset_name,
                                    date_start,
                                    date_end,
                                    download_path_base){
  
  date_range <- seq(as.Date(date_start),as.Date(date_end), "days") |>
    as.character()
  
  purrr::map_df(date_range,function(data_date){
    # If file has already been downloaded, can skip download
    download_path <- glue::glue("{download_path_base}/{dataset_name}_{stringr::str_replace_all(data_date,'-','_')}.csv")
    
    if(file.exists(download_path)){
      print(glue::glue("{data_date} already exists, skipping download"))
      return(tibble::tibble(data_date = data_date,
                            download_path = download_path,
                            download_timestamp =Sys.time(),
                            error = NA))
    }
    
    # Keep trying til it works: https://stackoverflow.com/a/63341321
    ntry <- 0
    max_tries <- 10
    repeat{
      fl <- tryCatch(
        downloaded_data <- rerddap::griddap(dataset_name, 
                                            time = c(data_date, data_date)),
        error = function(e) e
      )
      not.yet <- inherits(fl, "error")
      if(not.yet){
        print(glue::glue("{data_date} download re-trying"))
        Sys.sleep(5)}
      else break
      ntry <- ntry + 1
      if(ntry > max_tries) {
        print(glue::glue("{data_date} download failed after {max_tries} tries"))
        return(tibble::tibble(data_date = data_date,
                              download_path = "download_failed",
                              download_timestamp =NA,
                              error = fl$message))
      }
    }
    
    data_tibble <- downloaded_data$data |>
      dplyr::select(-zlev) |>
      tibble::as_tibble()
    
    # We noticed there is an error in the 2023-02-01 file - it incorrectly gives the data as 2023-01-31
    # So we need to manually fix it
    if(data_date=="2023-02-01") data_tibble <- data_tibble |>
      collapse::fmutate(time = lubridate::ymd_hms("2023-02-01 12:00:00"))
    
    data.table::fwrite(data_tibble,
                       download_path)
    
    print(glue::glue("{data_date} download complete"))
    
    return(tibble::tibble(data_date = data_date,
                          download_path = download_path,
                          download_timestamp =Sys.time(),
                          error = NA))
    
  })
}

spatio_temporal_aggregate <- function(file_list,
                                      spatial_resolution,
                                      temporal_resolution){
  
  temporal_resolution_lower <- stringr::str_to_lower(temporal_resolution)
  
  file_list |>
    purrr::map(function(data_file){
      data_file |>
        data.table::fread(select = c("time","longitude","latitude","sst"))  |>
        collapse::fsubset(!is.na(sst)) |>
        collapse::fmutate(month = lubridate::floor_date(time, temporal_resolution_lower),
                          lon_bin = floor(longitude / spatial_resolution) * spatial_resolution,
                          lat_bin = floor(latitude / spatial_resolution) * spatial_resolution)}) |>
    data.table::rbindlist() |>
    collapse::collap(FUN = list(sst_deg_c_mean = collapse::fmean,
      sst_deg_c_sd = collapse::fsd,
    sst_deg_c_min = collapse::fmin,
  sst_deg_c_max = collapse::fmax),
                     by = ~ month + lon_bin + lat_bin,
                     cols = "sst")|> 
    dplyr::rename_with(~stringr::str_remove_all(.,".sst"), .cols = everything())
}

# Pull NOAA Oceanic Nino Index (ONI) data
pull_oni_data <- function(){
  read.table(url("https://psl.noaa.gov/data/correlation/oni.data"),skip=1,nrows=75) |>
    tibble::as_tibble() |>
    dplyr::rename(year = V1) |>
    tidyr::pivot_longer(-year) |>
    dplyr::mutate(month = stringr::str_remove_all(name,"V") |>
                    as.numeric() - 1,
                  month = lubridate::ymd(glue::glue("{year}-{month}-1"))) |>
    dplyr::filter(month < lubridate::ymd("2024-08-01")) |>
    dplyr::select(month,oceanic_nino_index = value)
}

# Load all cliamte change SST forecast data, process into tidy tibble
process_sst_cc_forecast_data <- function(project_directory){
  list.files(glue::glue("{project_directory}/data/raw/ipcc_wgi_climate_forecasts"), full.names = TRUE) |>
  purrr::map_df(function(file_name){
    
    
    file_info_tibble <- tibble::tibble(file_name = file_name) |>
      dplyr::mutate(time_period = dplyr::case_when(stringr::str_detect(file_name,"Long Term") ~ "Long Term (2081-2100)",
                                                   stringr::str_detect(file_name,"Medium Term") ~ "Medium Term (2041-2060)",
                                                   stringr::str_detect(file_name,"Near Term") ~ "Near Term (2021-2040)")) |>
      dplyr::mutate(scenario = dplyr::case_when(stringr::str_detect(file_name,"SSP1-2.6") ~ "SSP1-2.6",
                                                stringr::str_detect(file_name,"SSP2-4.5") ~ "SSP2-4.5",
                                                stringr::str_detect(file_name,"SSP3-7.0") ~ "SSP3-7.0",
                                                stringr::str_detect(file_name,"SSP5-8.5 ") ~ "SSP5-8.5")) |>
      dplyr::mutate(month = dplyr::case_when(stringr::str_detect(file_name,"January") ~ "January",
                                             stringr::str_detect(file_name,"February") ~ "February",
                                             stringr::str_detect(file_name,"March") ~ "March",
                                             stringr::str_detect(file_name,"April") ~ "April",
                                             stringr::str_detect(file_name,"May") ~ "May",
                                             stringr::str_detect(file_name,"June") ~ "June",
                                             stringr::str_detect(file_name,"July") ~ "July",
                                             stringr::str_detect(file_name,"August") ~ "August",
                                             stringr::str_detect(file_name,"September") ~ "September",
                                             stringr::str_detect(file_name,"October") ~ "October",
                                             stringr::str_detect(file_name,"November") ~ "November",
                                             stringr::str_detect(file_name,"December") ~ "December")) |>
      dplyr::select(-file_name)
    
    file_name |>
      terra::rast() |>
      tidyterra::as_tibble(xy = TRUE) |>
      dplyr::select(lon_bin = x,
                    lat_bin = y,
                    sst_deg_c_mean = tos) |>
      dplyr::filter(!is.na(sst_deg_c_mean)) |>
      tidyr::crossing(file_info_tibble)|>
      dplyr::mutate(month_number = match(month, month.name))  |>
      # Don't need month name column now
      dplyr::select(-month) |>
      # Data is at 1x1 degree resolution. Make lon/lat bin at lower left corner instead of centroid, for easy joining
      dplyr::mutate(lon_bin = floor(lon_bin),
                    lat_bin = floor(lat_bin))
  })}

make_bounding_box <- function(analysis_scope_lon,
                              analysis_scope_lat){
  
  analysis_bounding_box_point1 <- data.frame(geometry = glue::glue("POINT ({analysis_scope_lon[1]} {analysis_scope_lat[1]})")) |> 
    sf::st_as_sf(wkt = "geometry", crs = "WGS84") 
  analysis_bounding_box_point2 <- data.frame(geometry = glue::glue("POINT ({analysis_scope_lon[2]} {analysis_scope_lat[2]})")) |> 
    sf::st_as_sf(wkt = "geometry", crs = "WGS84") 
  
  analysis_bounding_box <- dplyr::bind_rows(analysis_bounding_box_point1,
                                            analysis_bounding_box_point2) |>
    sf::st_bbox() |> 
    sf::st_as_sfc(crs = "WGS84")
}