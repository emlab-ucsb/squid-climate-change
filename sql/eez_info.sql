  #### Define our pixel size for aggregation
CREATE TEMPORARY FUNCTION
  pixel_size() AS ({spatial_resolution});
WITH
  # Select pixels in ocean (i.e., where elevation is less than 0)
  ocean_pixels AS(
  SELECT
    FORMAT("lon:%+07.2f_lat:%+07.2f", ROUND(lon/0.01)*0.01, ROUND(lat/0.01)*0.01) AS gridcode
  FROM
    `world-fishing-827.pipe_static.bathymetry`
  WHERE
    elevation_m < 0 ),
  full_resolution_info AS(
  SELECT
    FLOOR(CAST(SUBSTR(gridcode, 17, 7) AS FLOAT64) / pixel_size()) * pixel_size() lat_bin,
    FLOOR(CAST(SUBSTR(gridcode, 5, 7) AS FLOAT64) / pixel_size()) * pixel_size() lon_bin,
    eez_id
  FROM
    `world-fishing-827.pipe_static.regions`
    # Only calculate for pixels that are in ocean
  JOIN
    ocean_pixels
  USING
    (gridcode)
  LEFT JOIN
    UNNEST(regions.eez) eez_id),
  # Summarize EEZ count in each pixel
  eez_count_by_pixel AS(
  SELECT
    # Need to cast these as strings for partitioning below
    CAST(lat_bin AS STRING) lat_bin,
    CAST(lon_bin AS STRING) lon_bin,
    CAST(eez_id AS INT64) eez_id,
    COUNT(*) eez_count
  FROM
    full_resolution_info
  GROUP BY
    lat_bin,
    lon_bin,
    eez_id),
  eez_info AS(
  SELECT
    *
  FROM
    `world-fishing-827.gfw_research.eez_info` ),
  # Select best EEZ for each pixel
  eez_by_pixel AS(
  SELECT
    lat_bin,
    lon_bin,
    eez_id
  FROM
    eez_count_by_pixel
    # FOr each pixel, just pick eez_id that has the most counts
  QUALIFY
    ROW_NUMBER() OVER (PARTITION BY lat_bin, lon_bin ORDER BY eez_count DESC) = 1),
  # Now make this spatial
  eez_by_pixel_spatial AS(
  SELECT
    lat_bin,
    lon_bin,
    ST_GEOGPOINT(CAST(lon_bin AS FLOAT64),CAST(lat_bin AS FLOAT64)) pixel_corner,
    eez_id
  FROM
    eez_by_pixel),
  high_seas_pixels AS(
  SELECT
    lat_bin,
    lon_bin,
    pixel_corner
  FROM
    eez_by_pixel_spatial
  WHERE
    eez_id IS NULL ),
  in_eez_pixels AS(
  SELECT
    pixel_corner pixel_corner_eez,
    eez_id nearest_eez_id
  FROM
    eez_by_pixel_spatial
  WHERE
    NOT eez_id IS NULL ),
  distance_from_high_seas_pixels_to_nearest_eez AS(
  SELECT
    lat_bin,
    lon_bin,
    ST_DISTANCE(pixel_corner, pixel_corner_eez, TRUE) distance_to_nearest_eez_m,
    nearest_eez_id
  FROM
    high_seas_pixels
  CROSS JOIN
    in_eez_pixels
    # FOr each pixel, just pick nearest eez
  QUALIFY
    ROW_NUMBER() OVER (PARTITION BY lat_bin, lon_bin ORDER BY distance_to_nearest_eez_m ASC) = 1 )
# Now join everything together
SELECT
  CAST(lon_bin AS FLOAT64) lon_bin,
  CAST(lat_bin AS FLOAT64) lat_bin,
  IFNULL(CAST(eez_id AS STRING),'high_seas') eez_id,
  distance_to_nearest_eez_m,
  nearest_eez_id
FROM
  eez_by_pixel
LEFT JOIN
  distance_from_high_seas_pixels_to_nearest_eez
USING
  (lon_bin,
    lat_bin)
# Add eez info
LEFT JOIN
  eez_info
USING
  (eez_id)