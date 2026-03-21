"""schedule.py — Centralized schedule check for Python AAU components.

Usage:
    from schedule import is_active, get_schedule_info
    if not is_active(cfg, "director"):
        # quiet hours
"""

import os
import re
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None  # Python < 3.9 fallback


def _parse_schedule(cfg: dict) -> dict:
    """Extract schedule config from aau.yaml cfg dict."""
    sched = cfg.get("schedule", {})
    if not isinstance(sched, dict):
        sched = {}

    # Also try flat keys from config.sh-style parsing
    return {
        "timezone": sched.get("timezone", cfg.get("schedule_timezone", "")),
        "active_hours": sched.get("active_hours", cfg.get("schedule_active_hours", "")),
        "breaks": sched.get("breaks", []),
        "weekend_mode": sched.get("weekend", {}).get("mode", cfg.get("schedule_weekend_mode", "normal")),
        "weekend_active_hours": sched.get("weekend", {}).get("active_hours", cfg.get("schedule_weekend_active_hours", "")),
        "overrides": sched.get("overrides", {}),
    }


def _hhmm_to_min(t: str) -> int:
    """Convert 'HH:MM' to minutes since midnight."""
    parts = t.strip().split(":")
    return int(parts[0]) * 60 + int(parts[1])


def _in_range(now_min: int, time_range: str) -> bool:
    """Check if now_min is within 'HH:MM-HH:MM' range."""
    parts = time_range.split("-")
    if len(parts) != 2:
        return False
    start = _hhmm_to_min(parts[0])
    end = _hhmm_to_min(parts[1])
    if start <= end:
        return start <= now_min < end
    else:
        # Overnight range (e.g. 22:00-06:00)
        return now_min >= start or now_min < end


def _get_now(tz_name: str) -> datetime:
    """Get current datetime in the specified timezone."""
    if tz_name and ZoneInfo:
        try:
            return datetime.now(ZoneInfo(tz_name))
        except Exception:
            pass
    if tz_name:
        # Fallback: try common offsets
        tz_offsets = {"Asia/Tokyo": 9, "US/Pacific": -7, "US/Eastern": -4, "UTC": 0}
        offset = tz_offsets.get(tz_name)
        if offset is not None:
            return datetime.now(timezone(timedelta(hours=offset)))
    return datetime.now()


def is_active(cfg: dict, component: str = "", tmp_dir: str = "/tmp", prefix: str = "aau") -> bool:
    """Check if the system should be active now.

    Args:
        cfg: parsed aau.yaml config dict (or raw schedule dict)
        component: "director", "agents", or "" (default)
        tmp_dir: temp directory for override files
        prefix: AAU prefix for temp files

    Returns:
        True if active, False if quiet/break/weekend-off
    """
    sched = _parse_schedule(cfg)
    now = _get_now(sched["timezone"])
    now_min = now.hour * 60 + now.minute
    now_dow = now.isoweekday()  # 1=Mon, 7=Sun

    # ─── Emergency override ──────────────────────────────────────
    override_file = Path(tmp_dir) / f"{prefix}_emergency_override"
    if override_file.exists():
        try:
            duration = int(override_file.read_text().strip())
            file_mtime = override_file.stat().st_mtime
            if time.time() < file_mtime + duration:
                return True  # Emergency override active
            else:
                override_file.unlink(missing_ok=True)
        except Exception:
            pass

    # ─── Determine active_hours ──────────────────────────────────
    active_hours = sched["active_hours"]

    # Weekend check
    if now_dow >= 6:
        mode = sched["weekend_mode"]
        if mode == "off":
            return False
        elif mode == "reduced" and sched["weekend_active_hours"]:
            active_hours = sched["weekend_active_hours"]

    # Component override
    overrides = sched["overrides"]
    if component == "director" and "director" in overrides:
        oh = overrides["director"]
        if isinstance(oh, dict) and oh.get("active_hours"):
            active_hours = oh["active_hours"]
    elif component == "agents" and "agents" in overrides:
        oh = overrides["agents"]
        if isinstance(oh, dict) and oh.get("active_hours"):
            active_hours = oh["active_hours"]

    # ─── Legacy fallback ─────────────────────────────────────────
    if not active_hours:
        director_cfg = cfg.get("director", {})
        quiet_start = int(director_cfg.get("quiet_hours_start", 0))
        quiet_end = int(director_cfg.get("quiet_hours_end", 8))
        if quiet_start <= now.hour < quiet_end:
            return False
        return True

    # ─── Active hours check ──────────────────────────────────────
    if not _in_range(now_min, active_hours):
        return False

    # ─── Breaks check ────────────────────────────────────────────
    breaks = sched["breaks"]
    if isinstance(breaks, str):
        breaks = [b.strip().strip('"') for b in breaks.split("|") if b.strip()]
    for brk in breaks:
        if isinstance(brk, str) and _in_range(now_min, brk.strip().strip('"')):
            return False

    return True


def get_schedule_info(cfg: dict, tmp_dir: str = "/tmp", prefix: str = "aau") -> dict:
    """Get schedule status info for monitoring/display."""
    sched = _parse_schedule(cfg)
    now = _get_now(sched["timezone"])
    override_file = Path(tmp_dir) / f"{prefix}_emergency_override"

    emergency_active = False
    emergency_remaining = 0
    if override_file.exists():
        try:
            duration = int(override_file.read_text().strip())
            remaining = override_file.stat().st_mtime + duration - time.time()
            if remaining > 0:
                emergency_active = True
                emergency_remaining = int(remaining)
        except Exception:
            pass

    return {
        "timezone": sched["timezone"] or "system",
        "active_hours": sched["active_hours"],
        "breaks": sched["breaks"],
        "weekend_mode": sched["weekend_mode"],
        "weekend_active_hours": sched["weekend_active_hours"],
        "current_time": now.strftime("%H:%M"),
        "is_weekend": now.isoweekday() >= 6,
        "director_active": is_active(cfg, "director", tmp_dir, prefix),
        "agents_active": is_active(cfg, "agents", tmp_dir, prefix),
        "emergency_override": emergency_active,
        "emergency_remaining_sec": emergency_remaining,
    }
