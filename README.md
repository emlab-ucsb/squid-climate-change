# squid-climate-change

The live quarto notebook detailing the analysis can be found [here](https://emlab-ucsb.github.io/squid-climate-change).

This analysis is for the analysis: "Toward sustainable and resilient fisheries management for the Humboldt squid deep-water fishery", a project for Environmental Defense Fund

# Reproducibility  

## Package management  

To manage package dependencies, we use the `renv` package. When you first clone this repo onto your machine, run `renv::restore()` to ensure you have all correct package versions installed in the project. Please see the [renv website](https://rstudio.github.io/renv/articles/renv.html) for more information.

## Data processing and analysis pipeline

To ensure reproducibility in the data processing and analysis pipeline, we use the `targets` package. Targets is a Make-like pipeline tool. Using targets means that anytime an upstream change is made to the data or models, all downstream components of the data processing and analysis will be re-run automatically when the `targets::tar_make()` command is run. It also means that once components of the analysis have already been run and are up-to-date, they will not need to be re-run. All objects are cached in the `_targets` directory. Please see the [targets website](https://github.com/ropensci/targets) for more information. The `_targets` cache directory, and all other data, are stored on emLab's internal GRIT/Nextcloud data storage space.


In order to see what the targets pipeline looks like, you can run `targets::tar_manifest()` or `targets::tar_visnetwork()`, which also shows which targets are current or out-of-date.

# Repository Structure 

The repository uses the following basic structure:  
```
squid-climate-change
  |__ docs
  |__ qmd
  |__ r
  |__ renv
  |__ sql
```
