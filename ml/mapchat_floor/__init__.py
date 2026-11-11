"""Floor estimation from barometric pressure (MapChat Phase 7 groundwork).

Modules:
    physics   pressure <-> altitude conversion
    synth     synthetic walking sessions (SYNTHETIC, for development only)
    baseline  rule-based estimator: pressure change / floor height
    model     simple ML estimator (random forest on smoothed features)
    evaluate  metrics + docs/EVALUATION.md report
    export    CSV export of a user's own consented samples from Supabase
"""
