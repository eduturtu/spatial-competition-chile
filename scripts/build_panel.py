#!/usr/bin/env python3
"""Build the station-week gasoline panel used by the R analysis.

This is a cleaned and faster version of the original ``procesar_datos_cne.py``.
It handles the historical CNE/Bencina en Línea CSV formats, keeps 93-octane
retail gasoline, forms one observation per station-week (the last report in the
week), and counts active competitors within 1, 2, 3 and 5 km using Haversine
geodesic distance.

The econometric entry/exit definitions are intentionally *not* created here.
They live in ``R/02_clean_data.R`` so that event construction has a single
source of truth.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
import warnings

import numpy as np
import pandas as pd

warnings.filterwarnings("ignore", category=FutureWarning)

RADII_KM = (1.0, 2.0, 3.0, 5.0)
EARTH_RADIUS_KM = 6371.0
REQUIRED_RAW = {"codigo", "combustible", "precio", "fecha_actualizacion", "latitud", "longitud"}
OPTIONAL_PANEL = ("distribuidor", "nom_comuna", "nom_region", "razon_social")


def _detect_delimiter(path: Path) -> str:
    with path.open("r", encoding="utf-8", errors="ignore") as fh:
        header = fh.readline()
    return ";" if header.count(";") > header.count(",") else ","


def _read_csv(path: Path) -> pd.DataFrame:
    sep = _detect_delimiter(path)
    # UTF-8 first: decoding is strict, so a latin1 file fails and falls through.
    # Reading a UTF-8 file as latin1 never fails but produces "ValparaÃ­so".
    encodings = ("utf-8-sig", "latin1")
    last_exc: Exception | None = None
    for enc in encodings:
        try:
            # dtype=str: otherwise pandas turns "1.080" (CLP 1,080) into 1.08 and
            # drops leading zeros in station codes before any parsing happens here.
            return pd.read_csv(path, sep=sep, encoding=enc, on_bad_lines="skip",
                               dtype=str, keep_default_na=False, na_values=[""])
        except Exception as exc:  # pragma: no cover - format-specific fallback
            last_exc = exc
    raise RuntimeError(f"Could not read {path}") from last_exc


def _fix_mojibake(x: str) -> str:
    """Repair UTF-8 text that was decoded as latin1 (e.g. 'ValparaÃ\xadso')."""
    if "Ã" in x or "Â" in x:
        try:
            return x.encode("latin1").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            return x
    return x


def _parse_price(s: pd.Series) -> pd.Series:
    """Parse prices written as 1234, 1234.5, 1234,5, 1.234 or 1.234,5."""
    t = s.astype("string").str.strip().str.replace(r"[^0-9.,]", "", regex=True)
    both = t.str.contains(",", regex=False) & t.str.contains(".", regex=False)
    t = t.mask(both, t.str.replace(".", "", regex=False))                 # 1.234,5 -> 1234,5
    thousands = t.str.fullmatch(r"\d{1,3}(\.\d{3})+", na=False)
    t = t.mask(thousands, t.str.replace(".", "", regex=False))            # 1.234 -> 1234
    t = t.str.replace(",", ".", regex=False)
    return pd.to_numeric(t, errors="coerce")


def _parse_dates(s: pd.Series) -> pd.Series:
    """Element-wise parsing: pandas otherwise infers ONE format from the first
    row and silently turns every row in another format into NaT."""
    t = s.astype("string").str.strip()
    iso = t.str.match(r"^\d{4}[-/]\d{1,2}[-/]\d{1,2}", na=False)
    out = pd.Series(pd.NaT, index=t.index, dtype="datetime64[ns]")
    if iso.any():
        out[iso] = pd.to_datetime(t[iso], errors="coerce", format="mixed", yearfirst=True)
    if (~iso).any():
        out[~iso] = pd.to_datetime(t[~iso], errors="coerce", format="mixed", dayfirst=True)
    return out


def _normalise_columns(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df.columns = [str(c).strip() for c in df.columns]
    rename = {
        "id": "codigo",
        "comuna": "nom_comuna",
        "region": "nom_region",
    }
    df = df.rename(columns={k: v for k, v in rename.items() if k in df.columns})

    missing = REQUIRED_RAW.difference(df.columns)
    if missing:
        raise ValueError("Missing required columns: " + ", ".join(sorted(missing)))

    for col in OPTIONAL_PANEL:
        if col not in df.columns:
            df[col] = pd.NA

    # Historical files sometimes store fuel as labels rather than short codes.
    fuel_map = {
        "Gasolina 93": "93",
        "Gasolina 95": "95",
        "Gasolina 97": "97",
        "Petroleo Diesel": "DI",
        "Petróleo Diesel": "DI",
        "Kerosene": "KE",
        "GLP Vehicular": "GLP",
        "GNC": "GNC",
    }
    fuel = df["combustible"].astype("string").str.strip().replace(fuel_map)
    fuel = fuel.str.replace(r"^A(?=93$|95$|97$)", "", regex=True)
    fuel = fuel.replace({"ADI": "DI", "AKE": "KE"})
    df["combustible"] = fuel

    df["codigo"] = df["codigo"].astype("string").str.strip()
    # Same brand/municipality must have the same spelling across archive eras
    # ("Sin Bandera" vs "SIN BANDERA" would otherwise look like a brand change).
    for col in ("distribuidor", "nom_comuna", "nom_region", "razon_social"):
        df[col] = (df[col].astype("string").map(_fix_mojibake, na_action="ignore")
                   .str.normalize("NFC").str.strip().str.replace(r"\s+", " ", regex=True)
                   .str.upper())
    for col in ("latitud", "longitud"):
        df[col] = pd.to_numeric(
            df[col].astype("string").str.replace(",", ".", regex=False), errors="coerce"
        )
    return df


def load_raw_files(raw_dir: Path) -> pd.DataFrame:
    paths = sorted(raw_dir.glob("*.csv"))
    if not paths:
        raise FileNotFoundError(f"No raw CNE CSV files found in {raw_dir}")

    chunks: list[pd.DataFrame] = []
    for i, path in enumerate(paths, start=1):
        print(f"[{i}/{len(paths)}] Reading {path.name}", flush=True)
        try:
            df = _normalise_columns(_read_csv(path))
        except ValueError as exc:
            raise ValueError(f"{path.name}: {exc}") from exc
        df["archivo_origen"] = path.name
        chunks.append(df)
    return pd.concat(chunks, ignore_index=True)


def build_weekly_panel(raw: pd.DataFrame, fuel: str = "93") -> pd.DataFrame:
    raw = raw.copy()
    raw["es_fuel"] = raw["combustible"].astype("string") == fuel
    df = raw.loc[raw["es_fuel"]].copy()
    if df.empty:
        raise ValueError(f"No observations found for fuel code {fuel!r}")

    df["fecha"] = _parse_dates(df["fecha_actualizacion"])
    df["precio"] = _parse_price(df["precio"])
    df["fecha_ok"] = df["fecha"].notna()
    df["precio_ok"] = df["precio"].notna()
    df["geo_ok"] = (
        df["latitud"].between(-56, -17, inclusive="both")
        & df["longitud"].between(-76, -66, inclusive="both")
    )
    df["kept"] = df["fecha_ok"] & df["precio_ok"] & df["geo_ok"]
    report_by_file(raw, df)
    df = df.loc[df["kept"]].copy()

    iso = df["fecha"].dt.isocalendar()
    df["iso_year"] = iso.year.astype(int)
    df["iso_week"] = iso.week.astype(int)
    df["year_week"] = df["iso_year"].astype(str) + "-W" + df["iso_week"].astype(str).str.zfill(2)

    # Last reported price in each station-week, as in the original processor.
    # A stable sort plus drop_duplicates keeps the whole last row (groupby().last()
    # would mix columns from different rows when some fields are missing).
    df = df.sort_values(["codigo", "fecha"], kind="mergesort")
    keep = ["codigo", "year_week", "precio", "fecha", "latitud", "longitud", *OPTIONAL_PANEL]
    panel = df.drop_duplicates(["codigo", "year_week"], keep="last")[keep].reset_index(drop=True)

    # Report date without time of day, so R reads `fecha` as a Date.
    panel["fecha"] = panel["fecha"].dt.normalize()

    # Consecutive week index counted from the first ISO week in the data. Weeks
    # with no reports in the archive still advance the index, so the 26-week
    # event buffers in R are measured in calendar weeks.
    monday = panel["fecha"] - pd.to_timedelta(panel["fecha"].dt.weekday, unit="D")
    panel["semana_ord"] = ((monday - monday.min()).dt.days // 7).astype(int)

    return panel


LAST_REPORT: pd.DataFrame | None = None


def report_by_file(raw: pd.DataFrame, fuel_rows: pd.DataFrame) -> None:
    """Rows surviving each step, by raw file. A file that loses most of its rows
    (or has no fuel rows) points to a format the builder does not handle."""
    global LAST_REPORT
    base = raw.groupby("archivo_origen").agg(
        rows=("es_fuel", "size"), fuel_rows=("es_fuel", "sum"),
        n_codigo=("codigo", "nunique"))
    steps = fuel_rows.groupby("archivo_origen").agg(
        fecha_ok=("fecha_ok", "sum"), precio_ok=("precio_ok", "sum"),
        geo_ok=("geo_ok", "sum"), kept=("kept", "sum"),
        fecha_min=("fecha", "min"), fecha_max=("fecha", "max"))
    rep = base.join(steps, how="left").fillna({"fecha_ok": 0, "precio_ok": 0, "geo_ok": 0, "kept": 0})
    rep["share_kept"] = (rep["kept"] / rep["fuel_rows"].where(rep["fuel_rows"] > 0)).round(3)
    LAST_REPORT = rep.reset_index()
    with pd.option_context("display.width", 200, "display.max_columns", 20, "display.max_rows", 500):
        print("\nRows by raw file and step:")
        print(LAST_REPORT.to_string(index=False))
    for f in rep.index[(rep["fuel_rows"] == 0) | (rep["share_kept"] < 0.8)]:
        sub = raw.loc[raw["archivo_origen"] == f]
        print(f"\nWARNING {f}: fuel_rows={int(rep.loc[f, 'fuel_rows'])}, share_kept={rep.loc[f, 'share_kept']}")
        print("  combustible values:", sub["combustible"].astype("string").value_counts().head(8).to_dict())
        print("  fecha_actualizacion examples:", sub["fecha_actualizacion"].astype("string").dropna().head(3).tolist())
        print("  precio examples:", sub["precio"].astype("string").dropna().head(3).tolist())
        print("  codigo examples:", sub["codigo"].astype("string").dropna().head(3).tolist())


def _distance_matrix_km(lat_deg: np.ndarray, lon_deg: np.ndarray) -> np.ndarray:
    lat = np.radians(lat_deg.astype(float))
    lon = np.radians(lon_deg.astype(float))
    dlat = lat[:, None] - lat[None, :]
    dlon = lon[:, None] - lon[None, :]
    a = np.sin(dlat / 2.0) ** 2 + np.cos(lat[:, None]) * np.cos(lat[None, :]) * np.sin(dlon / 2.0) ** 2
    a = np.clip(a, 0.0, 1.0)
    return 2.0 * EARTH_RADIUS_KM * np.arcsin(np.sqrt(a))


def add_competitor_counts(panel: pd.DataFrame, radii_km: tuple[float, ...] = RADII_KM) -> pd.DataFrame:
    # The original processor represents each station by a time-invariant median location.
    stations = (
        panel.groupby("codigo", as_index=False)
        .agg(latitud=("latitud", "median"), longitud=("longitud", "median"))
        .sort_values("codigo")
        .reset_index(drop=True)
    )
    codes = stations["codigo"].astype(str).to_numpy()
    code_to_idx = {code: i for i, code in enumerate(codes)}
    dist = _distance_matrix_km(stations["latitud"].to_numpy(), stations["longitud"].to_numpy())
    np.fill_diagonal(dist, np.inf)

    max_radius = max(radii_km)
    neighbour_idx = [np.flatnonzero(dist[i] <= max_radius) for i in range(len(codes))]
    neighbour_dist = [dist[i, idx] for i, idx in enumerate(neighbour_idx)]

    out = panel.copy()
    for radius in radii_km:
        out[f"n_comp_{int(radius)}km"] = 0

    # Index labels grouped once; work inside NumPy for speed and deterministic counts.
    for n_week, (_, row_idx) in enumerate(out.groupby("year_week", sort=True).groups.items(), start=1):
        locs = np.fromiter(row_idx, dtype=int)
        active_codes = out.loc[locs, "codigo"].astype(str).to_numpy()
        active = np.zeros(len(codes), dtype=bool)
        active[[code_to_idx[c] for c in active_codes]] = True

        for row_pos, code in zip(locs, active_codes):
            i = code_to_idx[code]
            idx = neighbour_idx[i]
            if idx.size == 0:
                continue
            d = neighbour_dist[i]
            active_neighbours = active[idx]
            for radius in radii_km:
                out.at[row_pos, f"n_comp_{int(radius)}km"] = int(np.count_nonzero(active_neighbours & (d <= radius)))

        if n_week % 50 == 0:
            print(f"  competitor counts: {n_week} weeks", flush=True)

    return out


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw-dir", type=Path, required=True, help="Directory containing raw CNE CSV files")
    parser.add_argument("--output", type=Path, required=True, help="Output panel_estacion_semana.csv path")
    parser.add_argument("--fuel", default="93", help="Fuel code to retain (default: 93)")
    parser.add_argument("--report-only", action="store_true",
                        help="Only print/save the per-file report (fast); do not build the panel")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    print(f"Raw directory: {args.raw_dir}")
    raw = load_raw_files(args.raw_dir)
    print(f"Loaded {len(raw):,} raw rows")
    panel = build_weekly_panel(raw, fuel=args.fuel)
    if args.report_only:
        report_path = args.output.parent / "raw_file_report.csv"
        report_path.parent.mkdir(parents=True, exist_ok=True)
        LAST_REPORT.to_csv(report_path, index=False)
        print(f"Per-file report written to {report_path}")
        return 0
    print(f"Weekly panel before competition counts: {len(panel):,} rows, {panel['codigo'].nunique():,} stations")
    panel = add_competitor_counts(panel)

    order = [
        "codigo", "year_week", "precio", "fecha", "latitud", "longitud",
        "distribuidor", "nom_comuna", "nom_region", "razon_social",
        "n_comp_1km", "n_comp_2km", "n_comp_3km", "n_comp_5km", "semana_ord",
    ]
    panel = panel[order].sort_values(["codigo", "semana_ord"]).reset_index(drop=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if LAST_REPORT is not None:
        report_path = args.output.parent / "raw_file_report.csv"
        LAST_REPORT.to_csv(report_path, index=False)
        print(f"Per-file report written to {report_path}")
    panel["fecha"] = panel["fecha"].dt.strftime("%Y-%m-%d")
    panel.to_csv(args.output, index=False)
    print(
        f"Wrote {args.output}: {len(panel):,} rows | {panel['codigo'].nunique():,} stations | "
        f"{panel['year_week'].nunique():,} weeks | {panel['fecha'].min()} to {panel['fecha'].max()}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
