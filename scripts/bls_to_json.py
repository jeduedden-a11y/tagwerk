#!/usr/bin/env python3
"""Builds the food table the app bundles from the Bundeslebensmittelschlüssel (BLS).

Source: Max Rubner-Institut (2025): Bundeslebensmittelschlüssel (BLS), Version 4.0 -
Deutsche Nährstoffdatenbank. Karlsruhe. DOI 10.25826/Data20251217-134202-0. Licence CC BY 4.0.

Changes made here (CC BY asks for them to be named): only ten components are kept, values are
rounded, salt is computed from sodium (Na x 2.5), and the errata of August 2026 for version 4.0
are applied: the available oligosaccharides were counted twice in the energy (2 kcal per g too
much), and the fat of raw anchovy and the dishes made mainly from it is withheld, so those
entries are left out.

Usage: bls_to_json.py OUT.json [ZIP]   (without ZIP the current zip is downloaded)
"""

import hashlib
import html
import io
import json
import re
import sys
import urllib.request
import zipfile
from datetime import date

import openpyxl

PAGE = "https://www.blsdb.de/download"
UPLOADS = "https://www.blsdb.de/assets/uploads/"
ZIP_RE = re.compile(r"/assets/uploads/(BLS_\w+_DE\.zip)")
DATA_RE = re.compile(r"_Daten_\w+\.xlsx$")
VALUE_RE = re.compile(r"^(\S+) .*\[(.+)/100g\]$")
ANCHOVY = {"T104100", "T104162", "T104172", "T104182", "T104400", "T104702", "T860100"}
WANTED = {"ENERCC": "kcal", "PROT625": "g", "FAT": "g", "CHO": "g", "FIBT": "g",
          "SUGAR": "g", "FASAT": "g", "NA": "mg", "OLSAC": "g"}
UA = {"User-Agent": "Tagwerk-BLS-Import/1.0 (github.com/jeduedden-a11y/tagwerk)"}


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def number(v):
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    s = str(v).strip()
    if s == "TR":
        return 0.0
    try:
        return float(s.replace(",", "."))
    except ValueError:
        return None


def r1(x):
    return None if x is None else round(x + 0.0, 1)


def main() -> None:
    out = sys.argv[1]
    if len(sys.argv) > 2:
        blob = open(sys.argv[2], "rb").read()
        zip_name = sys.argv[2].rsplit("/", 1)[-1]
    else:
        page = html.unescape(fetch(PAGE).decode("utf-8", "replace"))
        m = ZIP_RE.search(page)
        if not m:
            sys.exit("Kein ZIP auf der Downloadseite gefunden, Seitenaufbau geändert.")
        zip_name = m[1]
        blob = fetch(UPLOADS + zip_name)
    sha = hashlib.sha256(blob).hexdigest()
    z = zipfile.ZipFile(io.BytesIO(blob))
    member = next((i for i in z.infolist() if DATA_RE.search(i.filename)), None)
    if member is None:
        sys.exit(f"Keine Datentabelle im ZIP: {z.namelist()}")
    wb = openpyxl.load_workbook(io.BytesIO(z.read(member)), read_only=True, data_only=True)
    rows = wb.worksheets[0].iter_rows(values_only=True)
    header = [str(h) if h is not None else "" for h in next(rows)]
    col = {}
    for i, h in enumerate(header):
        m = VALUE_RE.match(h)
        if m and m[1] in WANTED:
            if m[2] != WANTED[m[1]]:
                sys.exit(f"{m[1]} hat die Einheit {m[2]}, erwartet {WANTED[m[1]]}")
            col[m[1]] = i
    for need in ("BLS Code", "Lebensmittelbezeichnung", "Food name"):
        if need not in header:
            sys.exit(f"Spalte {need} fehlt")
    missing = [c for c in WANTED if c not in col]
    if missing:
        sys.exit(f"Komponenten fehlen: {missing}")
    i_code, i_de, i_en = header.index("BLS Code"), header.index("Lebensmittelbezeichnung"), header.index("Food name")
    erratum = zip_name.startswith("BLS_4_0_")

    foods = []
    skipped = 0
    for row in rows:
        cell = lambda i: row[i] if i < len(row) else None
        code = str(cell(i_code) or "").strip()
        de = str(cell(i_de) or "").strip()
        en = str(cell(i_en) or "").strip()
        if not code or not de:
            continue
        v = {k: number(cell(i)) for k, i in col.items()}
        if erratum and code in ANCHOVY:
            skipped += 1
            continue
        kcal = v["ENERCC"]
        if kcal is None:
            skipped += 1
            continue
        if erratum and v["OLSAC"]:
            kcal = max(0.0, kcal - 2 * v["OLSAC"])
        salt = None if v["NA"] is None else round(v["NA"] * 2.5 / 1000, 2)
        foods.append([code, de, en, round(kcal), r1(v["PROT625"]), r1(v["FAT"]), r1(v["CHO"]),
                      r1(v["FIBT"]), r1(v["SUGAR"]), r1(v["FASAT"]), salt])

    foods.sort(key=lambda f: f[1].casefold())
    doc = {
        "source": "Max Rubner-Institut (2025): Bundeslebensmittelschlüssel (BLS), Version 4.0 – Deutsche Nährstoffdatenbank. Karlsruhe.",
        "doi": "10.25826/Data20251217-134202-0",
        "license": "CC BY 4.0",
        "changes": "Auszug von zehn Komponenten, gerundet, Salz aus Natrium (x 2,5), Errata 08/2026 angewandt.",
        "zip": zip_name,
        "sha256": sha,
        "built": date.today().isoformat(),
        "fields": ["code", "de", "en", "kcal", "protein", "fat", "carbs", "fiber", "sugar", "satFat", "salt"],
        "foods": foods,
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, separators=(",", ":"))
    print(f"{len(foods)} Lebensmittel, {skipped} ausgelassen, ZIP {zip_name} sha256 {sha}")


if __name__ == "__main__":
    main()
