# =============================================================================
# 00_setup.R
# Packages, paths, constants and helper functions shared by all scripts.
# Every other script starts with source(here::here("R", "00_setup.R")).
# =============================================================================

required_pkgs <- c("here", "tidyverse", "fixest", "lubridate", "modelsummary", "rmarkdown",
                   "readxl", "HonestDiD", "spacefillr")

missing_pkgs <- required_pkgs[!vapply(required_pkgs, requireNamespace,
                                      logical(1), quietly = TRUE)]
if (length(missing_pkgs) > 0) {
  stop("Missing packages: ", paste(missing_pkgs, collapse = ", "),
       "\nRun renv::restore() or install.packages(c(",
       paste0('"', missing_pkgs, '"', collapse = ", "), "))", call. = FALSE)
}

suppressPackageStartupMessages({
  library(here)
  library(tidyverse)
  library(fixest)
  library(lubridate)
})

# ---- Paths ------------------------------------------------------------------
dir_data    <- here("data")
dir_derived <- here("data", "derived")
dir_output  <- here("output")
dir_figures <- here("figures")      # versioned: figures shown in the README
for (d in c(dir_derived, dir_output, dir_figures)) dir.create(d, showWarnings = FALSE, recursive = TRUE)

# The station-week panel may be stored plain or gzip-compressed.
path_panel_raw <- file.path(dir_data, "panel_estacion_semana.csv")
if (!file.exists(path_panel_raw) && file.exists(paste0(path_panel_raw, ".gz"))) {
  path_panel_raw <- paste0(path_panel_raw, ".gz")
}
path_pairs     <- file.path(dir_data, "pares_distancia_manejo.csv")
path_margins   <- file.path(dir_data, "sh_precios_margenes_semanales_rm.xlsx")
path_panel     <- file.path(dir_derived, "panel_limpio.rds")

# ---- Sample constants -------------------------------------------------------
PRICE_MIN  <- 400     # CLP per litre; plausibility filter (see paper, Section 4)
PRICE_MAX  <- 2000
BUF_WEEKS  <- 26      # edge buffer for entry/exit definitions (weeks)
MIN_OBS_EV <- 20      # minimum reported weeks for an entrant/exiter
MIN_OBS_INC <- 50     # minimum reported weeks for an incumbent
RADIUS_KM  <- 1       # local market radius
MEPCO_DATE <- as.Date("2014-07-01")

# Sample window. SAMPLE_END reproduces the paper's sample (743 weeks); set it
# to NA to use every week in the panel.
SAMPLE_END  <- as.Date("2026-03-22")
# Bencina en Linea launched in 2012 and stations joined the platform during that
# year: a first report in 2012 is onboarding, not entry.
ENTRY_START <- as.Date("2013-01-01")
# Archive seam: the historical yearly files end in December 2022 and the new
# system starts in 2023. About 130 stations have their last report in the last
# days of 2022 and never appear in the new system. Their disappearance is a
# change of data source, not an observed closure, so they are treated as
# censored (neither exits nor incumbents).
ARCHIVE_SEAM <- as.Date(c("2022-12-15", "2022-12-31"))

# ---- Helpers ----------------------------------------------------------------
haversine <- function(lat1, lon1, lat2, lon2) {
  R <- 6371
  dlat <- (lat2 - lat1) * pi / 180
  dlon <- (lon2 - lon1) * pi / 180
  a <- sin(dlat / 2)^2 + cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dlon / 2)^2
  2 * R * asin(sqrt(a))
}

load_clean <- function() {
  if (!file.exists(path_panel)) {
    stop("Clean panel not found. Run R/02_clean_data.R first (or source run_all.R).",
         call. = FALSE)
  }
  readRDS(path_panel)
}

save_plot <- function(plot, name, width = 10, height = 6, readme = FALSE) {
  ggsave(file.path(dir_output, name), plot, width = width, height = height, dpi = 300, bg = "white")
  if (readme) file.copy(file.path(dir_output, name), file.path(dir_figures, name), overwrite = TRUE)
  invisible(file.path(dir_output, name))
}

