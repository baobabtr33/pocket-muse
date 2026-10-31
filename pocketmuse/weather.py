"""Forecast snapshot from Open-Meteo (free, no API key), turned into a pack card.

The forecast is fetched once while online. Offline, the pack answers from this
snapshot and says when it was fetched.
"""

import json
import urllib.parse
import urllib.request
from datetime import date, datetime

# WMO weather codes -> short words.
WMO = {
    0: "clear", 1: "mostly clear", 2: "partly cloudy", 3: "overcast", 45: "fog", 48: "freezing fog",
    51: "light drizzle", 53: "drizzle", 55: "heavy drizzle", 56: "freezing drizzle", 57: "freezing drizzle",
    61: "light rain", 63: "rain", 65: "heavy rain", 66: "freezing rain", 67: "freezing rain",
    71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow grains",
    80: "rain showers", 81: "rain showers", 82: "heavy rain showers", 85: "snow showers", 86: "heavy snow showers",
    95: "thunderstorms", 96: "thunderstorms with hail", 99: "thunderstorms with hail",
}


def _f(c: float) -> int:
    return round(c * 9 / 5 + 32)


def geocode(name: str, near: tuple[float, float]) -> tuple[float, float]:
    """Open-Meteo place lookup: more precise than coordinates an LLM remembers. Many places share a
    name (Santa Cruz, CA vs Santa Cruz, Bolivia), so take the match nearest the LLM's rough guess."""
    query = urllib.parse.urlencode({"name": name.split(",")[0].strip(), "count": 10})
    with urllib.request.urlopen("https://geocoding-api.open-meteo.com/v1/search?" + query, timeout=15) as r:
        hits = json.load(r).get("results") or []
    hits = [h for h in hits if (h["latitude"] - near[0]) ** 2 + (h["longitude"] - near[1]) ** 2 < 1.0]  # within ~1°
    if not hits:
        return near
    best = min(hits, key=lambda h: (h["latitude"] - near[0]) ** 2 + (h["longitude"] - near[1]) ** 2)
    return best["latitude"], best["longitude"]


def forecast_card(name: str, lat: float, lon: float, start: date, days: int) -> dict:
    params = {
        "latitude": lat,
        "longitude": lon,
        "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunset",
        "timezone": "auto",
        "start_date": start.isoformat(),
        "end_date": date.fromordinal(start.toordinal() + max(1, min(days, 7)) - 1).isoformat(),
    }
    url = "https://api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=15) as r:
        daily = json.load(r)["daily"]

    fetched = datetime.now().strftime("%a %b %-d, %-I:%M %p")
    facts = [f"Forecast for {name}, fetched {fetched}. It cannot update while offline."]
    days = []
    for i, day in enumerate(daily["time"]):
        d = date.fromisoformat(day)
        hi, lo = daily["temperature_2m_max"][i], daily["temperature_2m_min"][i]
        rain = daily["precipitation_probability_max"][i]
        rain = "unknown" if rain is None else f"{rain}%"
        sunset = datetime.fromisoformat(daily["sunset"][i]).strftime("%-I:%M %p")
        text = (
            f"{d.strftime('%A %b %-d')}: {WMO.get(daily['weather_code'][i], 'mixed')}, "
            f"high {_f(hi)}°F ({hi:.0f}°C), low {_f(lo)}°F ({lo:.0f}°C), "
            f"{rain} chance of precipitation, sunset {sunset}."
        )
        days.append({"date": day, "text": text})
        facts.append(text[:-1] + f" (forecast as of {fetched}).")
    return {"title": "Weather forecast", "facts": facts, "kind": "forecast", "fetched": fetched, "days": days}
