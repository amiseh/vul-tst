#!/bin/bash
set -e
TARGET=/var/lib/docker/volumes/hass_config/_data/custom_components/eduvulcan

# Zachowaj folder www/ (karty JS) jeśli już istnieje - nie ruszamy go w tym skrypcie
if [ -d "$TARGET/www" ]; then
  rm -rf /tmp/eduvulcan_www_backup
  cp -r "$TARGET/www" /tmp/eduvulcan_www_backup
  echo "Zachowano istniejący folder www/ (karty)."
else
  echo "UWAGA: folder www/ nie istniał - karty Lovelace trzeba będzie dograć osobno!"
fi

rm -rf "$TARGET"
mkdir -p "$TARGET/translations"

cat > "$TARGET/__init__.py" << 'EDUVULCAN_EOF'
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
EDUVULCAN_EOF

cat > "$TARGET/api.py" << 'EDUVULCAN_EOF'
"""Klient API EduVulcan/uonet+ dla integracji HA.

W przeciwieństwie do oryginalnego dodatku Vultron, ten klient NIGDY sam się
nie loguje przez Selenium/Chromium. Zamiast tego użytkownik wkleja gotowe
ciasteczko sesji (wyciągnięte z własnej przeglądarki po zwykłym zalogowaniu
na eduvulcan.pl). Klient używa tego ciasteczka do zwykłych zapytań HTTP do
tych samych wewnętrznych endpointów, których używa oryginalny dodatek.

Gdy ciasteczko wygaśnie, wszystkie metody rzucają EduVulcanAuthError, co
integracja tłumaczy na ConfigEntryAuthFailed -> Home Assistant sam poprosi
użytkownika o wklejenie nowego ciasteczka (natywny "reauth flow").
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta
from http.cookies import SimpleCookie
from typing import Any

import httpx

from .const import MAPA_FREKWENCJI, MAPA_STATUSOW, MAPA_TYP_TERMINARZA, UCZEN_BASE, WIADOMOSCI_BASE
from .html_utils import clean_html, map_grade_to_num, parse_grade_value, slugify

_LOGGER = logging.getLogger(__name__)


class EduVulcanAuthError(Exception):
    """Ciasteczko wygasło / jest nieprawidłowe."""


def parse_cookie_header(raw: str) -> dict[str, str]:
    """Zamienia wklejony string 'Cookie: a=1; b=2' albo samo 'a=1; b=2' na dict."""
    raw = raw.strip()
    if raw.lower().startswith("cookie:"):
        raw = raw.split(":", 1)[1].strip()
    jar: SimpleCookie = SimpleCookie()
    jar.load(raw)
    return {k: morsel.value for k, morsel in jar.items()}


def _looks_like_login_redirect(resp: httpx.Response) -> bool:
    url = str(resp.url).lower()
    if "logowanie" in url:
        return True
    head = resp.text[:2000].lower() if resp.text else ""
    return 'id="username"' in head or 'name="password"' in head


def _dt(days_offset: int, end_of_day: bool = False) -> str:
    d = datetime.now() + timedelta(days=days_offset)
    return d.strftime("%Y-%m-%dT23:59:59.999Z" if end_of_day else "%Y-%m-%dT00:00:00.000Z")


class EduVulcanClient:
    """Cienki, w pełni asynchroniczny wrapper na wewnętrzne API EduVulcan."""

    def __init__(self, cookies: dict[str, str]) -> None:
        self._client = httpx.AsyncClient(
            cookies=cookies,
            headers={"X-Requested-With": "XMLHttpRequest"},
            timeout=20,
            follow_redirects=True,
        )
        self._msg_client: httpx.AsyncClient | None = None

    async def aclose(self) -> None:
        await self._client.aclose()
        if self._msg_client is not None:
            await self._msg_client.aclose()

    def current_cookie_header(self) -> str:
        """Zwraca AKTUALNY stan ciasteczek (po ewentualnej rotacji przez serwer).

        Serwer EduVulcan potrafi przy każdym zapytaniu wydać nowe
        Set-Cookie (rolling session) — httpx aktualizuje to automatycznie
        w pamięci, ale trzeba to jawnie odczytać i zapisać z powrotem do
        konfiguracji integracji, inaczej po restarcie HA wrócimy do
        dawno nieaktualnej wartości z momentu wklejenia.

        Celowo POMIJAMY ciasteczka "X-V-RequestVerificationToken#<hash>" —
        serwer dokłada NOWE (z inną nazwą/hashem) przy każdej wizycie,
        nigdy nie nadpisując starych, więc ich liczba rosłaby bez końca
        przy każdym zapisie. Nie są nam potrzebne, bo integracja robi
        tylko zapytania GET (ochrona CSRF dotyczy zapytań zmieniających
        stan, czyli POST/PUT, których tu nie ma).
        """
        return "; ".join(
            f"{name}={value}"
            for name, value in self._client.cookies.items()
            if not name.startswith("X-V-RequestVerificationToken")
        )

    async def _get_json(self, url: str, params: dict | None = None) -> Any:
        resp = await self._client.get(url, params=params)
        if _looks_like_login_redirect(resp):
            raise EduVulcanAuthError("Przekierowano do logowania — ciasteczko wygasło.")
        try:
            return resp.json()
        except ValueError as exc:
            raise EduVulcanAuthError(
                "Nie udało się sparsować odpowiedzi JSON — ciasteczko mogło wygasnąć "
                "albo serwer pokazał CAPTCHA/blokadę."
            ) from exc

    # ────────────────────────────────────────────────
    # KONTEKST / LISTA UCZNIÓW
    # ────────────────────────────────────────────────

    async def async_fetch_students(self, city: str) -> list[dict[str, Any]]:
        """Odpowiednik run_diary_auth() z oryginału, ale bez Selenium."""
        base = f"{UCZEN_BASE}/{city}"
        context = await self._get_json(f"{base}/api/Context")

        if not isinstance(context, dict) or "uczniowie" not in context:
            # Serwer dla wygasłej/nieprawidłowej sesji czasem nie przekierowuje
            # na stronę logowania (to wykryłby _looks_like_login_redirect), tylko
            # zwraca "pusty"/inny kształt JSON-a. Traktujemy to jako błąd auth,
            # a nie "brak uczniów", żeby użytkownik dostał właściwy komunikat.
            raise EduVulcanAuthError(
                "Odpowiedź /api/Context ma nieoczekiwany kształt — ciasteczko "
                "prawdopodobnie wygasło albo jest nieprawidłowe."
            )

        students: list[dict[str, Any]] = []
        for u in context.get("uczniowie", []):
            key = u.get("key")
            id_dz = str(u.get("idDziennik"))
            okresy = await self._get_json(
                f"{base}/api/OkresyKlasyfikacyjne", params={"key": key, "idDziennik": id_dz}
            )
            curr_p = okresy[-1]["id"] if okresy else None
            now = datetime.now()
            for o in okresy or []:
                try:
                    if (
                        datetime.strptime(o["dataOd"][:19], "%Y-%m-%dT%H:%M:%S")
                        <= now
                        <= datetime.strptime(o["dataDo"][:19], "%Y-%m-%dT%H:%M:%S")
                    ):
                        curr_p = o["id"]
                        break
                except (ValueError, KeyError):
                    continue

            students.append(
                {
                    "slug": slugify(u.get("uczen", "")),
                    "uczen": u.get("uczen", ""),
                    "city": city,
                    "key": key,
                    "idDziennik": id_dz,
                    "periodId": curr_p,
                    "klasa": u.get("oddzial", ""),
                    "globalKeySkrzynka": u.get("globalKeySkrzynka", ""),
                }
            )
        return students

    # ────────────────────────────────────────────────
    # OCENY
    # ────────────────────────────────────────────────

    async def async_fetch_grades(self, s: dict) -> dict[str, Any]:
        base = f"{UCZEN_BASE}/{s['city']}"
        key, id_dz = s["key"], s["idDziennik"]
        okresy = await self._get_json(
            f"{base}/api/OkresyKlasyfikacyjne", params={"key": key, "idDziennik": id_dz}
        )
        periods_out: dict[str, Any] = {}
        for period in okresy or []:
            p_id, p_num = str(period["id"]), period["numerOkresu"]
            oceny = await self._get_json(f"{base}/api/Oceny", params={"key": key, "idOkresKlasyfikacyjny": p_id})

            subjects: dict[str, list] = {}
            subj_periodic: dict[str, dict] = {}
            for p_item in oceny.get("ocenyPrzedmioty") or []:
                subj = p_item.get("przedmiotNazwa", "Inne")
                subj_periodic[subj] = {
                    "proponowana": (p_item.get("proponowanaOcenaOkresowa") or "").strip() or None,
                    "okresowa": (p_item.get("ocenaOkresowa") or "").strip() or None,
                }
                subjects.setdefault(subj, [])
                for kol in p_item.get("kolumnyOcenyCzastkowe") or []:
                    desc = f"{kol.get('kategoriaKolumny','')}: {kol.get('nazwaKolumny','')}".strip(": ")
                    for o in kol.get("oceny") or []:
                        v, dt = str(o.get("wpis", "")), str(o.get("dataOceny", ""))
                        subjects[subj].append({"w": v, "d": dt[:10], "i": desc})

            lista, prop_vals, okr_vals = [], [], []
            for subj_name, grades in subjects.items():
                vals = [x for x in (parse_grade_value(g["w"]) for g in grades) if x is not None]
                periodic = subj_periodic.get(subj_name, {})
                prop_raw, okr_raw = periodic.get("proponowana"), periodic.get("okresowa")
                prop_num, okr_num = map_grade_to_num(prop_raw), map_grade_to_num(okr_raw)
                if subj_name.strip().lower() != "zachowanie":
                    if prop_num is not None:
                        prop_vals.append(prop_num)
                    if okr_num is not None:
                        okr_vals.append(okr_num)
                lista.append(
                    {
                        "przedmiot": subj_name,
                        "oceny": grades,
                        "srednia": round(sum(vals) / len(vals), 2) if vals else None,
                        "proponowana": prop_raw,
                        "okresowa": okr_raw,
                    }
                )

            periods_out[p_num] = {
                "period_id": p_id,
                "active": p_id == str(s.get("periodId")),
                "lista_przedmiotow": lista,
                "srednia_proponowanych": round(sum(prop_vals) / len(prop_vals), 3) if prop_vals else None,
                "srednia_okresowych": round(sum(okr_vals) / len(okr_vals), 3) if okr_vals else None,
                "liczba_ocen": sum(len(x["oceny"]) for x in lista),
            }
        return periods_out

    # ────────────────────────────────────────────────
    # PLAN LEKCJI + DNI WOLNE
    # ────────────────────────────────────────────────

    async def async_fetch_schedule(self, s: dict) -> dict[str, Any]:
        base = f"{UCZEN_BASE}/{s['city']}"
        key = s["key"]
        now = datetime.now()
        d_od = now - timedelta(days=now.weekday() + 7)
        d_do = now + timedelta(days=21)

        lessons = await self._get_json(
            f"{base}/api/PlanZajec",
            params={
                "key": key,
                "dataOd": d_od.strftime("%Y-%m-%dT00:00:00.000Z"),
                "dataDo": d_do.strftime("%Y-%m-%dT23:59:59.999Z"),
                "zakresDanych": "2",
            },
        )
        free_days_raw = await self._get_json(
            f"{base}/api/DniWolne",
            params={
                "key": key,
                "dataOd": d_od.strftime("%Y-%m-%dT00:00:00.000Z"),
                "dataDo": d_do.strftime("%Y-%m-%dT23:59:59.999Z"),
            },
        )
        if not isinstance(lessons, list):
            lessons = []
        if not isinstance(free_days_raw, list):
            free_days_raw = []

        jednostki = {l.get("idJednostkaSkladowa") for l in lessons if l.get("idJednostkaSkladowa") is not None}

        proc_lessons = []
        for lesson in lessons:
            status = MAPA_STATUSOW.get(int(lesson.get("adnotacja") or 0), "")
            info = " ".join((c.get("informacjeNieobecnosc") or "").lower() for c in lesson.get("zmiany") or [])
            if "zwolnieni" in info or "okienko" in info:
                status = "ODWOL"
            godz_od = lesson.get("godzinaOd") or "T00:00"
            godz_do = lesson.get("godzinaDo") or "T00:00"
            proc_lessons.append(
                {
                    "d": (lesson.get("data") or "").split("T")[0],
                    "g": f"{godz_od.split('T')[-1][:5]}-{godz_do.split('T')[-1][:5]}",
                    "p": lesson.get("przedmiot") or "Zajęcia",
                    "s": lesson.get("sala", "") or "",
                    "n": lesson.get("prowadzacy", "") or "",
                    "st": status,
                }
            )

        free_days = []
        for fd in free_days_raw:
            valid = fd.get("wszystkieSkladowe", False)
            if not valid:
                valid = any(j.get("id") in jednostki for j in fd.get("jednostkiSkladowe") or [])
            if not valid:
                continue
            dt_od, dt_do = (fd.get("dataOd") or "")[:10], (fd.get("dataDo") or "")[:10]
            if dt_od and dt_do:
                free_days.append({"od": dt_od, "do": dt_do, "n": fd.get("nazwa") or ""})

        monday = now - timedelta(days=now.weekday())
        weeks = {
            "prev": (monday - timedelta(7), monday - timedelta(1)),
            "curr": (monday, monday + timedelta(6)),
            "next": (monday + timedelta(7), monday + timedelta(13)),
        }
        out: dict[str, Any] = {}
        today = now.strftime("%Y-%m-%d")
        for suf, (sd, ed) in weeks.items():
            sd_s, ed_s = sd.strftime("%Y-%m-%d"), ed.strftime("%Y-%m-%d")
            week_lessons = [l for l in proc_lessons if sd_s <= l["d"] <= ed_s]
            week_free = [f for f in free_days if not (f["do"] < sd_s or f["od"] > ed_s)]
            state = len([l for l in week_lessons if l["d"] == today]) if suf == "curr" else len(week_lessons)
            out[suf] = {"state": state, "lekcje": week_lessons, "dni_wolne": week_free}
        return out

    # ────────────────────────────────────────────────
    # TERMINARZ (SPRAWDZIANY / ZADANIA)
    # ────────────────────────────────────────────────

    async def async_fetch_agenda(self, s: dict) -> dict[str, Any]:
        base = f"{UCZEN_BASE}/{s['city']}"
        key = s["key"]
        now = datetime.now()
        last_day_prev_month = now.replace(day=1) - timedelta(days=1)

        items = await self._get_json(
            f"{base}/api/SprawdzianyZadaniaDomowe",
            params={
                "key": key,
                "dataOd": last_day_prev_month.strftime("%Y-%m-%dT00:00:00.000Z"),
                "dataDo": (now + timedelta(days=61)).strftime("%Y-%m-%dT23:59:59.999Z"),
            },
        )
        if not isinstance(items, list):
            items = []

        lista = []
        for item in items:
            item_id = item.get("id")
            if not item_id:
                continue
            ep = "ZadanieDomoweSzczegoly" if item.get("typ") == 4 else "SprawdzianSzczegoly"
            try:
                dj = await self._get_json(f"{base}/api/{ep}", params={"key": key, "id": item_id})
                if not isinstance(dj, dict):
                    dj = {}
            except EduVulcanAuthError:
                raise
            except Exception:  # noqa: BLE001 - pojedynczy szczegół nie może wywalić całości
                dj = {}

            data_str = dj.get("data") or item.get("data", "")
            termin_str = dj.get("terminOdpowiedzi") or item.get("terminOdpowiedzi") or ""
            data = (termin_str or data_str).split("T")[0]
            raw_opis = (
                dj.get("opis") or dj.get("temat") or dj.get("tresc")
                or item.get("opis") or item.get("temat") or ""
            )
            opis = clean_html(raw_opis)
            if opis == "Brak opisu" and "<iframe" in raw_opis.lower():
                opis = "[Wstawiono załącznik - sprawdź treść w oficjalnej aplikacji]"

            lista.append(
                {
                    "data": data,
                    "przedmiot": dj.get("przedmiotNazwa") or item.get("przedmiotNazwa", ""),
                    "typ": MAPA_TYP_TERMINARZA.get(item.get("typ"), "Inne"),
                    "opis": opis,
                    "autor": dj.get("nauczycielImieNazwisko") or item.get("nauczycielImieNazwisko", ""),
                }
            )

        today = now.strftime("%Y-%m-%d")
        nadchodzace = [x for x in lista if x["data"] >= today]
        nadchodzace.sort(key=lambda x: x["data"])
        return {"state": len(nadchodzace), "lista": nadchodzace}

    # ────────────────────────────────────────────────
    # UWAGI I POCHWAŁY
    # ────────────────────────────────────────────────

    async def async_fetch_remarks(self, s: dict) -> dict[str, Any]:
        base = f"{UCZEN_BASE}/{s['city']}"
        items = await self._get_json(f"{base}/api/Uwagi", params={"key": s["key"]})
        if not isinstance(items, list):
            items = []
        lista = []
        for item in items:
            if not item.get("id"):
                continue
            tr = item.get("tresc", "")
            typ = (
                "pozytywna" if "pochwa" in tr.lower()
                else "negatywna" if "uwaga" in tr.lower()
                else "informacja"
            )
            lista.append(
                {
                    "data": item.get("data", "").split("T")[0],
                    "tresc": tr,
                    "autor": item.get("autor", ""),
                    "kategoria": item.get("kategoria", ""),
                    "punkty": item.get("liczbaPunktow"),
                    "typ": typ,
                }
            )
        lista.sort(key=lambda x: x["data"], reverse=True)
        return {"state": len(lista), "lista": lista}

    # ────────────────────────────────────────────────
    # FREKWENCJA + STATYSTYKI
    # ────────────────────────────────────────────────

    async def async_fetch_attendance(self, s: dict) -> dict[str, Any]:
        base = f"{UCZEN_BASE}/{s['city']}"
        key = s["key"]
        now = datetime.now()

        freq = await self._get_json(
            f"{base}/api/Frekwencja",
            params={
                "key": key,
                "dataOd": (now - timedelta(14)).strftime("%Y-%m-%dT00:00:00.000Z"),
                "dataDo": now.strftime("%Y-%m-%dT23:59:59.999Z"),
            },
        )
        if isinstance(freq, dict):
            freq = freq.get("oddzialy") or []
        if not isinstance(freq, list):
            freq = []

        wpisy = []
        for fi in freq:
            data, godz = fi.get("data", ""), fi.get("godzinaOd", "")
            if data and godz:
                wpisy.append(
                    {
                        "d": data.split("T")[0],
                        "t": godz.split("T")[-1][:5],
                        "k": int(fi.get("kategoriaFrekwencji", 0)),
                    }
                )
        wpisy.sort(key=lambda x: (x["d"], x["t"]), reverse=True)

        przedmioty = await self._get_json(f"{base}/api/Przedmioty", params={"key": key})
        if not isinstance(przedmioty, list):
            przedmioty = []

        def _parse_rows(fsd: dict) -> list:
            return [
                {
                    "k": MAPA_FREKWENCJI.get(row.get("kategoriaFrekwencji"), "Inna"),
                    "m": {str(m["miesiac"]): m["wartosc"] for m in (row.get("miesiace") or [])},
                    "s1": (row.get("okresy") or [0, 0])[0],
                    "s2": (row.get("okresy") or [0, 0])[1] if len(row.get("okresy") or []) > 1 else 0,
                    "r": row.get("razem", 0),
                }
                for row in (fsd.get("statystyki") or [])
            ]

        stats_all = await self._get_json(f"{base}/api/FrekwencjaStatystyki", params={"key": key, "idPrzedmiot": -1})
        stats_global = {
            "procent": stats_all.get("podsumowanie", 0) if isinstance(stats_all, dict) else 0,
            "rows": _parse_rows(stats_all) if isinstance(stats_all, dict) else [],
        }

        per_subject = []
        for p in przedmioty:
            if p.get("id", -1) == -1:
                continue
            try:
                fsd_p = await self._get_json(
                    f"{base}/api/FrekwencjaStatystyki", params={"key": key, "idPrzedmiot": p["id"]}
                )
            except EduVulcanAuthError:
                raise
            except Exception:  # noqa: BLE001
                continue
            if not isinstance(fsd_p, dict) or fsd_p.get("podsumowanie") is None:
                continue
            per_subject.append(
                {
                    "id": p["id"],
                    "przedmiot": p.get("nazwa"),
                    "procent": fsd_p.get("podsumowanie"),
                    "rows": _parse_rows(fsd_p),
                }
            )

        return {"wpisy": wpisy, "statystyki_globalne": stats_global, "statystyki_przedmioty": per_subject}

    # ────────────────────────────────────────────────
    # OSIĄGNIĘCIA
    # ────────────────────────────────────────────────

    async def async_fetch_achievements(self, s: dict) -> dict[str, Any]:
        base = f"{UCZEN_BASE}/{s['city']}"
        items = await self._get_json(f"{base}/api/Osiagniecia", params={"key": s["key"]})
        if not isinstance(items, list):
            items = []
        lista = [{"id": i.get("id"), "tresc": i.get("tresc", "")} for i in items if i.get("id")]
        return {"state": len(lista), "lista": lista}

    # ────────────────────────────────────────────────
    # ZEBRANIA
    # ────────────────────────────────────────────────

    async def async_fetch_meetings(self, s: dict) -> dict[str, Any]:
        base = f"{UCZEN_BASE}/{s['city']}"
        items = await self._get_json(f"{base}/api/Zebrania", params={"key": s["key"]})
        if not isinstance(items, list):
            items = []
        lista = []
        for item in items:
            if not item.get("id"):
                continue
            dt_raw = item.get("dataCzas") or ""
            lista.append(
                {
                    "data": dt_raw.split("T")[0] if "T" in dt_raw else dt_raw,
                    "godzina": dt_raw.split("T")[1][:5] if "T" in dt_raw else "",
                    "sala": item.get("sala") or "",
                    "opis": item.get("opis") or "",
                    "online": bool(item.get("zebranieOnline")),
                }
            )
        lista.sort(key=lambda x: (x["data"], x["godzina"]), reverse=True)
        today = datetime.now().strftime("%Y-%m-%d")
        nadchodzace = sum(1 for r in lista if r["data"] >= today)
        return {"state": nadchodzace, "lista": lista}

    # ────────────────────────────────────────────────
    # SZCZĘŚLIWY NUMEREK
    # ────────────────────────────────────────────────

    async def async_fetch_lucky_number(self, s: dict) -> dict[str, Any]:
        base = f"{UCZEN_BASE}/{s['city']}"
        data = await self._get_json(f"{base}/api/SzczesliwyNumerTablica", params={"key": s["key"]})
        if isinstance(data, dict) and data:
            return {"numer": str(data.get("numer", "Brak")), "id": str(data.get("id", ""))}
        return {"numer": "Brak", "id": ""}

    # ────────────────────────────────────────────────
    # WIADOMOŚCI (osobna domena + "przesiadka" sesji SSO)
    # ────────────────────────────────────────────────

    async def _ensure_messages_session(self, s: dict) -> httpx.AsyncClient | None:
        if self._msg_client is not None:
            return self._msg_client
        city = s["city"]
        client = httpx.AsyncClient(
            cookies=dict(self._client.cookies),
            headers={
                "X-Requested-With": "XMLHttpRequest",
                "Referer": f"{WIADOMOSCI_BASE}/{city}/App",
            },
            timeout=20,
            follow_redirects=True,
        )
        try:
            resp = await client.get(f"{WIADOMOSCI_BASE}/{city}/App")
        except httpx.HTTPError as exc:
            await client.aclose()
            raise EduVulcanAuthError(f"Błąd inicjalizacji sesji wiadomości: {exc}") from exc
        if _looks_like_login_redirect(resp):
            await client.aclose()
            raise EduVulcanAuthError("Sesja wiadomości: przekierowano do logowania.")
        self._msg_client = client
        return client

    async def async_fetch_messages(self, s: dict) -> dict[str, Any]:
        gk = s.get("globalKeySkrzynka")
        if not gk:
            return {"state": 0, "wiadomosci": [], "stats": "0 / 0"}

        client = await self._ensure_messages_session(s)
        url = (
            f"{WIADOMOSCI_BASE}/{s['city']}/api/OdebraneSkrzynka"
            f"?globalKeySkrzynka={gk}&idLastWiadomosc=0&pageSize=50"
        )
        resp = await client.get(url)
        if resp.status_code != 200:
            raise EduVulcanAuthError(f"Błąd pobierania skrzynki: HTTP {resp.status_code}")
        rows = resp.json()
        if not isinstance(rows, list):
            rows = []

        rows.sort(key=lambda r: r.get("data", ""), reverse=True)
        total = len(rows)
        unread_total = sum(1 for r in rows if not r.get("przeczytana"))

        # Treść wiadomości pobieramy tylko dla 10 najnowszych (jak w oryginale
        # ograniczenie do LIMIT 10 przy wyświetlaniu) i tylko dla nieprzeczytanych
        # (przeczytane pokazujemy bez treści, tak jak oryginalny dodatek).
        msgs = []
        for r in rows[:10]:
            is_read = bool(r.get("przeczytana"))
            body = ""
            if not is_read:
                m_k = r.get("apiGlobalKey")
                if m_k:
                    try:
                        det = await client.get(
                            f"{WIADOMOSCI_BASE}/{s['city']}/api/WiadomoscSzczegoly",
                            params={"apiGlobalKey": m_k},
                        )
                        if det.status_code == 200:
                            body = clean_html(det.json().get("tresc", "Brak"))
                    except Exception as exc:  # noqa: BLE001
                        _LOGGER.debug("Błąd pobierania treści wiadomości: %s", exc)
                if len(body) > 2000:
                    body = body[:1997] + "..."
            msgs.append(
                {
                    "data": (r.get("data", "") or "").replace("T", " ")[:16],
                    "nadawca": r.get("korespondenci", ""),
                    "temat": r.get("temat", ""),
                    "tresc": body,
                    "przeczytana": is_read,
                }
            )
        return {"state": unread_total, "wiadomosci": msgs, "stats": f"{unread_total} / {total}"}
EDUVULCAN_EOF

cat > "$TARGET/config_flow.py" << 'EDUVULCAN_EOF'
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
EDUVULCAN_EOF

cat > "$TARGET/const.py" << 'EDUVULCAN_EOF'
"""Stałe dla integracji EduVulcan (nieoficjalna)."""
from __future__ import annotations

DOMAIN = "eduvulcan"

CONF_COOKIE = "cookie"
CONF_CITY = "city"

UCZEN_BASE = "https://uczen.eduvulcan.pl"
WIADOMOSCI_BASE = "https://wiadomosci.eduvulcan.pl"

# Odpowiednik anty-detekcyjnego harmonogramu z oryginalnego dodatku:
# losowy odstęp 40-60 minut między cyklami.
MIN_INTERVAL_SECONDS = 40 * 60
MAX_INTERVAL_SECONDS = 60 * 60

# Mapy tłumaczeń kodów zwracanych przez API (przepisane 1:1 z oryginału)
MAPA_STATUSOW: dict[int, str] = {0: "", 1: "ZAST", 2: "PRZEN", 3: "ODWOL", 4: "NIEOB"}
MAPA_FREKWENCJI: dict[int, str] = {
    1: "Obecność", 2: "Nieobecność", 3: "Usprawiedliwiona",
    4: "Spóźnienie", 5: "Spóźnienie uspraw.", 6: "Szkolne", 7: "Zwolnienie",
}
MAPA_TYP_TERMINARZA: dict[int, str] = {
    1: "Sprawdzian", 2: "Kartkówka", 3: "Klasówka", 4: "Zadanie domowe",
}
EDUVULCAN_EOF

cat > "$TARGET/coordinator.py" << 'EDUVULCAN_EOF'
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
        if len(new_cookie) > 6000:
            _LOGGER.warning(
                "EduVulcan: zrotowane ciasteczko jest podejrzanie duże (%d znaków) — "
                "zapisuję mimo to, ale jeśli reauth zacznie się powtarzać, to prawdopodobnie "
                "przyczyna: sprawdź czy nie doszło do jeszcze innego niekontrolowanego "
                "narastania jakiegoś ciasteczka.",
                len(new_cookie),
            )
        self.hass.config_entries.async_update_entry(
            self.entry, data={**self.entry.data, CONF_COOKIE: new_cookie}
        )
        _LOGGER.debug("EduVulcan: zapisano zrotowane ciasteczko sesji")
EDUVULCAN_EOF

cat > "$TARGET/html_utils.py" << 'EDUVULCAN_EOF'
"""Pomocnicze funkcje czyszczenia HTML / slugify.

