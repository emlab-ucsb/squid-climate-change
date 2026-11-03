## ---------------------------
## Script name: r/gfw.R
## Purpose:
## Functions for pipelines/gfw.R: build the AIS tables in BigQuery from GFW
## data, and export the tables the analysis uses to local parquet files.
## Running queries against GFW tables requires special permissions, and the
## effort query is expensive (~$84), so the functions guard against both
## overwriting tables and runaway costs.
## ---------------------------

#' Full name of a BigQuery table
#'
#' @param table A bigrquery::bq_table().
#' @return Character string, "project.dataset.table".
bq_table_full_name <- function(table) {
  paste(table$project, table$dataset, table$table, sep = ".")
}

#' Description that records which SQL built a table
#'
#' @description create_bq_table() stores this in the table's description, so
#'   a later run can tell whether an existing table was built from the same
#'   SQL.
#' @param sql The full SQL the table is built from, after glue substitution.
#' @return Character string.
bq_table_fingerprint <- function(sql) {
  # paste0() drops the glue class, so this hashes the SQL text itself
  paste0(
    "Built by the squid-climate-change gfw targets pipeline. sql_sha256: ",
    secretbase::sha256(paste0(sql))
  )
}

#' Stable summary of a BigQuery table, for targets to track
#'
#' @description Full table metadata includes fields that change on their own
#'   (e.g., long-term storage bytes), which would make downstream targets
#'   rerun. This keeps only what identifies the table's contents.
#' @param table A bigrquery::bq_table().
#' @return List with the table's full name, last modified time, and row count.
bq_table_info <- function(table) {
  meta <- bigrquery::bq_table_meta(table)
  list(
    table = bq_table_full_name(table),
    last_modified_time = meta$lastModifiedTime,
    num_rows = meta$numRows
  )
}

#' Build a versioned BigQuery table from a query, without ever overwriting
#'
#' @description Runs the query into a new table. Versioned tables are
#'   immutable:
#'   * If the table already exists and was built from the same SQL (its
#'     description holds the SQL's fingerprint), returns it without running
#'     the query, at no cost.
#'   * If it exists but was built from different SQL, or the fingerprint is
#'     missing, stops. Bump the table version to rebuild.
#'   Before running, dry-runs the query (free) and stops if it would bill
#'   more than max_bytes_billed. BigQuery also enforces that cap on the query
#'   itself, and writes with WRITE_EMPTY, so the query can't overwrite data.
#' @param sql SQL to run, after glue substitution.
#' @param table_name Name of the table to create.
#' @param bq_dataset,bq_project Dataset and project of the table.
#' @param billing_project Project billed for the query.
#' @param max_bytes_billed Most bytes the query may bill.
#' @return bq_table_info() of the table.
create_bq_table <- function(
  sql,
  table_name,
  bq_dataset,
  bq_project,
  billing_project,
  max_bytes_billed
) {
  sql <- paste0(sql)
  table <- bigrquery::bq_table(
    project = bq_project,
    dataset = bq_dataset,
    table = table_name
  )
  full_name <- bq_table_full_name(table)
  fingerprint <- bq_table_fingerprint(sql)

  if (bigrquery::bq_table_exists(table)) {
    description <- bigrquery::bq_table_meta(table)$description
    if (identical(description, fingerprint)) {
      message(
        full_name,
        " already exists and was built from this SQL; not re-running the query"
      )
      return(bq_table_info(table))
    }
    stop(
      full_name,
      " already exists, but its description does not match ",
      "this SQL's fingerprint (",
      if (is.null(description)) "no description" else description,
      "). Versioned tables are never overwritten. If the SQL or its inputs ",
      "changed, bump the table version in r/config.R. If you know the ",
      "table was built from this exact SQL (e.g., the run stopped before ",
      "recording the fingerprint), set its description to: ",
      fingerprint
    )
  }

  bytes <- as.numeric(bigrquery::bq_perform_query_dry_run(
    sql,
    billing = billing_project
  ))
  if (bytes > max_bytes_billed) {
    stop(
      "Query for ",
      full_name,
      " would bill ",
      signif(bytes / 1024^4, 4),
      " TiB, more than the ",
      signif(max_bytes_billed / 1024^4, 4),
      " TiB cap (gfw_max_bytes_billed in r/config.R). Not running it."
    )
  }
  message(
    "Running query for ",
    full_name,
    ": dry run estimates ",
    signif(bytes / 1024^4, 4),
    " TiB"
  )

  job <- bigrquery::bq_perform_query(
    sql,
    billing = billing_project,
    destination_table = table,
    create_disposition = "CREATE_IF_NEEDED",
    write_disposition = "WRITE_EMPTY",
    use_legacy_sql = FALSE,
    # bigrquery merges this into the job request; BigQuery fails the query,
    # without billing it, if it would bill more than this
    configuration = list(
      query = list(
        maximumBytesBilled = format(max_bytes_billed, scientific = FALSE)
      )
    )
  )
  bigrquery::bq_job_wait(job, quiet = TRUE)
  billed <- as.numeric(
    bigrquery::bq_job_meta(job)$statistics$query$totalBytesBilled
  )
  message(
    "Created ",
    full_name,
    "; billed ",
    signif(billed / 1024^4, 4),
    " TiB (job ",
    job$job,
    ")"
  )

  # Record which SQL built the table. ALTER TABLE ... SET OPTIONS is free
  ddl <- sprintf(
    'ALTER TABLE `%s` SET OPTIONS (description = "%s")',
    full_name,
    fingerprint
  )
  bigrquery::bq_job_wait(
    bigrquery::bq_perform_query(ddl, billing = billing_project),
    quiet = TRUE
  )

  bq_table_info(table)
}

