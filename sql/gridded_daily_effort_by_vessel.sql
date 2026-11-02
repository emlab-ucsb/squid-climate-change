  #### Define our pixel size for aggregation
CREATE TEMPORARY FUNCTION
  pixel_size() AS ({spatial_resolution});
WITH
  -- Get vessel info data
  vessel_data AS(
  SELECT
  *
  FROM
  `emlab-gcp.squid_climate_change.squid_vessel_list`
  ),
  -- Get all AIS message data from GFW's pipeline 5 (V5) messages table
  -- 0.25 is a power of two, so FLOAT64 binning is exact here (no need for the
  -- NUMERIC binning megafauna-and-fronts uses for 0.01 degree pixels)
  daily_gridded_ais_data AS (
  SELECT
    ssvid,
    flag,
    DATE(timestamp) date,
    FLOOR(lon / pixel_size()) * pixel_size() AS lon_bin,
    FLOOR(lat / pixel_size()) * pixel_size() AS lat_bin,
    SUM(hours) fishing_hours,
    SUM(hours * engine_power_kw) fishing_kw_hours
  FROM
    `{gfw_messages_table}`
  JOIN
    vessel_data
  USING
    (ssvid)
  WHERE
    DATE(timestamp) BETWEEN {ais_date_start}
    AND {ais_date_end}
    AND clean_segs
    # Squid fishing heuristic for whether or not its fishing - it's very simple
    # In V5, night_loitering is an INT64 of 0 or 1
    AND night_loitering > 0.5
  GROUP BY
    ssvid,
    date,
    flag,
    lat_bin,
    lon_bin)
SELECT
  *
FROM
  daily_gridded_ais_data