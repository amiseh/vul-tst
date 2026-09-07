"""Encje sensor.* dla integracji EduVulcan.

Kształty atrybutów są dopasowane 1:1 do oryginalnych kart Lovelace
(vultron-*.js) z dodatku htomasz/vultron, żeby dało się ich użyć bez
modyfikacji — patrz README, sekcja "Karty Lovelace".
"""
from __future__ import annotations

from typing import Any

from homeassistant.components.sensor import SensorEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import EduVulcanCoordinator
from .html_utils import slugify


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    coordinator: EduVulcanCoordinator = hass.data[DOMAIN][entry.entry_id]

    entities: list[SensorEntity] = []
    for slug, student_data in coordinator.data.items():
        entities.extend(
            [
                EduVulcanPlanSensor(coordinator, entry, slug, "prev", "Plan (poprzedni tydzień)"),
                EduVulcanPlanSensor(coordinator, entry, slug, "curr", "Plan (ten tydzień)"),
                EduVulcanPlanSensor(coordinator, entry, slug, "next", "Plan (następny tydzień)"),
                EduVulcanTerminarzSensor(coordinator, entry, slug),
                EduVulcanUwagiSensor(coordinator, entry, slug),
                EduVulcanFrekwencjaSensor(coordinator, entry, slug),
                EduVulcanOsiagnieciaSensor(coordinator, entry, slug),
                EduVulcanZebraniaSensor(coordinator, entry, slug),
                EduVulcanNumerekSensor(coordinator, entry, slug),
            ]
        )

        # Jeden sensor na KAŻDY okres klasyfikacyjny (tak jak oryginalny dodatek:
        # sensor.vultron_oceny_{slug}_p1, _p2, ...) — karta ocen tego wymaga.
        for p_num in (student_data.get("oceny") or {}):
            entities.append(EduVulcanOcenyPeriodSensor(coordinator, entry, slug, p_num))

        # Statystyki frekwencji: jeden sensor zbiorczy + jeden na KAŻDY przedmiot,
        # z entity_id wymuszonym na wzór oryginału (karta ma to zaszyte na sztywno
        # w JS: sensor.vultron_stats_{slug} / sensor.vultron_stats_{slug}_{przedmiot}).
        entities.append(EduVulcanStatsIndexSensor(coordinator, entry, slug))
        for subj in (student_data.get("frekwencja") or {}).get("statystyki_przedmioty", []):
            entities.append(EduVulcanStatsSubjectSensor(coordinator, entry, slug, subj["przedmiot"]))

    async_add_entities(entities)


class _BaseEduVulcanEntity(CoordinatorEntity[EduVulcanCoordinator], SensorEntity):
    """Wspólna baza — grupuje encje w jedno urządzenie na dziecko."""

    _attr_has_entity_name = True

    def __init__(self, coordinator: EduVulcanCoordinator, entry: ConfigEntry, slug: str, key: str, name: str) -> None:
        super().__init__(coordinator)
        self._entry = entry
        self._slug = slug
        self._key = key
        self._attr_name = name
        self._attr_unique_id = f"{entry.entry_id}_{slug}_{key}"
        student_name = self._student.get("info", {}).get("uczen", slug)
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, f"{entry.entry_id}_{slug}")},
            name=student_name,
            manufacturer="EduVulcan (integracja nieoficjalna)",
            model="Uczeń",
        )

    @property
    def _student(self) -> dict[str, Any]:
        return self.coordinator.data.get(self._slug, {}) or {}

    @property
    def _section(self) -> dict[str, Any]:
        return self._student.get(self._key) or {}

    @property
    def available(self) -> bool:
        return super().available and self._slug in self.coordinator.data


class EduVulcanOcenyPeriodSensor(_BaseEduVulcanEntity):
    """Jeden sensor na okres klasyfikacyjny — kompatybilny z vultron-grades-card.js."""

    _attr_icon = "mdi:school"

    def __init__(self, coordinator, entry, slug, p_num):
        self._p_num = p_num
        super().__init__(coordinator, entry, slug, f"oceny_p{p_num}", f"Oceny (okres {p_num})")

    @property
    def _section(self) -> dict[str, Any]:
        return (self._student.get("oceny") or {}).get(self._p_num) or {}

    @property
    def native_value(self) -> int:
        return self._section.get("liczba_ocen", 0)

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        sec = self._section
        return {
            "lista_przedmiotow": sec.get("lista_przedmiotow", []),
            "period_number": self._p_num,
            "active_period": sec.get("active", False),
            "srednia_proponowanych": sec.get("srednia_proponowanych"),
            "srednia_okresowych": sec.get("srednia_okresowych"),
        }


