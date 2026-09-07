"""Coordinator dla integracji EduVulcan."""
from __future__ import annotations

import logging
import random
from datetime import datetime, timedelta
from typing import Any

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ConfigEntryAuthFailed
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed
from homeassistant.util import dt as dt_util

from .api import EduVulcanAuthError, EduVulcanClient
from .const import CONF_COOKIE, DOMAIN, MAX_INTERVAL_SECONDS, MIN_INTERVAL_SECONDS

_LOGGER = logging.getLogger(__name__)


def _next_quiet_wake_delay(now: datetime) -> timedelta | None:
    """Odpowiednik harmonogramu nocnego/weekendowego z oryginalnego dodatku.

    Zwraca None jeśli można pobierać dane teraz, albo czas do najbliższego
    "obudzenia", jeśli jesteśmy w oknie ciszy (celowe ograniczenie
    częstotliwości zapytań do serwera EduVulcan).
    """
    wd = now.weekday()  # 0=Pon ... 6=Nie

    if wd < 5 and (now.hour < 6 or now.hour > 22 or (now.hour == 22 and now.minute >= 30)):
        if now.hour < 6:
            wake_at = now.replace(hour=6, minute=0, second=0, microsecond=0)
        else:
            wake_at = (now + timedelta(days=1)).replace(hour=6, minute=0, second=0, microsecond=0)
        return max(wake_at - now, timedelta(minutes=1))

    if wd == 5 and now.hour not in (8, 16, 23):
        nexts = [h for h in (8, 16, 23) if h > now.hour]
        wake_at = (
            now.replace(hour=nexts[0], minute=0, second=0, microsecond=0)
            if nexts
            else (now + timedelta(days=1)).replace(hour=8, minute=0, second=0, microsecond=0)
        )
        return max(wake_at - now, timedelta(minutes=1))

    if wd == 6 and now.hour not in (8, 12, 20):
        nexts = [h for h in (8, 12, 20) if h > now.hour]
        wake_at = (
            now.replace(hour=nexts[0], minute=0, second=0, microsecond=0)
            if nexts
            else (now + timedelta(days=1)).replace(hour=6, minute=0, second=0, microsecond=0)
        )
        return max(wake_at - now, timedelta(minutes=1))

    return None


class EduVulcanCoordinator(DataUpdateCoordinator[dict[str, Any]]):
    """Pobiera dane wszystkich dzieci powiązanych z jednym wklejonym ciasteczkiem."""

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry, client: EduVulcanClient, city: str) -> None:
        super().__init__(
            hass,
            _LOGGER,
            name=DOMAIN,
            update_interval=timedelta(seconds=random.randint(MIN_INTERVAL_SECONDS, MAX_INTERVAL_SECONDS)),
        )
        self.entry = entry
        self.client = client
        self.city = city

    async def _async_update_data(self) -> dict[str, Any]:
        now = dt_util.now()
        quiet_delay = _next_quiet_wake_delay(now)
        if quiet_delay is not None:
            _LOGGER.debug("EduVulcan: okno ciszy, wznowienie za %s", quiet_delay)
            self.update_interval = min(quiet_delay, timedelta(hours=3))
            return self.data or {}

        try:
            students = await self.client.async_fetch_students(self.city)
        except EduVulcanAuthError as exc:
            raise ConfigEntryAuthFailed(str(exc)) from exc
        except Exception as exc:  # noqa: BLE001
            raise UpdateFailed(f"Błąd pobierania listy uczniów: {exc}") from exc

        result: dict[str, Any] = {}
        for s in students:
            slug = s["slug"]
            student_data: dict[str, Any] = {"info": s}

            fetchers = {
                "oceny": self.client.async_fetch_grades,
                "plan": self.client.async_fetch_schedule,
                "terminarz": self.client.async_fetch_agenda,
                "uwagi": self.client.async_fetch_remarks,
                "frekwencja": self.client.async_fetch_attendance,
                "osiagniecia": self.client.async_fetch_achievements,
                "zebrania": self.client.async_fetch_meetings,
                "numerek": self.client.async_fetch_lucky_number,
                # "wiadomosci": self.client.async_fetch_messages,  # wyłączone — niepotrzebne
            }
            for key, fn in fetchers.items():
                try:
                    student_data[key] = await fn(s)
                except EduVulcanAuthError as exc:
                    if key == "wiadomosci":
                        # Sesja wiadomości (wiadomosci.eduvulcan.pl) to osobna domena
                        # z własnym uwierzytelnieniem SSO, niezależna od głównej sesji
                        # dziennika. Jej awaria nie powinna wywalać całej integracji —
                        # traktujemy ją jak zwykły błąd pojedynczej sekcji.
                        _LOGGER.warning(
                            "EduVulcan [%s/wiadomosci]: sesja wiadomości nieprawidłowa: %s", slug, exc
                        )
                        student_data[key] = (self.data or {}).get(slug, {}).get(key)
                    else:
                        raise ConfigEntryAuthFailed(str(exc)) from exc
                except Exception as exc:  # noqa: BLE001
                    _LOGGER.warning("EduVulcan [%s/%s]: błąd pobierania: %s", slug, key, exc)
                    # Zachowaj poprzednią wartość, jeśli jest — pojedynczy błąd
                    # nie powinien wywalać całego ucznia ani reszty encji.
                    prev = (self.data or {}).get(slug, {}).get(key)
                    student_data[key] = prev

            result[slug] = student_data

        self._async_persist_rotated_cookie()

        self.update_interval = timedelta(seconds=random.randint(MIN_INTERVAL_SECONDS, MAX_INTERVAL_SECONDS))
        return result

    def _async_persist_rotated_cookie(self) -> None:
        """Zapisuje aktualny stan ciasteczek do konfiguracji, jeśli się zmienił.

        Serwer EduVulcan rotuje ciasteczko sesji przy (prawie) każdym
        zapytaniu — przeglądarka nadąża za tym automatycznie, my musimy
        to zrobić jawnie, inaczej po restarcie HA cofniemy się do dawno
        nieaktualnej wartości sprzed rotacji i integracja poprosi o reauth
        mimo że sesja tak naprawdę cały czas była ważna.
        """
        new_cookie = self.client.current_cookie_header()
        if not new_cookie or new_cookie == self.entry.data.get(CONF_COOKIE):
            return
        self.hass.config_entries.async_update_entry(
            self.entry, data={**self.entry.data, CONF_COOKIE: new_cookie}
        )
        _LOGGER.debug("EduVulcan: zapisano zrotowane ciasteczko sesji")
