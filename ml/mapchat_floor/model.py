"""A simple ML floor estimator.

Features are computed causally (only past samples), so the model could run
live on the phone or server:
    dh_raw     height change since entry, in floor-heights
    dh_med15   15 s rolling median (suppresses door/HVAC spikes)
    dh_med60   60 s rolling median
    vspeed     vertical speed over the last 10 s (m/s), separates stairs/lift
    t_min      minutes since entry (drift grows with time)
    h          nominal floor height (m), n_floors
Target: true floor. A random-forest regressor predicts a continuous floor;
the estimate is rounded and clamped to [1, n_floors].
"""
from __future__ import annotations

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestRegressor

from .physics import altitude_change_m

FEATURES = ["dh_raw", "dh_med15", "dh_med60", "vspeed", "t_min", "h", "n_floors"]


def features(df: pd.DataFrame) -> pd.DataFrame:
    parts = []
    for _, s in df.groupby("session_id", sort=False):
        entry = int(s["entry_index"].iloc[0])
        p = s["pressure_kpa"].to_numpy()
        p_ref = float(np.median(p[entry : entry + 5]))
        dh = pd.Series(altitude_change_m(p_ref, p), index=s.index)
        h = float(s["floor_height_m"].iloc[0])
        f = pd.DataFrame(index=s.index)
        f["dh_raw"] = dh / h
        f["dh_med15"] = dh.rolling(15, min_periods=1).median() / h
        f["dh_med60"] = dh.rolling(60, min_periods=1).median() / h
        f["vspeed"] = dh.diff(10).fillna(0) / 10.0
        f["t_min"] = np.maximum(0, s["t_s"].to_numpy() - entry) / 60.0
        f["h"] = h
        f["n_floors"] = s["n_floors"].to_numpy()
        parts.append(f)
    return pd.concat(parts).loc[df.index]


class FloorModel:
    def __init__(self, seed: int = 0):
        self.rf = RandomForestRegressor(n_estimators=80, max_depth=14, min_samples_leaf=5, n_jobs=-1, random_state=seed)

    def fit(self, df: pd.DataFrame) -> "FloorModel":
        X = features(df)[FEATURES].to_numpy()
        self.rf.fit(X, df["true_floor"].to_numpy())
        return self

    def predict(self, df: pd.DataFrame) -> np.ndarray:
        X = features(df)[FEATURES]
        raw = self.rf.predict(X.to_numpy())
        return np.clip(np.rint(raw).astype(int), 1, X["n_floors"].to_numpy().astype(int))
