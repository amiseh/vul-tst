"""Integracja EduVulcan (nieoficjalna) — bez Selenium, na wklejonym ciasteczku."""
from __future__ import annotations

import logging
from pathlib import Path

from homeassistant.components.frontend import add_extra_js_url
from homeassistant.components.http import StaticPathConfig
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant

from .api import EduVulcanClient, parse_cookie_header
from .const import CONF_CITY, CONF_COOKIE, DOMAIN
from .coordinator import EduVulcanCoordinator

_LOGGER = logging.getLogger(__name__)

PLATFORMS: list[Platform] = [Platform.SENSOR]

# Karty Lovelace przepisane 1:1 z oryginalnego dodatku htomasz/vultron —
# trzymane wewnątrz folderu integracji, żeby HACS aktualizował je razem
# z resztą kodu, bez ręcznego kopiowania do /config/www ani rejestrowania
# zasobów. Rejestrujemy je automatycznie przy starcie (patrz niżej).
CARD_FILES = [
    "vultron-card.js",
    "vultron-grades-card.js",
    "vultron-work-card.js",
    "vultron-uwagi-card.js",
    "vultron-stats-card.js",
    "vultron-osiagniecia-card.js",
    "vultron-zebrania-card.js",
    "vultron-szczesliwy-numerek-card.js",
]
_STATIC_URL = f"/{DOMAIN}_cards"


async def _async_register_cards(hass: HomeAssistant) -> None:
    """Wystawia pliki kart pod URL-em i wstrzykuje je do frontendu.

    Odpowiednik run_setup_ui() z oryginalnego dodatku — ale zamiast
    ręcznie łączyć się przez WebSocket do Lovelace/resources przy każdym
    starcie, korzystamy z natywnego mechanizmu HA (add_extra_js_url),
    który sam dba o to, żeby karta była zawsze dostępna na każdym
    dashboardzie, bez żadnej rejestracji ze strony użytkownika.
    """
    flag = f"{DOMAIN}_cards_registered"
    _LOGGER.info("EduVulcan: _async_register_cards() wywołane, flaga=%s", hass.data.get(flag))
    if hass.data.get(flag):
        return
    hass.data[flag] = True

    try:
        www_path = Path(__file__).parent / "www"
        _LOGGER.info("EduVulcan: rejestruję pliki statyczne z %s (istnieje=%s)", www_path, www_path.exists())
        await hass.http.async_register_static_paths(
            [StaticPathConfig(_STATIC_URL, str(www_path), cache_headers=False)]
        )
        for fname in CARD_FILES:
            add_extra_js_url(hass, f"{_STATIC_URL}/{fname}")
        _LOGGER.info("EduVulcan: zarejestrowano %d kart Lovelace pod %s", len(CARD_FILES), _STATIC_URL)
    except Exception:  # noqa: BLE001
        _LOGGER.exception(
            "EduVulcan: nie udało się automatycznie zarejestrować kart Lovelace — "
            "sensory i tak będą działać, ale karty trzeba będzie dodać ręcznie "
            "(patrz README, sekcja 'Karty Lovelace — rejestracja awaryjna')."
        )


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    await _async_register_cards(hass)

    cookies = parse_cookie_header(entry.data[CONF_COOKIE])
    client = await hass.async_add_executor_job(EduVulcanClient, cookies)
    coordinator = EduVulcanCoordinator(hass, entry, client, entry.data[CONF_CITY])

    await coordinator.async_config_entry_first_refresh()

    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = coordinator
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    unload_ok = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if unload_ok:
        coordinator: EduVulcanCoordinator = hass.data[DOMAIN].pop(entry.entry_id)
        await coordinator.client.aclose()
    return unload_ok
