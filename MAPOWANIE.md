# Mapowanie: vultron.py (htomasz) → nasza integracja EduVulcan

Ten dokument pokazuje, gdzie szukać odpowiednika danej funkcji z
oryginalnego `vultron.py`, jeśli autor coś tam zmieni/naprawi. Przydatne
przy aktualizacjach — zamiast czytać cały plik od nowa, sprawdź tabelę,
znajdź sekcję, porównaj.

## Zasada ogólna

Oryginał to **jeden plik** (`vultron.py`, ~1850 linii) łączący: logowanie
Selenium, scraping HTTP, zapis do SQLite, i publikację do HA przez REST
API "z zewnątrz". Nasza integracja jest **rozbita na moduły** i działa
"od środka" HA (native `SensorEntity` + `DataUpdateCoordinator`), więc
mapowanie 1:1 nie zawsze istnieje — czasem jedna funkcja w oryginale
odpowiada dwóm miejscom u nas, a czasem coś w ogóle nie ma odpowiednika
(bo HA załatwia to za nas).

## Konfiguracja / stałe

| vultron.py | U nas | Uwagi |
| --- | --- | --- |
| `HA_URL`, `HA_TOKEN`, nagłówki | — (niepotrzebne) | HA samo dostarcza `hass`/`ConfigEntry`, integracja działa "od środka" |
| `DB_PATH`, `_DB_DDL`, `db_connect()`, `db_init()` | — (niepotrzebne) | Zero SQLite — każde zapytanie do API już zwraca pełny stan, nie trzeba go akumulować |
| `MAPA_STATUSOW`, `MAPA_FREKWENCJI`, `MAPA_TYP_TERMINARZA` | `const.py` | Przepisane 1:1, te same klucze/wartości |
| `_PL_TRANS`, `slugify()` | `html_utils.py: slugify()` | Identyczna logika |
| `_HTMLStripper`, `clean_html()` | `html_utils.py` | Identyczna logika |
| `_sent_hashes`, dedup powiadomień | — (nie zaimplementowane) | U nas nie ma warstwy powiadomień — do zrobienia jako osobna automatyzacja/blueprint, jeśli zechcesz |

## Logowanie i sesja

| vultron.py | U nas | Uwagi |
| --- | --- | --- |
| `_get_driver()`, Selenium/Chromium | — (usunięte całkowicie) | Zamiast tego: ręcznie wklejone ciasteczko przez `config_flow.py` |
| `run_diary_auth()` (logowanie + `/api/Context` + pętla po uczniach) | `api.py: async_fetch_students()` | Ta sama logika parsowania `/api/Context` i `/api/OkresyKlasyfikacyjne`, tylko bez kroku logowania Selenium |
| Ekstrakcja `city` z `driver.current_url` | Pole "Miasto" w `config_flow.py` (podajesz ręcznie) | Nie mamy przeglądarki, która by nas tam przekierowała |
| Ciasteczka `wiadomosci_cookies` (osobny SSO) | `api.py: _ensure_messages_session()` | Zaimplementowane, ale **wyłączone** w `coordinator.py` (sesja SSO wiadomości wymaga dalszej diagnostyki) |

## Pobieranie danych (główna logika)

| vultron.py | U nas | Uwagi |
| --- | --- | --- |
| `_fetch_grades()` | `api.py: async_fetch_grades()` | Ten sam endpoint `/api/Oceny`, te same mapowania ocen (`map_grade_to_num`, `parse_grade_value` w `html_utils.py`) |
| `_fetch_schedule()` | `api.py: async_fetch_schedule()` | `/api/PlanZajec` + `/api/DniWolne`, ten sam podział na `prev`/`curr`/`next` |
| `_fetch_timetable()` (terminarz) | `api.py: async_fetch_agenda()` | `/api/SprawdzianyZadaniaDomowe` + szczegóły |
| `_fetch_remarks()` (uwagi) | `api.py: async_fetch_remarks()` | `/api/Uwagi` |
| `_fetch_frequency()` (frekwencja + statystyki) | `api.py: async_fetch_attendance()` | `/api/Frekwencja`, `/api/Przedmioty`, `/api/FrekwencjaStatystyki` |
| `_fetch_achievements()` | `api.py: async_fetch_achievements()` | `/api/Osiagniecia` |
| `_fetch_lucky_number()` | `api.py: async_fetch_lucky_number()` | `/api/SzczesliwyNumerTablica` |
| `_fetch_meetings()` (zebrania) | `api.py: async_fetch_meetings()` | `/api/Zebrania` |
| `run_messages_sync()`, `_fetch_inbox()`, `_build_city_session()` | `api.py: async_fetch_messages()` | Zaimplementowane, ale **wyłączone** (patrz wyżej) |
| `sync_diary_data()` (orkiestrator wołający wszystkie `_fetch_*`) | `coordinator.py: EduVulcanCoordinator._async_update_data()` | U nas to pętla po słowniku `fetchers` zamiast osobnych `await` w jednej funkcji |

## Publikacja do Home Assistant

| vultron.py | U nas | Uwagi |
| --- | --- | --- |
| `publish_sensor()` / `publish_sensor_sync()` (POST do `/api/states/...`) | `sensor.py`: właściwości `native_value` / `extra_state_attributes` na klasach `SensorEntity` | **Fundamentalna różnica architektoniczna**: oryginał "pcha" stan do HA z zewnątrz przez REST; my jesteśmy natywną integracją — HA sam czyta stan z naszych obiektów Pythona, nic nigdzie nie "wysyłamy" |
| `check_and_restore()`, `restore_entities_from_cache()` (VUL_PKL/BUL_PKL) | — (niepotrzebne) | `CoordinatorEntity` w HA sam pamięta ostatni stan między restartami, nie trzeba własnego cache na dysku |
| `run_setup_ui()` (WebSocket → `lovelace/resources/create`) | `__init__.py: _async_register_cards()` | Ten sam **cel** (auto-rejestracja kart), inny **mechanizm**: `add_extra_js_url()` zamiast wpisów na liście Zasobów — patrz nasza wcześniejsza rozmowa o różnicy |
| `_MONITOR_TEMPLATE`, `_run_size_monitor()` (monitor rozmiaru atrybutów ~16kB) | — (nie zaimplementowane) | Możliwe do dodania jako osobny sensor diagnostyczny, jeśli kiedyś zaczniesz dostawać ostrzeżenia w logach HA o zbyt dużych atrybutach |

## Harmonogram

| vultron.py | U nas | Uwagi |
| --- | --- | --- |
| `main_loop()` — pętla `while`, logika nocna/weekendowa, `secrets.randbelow()` | `coordinator.py: _next_quiet_wake_delay()` + `EduVulcanCoordinator._async_update_data()` | Ta sama logika godzinowa (przepisana), ale u nas to `DataUpdateCoordinator` z dynamicznym `update_interval`, a nie ręczna pętla `while` ze `sleep` |

## Jak korzystać z tej tabeli przy aktualizacji

1. Sprawdź [CHANGELOG](https://github.com/htomasz/vultron/blob/main/vultron/CHANGELOG.md) albo commity w `vultron.py` — co się zmieniło.
2. Znajdź w tabeli, której funkcji to dotyczy.
3. Podeślij mi fragment jego zmienionego kodu (starą i nową wersję) + wskaż z tabeli, gdzie to u nas mieszka — przeniosę zmianę.
4. Jeśli zmiana dotyczy kart `.js` — zwykle wystarczy podmienić plik w `custom_components/eduvulcan/www/`, bez zmian w Pythonie.
