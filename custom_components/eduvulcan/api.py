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
        """
        return "; ".join(f"{name}={value}" for name, value in self._client.cookies.items())

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
