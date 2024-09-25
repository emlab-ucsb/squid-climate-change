CREATE TEMP FUNCTION
  RAD_THRESHOLD() AS (10);
SELECT
    TIMESTAMP_TRUNC(TIMESTAMP(date), {temporal_resolution}) AS {stringr::str_to_lower(temporal_resolution)},
    CAST(lon_bin AS FLOAT64) lon_bin,
    CAST(lat_bin AS FLOAT64) lat_bin,
  COUNT(DISTINCT detect_id) viirs_detections
FROM
  `emlab-gcp.squid_climate_change.viirs_smallest_zenith`
  # Require radiance be above this threshold to be considered a squid vessel
WHERE
  Rad_DNB > RAD_THRESHOLD()
GROUP BY
  {stringr::str_to_lower(temporal_resolution)},
  lon_bin,
  lat_bin