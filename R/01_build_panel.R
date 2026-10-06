# =============================================================================
# 01_build_panel.R
# Builds data/panel_estacion_semana.csv from the raw CNE price records
# (Bencina en Línea / Energía Abierta).
#
# Output columns used downstream:
#   codigo, fecha, year_week, semana_ord, precio, latitud, longitud,
#   distribuidor, razon_social, nom_comuna, nom_region,
#   n_comp_1km, n_comp_2km, n_comp_3km, n_comp_5km
# =============================================================================

source(here::here("R", "00_setup.R"))

if (file.exists(path_panel_raw)) {
  message("Station-week panel already present at data/panel_estacion_semana.csv; skipping build.")
} else {
  stop("data/panel_estacion_semana.csv not found and the raw-data build step ",
       "is not yet included. See data/README.md.", call. = FALSE)
}
