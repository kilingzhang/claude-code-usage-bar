from datetime import datetime, timedelta, timezone

from claude_statusbar.core import (
    build_usage_forecast,
    format_compact_duration,
    format_forecast_label,
)


def test_format_compact_duration():
    assert format_compact_duration(8) == "8m"
    assert format_compact_duration(70) == "1h10m"
    assert format_compact_duration(27 * 60) == "1d03h"


def test_build_usage_forecast_predicts_exhaustion_before_reset():
    now = datetime(2026, 3, 29, 12, 0, tzinfo=timezone.utc)
    entries = [
        {"timestamp": now - timedelta(minutes=55), "cost": 0.4, "total_tokens": 4000},
        {"timestamp": now - timedelta(minutes=30), "cost": 0.6, "total_tokens": 6000},
        {"timestamp": now - timedelta(minutes=10), "cost": 1.0, "total_tokens": 10000},
    ]

    forecast = build_usage_forecast(
        current_pct=80,
        reset_at=(now + timedelta(hours=2)).timestamp(),
        current_window_entries=entries,
        history_entries=entries,
        lookback_minutes=60,
        now=now,
        history_mode="recent",
    )

    assert forecast is not None
    assert forecast["will_exhaust_before_reset"] is True
    assert forecast["eta_minutes"] == 13
    assert forecast["metric"] == "cost"
    assert forecast["confidence"]["score"] >= 5
    assert format_forecast_label(forecast, None).startswith("⌛5h:13m(")


def test_build_usage_forecast_marks_reset_first_when_rate_is_safe():
    now = datetime(2026, 3, 29, 12, 0, tzinfo=timezone.utc)
    entries = [
        {"timestamp": now - timedelta(minutes=50), "cost": 0.2, "total_tokens": 2000},
        {"timestamp": now - timedelta(minutes=20), "cost": 0.1, "total_tokens": 1000},
    ]

    forecast = build_usage_forecast(
        current_pct=40,
        reset_at=(now + timedelta(minutes=30)).timestamp(),
        current_window_entries=entries,
        history_entries=entries,
        lookback_minutes=60,
        now=now,
        history_mode="recent",
    )

    assert forecast is not None
    assert forecast["will_exhaust_before_reset"] is False
    assert forecast["eta_minutes"] > forecast["reset_minutes"]
    assert format_forecast_label(forecast, None).startswith("⌛5h:>reset(")


def test_build_usage_forecast_uses_all_history_for_weekly():
    now = datetime(2026, 3, 29, 12, 0, tzinfo=timezone.utc)
    entries = [
        {"timestamp": now - timedelta(days=6), "cost": 4.0, "total_tokens": 40000},
        {"timestamp": now - timedelta(days=3), "cost": 3.0, "total_tokens": 30000},
        {"timestamp": now - timedelta(hours=6), "cost": 2.0, "total_tokens": 20000},
    ]

    current_window_entries = [entry for entry in entries if entry["timestamp"] >= now - timedelta(days=7)]
    forecast = build_usage_forecast(
        current_pct=70,
        reset_at=(now + timedelta(days=1)).timestamp(),
        current_window_entries=current_window_entries,
        history_entries=entries,
        lookback_minutes=None,
        now=now,
        history_mode="weighted",
        span_mode="elapsed",
    )

    assert forecast is not None
    assert forecast["history_mode"] == "weighted"
    assert forecast["span_mode"] == "elapsed"
    assert forecast["samples"] == 3
    assert forecast["confidence"]["span_hours"] > 0
    assert format_forecast_label(None, forecast).startswith("⌛7d:")


def test_format_forecast_label_renders_both_windows():
    five_hour = {"will_exhaust_before_reset": True, "eta_text": "42m", "samples": 12, "confidence": {"score": 78}}
    seven_day = {"will_exhaust_before_reset": False, "eta_text": "3d02h", "samples": 12304, "confidence": {"score": 61}}
    assert format_forecast_label(five_hour, seven_day) == "⌛5h:42m(78|n12) 7d:>reset(61|n12.3k)"
