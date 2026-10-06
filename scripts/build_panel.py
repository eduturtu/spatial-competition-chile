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


RAW_PATTERNS = ("*.csv", "*.csv.bz2", "*.csv.gz", "*.csv.zip")
FUEL_MAP = {
    "Gasolina 93": "93", "Gasolina 95": "95", "Gasolina 97": "97",
    "Petroleo Diesel": "DI", "Petróleo Diesel": "DI", "Kerosene": "KE",
    "GLP Vehicular": "GLP", "GNC": "GNC",
}
CHUNK_ROWS = 500_000


def _open_text(path: Path):
    """Text handle for plain or compressed files (only used to sniff the header)."""
    name = path.name.lower()
    if name.endswith(".bz2"):
        import bz2
        return bz2.open(path, "rt", encoding="utf-8", errors="ignore")
    if name.endswith(".gz"):
        import gzip
        return gzip.open(path, "rt", encoding="utf-8", errors="ignore")
    if name.endswith(".zip"):
        import io, zipfile
        zf = zipfile.ZipFile(path)
        return io.TextIOWrapper(zf.open(zf.namelist()[0]), encoding="utf-8", errors="ignore")
    return path.open("r", encoding="utf-8", errors="ignore")


def _detect_delimiter(path: Path) -> str:
    with _open_text(path) as fh:
        header = fh.readline()
    return ";" if header.count(";") > header.count(",") else ","


def _fix_mojibake(x: str) -> str:
    """Repair UTF-8 text that was decoded as latin1 (e.g. 'ValparaÃ\xadso')."""
    if "Ã" in x or "Â" in x:
        try:
            return x.encode("latin1").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            return x
    return x


def _norm_text(s: pd.Series) -> pd.Series:
    """Mojibake repair, NFC, trimmed single spaces, upper case. Applied to the
    unique values only, then mapped back (fast on millions of rows)."""
    s = s.astype("string")
    uniq = pd.Series(s.dropna().unique(), dtype="string")
    fixed = (uniq.map(_fix_mojibake).str.normalize("NFC").str.strip()
             .str.replace(r"\s+", " ", regex=True).str.upper())
    return s.map(dict(zip(uniq, fixed)))


def _parse_price(s: pd.Series) -> pd.Series:
    """Prices come as 759, 1331.000, 1234,5 or (rarely) 1.080 = 1,080 CLP.
    A dot is read as a thousands separator only when the decimal reading would
    give an impossible price (< 10 CLP), so "945.000" stays 945."""
    t = s.astype("string").str.strip().str.replace(r"[^0-9.,]", "", regex=True)
    both = t.str.contains(",", regex=False) & t.str.contains(".", regex=False)
    t = t.mask(both, t.str.replace(".", "", regex=False))                 # 1.234,5 -> 1234,5
    t = t.str.replace(",", ".", regex=False)
    val = pd.to_numeric(t, errors="coerce")
    thousands = t.str.fullmatch(r"\d{1,3}(\.\d{3})+", na=False) & (val < 10)
    val = val.mask(thousands, pd.to_numeric(t.str.replace(".", "", regex=False), errors="coerce"))
    return val


def _parse_dates(s: pd.Series) -> pd.Series:
    """Fast explicit formats first; element-wise 'mixed' parsing only for the
    rest. (A single to_datetime call infers ONE format from the first row and
    silently turns every row in another format into NaT.)"""
    t = s.astype("string").str.strip()
    out = pd.Series(pd.NaT, index=t.index, dtype="datetime64[ns]")
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d", "%d/%m/%Y %H:%M:%S", "%d/%m/%Y %H:%M",
                "%d/%m/%Y", "%d-%m-%Y", "%Y/%m/%d"):
        todo = out.isna() & t.notna()
        if not todo.any():
            break
        out[todo] = pd.to_datetime(t[todo], errors="coerce", format=fmt)
    todo = out.isna() & t.notna()
    if todo.any():
        iso = t.str.match(r"^\d{4}", na=False)
        for mask, kw in ((todo & iso, {"yearfirst": True}), (todo & ~iso, {"dayfirst": True})):
            if mask.any():
                out[mask] = pd.to_datetime(t[mask], errors="coerce", format="mixed", **kw)
    return out


