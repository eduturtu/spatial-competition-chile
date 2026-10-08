# Data

Input files are not versioned (see `.gitignore`). All come from the public *Bencina en Línea* / *Energía Abierta* portal of Chile's National Energy Commission (CNE): https://www.energiaabierta.cl

There are two ways to reproduce the analysis:

1. **Start from a pre-built station-week panel (fastest):** place `panel_estacion_semana.csv` (or the compressed `panel_estacion_semana.csv.gz`) directly in `data/`.
2. **Rebuild the panel from the raw CNE archive:** place the yearly raw files (`2012.csv.bz2` ... `2026.csv.bz2`; plain, `.bz2`, `.gz` or `.zip` CSVs all work) in `data/raw_cne/`. `R/01_build_panel.R` will call `scripts/build_panel.py` automatically when the pre-built panel is absent. Install the Python dependencies first with `pip install -r requirements.txt`.

Optional inputs can also be placed directly in `data/`:

| File | Required | Used in | Content |
|---|---|---|---|
| `panel_estacion_semana.csv` | Yes* | all scripts | Station-week panel; may be supplied directly or rebuilt by `R/01_build_panel.R` |
| `sh_precios_margenes_semanales_rm.xlsx` | No | `R/06_mechanisms.R` | Weekly parity price, retail price and gross margin, Metropolitan Region (descriptive only) |
| `pares_distancia_manejo.csv` | No | `R/03_main_analysis.R` | Sample of station pairs with Haversine and Google Maps driving distance (validation only) |


`*` Required unless `data/raw_cne/` contains the historical CNE CSV files needed to rebuild it.

## Raw CNE files

The raw files are not versioned. The builder is based on the original processing script used in this project: it handles the historical delimiter/encoding differences, harmonises fuel codes, keeps 93-octane gasoline, takes the last reported price in each station-week, and counts active competitors within 1, 2, 3 and 5 km using Haversine distance. Entry and exit events are **not** defined in Python; they are constructed once, downstream, in `R/02_clean_data.R`.

Features of the archive that the pipeline handles explicitly:

- Two formats. 2012 to 2022: `;`-separated, comma decimals, fuel labels such as "Gasolina 93", station id in `id`. 2023 onwards: `,`-separated, fuel codes such as "A93", time of update in a separate column, id in `codigo`. Station ids are the same across both.
- The 2023 file re-exports the full history (back to 2011) of every station still active in 2023, labelled with its current brand, so former Petrobras stations appear as ARAMCO in 2012. When a station-week is in more than one file, the builder keeps the record from the file of that year.
- 2012 is the platform's first year and stations join it gradually; a first report in 2012 is not treated as an entry (`ENTRY_START` in `R/00_setup.R`).
- About 130 stations report for the last time in the last days of 2022 and never appear in the new system. That is a change of data source, not observed closures, so they are treated as censored: neither exits nor incumbents (`ARCHIVE_SEAM`).
- Before 2023 stations report roughly weekly; from 2023 the system records price changes, so a station can be active in a week without a report. Competitor counts use stations that report in the week, which understates them somewhat from 2023 on.

Because the public archive has changed formats over time, a rebuild from raw files should be checked against the summary statistics reported in the paper before replacing an existing validated panel.

To check how each raw file is parsed without building the panel (fast):

```
python scripts/build_panel.py --raw-dir data/raw_cne --output data/panel_estacion_semana.csv --report-only
```

This writes `data/raw_file_report.csv` with the rows of each file that survive each step (fuel code, date, price, coordinates) and prints examples from any file that loses more than 20% of its rows. `R/02_clean_data.R` also stops if any year of the panel has less than a quarter of the observations of the best-covered year.

## `panel_estacion_semana.csv`

One row per station and week. Columns used:

| Column | Description |
|---|---|
| `codigo` | Station identifier (CNE) |
| `fecha` | Date (no time of day) of the last price report in the station-week |
| `year_week` | Year-week identifier (week fixed effect) |
| `semana_ord` | Calendar-week index from the first ISO week in the data (weeks without reports still count) |
| `precio` | Retail price of 93-octane gasoline, CLP per litre |
| `latitud`, `longitud` | Station coordinates |
| `distribuidor` | Brand (Copec, Shell, Petrobras, Aramco, independents) |
| `razon_social` | Legal name of the operator |
| `nom_comuna`, `nom_region` | Municipality and region |
| `n_comp_1km` ... `n_comp_5km` | Number of other stations within 1, 2, 3 and 5 km (Haversine) |

## `pares_distancia_manejo.csv`

Columns `dist_haversine` and `dist_manejo_km`. Driving distances come from the Google Maps Distance Matrix API, whose terms restrict redistribution, so this file is not shared. The validation step is skipped if it is absent.

## Derived files

`R/02_clean_data.R` writes `data/derived/panel_limpio.rds` and `data/derived/eventos.rds`. They are regenerated on every run and are not versioned.
