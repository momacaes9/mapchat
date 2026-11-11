"""Rule-based baseline: floor = entry floor + round(height change / floor height).

The reference pressure is the median of the first 5 s after entering the
building (the entry floor is assumed to be floor 1, as on the app). The only
building knowledge used is the nominal floor height and the floor count (to
clamp), the same information the app has from `places`.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from .physics import altitude_change_m


def estimate_session(s: pd.DataFrame, entry_floor: int = 1) -> np.ndarray:
    entry = int(s["entry_index"].iloc[0])
    p = s["pressure_kpa"].to_numpy()
    p_ref = float(np.median(p[entry : entry + 5]))
    dh = altitude_change_m(p_ref, p)
    h = float(s["floor_height_m"].iloc[0])
    n = int(s["n_floors"].iloc[0])
    est = entry_floor + np.rint(dh / h).astype(int)
    return np.clip(est, 1, n)


def estimate(df: pd.DataFrame) -> pd.Series:
    out = pd.Series(index=df.index, dtype="int64")
    for _, s in df.groupby("session_id", sort=False):
        out.loc[s.index] = estimate_session(s)
    return out
