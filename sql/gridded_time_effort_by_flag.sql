SELECT
  TIMESTAMP_TRUNC(TIMESTAMP(date), {temporal_resolution}) AS {stringr::str_to_lower(temporal_resolution)},
  flag,
  lon_bin,
  lat_bin,
  SUM(fishing_hours) fishing_hours,
  SUM(fishing_kw_hours) fishing_kw_hours
FROM
  `{gridded_daily_effort_by_vessel_table}`
  WHERE
fishing_kw_hours > 0
GROUP BY
  {stringr::str_to_lower(temporal_resolution)},
  flag,
  lon_bin,
  lat_bin