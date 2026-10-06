# =============================================================================
# 01_build_panel.R
# Builds data/panel_estacion_semana.csv from the raw CNE price records.
#
# If the panel is already present, this step is skipped. To rebuild from raw
# CNE files, place the historical CSVs in data/raw_cne/ and install the Python
# dependencies in requirements.txt.
# =============================================================================

source(here::here("R", "00_setup.R"))
section("Station-week panel")

raw_dir <- here::here("data", "raw_cne")
builder <- here::here("scripts", "build_panel.py")

if (file.exists(path_panel_raw)) {
  message("Station-week panel already present at data/panel_estacion_semana.csv; skipping build.")
} else {
  raw_files <- list.files(raw_dir, pattern = "\\.csv$", full.names = TRUE)
  if (length(raw_files) == 0L) {
    stop(
      "data/panel_estacion_semana.csv is missing and no raw CNE CSV files were found in ",
      "data/raw_cne/. See data/README.md.", call. = FALSE
    )
  }
  if (!file.exists(builder)) stop("Panel builder not found: ", builder, call. = FALSE)

  python_candidates <- unname(Sys.which(c("python", "python3")))
  python_candidates <- python_candidates[nzchar(python_candidates)]
  if (length(python_candidates) == 0L) {
    stop("Python 3 was not found on PATH. See data/README.md.", call. = FALSE)
  }
  python <- python_candidates[[1]]

  message(sprintf("Building station-week panel from %d raw CNE files...", length(raw_files)))
  status <- system2(
    python,
    args = c(builder, "--raw-dir", raw_dir, "--output", path_panel_raw, "--fuel", "93")
  if (!identical(status, 0L)) {
    stop("Python panel builder failed with exit status ", status, call. = FALSE)
  }
}

# Fail early if a pre-built or newly-built panel does not satisfy the analysis contract.
required_cols <- c(
  "codigo", "fecha", "year_week", "semana_ord", "precio", "latitud", "longitud",
  "distribuidor", "razon_social", "nom_comuna", "nom_region",
  "n_comp_1km", "n_comp_2km", "n_comp_3km", "n_comp_5km"
)
panel_schema <- readr::read_csv(path_panel_raw, n_max = 1, show_col_types = FALSE)
missing_cols <- setdiff(required_cols, names(panel_schema))
if (length(missing_cols) > 0L) {
  stop("Panel is missing required columns: ", paste(missing_cols, collapse = ", "), call. = FALSE)
}
message("Panel schema check passed.")
