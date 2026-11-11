import io

import numpy as np
import pandas as pd
import pytest

from mapchat_floor import baseline
from mapchat_floor.evaluate import accuracy, report, run
from mapchat_floor.export import build_request, export_csv
from mapchat_floor.model import FEATURES, FloorModel, features
from mapchat_floor.physics import altitude_change_m, pressure_at
from mapchat_floor.synth import Building, generate, simulate_session


def test_physics_roundtrip_and_scale():
    p = pressure_at(99.5, 10.0)
    assert altitude_change_m(99.5, p) == pytest.approx(10.0, abs=1e-6)
    # ~12 Pa per metre near the ground
    assert (99.5 - pressure_at(99.5, 1.0)) * 1000 == pytest.approx(11.6, abs=0.6)


def test_synthetic_schema_matches_floor_samples():
    df = generate(3, seed=0)
    for col in ["session_id", "pressure_kpa", "rel_altitude_m", "gps_accuracy_m", "confirmed_floor", "movement"]:
        assert col in df.columns
    assert set(df["movement"]) <= {"idle", "stairs", "elevator", "walking"}
    assert df["pressure_kpa"].between(50, 120).all()


def test_pressure_falls_when_going_up():
    rng = np.random.default_rng(1)
    s = simulate_session(rng)
    hi = s["true_altitude_m"] > s["true_altitude_m"].max() - 0.5
    lo = (s["true_altitude_m"] < 0.5) & s["indoor"]
    assert s.loc[hi, "pressure_kpa"].mean() < s.loc[lo, "pressure_kpa"].mean()


def test_elevator_is_faster_than_stairs():
    df = generate(40, seed=2)
    v = df.groupby("session_id")["true_altitude_m"].diff().abs()
    stairs = v[df["movement"] == "stairs"].median()
    lift = v[(df["movement"] == "elevator") & (v > 0)].median()
    assert lift > 2 * stairs


def test_confirmed_floors_are_sparse_and_correct():
    df = generate(10, seed=3)
    c = df.dropna(subset=["confirmed_floor"])
    assert 0 < len(c) <= 20
    assert (c["confirmed_floor"] == c["true_floor"]).all()


def test_baseline_is_exact_without_noise():
    # Ideal building and a perfect barometer: the rule must be exact.
    alts = np.arange(5) * 3.5
    s = pd.DataFrame({
        "session_id": "x", "t_s": np.arange(6.0), "entry_index": 0, "n_floors": 5, "floor_height_m": 3.5,
        "pressure_kpa": pressure_at(99.5, np.array([0, 0, 0, 0, 0, 0]) + np.r_[0, 0, 0, 0, 0, alts[3]]),
    })
    est = baseline.estimate_session(s)
    assert est[0] == 1 and est[-1] == 4


def test_model_features_are_causal():
    df = generate(2, seed=4)
    f1 = features(df)
    # Changing the last sample of a session must not change earlier features.
    df2 = df.copy()
    last = df2.groupby("session_id").tail(1).index
    df2.loc[last, "pressure_kpa"] += 0.5
    f2 = features(df2)
    keep = ~df.index.isin(last)
    pd.testing.assert_frame_equal(f1.loc[keep, FEATURES], f2.loc[keep, FEATURES])


def test_accuracy_metric():
    assert accuracy(np.array([1, 2, 4]), np.array([1, 3, 2])) == (pytest.approx(1 / 3), pytest.approx(2 / 3))


def test_end_to_end_evaluation_is_reasonable_and_report_says_synthetic():
    res = run(train_sessions=30, test_sessions=15, seed=5)
    settled = next(r for r in res["rows"] if r[0].startswith("Settled"))
    # Both methods should be well above chance on settled samples.
    assert settled[3] > 0.8 and settled[5] > 0.8
    text = report(res)
    assert "SYNTHETIC" in text and "not** real-world accuracy" in text


def test_export_builds_an_rls_scoped_csv_request(tmp_path):
    req = build_request("http://127.0.0.1:54321/", "anon", "user-token")
    assert req.get_header("Accept") == "text/csv"
    assert req.get_header("Authorization") == "Bearer user-token"
    assert "/rest/v1/floor_samples?select=" in req.full_url

    class FakeResp(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    out = tmp_path / "s.csv"
    n = export_csv("http://x", "a", "t", str(out), opener=lambda r, timeout: FakeResp(b"session_id,pressure_kpa\nabc,99.5\nabc,99.4\n"))
    assert n == 2
    assert out.read_text().startswith("session_id")
