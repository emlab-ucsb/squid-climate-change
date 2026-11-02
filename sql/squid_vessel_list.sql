# Squid jiggers from GFW's pipeline 5 (V5) vessel identity table, which has one
# row per vessel (ssvid) summarizing its whole AIS record. Gear, the fishing
# vessel call, and engine power come from the pipeline 5 random forest
# (random_forest_info), which replaces the deprecated best.best_vessel_class
# and on_fishing_list_best (GFW, Pipe5 Release Notes for Research Partners,
# Sept 2026). Same vessel definition as the megafauna-and-fronts and
# fishing-effort-drivers repos, restricted to squid jiggers.
SELECT
    ssvid,
    # Random forest engine power, overridden by a known engine power where
    # there is one
    random_forest_info.best_engine_power_kw engine_power_kw,
    best.best_flag flag
  FROM
    `{gfw_vessel_info_table}`
  WHERE
    # The random forest's fishing vessel call, overridden by registries where
    # available
    random_forest_info.on_fishing_list_best
    # The random forest only names a specific gear when it scores it at least
    # 0.35, and otherwise rolls up to a broader parent class. Where it rolls
    # all the way up to generic 'fishing', use the model's finest-level
    # prediction (atomic_class), which GFW says is reliable for squid_jigger
    AND (
      random_forest_info.best_vessel_class = 'squid_jigger'
      OR (
        random_forest_info.best_vessel_class = 'fishing'
        AND random_forest_info.atomic_class = 'squid_jigger'
      )
    )
    # Filter out vessels that broadcast exceedingly infrequently
    AND activity.active_hours >= 24
    # Do not include noisy vessels, using GFW's noisy_vessel definition:
    # offsetting (spoofing) positions, or 24+ hours broadcasting the MMSI under
    # multiple names at once
    AND NOT activity.offsetting
    AND activity.overlap_hours_multinames < 24