class EduVulcanPlanSensor(_BaseEduVulcanEntity):
    _attr_icon = "mdi:calendar-clock"

    def __init__(self, coordinator, entry, slug, week: str, name: str):
        self._week = week
        super().__init__(coordinator, entry, slug, f"plan_{week}", name)
        # vultron-card.js samo przełącza tygodnie doklejając/ucinając sufiks
        # _prev/_curr/_next (po angielsku, na sztywno w kodzie JS) — entity_id
        # MUSI się na to kończyć, inaczej karta nie znajdzie sąsiednich tygodni.
        self.entity_id = f"sensor.{slug}_plan_{week}"

    @property
    def _section(self) -> dict[str, Any]:
        return (self._student.get("plan") or {}).get(self._week) or {}

    @property
    def native_value(self) -> int:
        return self._section.get("state", 0)

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        return {"lekcje": self._section.get("lekcje", []), "dni_wolne": self._section.get("dni_wolne", [])}


class EduVulcanTerminarzSensor(_BaseEduVulcanEntity):
    _attr_icon = "mdi:clipboard-text-clock"

    def __init__(self, coordinator, entry, slug):
        super().__init__(coordinator, entry, slug, "terminarz", "Terminarz")

    @property
    def native_value(self) -> int:
        return self._section.get("state", 0)

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        return {"lista": self._section.get("lista", [])}


class EduVulcanUwagiSensor(_BaseEduVulcanEntity):
    _attr_icon = "mdi:comment-alert"

    def __init__(self, coordinator, entry, slug):
        super().__init__(coordinator, entry, slug, "uwagi", "Uwagi i pochwały")

    @property
    def native_value(self) -> int:
        return self._section.get("state", 0)

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        return {"uwagi": self._section.get("lista", [])}


class EduVulcanFrekwencjaSensor(_BaseEduVulcanEntity):
    _attr_icon = "mdi:calendar-check"

    def __init__(self, coordinator, entry, slug):
        super().__init__(coordinator, entry, slug, "frekwencja", "Frekwencja (wpisy)")

    @property
    def native_value(self) -> int:
        return len(self._section.get("wpisy", []))

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        return {"wpisy": self._section.get("wpisy", [])}


class EduVulcanStatsIndexSensor(_BaseEduVulcanEntity):
    """Sensor zbiorczy statystyk frekwencji — entity_id wymuszony na wzór oryginału."""

    _attr_icon = "mdi:percent"
    _attr_native_unit_of_measurement = "%"

    def __init__(self, coordinator, entry, slug):
        super().__init__(coordinator, entry, slug, "stats_index", "Frekwencja (statystyki)")
        self.entity_id = f"sensor.vultron_stats_{slug}"

    @property
    def _section(self) -> dict[str, Any]:
        return self._student.get("frekwencja") or {}

    @property
    def native_value(self) -> float | None:
        return (self._section.get("statystyki_globalne") or {}).get("procent")

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        glob = self._section.get("statystyki_globalne") or {}
        przedmioty = [
            {"id": p["id"], "nazwa": p["przedmiot"]} for p in self._section.get("statystyki_przedmioty", [])
        ]
        return {"rows": glob.get("rows", []), "przedmioty": przedmioty}


class EduVulcanStatsSubjectSensor(_BaseEduVulcanEntity):
    """Sensor statystyk frekwencji dla JEDNEGO przedmiotu."""

    _attr_icon = "mdi:percent"
    _attr_native_unit_of_measurement = "%"

    def __init__(self, coordinator, entry, slug, subject_name: str):
        self._subject_name = subject_name
        subj_slug = slugify(subject_name)
        super().__init__(
            coordinator, entry, slug, f"stats_{subj_slug}", f"Frekwencja (statystyki) — {subject_name}"
        )
        self.entity_id = f"sensor.vultron_stats_{slug}_{subj_slug}"

    @property
    def _entry_data(self) -> dict[str, Any] | None:
        for p in (self._student.get("frekwencja") or {}).get("statystyki_przedmioty", []):
            if p["przedmiot"] == self._subject_name:
                return p
        return None

    @property
    def native_value(self) -> float | None:
        d = self._entry_data
        return d.get("procent") if d else None

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        d = self._entry_data
        return {"rows": d.get("rows", []) if d else []}


class EduVulcanOsiagnieciaSensor(_BaseEduVulcanEntity):
    _attr_icon = "mdi:trophy"

    def __init__(self, coordinator, entry, slug):
        super().__init__(coordinator, entry, slug, "osiagniecia", "Osiągnięcia")

    @property
    def native_value(self) -> int:
        return self._section.get("state", 0)

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        return {"osiagniecia": self._section.get("lista", [])}


class EduVulcanZebraniaSensor(_BaseEduVulcanEntity):
    _attr_icon = "mdi:account-group"

    def __init__(self, coordinator, entry, slug):
        super().__init__(coordinator, entry, slug, "zebrania", "Zebrania")

    @property
    def native_value(self) -> int:
        return self._section.get("state", 0)

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        return {"zebrania": self._section.get("lista", [])}


class EduVulcanNumerekSensor(_BaseEduVulcanEntity):
    _attr_icon = "mdi:clover"

    def __init__(self, coordinator, entry, slug):
        super().__init__(coordinator, entry, slug, "numerek", "Szczęśliwy numerek")

    @property
    def native_value(self) -> str:
        return self._section.get("numer", "Brak")

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        return {"id_numerku": self._section.get("id", "")}