def _normalise_chunk(df: pd.DataFrame) -> pd.DataFrame:
    df.columns = [str(c).strip() for c in df.columns]
    rename = {"id": "codigo", "comuna": "nom_comuna", "region": "nom_region"}
    df = df.rename(columns={k: v for k, v in rename.items() if k in df.columns})
    missing = REQUIRED_RAW.difference(df.columns)
    if missing:
        raise ValueError("Missing required columns: " + ", ".join(sorted(missing)))
    for col in OPTIONAL_PANEL:
        if col not in df.columns:
            df[col] = pd.NA
    # 2023+ files carry the time of the update in a separate column; keep it so
    # the last report within a day/week is well defined.
    if "hora_actualizacion" in df.columns:
        hora = df["hora_actualizacion"].astype("string").str.strip()
        df["fecha_actualizacion"] = (df["fecha_actualizacion"].astype("string").str.strip()
                                     + (" " + hora.str.zfill(8)).fillna(""))
    fuel = df["combustible"].astype("string").str.strip().replace(FUEL_MAP)
    fuel = fuel.str.replace(r"^A(?=93$|95$|97$)", "", regex=True).replace({"ADI": "DI", "AKE": "KE"})
    df["combustible"] = fuel
    df["codigo"] = df["codigo"].astype("string").str.strip()
    return df[["codigo", "combustible", "precio", "fecha_actualizacion",
               "latitud", "longitud", *OPTIONAL_PANEL]]


def _read_file(path: Path, fuel: str) -> tuple[pd.DataFrame, dict]:
    """Read one raw file in chunks, keep only `fuel` rows. UTF-8 first (strict,
    so a latin1 file fails and is re-read); reading UTF-8 as latin1 never fails
    but produces 'ValparaÃ­so'."""
    sep = _detect_delimiter(path)
    last_exc: Exception | None = None
    for enc in ("utf-8-sig", "latin1"):
        try:
            kept, rows, codigos, fuels = [], 0, set(), {}
            # dtype=str: otherwise pandas turns "1.080" into 1.08 and drops
            # leading zeros in station codes before any parsing happens here.
            reader = pd.read_csv(path, sep=sep, encoding=enc, on_bad_lines="skip", dtype=str,
                                 keep_default_na=False, na_values=[""], chunksize=CHUNK_ROWS,
                                 compression="infer")
            for chunk in reader:
                chunk = _normalise_chunk(chunk)
                rows += len(chunk)
                codigos.update(chunk["codigo"].dropna().unique())
                for k, v in chunk["combustible"].value_counts().head(10).items():
                    fuels[k] = fuels.get(k, 0) + int(v)
                kept.append(chunk.loc[chunk["combustible"] == fuel])
            df = pd.concat(kept, ignore_index=True)
            stats = {"archivo_origen": path.name, "rows": rows, "fuel_rows": len(df),
                     "n_codigo": len(codigos), "encoding": enc,
                     "_fuels": dict(sorted(fuels.items(), key=lambda kv: -kv[1])[:8])}
            return df, stats
        except UnicodeDecodeError as exc:
            last_exc = exc
    raise RuntimeError(f"Could not decode {path}") from last_exc


def load_raw_files(raw_dir: Path, fuel: str = "93") -> tuple[pd.DataFrame, pd.DataFrame]:
    paths = sorted({p for pat in RAW_PATTERNS for p in raw_dir.glob(pat)})
    if not paths:
        raise FileNotFoundError(f"No raw CNE files (.csv, .csv.bz2, .csv.gz, .csv.zip) in {raw_dir}")
    frames, stats = [], []
    for i, path in enumerate(paths, start=1):
        print(f"[{i}/{len(paths)}] Reading {path.name}", flush=True)
        try:
            df, st = _read_file(path, fuel)
        except ValueError as exc:
            raise ValueError(f"{path.name}: {exc}") from exc
        df["archivo_origen"] = path.name
        frames.append(df)
        stats.append(st)
    fuel_rows = pd.concat(frames, ignore_index=True)
    for col in ("distribuidor", "nom_comuna", "nom_region", "razon_social"):
        fuel_rows[col] = _norm_text(fuel_rows[col])
    for col in ("latitud", "longitud"):
        fuel_rows[col] = pd.to_numeric(fuel_rows[col].astype("string").str.replace(",", ".", regex=False),
                                       errors="coerce")
    return fuel_rows, pd.DataFrame(stats)


