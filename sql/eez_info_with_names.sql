SELECT
  lon_bin,
  lat_bin,
  eez_id,
  IFNULL(distance_to_nearest_eez_m,0) distance_to_nearest_eez_m,
  IFNULL(CAST(nearest_eez_id AS STRING),eez_id) nearest_eez_id,
  IFNULL(pixel_sovereign1_iso3,'high_seas') pixel_sovereign1_iso3,
  IFNULL(nearest_sovereign1_iso3,pixel_sovereign1_iso3) nearest_sovereign1_iso3
FROM
  `emlab-gcp.squid_climate_change.eez_info`
LEFT JOIN (
  SELECT
    CAST(eez_id AS STRING) eez_id,
    sovereign1_iso3 pixel_sovereign1_iso3
  FROM
    `world-fishing-827.gfw_research.eez_info`)
USING
  (eez_id)
LEFT  JOIN (
  SELECT
    eez_id nearest_eez_id,
    sovereign1_iso3 nearest_sovereign1_iso3
  FROM
    `world-fishing-827.gfw_research.eez_info`)
USING
  (nearest_eez_id)