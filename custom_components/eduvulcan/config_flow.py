"""Config flow dla EduVulcan — logowanie przez wklejone ciasteczko przeglądarki."""
from __future__ import annotations

import logging
from typing import Any

import voluptuous as vol
from homeassistant.config_entries import ConfigFlow
from homeassistant.data_entry_flow import FlowResult
from homeassistant.helpers import selector

from .api import EduVulcanAuthError, EduVulcanClient, parse_cookie_header
from .const import CONF_CITY, CONF_COOKIE, DOMAIN

_LOGGER = logging.getLogger(__name__)

_COOKIE_SELECTOR = selector.TextSelector(selector.TextSelectorConfig(multiline=True))

STEP_USER_SCHEMA = vol.Schema(
    {
        vol.Required(CONF_CITY): str,
        vol.Required(CONF_COOKIE): _COOKIE_SELECTOR,
    }
)
STEP_REAUTH_SCHEMA = vol.Schema({vol.Required(CONF_COOKIE): _COOKIE_SELECTOR})


async def _validate(hass, city: str, cookie_raw: str) -> list[dict[str, Any]]:
    """Sprawdza ciasteczko wołając /api/Context; zwraca listę uczniów albo rzuca wyjątek."""
    cookies = parse_cookie_header(cookie_raw)
    client = await hass.async_add_executor_job(EduVulcanClient, cookies)
    try:
        return await client.async_fetch_students(city)
    finally:
        await client.aclose()


class EduVulcanConfigFlow(ConfigFlow, domain=DOMAIN):
    """Config flow dla EduVulcan."""

    VERSION = 1

    async def async_step_user(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        errors: dict[str, str] = {}
        if user_input is not None:
            city = user_input[CONF_CITY].strip().lower()
            cookie_raw = user_input[CONF_COOKIE]
            try:
                students = await _validate(self.hass, city, cookie_raw)
            except EduVulcanAuthError:
                errors["base"] = "invalid_auth"
            except Exception:  # noqa: BLE001
                _LOGGER.exception("Nieoczekiwany błąd podczas walidacji EduVulcan")
                errors["base"] = "cannot_connect"
            else:
                if not students:
                    errors["base"] = "no_students"
                else:
                    slugs = sorted(s["slug"] for s in students)
                    await self.async_set_unique_id(f"{city}:{','.join(slugs)}")
                    self._abort_if_unique_id_configured()
                    title = ", ".join(s["uczen"] for s in students)
                    return self.async_create_entry(
                        title=f"EduVulcan – {title}",
                        data={CONF_CITY: city, CONF_COOKIE: cookie_raw},
                    )

        return self.async_show_form(step_id="user", data_schema=STEP_USER_SCHEMA, errors=errors)

    async def async_step_reauth(self, entry_data: dict[str, Any]) -> FlowResult:
        return await self.async_step_reauth_confirm()

    async def async_step_reauth_confirm(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        errors: dict[str, str] = {}
        entry = self.hass.config_entries.async_get_entry(self.context["entry_id"])
        assert entry is not None

        if user_input is not None:
            cookie_raw = user_input[CONF_COOKIE]
            try:
                await _validate(self.hass, entry.data[CONF_CITY], cookie_raw)
            except EduVulcanAuthError:
                errors["base"] = "invalid_auth"
            except Exception:  # noqa: BLE001
                _LOGGER.exception("Nieoczekiwany błąd podczas reauth EduVulcan")
                errors["base"] = "cannot_connect"
            else:
                new_data = {**entry.data, CONF_COOKIE: cookie_raw}
                self.hass.config_entries.async_update_entry(entry, data=new_data)
                await self.hass.config_entries.async_reload(entry.entry_id)
                return self.async_abort(reason="reauth_successful")

        return self.async_show_form(
            step_id="reauth_confirm",
            data_schema=STEP_REAUTH_SCHEMA,
            errors=errors,
            description_placeholders={"city": entry.data.get(CONF_CITY, "")},
        )
