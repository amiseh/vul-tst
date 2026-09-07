![GitHub release](https://img.shields.io/github/v/release/amiseh/vul-tst?style=flat-square)
![GitHub last commit](https://img.shields.io/github/last-commit/amiseh/vul-tst?style=flat-square&logo=git&logoColor=white)
![Maintenance](https://img.shields.io/badge/Maintained%3F-yes-green.svg?style=flat-square)
![GitHub license](https://img.shields.io/github/license/amiseh/vul-tst?style=flat-square)
![GitHub issues](https://img.shields.io/github/issues/amiseh/vul-tst?style=flat-square)
[![HACS Custom](https://img.shields.io/badge/HACS-Custom-41BDF5.svg?style=flat-square&logo=home-assistant&logoColor=white)](https://hacs.xyz)
![Python](https://img.shields.io/badge/Python-blue?style=flat-square&logo=python&logoColor=white)
![No Selenium](https://img.shields.io/badge/Selenium-nie%20potrzebny-critical?style=flat-square)
![Native Integration](https://img.shields.io/badge/Integracja-natywna%20HA-success?style=flat-square&logo=home-assistant&logoColor=white)

<p align="center">
  <br><b>Nieoficjalna integracja EduVulcan.pl dla Home Assistant — bez Selenium, bez Dockera, bez dodatkowego kontenera.</b>
</p>

# EduVulcan (integracja nieoficjalna)

**EduVulcan** to natywna integracja Home Assistant instalowana przez moduł **HACS** — dodajesz ją normalnie jak każdą inną integrację, konfigurujesz przez zwykły formularz w interfejsie (bez edytowania żadnych plików YAML), i dostajesz prawdziwe encje `sensor.*` z urządzeniem per dziecko oraz te same ładne karty Lovelace co w oryginalnym dodatku [htomasz/vultron](https://github.com/htomasz/vultron) — bez Selenium, bez Chromium, bez osobnego kontenera Docker.

> [!NOTE]
> **Co to jest ten formularz konfiguracji?** W żargonie Home Assistanta nazywa się to `config_flow` — to standardowy mechanizm HA, dzięki któremu integrację ustawia się przez ekran "Ustawienia → Urządzenia i usługi → Dodaj integrację" zamiast ręcznie edytować `configuration.yaml`. Ten sam mechanizm obsługuje też ekran "wklej nowe ciasteczko", który zobaczysz, gdy sesja wygaśnie (tzw. reauth) — to po prostu kolejny krok tego samego formularza. Nie musisz nic o tym wiedzieć, żeby korzystać z integracji — to działa "samo".

**Bazuje na:** [htomasz/vultron](https://github.com/htomasz/vultron) (autor: htomasz) \
**Wersja:** 1.0.1 \
**Licencja:** GPL-3.0 (jak oryginał)

# 📖 Spis treści
* [🚨 Ważne](#-ważne)
* [🧬 Pochodzenie projektu](#-pochodzenie-projektu)
* [✨ Co tworzy integracja](#-co-tworzy-integracja-na-każde-dziecko)
* [🚀 Instalacja](#-instalacja)
* [🍪 Jak zdobyć ciasteczko](#-jak-zdobyć-ciasteczko-raz-ręcznie)
* [⚙️ Konfiguracja](#️-konfiguracja-w-home-assistant)
* [🔁 Rotacja ciasteczka sesji](#-rotacja-ciasteczka-sesji-ważne)
* [⏰ Harmonogram pobierania](#-harmonogram-pobierania)
* [🎨 Karty Lovelace](#-karty-lovelace--w-pełni-automatyczne)
* [📊 Przykładowe karty dashboardu](#-przykładowe-karty-dashboardu)
* [🔧 Wymuszanie odświeżenia](#-wymuszanie-odświeżenia-poza-harmonogramem)
* [🔄 Aktualizacje](#-aktualizacje)
* [🗺️ Mapowanie z oryginałem](#️-mapowanie-z-oryginałem)

## 🚨 Ważne

> [!WARNING]
> Korzystanie z tego API poza oficjalną aplikacją narusza regulamin EduVulcan.pl (autor oryginalnego dodatku sam to zaznacza wprost, mocno i wielokrotnie). To Twoja decyzja i ryzyko — ten kod tylko odtwarza w natywnej formie coś, co wcześniej działało jako dodatek Supervisora.

> [!NOTE]
> Logowanie robisz sam, raz, w swojej przeglądarce — integracja korzysta z ciasteczka sesji, które jej wklejasz, i dalej robi już tylko zwykłe zapytania HTTP do wewnętrznego API uonet+/EduVulcan. Selenium w oryginale było potrzebne tylko do samego zalogowania — tutaj nie jest potrzebne wcale.

## 🧬 Pochodzenie projektu

<details>
<summary><b>Co jest przepisane, a co nietknięte (rozwiń)</b></summary>

<br>

- **Backend (Python)** — napisany od zera, w innej architekturze: bez Selenium/Chromium (logowanie ręczne przez wklejone ciasteczko zamiast automatycznego), bez SQLite (HA sam trzyma stan encji), jako natywna integracja (`SensorEntity` + `DataUpdateCoordinator`) zamiast zewnętrznego kontenera pchającego dane przez REST API. Zobacz [MAPOWANIE.md](MAPOWANIE.md) — pełna tabela, która funkcja oryginału odpowiada której u nas.
- **Karty Lovelace (`www/*.js`)** — **nietknięte, oryginalne pliki** z repo htomasz/vultron. Cała zasługa za wygląd i UX kart należy do niego; jedyne co zrobiliśmy to dopasowanie kształtu atrybutów encji, żeby te karty działały bez modyfikacji.

</details>

## ✨ Co tworzy integracja (na każde dziecko)

| Encja | Zawartość |
| :--- | :--- |
| `sensor.*_oceny_okres_N` | jedna encja na okres klasyfikacyjny — przedmioty, oceny, średnie |
| `sensor.*_plan_curr` / `_prev` / `_next` | plan lekcji (ten/poprzedni/następny tydzień), statusy zastępstw/odwołań, dni wolne |
| `sensor.*_terminarz` | nadchodzące sprawdziany/zadania domowe |
| `sensor.*_uwagi_i_pochwaly` | uwagi wychowawcy z kategorią pozytywna/negatywna |
| `sensor.*_frekwencja_wpisy` | ostatnie wpisy frekwencji |
| `sensor.vultron_stats_<slug>` (+ jeden na przedmiot) | % frekwencji ogółem i per przedmiot, z rozbiciem na miesiące |
| `sensor.*_osiagniecia` | lista osiągnięć |
| `sensor.*_zebrania` | nadchodzące zebrania z rodzicami |
| `sensor.*_szczesliwy_numerek` | numerek na dziś |

> [!NOTE]
> **Wiadomości są wyłączone domyślnie** — sesja SSO do `wiadomosci.eduvulcan.pl` to osobna domena z własnym uwierzytelnieniem i wymaga dalszej diagnostyki. Można to włączyć z powrotem w kodzie (`coordinator.py`/`sensor.py`, szukaj komentarza "wyłączone — niepotrzebne").

## 🚀 Instalacja

### Metoda 1: Przez HACS (zalecana)

1. HACS → (⋮) → **Custom repositories** → wklej URL tego repo, kategoria **Integration**.
2. HACS → Integracje → wyszukaj **EduVulcan** → Zainstaluj.
3. Zrestartuj Home Assistant.
4. Ustawienia → Urządzenia i usługi → Dodaj integrację → **EduVulcan**.

Karty Lovelace **nie wymagają żadnego dodatkowego kroku** — integracja sama je rejestruje przy starcie (patrz [sekcja niżej](#-karty-lovelace--w-pełni-automatyczne)).

<details>
<summary><b>Metoda 2: Ręczna (bez HACS, przez podmianę plików na dysku)</b></summary>

<br>

Jeśli z jakiegoś powodu HACS nie może pobrać repo (np. błąd sieci), pliki integracji można wgrać bezpośrednio do wolumenu Dockera:

```bash
docker cp custom_components/eduvulcan homeassistant:/config/custom_components/eduvulcan
docker restart homeassistant
```

> [!CAUTION]
> **Nigdy nie usuwaj ręcznie folderu `custom_components/eduvulcan`, gdy jej config entry wciąż istnieje w HA** (Ustawienia → Urządzenia i usługi → EduVulcan). Usunięcie plików "spod nóg" działającej integracji potrafi zepsuć/usunąć sam wpis konfiguracji, nie tylko pliki — a wtedy trzeba dodawać integrację od zera. Najpierw usuń wpis integracji przez UI, dopiero potem ruszaj pliki na dysku.

</details>

## 🍪 Jak zdobyć ciasteczko (raz, ręcznie)

1. Zaloguj się normalnie na **eduvulcan.pl**, wejdź w Dziennik ucznia (żeby przejść przez SSO na `uczen.eduvulcan.pl`).
2. Otwórz **DevTools** (F12) → zakładka **Network**.
3. Odśwież stronę (F5), żeby złapać jakiekolwiek zapytanie do `uczen.eduvulcan.pl`.
4. Kliknij to zapytanie → **Headers** → **Request Headers** → znajdź nagłówek `Cookie:` → skopiuj **całą jego wartość** (prawym przyciskiem → Copy value, jeśli dostępne; w przeciwnym razie zaznacz i skopiuj ręcznie).
5. Zanotuj też **miasto** z adresu URL — to człon zaraz po `uczen.eduvulcan.pl/`, np. dla `https://uczen.eduvulcan.pl/kobylka/...` miastem jest `kobylka`. To nie geografia — to identyfikator instancji dziennika u operatora Vulcan.

<details>
<summary><b>Przeglądarka nie pokazuje pełnych nagłówków? (rozwiń)</b></summary>

<br>

Zaznacz **"Disable cache"** w panelu Network i zrób twarde odświeżenie (`Ctrl+Shift+R`), potem filtruj po **"Fetch/XHR"** zamiast **"All"** — dokumentowe żądanie czasem pokazuje tylko "Provisional headers are shown" zamiast realnych nagłówków. Alternatywnie: zakładka **Application → Cookies → uczen.eduvulcan.pl** — ale niektóre ciasteczka mają flagę HttpOnly i nie da się ich odczytać przez JavaScript ani skopiować z tego widoku, dlatego Network jest pewniejszą metodą.

</details>

## ⚙️ Konfiguracja w Home Assistant

W formularzu integracji wklej **miasto** i **cookie** z kroków powyżej. Integracja od razu spróbuje pobrać listę dzieci przypisanych do konta (`/api/Context`) — jeśli się uda, utworzy jedno urządzenie na dziecko z kompletem sensorów.

> [!TIP]
> Karty `vultron-card.js` (plan) i `vultron-stats-card.js` (statystyki) mają na sztywno zaszyte w JS oczekiwane nazwy encji — integracja to uwzględnia i wymusza poprawne entity_id **automatycznie przy pierwszym utworzeniu**. Jeśli aktualizujesz ze starszej wersji i encje już istniały pod inną nazwą, może być potrzebna jednorazowa ręczna zmiana Entity ID (Ustawienia → Urządzenia i usługi → Encje → ⚙️).

## 🔁 Rotacja ciasteczka sesji (ważne!)

Serwer EduVulcan **rotuje** ciasteczko sesji przy (prawie) każdym zapytaniu — wydaje nowy `Set-Cookie` z nową wartością. Przeglądarka nadąża za tym automatycznie i dlatego nigdy nie musisz się przelogowywać ręcznie, mimo że "pod spodem" token cały czas się zmienia.

Integracja robi to samo: po każdym udanym cyklu pobierania danych **sama zapisuje** aktualną, zrotowaną wartość ciasteczka z powrotem do swojej konfiguracji. Dzięki temu restart Home Assistanta nie powinien już wymuszać ręcznego wklejania nowego cookie — o ile HA nie stał wyłączony na tyle długo, że sesja realnie wygasła po stronie EduVulcan.

Jeśli mimo to zobaczysz prośbę o reauth: zaloguj się ponownie w przeglądarce i wklej świeże ciasteczko tak jak poprzednio.

## ⏰ Harmonogram pobierania

Integracja odpytuje serwer co **40–60 minut** (losowo, jak oryginalny dodatek — celowe utrudnienie wykrycia wzorca) i celowo pomija pobieranie w oknach ciszy:

| Dzień | Okno ciszy / harmonogram |
| :--- | :--- |
| Pon–Pt | 🌙 **22:30–05:59** cisza nocna |
| Sobota | ✅ pobiera tylko o 8:00, 16:00, 23:00 |
| Niedziela | ✅ pobiera tylko o 8:00, 12:00, 20:00 |

## 🎨 Karty Lovelace — w pełni automatyczne

Integracja **sama** rejestruje wszystkie karty przy starcie — zero kopiowania plików do `/config/www`, zero ręcznego dodawania zasobów w Lovelace. Pliki `vultron-*.js` leżą wewnątrz folderu integracji (`custom_components/eduvulcan/www/`), więc HACS aktualizuje je automatycznie razem z resztą kodu. Integracja przy starcie wystawia je pod `/eduvulcan_cards/...` i wstrzykuje do frontendu przez `add_extra_js_url` — natywny mechanizm HA, odpowiednik tego, co oryginalny dodatek robił ręcznie przez WebSocket przy każdym uruchomieniu.

Wystarczy zainstalować/zaktualizować przez HACS i zrestartować HA — karty `type: custom:vultron-card` itd. działają od razu w edytorze dashboardu (dodajesz je przez **"Manual"/YAML**, bo to karty niestandardowe — edytor wizualny ich nie wyszuka, to normalne dla `custom:` kart).

<details>
<summary><b>🆘 Rejestracja awaryjna (gdyby coś nie zadziałało automatycznie)</b></summary>

<br>

Jeśli w logach HA zobaczysz `nie udało się automatycznie zarejestrować kart Lovelace`, karty da się dodać ręcznie — pliki są też w folderze `lovelace-cards/` w tym repo:

```bash
docker cp lovelace-cards homeassistant:/config/www/community/vultron
```

i zarejestruj każdy jako zasób **JavaScript Module** pod `/local/community/vultron/vultron-*.js` (Ustawienia → Pulpity sterujące → (⋮) → Zasoby).

**Uwaga:** karty JS bywają mocno cache'owane przez przeglądarkę. Jeśli po instalacji/aktualizacji widzisz `Custom element doesn't exist`, zrób twarde odświeżenie (`Ctrl+Shift+R`), a jeśli to nie pomoże — wyczyść dane strony/Service Worker dla domeny Twojego HA (Ctrl+Shift+Delete w przeglądarce).

</details>

## 📊 Przykładowe karty dashboardu

Podmień `sensor.TWOJA_NAZWA_*` na realne entity_id z Twojego urządzenia (Ustawienia → Urządzenia i usługi → (dziecko) → lista Sensors).

<details open>
<summary><b>📅 Plan lekcji</b> (jedna karta wystarczy — strzałki `‹` `›` same przełączają tygodnie)</summary>

```yaml
type: custom:vultron-card
entity: sensor.TWOJA_NAZWA_plan_curr
freq_entity: sensor.TWOJA_NAZWA_frekwencja_wpisy
```

</details>

<details>
<summary><b>📈 Oceny</b> (osobna karta na każdy okres)</summary>

```yaml
type: custom:vultron-grades-card
entity: sensor.TWOJA_NAZWA_oceny_okres_1
default_sort: date
limit: 10
```

</details>

<details>
<summary><b>🎒 Terminarz</b></summary>

```yaml
type: custom:vultron-work-card
entity: sensor.TWOJA_NAZWA_terminarz
default_sort: asc
limit: 10
```

</details>

<details>
<summary><b>💬 Uwagi i pochwały</b></summary>

```yaml
type: custom:vultron-uwagi-card
entity: sensor.TWOJA_NAZWA_uwagi_i_pochwaly
default_sort: desc
limit: 10
```

</details>

<details>
<summary><b>✔️ Statystyki frekwencji</b> (entity_id NIE zmieniaj — jest wymuszone przez integrację)</summary>

```yaml
type: custom:vultron-stats-card
entity: sensor.vultron_stats_TWOJ_SLUG_DZIECKA
```

</details>

<details>
<summary><b>🏆 Osiągnięcia</b></summary>

```yaml
type: custom:vultron-osiagniecia-card
entity: sensor.TWOJA_NAZWA_osiagniecia
```

</details>

<details>
<summary><b>👩‍🏫 Zebrania</b></summary>

```yaml
type: custom:vultron-zebrania-card
entity: sensor.TWOJA_NAZWA_zebrania
```

</details>

<details>
<summary><b>🍀 Szczęśliwy numerek</b></summary>

```yaml
type: custom:vultron-szczesliwy-numerek-card
entity: sensor.TWOJA_NAZWA_szczesliwy_numerek
```

</details>

## 🔧 Wymuszanie odświeżenia poza harmonogramem

- **Narzędzia deweloperskie → Usługi** → `homeassistant.update_entity` → wybierz dowolny sensor EduVulcan tego dziecka → Wykonaj — odświeża od razu cały coordinator (wszystkie sensory naraz).
- Albo: **Ustawienia → Urządzenia i usługi → EduVulcan → (⋮) → Przeładuj** (cięższa opcja, przeładowuje całą integrację).

## 🔄 Aktualizacje

Po wgraniu nowej wersji plików na GitHub, jeśli HACS nie pokazuje automatycznie przycisku "Update" (bo nie ma opublikowanego Release/taga na repo), użyj **HACS → EduVulcan → (⋮) → Redownload**, potem `docker restart homeassistant`.

## 🗺️ Mapowanie z oryginałem

Pełna tabela funkcja-po-funkcji, pokazująca gdzie w naszym kodzie szukać odpowiednika danej części oryginalnego `vultron.py` — przydatna, jeśli autor oryginału coś tam naprawi/zmieni: **[MAPOWANIE.md](MAPOWANIE.md)**.

---

<p align="center">
  <sub>Oparte na pracy <a href="https://github.com/htomasz/vultron">htomasz/vultron</a> · Licencja GPL-3.0 · Integracja nieoficjalna, niezwiązana z EduVulcan.pl ani Vulcan sp. z o.o.</sub>
</p>
