"""Pressure/altitude conversion for small height differences.

Within a building the hypsometric equation is accurate to millimetres:
    dh = H * ln(p_ref / p),  H = R * T / (g * M)  (scale height, ~8.6 km at 20 °C)
Near the ground 1 m of height is about 12 Pa (0.012 kPa).
"""
import numpy as np

R = 8.314462618  # J/(mol K)
G = 9.80665  # m/s^2
M_AIR = 0.0289644  # kg/mol


def scale_height(temp_c: float = 20.0) -> float:
    return R * (temp_c + 273.15) / (G * M_AIR)


def altitude_change_m(p_ref_kpa, p_kpa, temp_c: float = 20.0):
    """Height above the reference pressure level, in metres."""
    return scale_height(temp_c) * np.log(np.asarray(p_ref_kpa) / np.asarray(p_kpa))


def pressure_at(p_ref_kpa, dh_m, temp_c: float = 20.0):
    """Pressure dh_m metres above the reference level."""
    return np.asarray(p_ref_kpa) * np.exp(-np.asarray(dh_m) / scale_height(temp_c))
