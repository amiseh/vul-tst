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
