# Run the targets projects ----
# Usage, from the repo root:
#   Rscript run.R                  # all three projects, in order
#   Rscript run.R gfw              # GFW BigQuery tables (needs GFW access)
#   Rscript run.R sst              # NOAA SST and ONI (needs internet)
#   Rscript run.R analysis         # joins and Quarto book (local files only)
#   Rscript run.R outdated [project ...]  # list outdated; builds nothing
# Each project has its own script in pipelines/ and its own store. This
# rewrites _targets.yaml first, so it always points at the right ones. To work
# with a project interactively, run write_targets_config() (from r/config.R)
# and Sys.setenv(TAR_PROJECT = "analysis"), then use targets as usual, e.g.
# targets::tar_read(joined_dataset_ais).

source("r/config.R")

# All dates and times in the pipeline are UTC. Setting this also saves R from
# asking the system for its time zone, which times out on some servers
Sys.setenv(TZ = "UTC")

args <- commandArgs(trailingOnly = TRUE)
outdated_only <- length(args) > 0 && args[1] == "outdated"
if (outdated_only) {
  args <- args[-1]
}
projects <- if (length(args) == 0) targets_projects else args
unknown <- setdiff(projects, targets_projects)
if (length(unknown) > 0) {
  stop(
    "Unknown project: ",
    paste(unknown, collapse = ", "),
    ". Choose from: ",
    paste(targets_projects, collapse = ", ")
  )
}
# Run in pipeline order, whatever order they were given in
projects <- intersect(targets_projects, projects)

write_targets_config()

for (project in projects) {
  Sys.setenv(TAR_PROJECT = project)
  if (outdated_only) {
    outdated <- targets::tar_outdated()
    cat(project, ": ", length(outdated), " outdated targets\n", sep = "")
    if (length(outdated) > 0) cat(paste0("  ", sort(outdated), "\n"), sep = "")
  } else {
    message("Running the ", project, " project")
    targets::tar_make()
    errored <- targets::tar_meta(fields = error, complete_only = TRUE)
    if (nrow(errored) > 0) {
      stop(
        "The ",
        project,
        " project has errored targets: ",
        paste(errored$name, collapse = ", ")
      )
    }
  }
}
