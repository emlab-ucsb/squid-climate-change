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

# Set target options:
tar_option_set(
  packages = c() # Packages that your targets need for their tasks.
)

# Run the R scripts in the R/ folder with your custom functions:
tar_source("r/functions")

# Replace the target list below with your own:
list(
  # Make quarto notebook -----
  tar_quarto(
    name = quarto_book,
    path = "qmd",
    quiet = FALSE
  )
)
