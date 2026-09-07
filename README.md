# EduVulcan (integracja nieoficjalna) dla Home Assistant

Natywna integracja HACS — instalujesz normalnie przez sklep, dostajesz
`config_flow`, prawdziwe encje `sensor.*`, urządzenie per dziecko, i te same
ładne karty Lovelace co w oryginalnym dodatku
[htomasz/vultron](https://github.com/htomasz/vultron). **Zero Selenium, zero
Chromium, zero dodatkowego kontenera Docker.**

## Pochodzenie projektu

Ten kod to przepisanie logiki dodatku Home Assistant Supervisor
**[htomasz/vultron](https://github.com/htomasz/vultron)** (autor: htomasz,
nazwa kodowa "Kurkkuviipale") na natywną integrację HACS, żeby dało się jej
używać na instalacjach Home Assistant Core **bez Supervisora** (np. HA Core
w Dockerze na LXC/VPS).

- **Backend (Python)** — napisany od zera, w innej architekturze: bez
  Selenium/Chromium (logowanie ręczne przez wklejone ciasteczko zamiast
  automatycznego), bez SQLite (HA sam trzyma stan encji), jako natywna
  integracja (`SensorEntity` + `DataUpdateCoordinator`) zamiast zewnętrznego
  kontenera pchającego dane przez REST API. Zobacz `MAPOWANIE.md` — pełna
  tabela, która funkcja oryginału odpowiada której u nas.
- **Karty Lovelace (`www/*.js`)** — **nietknięte, oryginalne pliki** z
  repo htomasz/vultron. Cała zasługa za wygląd i UX kart należy do niego;
  jedyne co zrobiliśmy to dopasowanie kształtu atrybutów encji, żeby te
  karty działały bez modyfikacji.

Licencja oryginału: GPL-3.0. Ten kod zachowuje tę samą licencję dla
zapożyczonych/przepisanych fragmentów (mapowania statusów, logika
czyszczenia HTML, karty JS).

**Nota:** korzystanie z tego API poza oficjalną aplikacją narusza regulamin
EduVulcan.pl (autor oryginalnego dodatku sam to zaznacza wprost). To Twoja
decyzja i ryzyko.

Logowanie robisz sam, raz, w swojej przeglądarce — integracja korzysta z
ciasteczka sesji, które jej wklejasz, i dalej robi już tylko zwykłe
zapytania HTTP do wewnętrznego API uonet+/EduVulcan (dokładnie tych samych
endpointów, których używał oryginalny dodatek — Selenium było tam potrzebne
tylko do samego zalogowania).

## Instalacja przez HACS

1. HACS → (⋮) → **Custom repositories** → wklej URL swojego repo z tym
   kodem, kategoria **Integration**.
2. HACS → Integracje → wyszukaj **EduVulcan** → Zainstaluj.
3. Zrestartuj Home Assistant.
4. Ustawienia → Urządzenia i usługi → Dodaj integrację → **EduVulcan**.

Karty Lovelace **nie wymagają żadnego dodatkowego kroku** — integracja sama
je rejestruje przy starcie (więcej w sekcji niżej).

## Jak zdobyć ciasteczko (raz, ręcznie)

1. Zaloguj się normalnie na **eduvulcan.pl**, wejdź w Dziennik ucznia (żeby
   przejść przez SSO na `uczen.eduvulcan.pl`).
2. Otwórz **DevTools** (F12) → zakładka **Network**.
3. Odśwież stronę (F5), żeby złapać jakiekolwiek zapytanie do
   `uczen.eduvulcan.pl`.
4. Kliknij to zapytanie → **Headers** → **Request Headers** → znajdź
   nagłówek `Cookie:` → skopiuj **całą jego wartość** (prawym przyciskiem →
   Copy value, jeśli dostępne; w przeciwnym razie zaznacz i skopiuj ręcznie).

   Jeśli w przeglądarce trudno znaleźć tę sekcję: zaznacz "Disable cache" w
   Network i zrób twarde odświeżenie (Ctrl+Shift+R), potem filtruj po
   "Fetch/XHR" zamiast "All" — dokumentowe żądanie czasem pokazuje tylko
   "Provisional headers are shown" zamiast realnych nagłówków.

5. Zanotuj też **miasto** z adresu URL — to człon zaraz po
   `uczen.eduvulcan.pl/`, np. dla `https://uczen.eduvulcan.pl/kobylka/...`
   miastem jest `kobylka`. To nie geografia — to identyfikator instancji
   dziennika u operatora Vulcan, po prostu tak nazywa się ten segment adresu.

## Konfiguracja w Home Assistant

W formularzu integracji wklej **miasto** i **cookie** z kroków powyżej.
Integracja od razu spróbuje pobrać listę dzieci przypisanych do konta
(`/api/Context`) — jeśli się uda, utworzy jedno urządzenie na dziecko z
kompletem sensorów.

## Co tworzy integracja (na każde dziecko)

| Encja | Zawartość |
| --- | --- |
| `sensor.*_oceny_okres_N` | jedna encja na okres klasyfikacyjny — przedmioty, oceny, średnie |
| `sensor.*_plan_curr` / `_prev` / `_next` | plan lekcji (ten/poprzedni/następny tydzień), statusy zastępstw/odwołań, dni wolne |
| `sensor.*_terminarz` | nadchodzące sprawdziany/zadania domowe |
| `sensor.*_uwagi_i_pochwaly` | uwagi wychowawcy z kategorią pozytywna/negatywna |
| `sensor.*_frekwencja_wpisy` | ostatnie wpisy frekwencji |
| `sensor.vultron_stats_<slug>` (+ jeden na przedmiot) | % frekwencji ogółem i per przedmiot, z rozbiciem na miesiące |
| `sensor.*_osiagniecia` | lista osiągnięć |
| `sensor.*_zebrania` | nadchodzące zebrania z rodzicami |
| `sensor.*_szczesliwy_numerek` | numerek na dziś |

**Wiadomości są wyłączone domyślnie** — sesja SSO do
`wiadomosci.eduvulcan.pl` to osobna domena z własnym uwierzytelnieniem i
wymaga dalszej diagnostyki. Można to włączyć z powrotem w kodzie
(`coordinator.py`/`sensor.py`, szukaj komentarza "wyłączone — niepotrzebne").

### Ważne: entity_id sensorów planu i statystyk jest wymuszone

Karty `vultron-card.js` (plan) i `vultron-stats-card.js` (statystyki
frekwencji) mają **na sztywno zaszyte w kodzie JS** oczekiwane nazwy encji:

- Plan: karta sama przełącza tygodnie doklejając/ucinając sufiks
  `_prev`/`_curr`/`_next` (po angielsku) do tego, co podasz w `entity:`.
  Dlatego encje planu mają wymuszone entity_id kończące się właśnie tak
  (`sensor.<dziecko>_plan_curr` itd.), a nie po polsku.
- Statystyki: karta ma zaszyty prefiks `sensor.vultron_stats_` do
  przełączania między przedmiotami — encje statystyk mają więc wymuszone
  entity_id `sensor.vultron_stats_<slug>` / `sensor.vultron_stats_<slug>_<przedmiot>`.

To wymuszanie działa automatycznie **tylko przy pierwszym utworzeniu**
encji (nowa instalacja, nowe dziecko, albo usunięcie i ponowne dodanie
integracji). Jeśli encja już wcześniej istniała w rejestrze HA pod inną
nazwą (np. zdążyła się utworzyć zanim ta wersja kodu miała wymuszanie),
Home Assistant **nie zmieni jej automatycznie** — trzeba to zrobić ręcznie
raz: Ustawienia → Urządzenia i usługi → Encje → znajdź sensor → ⚙️ →
zmień pole "Entity ID" na właściwe, zapisz. Nie trzeba tego powtarzać przy
kolejnych restartach ani aktualizacjach.

## Rotacja ciasteczka sesji (ważne!)

Serwer EduVulcan **rotuje** ciasteczko sesji przy (prawie) każdym zapytaniu
— wydaje nowy `Set-Cookie` z nową wartością. Przeglądarka nadąża za tym
automatycznie i dlatego nigdy nie musisz się przelogowywać ręcznie, mimo że
"pod spodem" token cały czas się zmienia.

Integracja robi to samo: po każdym udanym cyklu pobierania danych **sama
zapisuje** aktualną, zrotowaną wartość ciasteczka z powrotem do swojej
konfiguracji. Dzięki temu restart Home Assistanta nie powinien już
wymuszać ręcznego wklejania nowego cookie — o ile HA nie stał wyłączony na
tyle długo, że sesja realnie wygasła po stronie EduVulcan.

Jeśli mimo to zobaczysz prośbę o reauth: zaloguj się ponownie w
przeglądarce i wklej świeże ciasteczko tak jak poprzednio — to nadal jedyny
sposób na "twardy restart" sesji, gdyby faktycznie wygasła.

## Harmonogram pobierania

Integracja odpytuje serwer co 40–60 minut (losowo, tak jak oryginalny
dodatek) i celowo pomija pobieranie w oknach ciszy:

- **Dni robocze (pon–pt): 22:30–05:59** — cisza nocna.
- **Sobota:** pobiera tylko o 8:00, 16:00 i 23:00.
- **Niedziela:** pobiera tylko o 8:00, 12:00 i 20:00.

## Karty Lovelace — w pełni automatyczne

Integracja **sama** rejestruje wszystkie karty przy starcie — zero
kopiowania plików do `/config/www`, zero ręcznego dodawania zasobów w
Lovelace. Pliki `vultron-*.js` leżą wewnątrz folderu integracji
(`custom_components/eduvulcan/www/`), więc HACS aktualizuje je automatycznie
razem z resztą kodu. Integracja przy starcie wystawia je pod
`/eduvulcan_cards/...` i wstrzykuje do frontendu przez `add_extra_js_url`
(natywny mechanizm HA — odpowiednik tego, co oryginalny dodatek robił
ręcznie przez WebSocket przy każdym uruchomieniu).

Wystarczy zainstalować/zaktualizować przez HACS i zrestartować HA — karty
`type: custom:vultron-card` itd. działają od razu w edytorze dashboardu
(dodajesz je przez "Manual"/YAML, bo to karty niestandardowe — edytor
wizualny ich nie wyszuka, to normalne dla `custom:` kart).

### Rejestracja awaryjna (gdyby coś nie zadziałało automatycznie)

Jeśli w logach HA zobaczysz `nie udało się automatycznie zarejestrować
kart Lovelace`, karty da się dodać ręcznie — pliki są też w folderze
`lovelace-cards/` w tym repo:

```bash
docker cp lovelace-cards homeassistant:/config/www/community/vultron
```

i zarejestruj każdy jako zasób **JavaScript Module** pod
`/local/community/vultron/vultron-*.js` (Ustawienia → Pulpity sterujące →
(⋮) → Zasoby).

## Przykładowe karty dashboardu

Podmień `sensor.TWOJA_NAZWA_*` na realne entity_id z Twojego urządzenia
(Ustawienia → Urządzenia i usługi → (dziecko) → lista Sensors).

**Plan lekcji** (jedna karta wystarczy — strzałki `‹` `›` same przełączają tygodnie):
```yaml
type: custom:vultron-card
entity: sensor.TWOJA_NAZWA_plan_curr
freq_entity: sensor.TWOJA_NAZWA_frekwencja_wpisy
```

**Oceny** (osobna karta na każdy okres):
```yaml
type: custom:vultron-grades-card
entity: sensor.TWOJA_NAZWA_oceny_okres_1
default_sort: date
limit: 10
```

**Terminarz:**
```yaml
type: custom:vultron-work-card
entity: sensor.TWOJA_NAZWA_terminarz
default_sort: asc
limit: 10
```

**Uwagi i pochwały:**
```yaml
type: custom:vultron-uwagi-card
entity: sensor.TWOJA_NAZWA_uwagi_i_pochwaly
default_sort: desc
limit: 10
```

**Statystyki frekwencji** (entity_id NIE zmieniaj — jest wymuszone przez integrację):
```yaml
type: custom:vultron-stats-card
entity: sensor.vultron_stats_TWOJ_SLUG_DZIECKA
```

**Osiągnięcia:**
```yaml
type: custom:vultron-osiagniecia-card
entity: sensor.TWOJA_NAZWA_osiagniecia
```

**Zebrania:**
```yaml
type: custom:vultron-zebrania-card
entity: sensor.TWOJA_NAZWA_zebrania
```

**Szczęśliwy numerek:**
```yaml
type: custom:vultron-szczesliwy-numerek-card
entity: sensor.TWOJA_NAZWA_szczesliwy_numerek
```

## Wymuszanie odświeżenia poza harmonogramem

- Narzędzia deweloperskie → Usługi → `homeassistant.update_entity` →
  wybierz dowolny sensor EduVulcan tego dziecka → Wykonaj — odświeża od razu
  cały coordinator (wszystkie sensory naraz).
- Albo: Ustawienia → Urządzenia i usługi → EduVulcan → (⋮) → **Przeładuj**
  (cięższa opcja, przeładowuje całą integrację).

## Aktualizacje

Po wgraniu nowej wersji plików na GitHub, jeśli HACS nie pokazuje
automatycznie przycisku "Update" (bo nie ma opublikowanego Release/taga na
repo), użyj HACS → EduVulcan → (⋮) → **Redownload**, potem
`docker restart homeassistant`.