#' Refer to a legacy BigQuery table that the pipeline must not rebuild
#'
#' @description The VIIRS tables were built in October 2024, unversioned, by
#'   sql/get_viirs_without_noise.sql, sql/viirs_smallest_zenith.sql, and
#'   sql/gridded_viirs_detections.sql. They are frozen: the pipeline reads them
#'   but never re-runs those queries. Stops if the table changed since it was
#'   frozen.
#' @param table_name Name of the table.
#' @param bq_dataset,bq_project Dataset and project of the table.
#' @param expected_last_modified_time The table's lastModifiedTime (ms since
#'   epoch, as a string) when it was frozen.
#' @return bq_table_info() of the table.
frozen_bq_table <- function(
  table_name,
  bq_dataset,
  bq_project,
  expected_last_modified_time
) {
  table <- bigrquery::bq_table(
    project = bq_project,
    dataset = bq_dataset,
    table = table_name
  )
  info <- bq_table_info(table)
  if (!identical(info$last_modified_time, expected_last_modified_time)) {
    stop(
      info$table,
      " was modified at ",
      info$last_modified_time,
      " (ms since epoch), but was frozen at ",
      expected_last_modified_time,
      ". Someone rebuilt or changed it; check before using it."
    )
  }
  info
}

#' Export a BigQuery table to a local parquet file
#'
#' @description Downloads the whole table (free: it reads the table directly
#'   instead of querying it), converts TIMESTAMP month columns to dates, and
#'   sorts the rows by key_columns, so re-exporting an unchanged table gives an
#'   identical file and nothing downstream reruns.
#' @param table_info bq_table_info() of the table.
#' @param key_columns Columns that uniquely identify a row. Stops if they
#'   don't.
#' @param path Destination parquet path.
#' @return path, for format = "file" targets.
export_bq_table <- function(table_info, key_columns, path) {
  parts <- strsplit(table_info$table, ".", fixed = TRUE)[[1]]
  data <- bigrquery::bq_table_download(
    bigrquery::bq_table(parts[1], parts[2], parts[3]),
    n_max = Inf,
    quiet = TRUE
  ) |>
    dplyr::mutate(dplyr::across(dplyr::any_of("month"), as.Date)) |>
    dplyr::arrange(dplyr::across(dplyr::all_of(key_columns)))
  if (nrow(data) != as.numeric(table_info$num_rows)) {
    stop(
      "Downloaded ",
      nrow(data),
      " rows from ",
      table_info$table,
      ", but the table has ",
      table_info$num_rows
    )
  }
  if (anyDuplicated(data[key_columns])) {
    stop(
      table_info$table,
      " is not unique on ",
      paste(key_columns, collapse = ", ")
    )
  }
  write_parquet_atomic(data, path)
}
