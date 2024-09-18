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
  theme_minimal() %+replace%
    theme(panel.background = element_rect(fill = "black"),
          legend.position = "bottom",
          legend.direction = "horizontal",
          plot.title = element_text(hjust = 0.5),
          panel.grid.minor = element_line(color = "black"),
          panel.grid.major = element_line(color = "black"),
          axis.text.x = element_blank(),
          axis.ticks.x = element_blank(),
          axis.title.y = element_blank(),
          axis.text.y = element_blank(),
          axis.ticks.y = element_blank(),
          strip.background = element_rect(fill=NA,color=NA),
          plot.margin = unit(c(0.25,0,0,0), "cm"))
}

# Set consistent theme for all other plots
theme_plot <- function(){
  theme_minimal() %+replace%
    theme(axis.title.x = element_text(face = "bold"),
          axis.title.y = element_text(angle = 90,
                                      face = "bold",
                                      vjust = 3),
          strip.text.x = element_text(angle = 0,
                                      face = "bold"),
          strip.text.y = element_text(angle = 0,
                                      face = "bold"))} 
