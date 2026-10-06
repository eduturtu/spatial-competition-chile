# Data

Input files are not versioned (see `.gitignore`). All come from the public *Bencina en Línea* / *Energía Abierta* portal of Chile's National Energy Commission (CNE): https://www.energiaabierta.cl

Place these files directly in this folder before running `run_all.R`:

| File | Required | Used in | Content |
|---|---|---|---|
| `panel_estacion_semana.csv` | Yes | all scripts | Station-week panel (built by `R/01_build_panel.R`) |
| `sh_precios_margenes_semanales_rm.xlsx` | No | `R/06_mechanisms.R` | Weekly parity price, retail price and gross margin, Metropolitan Region (descriptive only) |
| `pares_distancia_manejo.csv` | No | `R/03_main_analysis.R` | Sample of station pairs with Haversine and Google Maps driving distance (validation only) |

## `panel_estacion_semana.csv`

One row per station and week. Columns used:

| Column | Description |
|---|---|
| `codigo` | Station identifier (CNE) |
| `fecha` | Date of the weekly observation |
| `year_week` | Year-week identifier (week fixed effect) |
| `semana_ord` | Consecutive week index used to define events |
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
