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
  raw_files <- list.files(raw_dir, pattern = "\\.csv(\\.bz2|\\.gz|\\.zip)?$", full.names = TRUE)
  if (length(raw_files) == 0L) {
    stop(
      "data/panel_estacion_semana.csv is missing and no raw CNE CSV files were found in ",
      "data/raw_cne/. See data/README.md.", call. = FALSE
    )
  }
  if (!file.exists(builder)) stop("Panel builder not found: ", builder, call. = FALSE)

  # First interpreter on PATH that runs and has pandas + numpy installed
  # (skips the Windows Store "python" stub and interpreters without the deps).
  python_candidates <- unname(Sys.which(c("python3", "python", "py")))
  python_candidates <- python_candidates[nzchar(python_candidates)]
  usable <- vapply(python_candidates, function(p) {
    out <- suppressWarnings(system2(p, c("-c", shQuote("import pandas, numpy")),
                                    stdout = FALSE, stderr = FALSE))
    identical(as.integer(out), 0L)
  }, logical(1))
  if (!any(usable)) {
    stop("No Python 3 interpreter with pandas and numpy was found on PATH. ",
         "Run: pip install -r requirements.txt", call. = FALSE)
  }
  python <- python_candidates[usable][[1]]

  message(sprintf("Building station-week panel from %d raw CNE files...", length(raw_files)))
  status <- system2(
    python,
    args = shQuote(c(builder, "--raw-dir", raw_dir, "--output", path_panel_raw, "--fuel", "93"))
  )
  if (!identical(as.integer(status), 0L)) {
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