Przepisane 1:1 z oryginalnego dodatku Vultron (autor: htomasz), bez zmian
w logice — tylko wydzielone do osobnego modułu.
"""
from __future__ import annotations

import re
from html.parser import HTMLParser

_RE_MULTIPLE_NEWLINES = re.compile(r"\n{3,}")
_RE_SPACES = re.compile(r" {2,}")
_PL_TRANS = str.maketrans("ąćęłńóśźż", "acelnoszz")


def slugify(text: str) -> str:
    if not text:
        return "unknown"
    return re.sub(r"[^a-z0-9]+", "_", text.lower().translate(_PL_TRANS)).strip("_")


class _HTMLStripper(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.reset()
        self.strict = False
        self.convert_charrefs = True
        self.text: list[str] = []
        self.current_href = ""

    @staticmethod
    def is_safe_url(url: str) -> bool:
        if not url:
            return False
        u = url.strip().lower()
        if u.startswith(("javascript:", "data:", "vbscript:")):
            return False
        return True

    def handle_starttag(self, tag, attrs):
        if tag in ("br", "p", "div", "li", "tr"):
            self.text.append("\n")
        elif tag in ("b", "strong"):
            self.text.append("**")
        elif tag in ("i", "em"):
            self.text.append("*")
        elif tag == "a":
            href = dict(attrs).get("href", "")
            if self.is_safe_url(href):
                self.current_href = href.strip()
        elif tag == "img":
            src = dict(attrs).get("src", "")
            alt = dict(attrs).get("alt", "")
            if self.is_safe_url(src):
                img_text = f" {alt} ({src}) " if alt else f" {src} "
                self.text.append(img_text)

    def handle_endtag(self, tag):
        if tag in ("p", "div", "li", "tr"):
            self.text.append("\n")
        elif tag in ("b", "strong"):
            self.text.append("**")
        elif tag in ("i", "em"):
            self.text.append("*")
        elif tag == "a" and self.current_href:
            self.text.append(f" ({self.current_href})")
            self.current_href = ""

    def handle_data(self, d):
        self.text.append(d)

    def get_data(self) -> str:
        return "".join(self.text)


def clean_html(raw: str) -> str:
    """Zamienia HTML na czytelny tekst (Markdown-lite), odporne na XSS."""
    if not raw:
        return "Brak opisu"
    stripper = _HTMLStripper()
    stripper.feed(raw)
    text = stripper.get_data().replace("&nbsp;", " ")
    text = _RE_MULTIPLE_NEWLINES.sub("\n\n", text)
    text = _RE_SPACES.sub(" ", text)
    return text.strip()


def map_grade_to_num(raw: str | None) -> float | None:
    """Mapuje ocenę słowną/cyfrową na liczbę (przepisane z vultron.py)."""
    if not raw:
        return None
    s = raw.strip().lower()
    word_map = {
        "celujący": 6, "celująca": 6, "wzorowe": 6,
        "bardzo dobry": 5, "bardzo dobra": 5, "bardzo dobre": 5,
        "dobry": 4, "dobra": 4, "dobre": 4,
        "dostateczny": 3, "dostateczna": 3, "poprawne": 3,
        "mierny": 2, "mierna": 2, "nieodpowiednie": 2,
        "niedostateczny": 1, "niedostateczna": 1, "naganne": 1,
    }
    if s in word_map:
        return float(word_map[s])
    m_slash = re.fullmatch(r"(\d+)\s*/\s*(\d+)", s)
    if m_slash:
        return float(min(int(m_slash.group(1)), int(m_slash.group(2))))
    m_digit = re.fullmatch(r"([1-6])", s)
    if m_digit:
        return float(m_digit.group(1))
    return None


def parse_grade_value(w: str) -> float | None:
    """Parsuje pojedynczy wpis oceny cząstkowej do liczby (do liczenia średniej)."""
    w_str = str(w).strip().upper()
    if re.search(r"[A-F%]|NB|NP|BZ", w_str):
        return None
    m_dec = re.search(r"(?<!\d)([1-6])(?:[.,](\d+))?(?!\d)", w_str)
    if not m_dec:
        return None
    v = float(m_dec.group(1))
    if m_dec.group(2):
        v += float("0." + m_dec.group(2))
    elif "+" in w_str:
        v += 0.5
    elif "-" in w_str:
        v -= 0.25
    return v
EDUVULCAN_EOF

cat > "$TARGET/sensor.py" << 'EDUVULCAN_EOF'
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
EDUVULCAN_EOF

cat > "$TARGET/manifest.json" << 'EDUVULCAN_EOF'
{
  "domain": "eduvulcan",
  "name": "EduVulcan (nieoficjalna)",
  "codeowners": ["@amiseh"],
  "config_flow": true,
  "documentation": "https://github.com/amiseh/vul-tst",
  "issue_tracker": "https://github.com/amiseh/vul-tst/issues",
  "iot_class": "cloud_polling",
  "requirements": ["httpx>=0.27.0"],
  "version": "1.0.2"
}
EDUVULCAN_EOF

cat > "$TARGET/strings.json" << 'EDUVULCAN_EOF'
{
  "config": {
    "step": {
      "user": {
        "title": "EduVulcan",
        "description": "Podaj miasto (segment z adresu uczen.eduvulcan.pl/<miasto>/...) oraz wklej cały nagłówek Cookie z zapytania do uczen.eduvulcan.pl (DevTools -> Network -> dowolne zapytanie do tej domeny -> Headers -> Cookie).",
        "data": {
          "city": "Miasto (z adresu URL)",
          "cookie": "Cookie (wklejone z przeglądarki)"
        }
      },
      "reauth_confirm": {
        "title": "Odśwież sesję EduVulcan",
        "description": "Ciasteczko wygasło. Zaloguj się ponownie w przeglądarce na eduvulcan.pl (miasto: {city}) i wklej nowy nagłówek Cookie.",
        "data": {
          "cookie": "Nowe Cookie"
        }
      }
    },
    "error": {
      "invalid_auth": "Ciasteczko jest nieprawidłowe albo wygasło.",
      "cannot_connect": "Nie udało się połączyć z EduVulcan.",
      "no_students": "Nie znaleziono żadnych uczniów dla tego konta."
    },
    "abort": {
      "already_configured": "To konto/miasto jest już skonfigurowane.",
      "reauth_successful": "Sesja odświeżona pomyślnie."
    }
  }
}
EDUVULCAN_EOF

cat > "$TARGET/translations/pl.json" << 'EDUVULCAN_EOF'
{
  "config": {
    "step": {
      "user": {
        "title": "EduVulcan",
        "description": "Podaj miasto (segment z adresu uczen.eduvulcan.pl/<miasto>/...) oraz wklej cały nagłówek Cookie z zapytania do uczen.eduvulcan.pl (DevTools -> Network -> dowolne zapytanie do tej domeny -> Headers -> Cookie).",
        "data": {
          "city": "Miasto (z adresu URL)",
          "cookie": "Cookie (wklejone z przeglądarki)"
        }
      },
      "reauth_confirm": {
        "title": "Odśwież sesję EduVulcan",
        "description": "Ciasteczko wygasło. Zaloguj się ponownie w przeglądarce na eduvulcan.pl (miasto: {city}) i wklej nowy nagłówek Cookie.",
        "data": {
          "cookie": "Nowe Cookie"
        }
      }
    },
    "error": {
      "invalid_auth": "Ciasteczko jest nieprawidłowe albo wygasło.",
      "cannot_connect": "Nie udało się połączyć z EduVulcan.",
      "no_students": "Nie znaleziono żadnych uczniów dla tego konta."
    },
    "abort": {
      "already_configured": "To konto/miasto jest już skonfigurowane.",
      "reauth_successful": "Sesja odświeżona pomyślnie."
    }
  }
}
EDUVULCAN_EOF

if [ -d /tmp/eduvulcan_www_backup ]; then
  mv /tmp/eduvulcan_www_backup "$TARGET/www"
  echo "Przywrócono folder www/ (karty)."
fi

echo "=== Weryfikacja: api.py pierwsza linia ==="
head -1 "$TARGET/api.py"
echo "=== Weryfikacja: brak importu z samego siebie ==="
grep -n "from .api import" "$TARGET/api.py" || echo "OK - brak (dobrze)"
echo "Gotowe. Zawartosc folderu:"
ls -la "$TARGET"
echo "Restartuje Home Assistant..."
docker restart homeassistant
