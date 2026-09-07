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