def build_weekly_panel(df: pd.DataFrame, file_stats: pd.DataFrame,
                       start: str = "2012-01-01") -> pd.DataFrame:
    start = pd.Timestamp(start)
    if df.empty:
        raise ValueError("No observations found for the requested fuel code")

    df["fecha"] = _parse_dates(df["fecha_actualizacion"])
    df["precio"] = _parse_price(df["precio"])
    df["fecha_ok"] = df["fecha"].notna()
    df["precio_ok"] = df["precio"].notna()
    df["geo_ok"] = (
        df["latitud"].between(-56, -17, inclusive="both")
        & df["longitud"].between(-76, -66, inclusive="both")
    )
    df["kept"] = df["fecha_ok"] & df["precio_ok"] & df["geo_ok"] & (df["fecha"] >= start)
    report_by_file(file_stats, df)
    df = df.loc[df["kept"]].copy()

    iso = df["fecha"].dt.isocalendar()
    df["year_week"] = iso.year.astype(int).astype(str) + "-W" + iso.week.astype(int).astype(str).str.zfill(2)

    # Last reported price in each station-week. Yearly files overlap at their
    # edges, so identical reports can appear twice; a stable sort plus
    # drop_duplicates keeps one whole row (groupby().last() would mix columns).
    #
    # The 2023 file re-exports the full history (back to 2012) of the stations
    # still active in 2023, labelled with their *current* brand: a Petrobras
    # station rebranded to Aramco in 2022 shows up as ARAMCO in 2012. When a
    # station-week appears in several files, prefer the file whose year matches
    # the report year (the contemporaneous record), then the latest report.
    file_year = pd.to_numeric(df["archivo_origen"].str.extract(r"((?:19|20)\d{2})")[0], errors="coerce")
    df["nativo"] = file_year.isna() | (file_year == df["fecha"].dt.year)
    df = df.sort_values(["codigo", "year_week", "nativo", "fecha"], kind="mergesort")
    keep = ["codigo", "year_week", "precio", "fecha", "latitud", "longitud", *OPTIONAL_PANEL]
    panel = df.drop_duplicates(["codigo", "year_week"], keep="last")[keep].reset_index(drop=True)

    # Report date without time of day, so R reads `fecha` as a Date.
    panel["fecha"] = panel["fecha"].dt.normalize()

    # Calendar-week index from the first ISO week in the data: weeks without
    # reports still advance it, so event buffers in R are calendar weeks.
    monday = panel["fecha"] - pd.to_timedelta(panel["fecha"].dt.weekday, unit="D")
    panel["semana_ord"] = ((monday - monday.min()).dt.days // 7).astype(int)
    return panel


LAST_REPORT: pd.DataFrame | None = None


def report_by_file(file_stats: pd.DataFrame, fuel_rows: pd.DataFrame) -> None:
    """Rows surviving each step, by raw file. A file that loses most of its rows
    (or has no fuel rows) points to a format the builder does not handle."""
    global LAST_REPORT
    steps = fuel_rows.groupby("archivo_origen").agg(
        fecha_ok=("fecha_ok", "sum"), precio_ok=("precio_ok", "sum"),
        geo_ok=("geo_ok", "sum"), kept=("kept", "sum"),
        fecha_min=("fecha", "min"), fecha_max=("fecha", "max"),
        precio_mediana=("precio", "median"))
    rep = (file_stats.drop(columns="_fuels").set_index("archivo_origen")
           .join(steps, how="left").fillna({"fecha_ok": 0, "precio_ok": 0, "geo_ok": 0, "kept": 0}))
    rep["share_kept"] = (rep["kept"] / rep["fuel_rows"].where(rep["fuel_rows"] > 0)).round(3)
    LAST_REPORT = rep.reset_index()
    with pd.option_context("display.width", 250, "display.max_columns", 30, "display.max_rows", 500):
        print("\nRows by raw file and step:")
        print(LAST_REPORT.to_string(index=False))
    fuels = file_stats.set_index("archivo_origen")["_fuels"]
    for f in rep.index[(rep["fuel_rows"] == 0) | (rep["share_kept"] < 0.8)]:
        sub = fuel_rows.loc[fuel_rows["archivo_origen"] == f]
        print(f"\nWARNING {f}: fuel_rows={int(rep.loc[f, 'fuel_rows'])}, share_kept={rep.loc[f, 'share_kept']}")
        print("  combustible values in file:", fuels[f])
        bad = sub.loc[~sub["kept"]]
        print("  fecha_actualizacion examples (dropped):", bad["fecha_actualizacion"].astype("string").head(3).tolist())
        print("  precio examples (dropped):", bad["precio"].astype("string").head(3).tolist())


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
    parser.add_argument("--start", default="2012-01-01",
                        help="Drop reports before this date (default 2012-01-01; the 2023 file "
                             "re-exports history back to 2011 for a handful of stations)")
    parser.add_argument("--report-only", action="store_true",
                        help="Only print/save the per-file report (fast); do not build the panel")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    print(f"Raw directory: {args.raw_dir}")
    fuel_rows, file_stats = load_raw_files(args.raw_dir, fuel=args.fuel)
    print(f"Loaded {int(file_stats['rows'].sum()):,} raw rows, {len(fuel_rows):,} for fuel {args.fuel}")
    panel = build_weekly_panel(fuel_rows, file_stats, start=args.start)
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
