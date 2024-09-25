WITH
  # Create list of all dates in time series
  date_list AS(
  SELECT
    *
  FROM
    UNNEST(GENERATE_DATE_ARRAY((
        SELECT
          MIN(date)
        FROM
          `emlab-gcp.squid_climate_change.viirs_smallest_zenith`), (
        SELECT
          MAX(date)
        FROM
          `emlab-gcp.squid_climate_change.viirs_smallest_zenith`), INTERVAL 1 DAY)) AS date),
  # Create half month indicator for each date
  date_list_with_half_month AS(
  SELECT
    date,
    # define half month colum
    CONCAT(EXTRACT(YEAR
      FROM
        date), LPAD(CAST(EXTRACT(MONTH
          FROM
            date) AS STRING), 2, '0'),
    IF
      (EXTRACT(DAY
        FROM
          date) <= 15, 'F', 'S' )) AS year_half_month
  FROM
    date_list),
  # Add half month indicator to viirs detection data
  detections_with_half_month AS(
  SELECT
    *
  FROM
    `emlab-gcp.squid_climate_change.viirs_smallest_zenith`
  JOIN
    date_list_with_half_month
  USING
    (date) ),
  # For each date and half month, count number of detections
  count_viirs_total AS (
  SELECT
    year_half_month,
    date,
    lat_bin,
    lon_bin,
    COUNT(DISTINCT detect_id) AS count_viirs_grid_half_month
  FROM
    detections_with_half_month
  GROUP BY
    year_half_month,
    lat_bin,
    lon_bin,
    date ),
  # get the dates that maximum number of VIIRS detections are observed for each area and half month
  count_viirs_half_month_max_date AS (
  SELECT
    MAX(count_viirs_grid_half_month) max_count_viirs_grid_half_month,
    year_half_month,
    lat_bin,
    lon_bin
    FROM
    count_viirs_total
    GROUP BY
    year_half_month,
    lat_bin,
    lon_bin
    ),
  # Now use max detections per half month and apply this to every date in each half month
  expanded_detections_per_date AS(
  SELECT
    *
  FROM
    count_viirs_half_month_max_date
  JOIN
    date_list_with_half_month
  USING
    (year_half_month))
SELECT
  TIMESTAMP_TRUNC(TIMESTAMP(date), MONTH) AS month,
  CAST(lat_bin AS FLOAT64) lat_bin,
  CAST(lon_bin AS FLOAT64) lon_bin,
  SUM(max_count_viirs_grid_half_month) viirs_detections
FROM
  expanded_detections_per_date
GROUP BY
  month,
  lon_bin,
  lat_bin