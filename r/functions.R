## ---------------------------
## Script name: r/functions.R
## Author: Gavin McDonald, emLab, UC Santa Barbara
## Date: 2024-09-05
## Purpose:
## Functions for pipelines/analysis.R and the Quarto book. GFW functions are in
## r/gfw.R, and SST and ONI functions are in r/sst.R.
## ---------------------------

#' Check a file from another targets project exists
#'
#' @description The analysis project reads files the gfw and sst projects
#'   write (handoff_files in r/config.R). Gives a clear error if one is
#'   missing.
#' @param path Path of the file.
#' @param project Project that writes the file.
#' @return path, for format = "file" targets.
handoff_file <- function(path, project) {
  if (!file.exists(path)) {
    stop(path, " not found. Run the ", project, " project first: Rscript run.R ", project)
  }
  path
}

#' Write a parquet file without leaving a partial file behind
#'
#' @description Writes to a temporary file in the same directory, then renames
#'   it into place, so an interrupted write never leaves a truncated file at
#'   path.
#' @param x Data frame to write.
#' @param path Destination path.
#' @return path, for format = "file" targets.
write_parquet_atomic <- function(x, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp <- paste0(path, ".tmp-", Sys.getpid())
  on.exit(unlink(tmp), add = TRUE)
  nanoparquet::write_parquet(x, tmp)
  if (!file.rename(tmp, path)) stop("Could not move ", tmp, " to ", path)
  path
}

#' Write a CSV file without leaving a partial file behind
#'
#' @description Like write_parquet_atomic(), for small files people may want
#'   to read directly.
#' @param x Data frame to write.
#' @param path Destination path.
#' @return path, for format = "file" targets.
write_csv_atomic <- function(x, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp <- paste0(path, ".tmp-", Sys.getpid())
  on.exit(unlink(tmp), add = TRUE)
  data.table::fwrite(x, tmp)
  if (!file.rename(tmp, path)) stop("Could not move ", tmp, " to ", path)
  path
}

#' Number of parallel workers to use
#'
#' @description One less than the cores available to this session (e.g., a
#'   Slurm job's allocation), at least 1. A function rather than a value, so
#'   running on a machine with a different number of cores doesn't make
#'   targets rerun the steps that use it.
#' @return Integer.
n_workers <- function() {
  max(1L, parallelly::availableCores() - 1L)
}

#' Check a joined dataset before the analysis uses it
#'
#' @param data Joined dataset.
#' @param keys Columns that should uniquely identify a row.
#' @param no_na Columns that should have no NA values.
#' @param months Months the dataset should cover, exactly.
#' @return data, unchanged.
check_joined_dataset <- function(data, keys, no_na, months) {
  if (anyDuplicated(data[keys])) {
    stop("Joined dataset is not unique on ", paste(keys, collapse = ", "))
  }
  has_na <- no_na[vapply(no_na, function(column) anyNA(data[[column]]), logical(1))]
  if (length(has_na) > 0) {
    stop("Joined dataset has NA values in ", paste(has_na, collapse = ", "))
  }
  data_months <- sort(unique(as.Date(data$month)))
  if (!identical(data_months, sort(as.Date(months)))) {
    stop("Joined dataset covers months ", min(data_months), " to ", max(data_months),
         " (", length(data_months), " months), not the expected ",
         min(months), " to ", max(months), " (", length(months), " months)")
  }
  data
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