# Base-graphics figures (fixest::iplot, HonestDiD) are written through this wrapper
save_base_plot <- function(expr, name, readme = FALSE, width = 1000, height = 600, res = 110) {
  png(file.path(dir_output, name), width = width, height = height, res = res)
  on.exit(dev.off())
  force(expr)
  if (readme) on.exit(file.copy(file.path(dir_output, name), file.path(dir_figures, name),
                                overwrite = TRUE), add = TRUE)
  invisible(file.path(dir_output, name))
}

load_events <- function() {
  p <- file.path(dir_derived, "eventos.rds")
  if (!file.exists(p)) stop("Event files not found. Run R/02_clean_data.R first.", call. = FALSE)
  readRDS(p)
}

# For each incumbent, the first entry/exit event within `radius` km.
# `events` has columns codigo + sem_evento (week index). If rival_only = TRUE,
# only events whose brand differs from the incumbent's brand are kept.
nearest_events <- function(incumbents, events, locations, radius = RADIUS_KM,
                           rival_only = FALSE) {
  ev_geo <- events %>%
    left_join(locations %>% select(codigo, lat, lon, nom_comuna, distribuidor, razon_social),
              by = "codigo") %>%
    rename(codigo_ev = codigo, lat_ev = lat, lon_ev = lon,
           marca_ev = distribuidor, sem_ev = sem_evento)
  out <- incumbents %>%
    transmute(codigo_inc = codigo, lat_inc = lat, lon_inc = lon, marca_inc = distribuidor) %>%
    crossing(ev_geo) %>%
    mutate(dist = haversine(lat_inc, lon_inc, lat_ev, lon_ev)) %>%
    filter(dist <= radius, dist > 0)
  if (rival_only) out <- out %>% filter(toupper(marca_inc) != toupper(marca_ev))
  out %>%
    group_by(codigo_inc) %>% arrange(sem_ev) %>% slice(1) %>% ungroup() %>%
    transmute(codigo = codigo_inc, sem_evento = sem_ev,
              marca_evento = marca_ev, codigo_evento = codigo_ev, distancia = dist)
}

# Station-week event panel within +-window weeks of the incumbent's event
event_panel <- function(panel, events, window = 52) {
  panel %>%
    inner_join(events, by = "codigo") %>%
    mutate(t = as.integer(semana_ord - sem_evento),
           post = as.integer(semana_ord >= sem_evento)) %>%
    filter(abs(t) <= window)
}

# Text normalisation: UTF-8 read as latin1 ("ValparaÃ­so"), case and spacing
# differences across archive eras ("Sin Bandera" vs "SIN BANDERA").
fix_mojibake <- function(x) {
  bad <- !is.na(x) & grepl("\u00c3|\u00c2", x)
  if (any(bad)) {
    fixed <- iconv(x[bad], from = "UTF-8", to = "latin1")
    Encoding(fixed) <- "UTF-8"
    ok <- !is.na(fixed) & validUTF8(fixed)
    x[bad][ok] <- fixed[ok]
  }
  x
}
norm_text <- function(x) toupper(stringr::str_squish(fix_mojibake(as.character(x))))

# ---- Results used by the paper ----------------------------------------------
# Every number the paper reports is saved here by the script that computes it;
# paper/paper_competencia_espacial.Rmd reads this file, so text and tables
# cannot drift from the code.
path_results <- file.path(dir_output, "resultados_paper.rds")
guardar <- function(...) {
  r <- if (file.exists(path_results)) readRDS(path_results) else list()
  nuevos <- list(...)
  r[names(nuevos)] <- nuevos
  saveRDS(r, path_results)
  invisible(r)
}
# Coefficient, SE, p-value, N and within R2 of one term of a fixest model
coef_info <- function(m, term) {
  ct <- fixest::coeftable(m)
  list(b = unname(ct[term, 1]), se = unname(ct[term, 2]), p = unname(ct[term, 4]),
       n = stats::nobs(m), wr2 = unname(fixest::r2(m, "wr2")))
}

section <- function(title) cat("\n", strrep("=", 70), "\n ", title, "\n", strrep("=", 70), "\n", sep = "")

stars_ms <- c("*" = 0.1, "**" = 0.05, "***" = 0.01)
