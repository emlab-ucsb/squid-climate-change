SELECT
    ssvid,
    best.best_engine_power_kw engine_power_kw,
    best.best_flag flag
  FROM
    `world-fishing-827.pipe_ais_v3_published.vi_ssvid_v20240801`
  WHERE
    on_fishing_list_best
    AND best.best_vessel_class = 'squid_jigger'
    # Filter out vessels that broadcast exceedingly infrequently
    AND activity.active_hours >= 24
    # Do not include noisy/spoofing/offsetting vessels. They are simply not reliable and will not provide good emissions estimates
    AND NOT activity.offsetting
    AND activity.overlap_hours_multinames = 0