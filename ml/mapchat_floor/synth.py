"""SYNTHETIC barometer sessions for developing the floor estimator.

This is simulated data, not measurements. It exists so the pipeline,
metrics and models can be built before real (consented) data is logged.
Every effect below is a modelling assumption with rough literature-scale
magnitudes:

* Weather drift: a per-session linear trend (sd 60 Pa/h, i.e. about 5 m/h of
  apparent height) plus a slow random walk.
* Sensor noise: white noise with sd 2.5 Pa (about 0.2 m).
* Building pressurization: a +2..+10 Pa offset while indoors.
* Door spikes: a +-10..30 Pa transient decaying over ~3 s when a door opens.
* Stairwell offset: stairwells are often pressurized differently (+-3..12 Pa).
* Elevator: 10-45 s wait, then 1.0-2.0 m/s vertical speed; small shaft
  pressure transient.
* Stairs: 0.25-0.40 m/s vertical speed.
* Uneven floors: the ground floor is 1.0-1.4x taller than the nominal floor
  height, and each floor gets +-0.2 m jitter. The app only knows the
  building's NOMINAL floor height, as with real building data.

Columns mirror public.floor_samples (pressure_kpa, rel_altitude_m,
gps_accuracy_m, confirmed_floor, movement) plus synthetic-only ground-truth
columns prefixed with `true_`.
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass

import numpy as np
import pandas as pd

from .physics import altitude_change_m, pressure_at

P0_KPA = 99.5  # Chapel Hill is ~150 m above sea level.


@dataclass
class Building:
    n_floors: int
    nominal_floor_height_m: float
    floor_altitudes_m: np.ndarray  # altitude of each floor (index 0 = floor 1)


def make_building(rng: np.random.Generator) -> Building:
    n = int(rng.integers(3, 11))
    h = float(rng.uniform(3.0, 4.5))
    heights = np.full(n - 1, h) + rng.normal(0, 0.2, n - 1)
    if n > 1:
        heights[0] *= rng.uniform(1.0, 1.4)  # tall lobby
    alts = np.concatenate([[0.0], np.cumsum(heights)])
    return Building(n_floors=n, nominal_floor_height_m=h, floor_altitudes_m=alts)


def _door_spike(t: np.ndarray, t0: float, amp_pa: float) -> np.ndarray:
    dt = t - t0
    return np.where(dt >= 0, amp_pa * np.exp(-dt / 3.0), 0.0)


def simulate_session(rng: np.random.Generator, building: Building | None = None, n_moves: int | None = None) -> pd.DataFrame:
    b = building or make_building(rng)
    n_moves = n_moves if n_moves is not None else int(rng.integers(2, 6))

    # Build a piecewise timeline of (altitude, movement, in_stairwell) at 1 Hz.
    alt: list[float] = []
    mov: list[str] = []
    stairwell: list[bool] = []
    indoor: list[bool] = []

    def hold(seconds: int, a: float, m: str, inside: bool, stair: bool = False) -> None:
        alt.extend([a] * seconds)
        mov.extend([m] * seconds)
        indoor.extend([inside] * seconds)
        stairwell.extend([stair] * seconds)

    hold(int(rng.integers(20, 40)), 0.0, "walking", inside=False)  # approach outdoors
    door_times = [len(alt)]
    floor = 0
    for _ in range(n_moves):
        hold(int(rng.integers(20, 180)), b.floor_altitudes_m[floor], "idle", inside=True)
        target = int(rng.choice([f for f in range(b.n_floors) if f != floor]))
        a0, a1 = b.floor_altitudes_m[floor], b.floor_altitudes_m[target]
        if rng.random() < 0.5:  # stairs
            speed = rng.uniform(0.25, 0.40)
            steps = max(2, int(abs(a1 - a0) / speed))
            door_times.append(len(alt))
            alt.extend(np.linspace(a0, a1, steps).tolist())
            mov.extend(["stairs"] * steps)
            indoor.extend([True] * steps)
            stairwell.extend([True] * steps)
            door_times.append(len(alt))
        else:  # elevator
            hold(int(rng.integers(10, 45)), a0, "elevator", inside=True)
            speed = rng.uniform(1.0, 2.0)
            steps = max(2, int(abs(a1 - a0) / speed) + 4)  # + door open/close
            alt.extend(np.linspace(a0, a1, steps).tolist())
            mov.extend(["elevator"] * steps)
            indoor.extend([True] * steps)
            stairwell.extend([False] * steps)
        floor = target
    hold(int(rng.integers(30, 120)), b.floor_altitudes_m[floor], "idle", inside=True)

    n = len(alt)
    t = np.arange(n, dtype=float)
    true_alt = np.asarray(alt)

    # Pressure model (Pa offsets added to the hydrostatic pressure).
    trend_pa_per_s = rng.normal(0, 60) / 3600.0
    walk = np.cumsum(rng.normal(0, 0.15, n))
    weather_pa = trend_pa_per_s * t + walk
    inside = np.asarray(indoor)
    building_offset = np.where(inside, rng.uniform(2, 10), 0.0)
    stair_offset = np.where(np.asarray(stairwell), rng.uniform(-12, 12), 0.0)
    spikes = sum(_door_spike(t, td, rng.choice([-1, 1]) * rng.uniform(10, 30)) for td in door_times)
    noise = rng.normal(0, 2.5, n)

    p_kpa = pressure_at(P0_KPA, true_alt) + (weather_pa + building_offset + stair_offset + spikes + noise) / 1000.0

    # CMAltimeter-style relative altitude since the session started.
    rel_alt = altitude_change_m(p_kpa[0], p_kpa)

    true_floor = 1 + np.array([int(np.argmin(np.abs(b.floor_altitudes_m - a))) for a in true_alt])

    # Simulated "I'm on floor N" taps: twice per session, while idle.
    confirmed = np.full(n, np.nan)
    idle_idx = np.flatnonzero((np.asarray(mov) == "idle") & inside)
    if idle_idx.size:
        for i in rng.choice(idle_idx, size=min(2, idle_idx.size), replace=False):
            confirmed[i] = true_floor[i]

    entry_idx = int(np.argmax(inside))
    return pd.DataFrame(
        {
            "session_id": str(uuid.UUID(int=int(rng.integers(0, 2**63)))),
            "t_s": t,
            "pressure_kpa": p_kpa,
            "rel_altitude_m": rel_alt,
            "gps_accuracy_m": np.where(inside, rng.uniform(15, 65, n), rng.uniform(4, 10, n)),
            "indoor": inside,
            "entry_index": entry_idx,
            "n_floors": b.n_floors,
            "floor_height_m": b.nominal_floor_height_m,
            "confirmed_floor": confirmed,
            "movement": mov,
            "true_altitude_m": true_alt,
            "true_floor": true_floor,
        }
    )


def generate(n_sessions: int, seed: int = 0) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    return pd.concat([simulate_session(rng) for _ in range(n_sessions)], ignore_index=True)


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description="Write a SYNTHETIC barometer dataset as CSV.")
    ap.add_argument("--sessions", type=int, default=200)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", default="synthetic_sessions.csv")
    args = ap.parse_args()
    df = generate(args.sessions, args.seed)
    df.to_csv(args.out, index=False)
    print(f"wrote {len(df)} SYNTHETIC samples from {args.sessions} sessions to {args.out}")
