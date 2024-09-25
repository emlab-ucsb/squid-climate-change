# VIIRS noise filter
# 
# This query will eliminate non-vessel detections (including those due to South Atlantic Anomaly) from raw VIIRS table.
# 
# All of filterring conditions used here are determined by examining scatterplot of RAD_DNB x SHI and 
# the actual spacial distributions of VIIRS detections.
#
# https://github.com/GlobalFishingWatch/viirs-noise-filter/blob/main/rendered_output/01_develop_viirs_noise_filter.md



-- CREATE TEMP FUNCTION START_DATE() AS (DATE('2017-01-01'));
-- CREATE TEMP FUNCTION END_DATE() AS (DATE('2020-12-31'));

# Return TRUE if (LAT, LON) is inside of Ellipse
CREATE TEMP FUNCTION IS_INSIDE_ELLIPSE(
  LAT FLOAT64,
  LON FLOAT64,
  CENTER_LAT FLOAT64,
  CENTER_LON FLOAT64,
  RADIUS_LAT FLOAT64,
  RADIUS_LON FLOAT64) AS (
  IF(POW((LON - CENTER_LON) / RADIUS_LON, 2) + POW((LAT - CENTER_LAT) / RADIUS_LAT, 2) < 1, TRUE, FALSE)
);



WITH 

# VIIRS detection
viirs AS (
  SELECT
        *,
        IS_INSIDE_ELLIPSE(Lat_DNB, Lon_DNB, -22, -50, 20, 50) as is_south_america_small,
        IS_INSIDE_ELLIPSE(Lat_DNB, Lon_DNB, -17, -50, 35, 75) as is_south_america_large,
  FROM
      `world-fishing-827.pipe_viirs_production_v20180723.raw_vbd_global`
  where
        QF_Detect IN (1,2,3,5,7,10)
        -- AND DATE(Date_Mscan) BETWEEN START_DATE() AND END_DATE()

),

filtered_viirs as (
    SELECT 
        *
    FROM 
        viirs
    WHERE

        # QF1
        # All QF1s are accepted outside of South America.
        (QF_Detect=1 AND NOT is_south_america_small) OR 
        # Part of QF1s are accepted in the South America. 
        (QF_Detect=1 AND is_south_america_small AND RAD_DNB BETWEEN 2500 and 100000 AND SHI<0.99) OR
        (QF_Detect=1 AND is_south_america_small AND RAD_DNB BETWEEN 1500 and 2500 AND SHI<1.0) OR
        (QF_Detect=1 AND is_south_america_small AND RAD_DNB BETWEEN 400 and 1500 AND SHI<0.995) OR
        (QF_Detect=1 AND is_south_america_small AND RAD_DNB BETWEEN 200 and 400 AND SHI<0.975) OR
        (QF_Detect=1 AND is_south_america_small AND RAD_DNB BETWEEN 130 and 200 AND SHI<0.920) OR
        (QF_Detect=1 AND is_south_america_small AND RAD_DNB BETWEEN 100 and 130 AND SHI<0.8) OR
        
        # QF2
        # All QF2s are accepted outside of South America.
        (QF_Detect=2 AND NOT is_south_america_small) OR
        # Part of QF2s are accepted in the South America. 
        (QF_Detect=2 AND is_south_america_small AND RAD_DNB BETWEEN 100 and 100000 AND SHI<1) OR
        (QF_Detect=2 AND is_south_america_small AND RAD_DNB BETWEEN 50 and 100 AND SHI<0.65) OR
        (QF_Detect=2 AND is_south_america_small AND RAD_DNB BETWEEN 10 and 50 AND SHI<0.4) OR
        
        # QF3
        # QF3s are accepted only outside of South America
        (QF_Detect=3 AND NOT is_south_america_large) OR

        # QF5
        # QF5s are accepted only in South America
        (QF_Detect=5 AND is_south_america_large AND RAD_DNB < 300 AND SHI<0.3) OR
        (QF_Detect=5 AND is_south_america_large AND RAD_DNB < 300 AND (SHI < 0.8 * LOG10(Rad_DNB) - 0.4)) OR
        (QF_Detect=5 AND is_south_america_large AND RAD_DNB < 300 AND (SHI >= 0.8 * LOG10(Rad_DNB) - 0.4) AND Rad_DNB > 15) OR

        # QF7
        # QF7s are accepted only in South America
        (QF_Detect=7 AND is_south_america_large) OR

        # QF10
        # QF10s are accepted globaly
        (QF_Detect=10)  
)


select
        id_Key,
        concat(cast(Date_Mscan as string),concat(cast(Lat_DNB as string),cast(Lon_DNB as string))) as detect_id,
        Date(Date_Mscan) as date,
        Date_Mscan,
        Lat_DNB,
        Lon_DNB,
        Rad_DNB,
        QF_Detect,    
        SATZ_GDNBO,
        # other fields for convenience of analysis
        CAST(SUBSTR(File_DNB, 40,5) AS INT64) AS OrbitNumber,
        CONCAT("A", CAST(extract(YEAR from Date_Mscan) as STRING), LPAD(CAST(extract(DAYOFYEAR from Date_Mscan) as STRING), 3, "0"), ".", LPAD(CAST(extract(HOUR from Date_Mscan) as STRING), 2, "0"), LPAD(CAST(DIV(extract(MINUTE from Date_Mscan), 6)*6 as STRING), 2, "0") ) as GranuleID
from
    filtered_viirs