CREATE TEMP FUNCTION
  RAD_THRESHOLD() AS (10);
CREATE TEMPORARY FUNCTION
  pixel_size() AS ({spatial_resolution});
WITH
  # Take filtered detections data, add columns for binned lat and lon
  gridded_data AS(
  SELECT
    *,
    CAST(FLOOR(Lon_DNB / pixel_size()) * pixel_size() AS STRING) AS lon_bin,
    CAST(FLOOR(Lat_DNB / pixel_size()) * pixel_size() AS STRING) AS lat_bin
  FROM
    `emlab-gcp.squid_climate_change.filtered_viirs`
    # Require radiance be above this threshold to be considered a squid vessel
  WHERE
    Rad_DNB > RAD_THRESHOLD()),
  ###########################################################################
  # Select orbit having smallest zenith angle for each grid and local night
  smallest_zenith_orbit AS (
  SELECT
    date,
    lat_bin,
    lon_bin,
    OrbitNumber,
    ROW_NUMBER() OVER (PARTITION BY date, lat_bin, lon_bin ORDER BY SATZ_GDNBO) AS rownum
  FROM
    gridded_data
  QUALIFY
    rownum = 1 )
SELECT
  *
FROM
  gridded_data
JOIN
  smallest_zenith_orbit
USING
  (date,
    lat_bin,
    lon_bin,
    OrbitNumber)