# =============================================================================
# 02_clean_data.R
# Cleans the station-week panel and builds the entry/exit event files.
# Outputs: data/derived/panel_limpio.rds, data/derived/eventos.rds
# =============================================================================

source(here::here("R", "00_setup.R"))
section("Data cleaning")

panel_raw <- read_csv(path_panel_raw, show_col_types = FALSE)
if (!inherits(panel_raw$fecha, "Date")) {
  stop("`fecha` must be a date without time of day (found ", class(panel_raw$fecha)[1],
       "). Rebuild the panel with scripts/build_panel.py.", call. = FALSE)
}
if (!is.na(SAMPLE_END)) panel_raw <- panel_raw %>% filter(fecha <= SAMPLE_END)
cat(sprintf("Raw observations: %s\n", format(nrow(panel_raw), big.mark = ",")))

n_high <- sum(panel_raw$precio > PRICE_MAX, na.rm = TRUE)
n_low  <- sum(panel_raw$precio < PRICE_MIN, na.rm = TRUE)
n_na   <- sum(is.na(panel_raw$precio))
cat(sprintf("Dropped: price > %d: %d | price < %d: %d | NA: %d (%.2f%% of total)\n",
            PRICE_MAX, n_high, PRICE_MIN, n_low, n_na,
            100 * (n_high + n_low + n_na) / nrow(panel_raw)))

panel <- panel_raw %>%
  filter(!is.na(precio), precio >= PRICE_MIN, precio <= PRICE_MAX) %>%
  mutate(across(c(distribuidor, nom_comuna, nom_region), norm_text),
         log_precio = log(precio),
         year_month = format(fecha, "%Y-%m"),
         year       = year(fecha))

# semana_ord must count calendar weeks. Older panels numbered only the weeks
# present in the data, so a multi-year gap collapsed into a few "weeks" and the
# 26-week event buffers lost their meaning.
semana_cal <- as.integer((floor_date(panel$fecha, "week", week_start = 1) -
                          floor_date(min(panel$fecha), "week", week_start = 1)) / 7)
if (!identical(rank(panel$semana_ord, ties.method = "min"), rank(semana_cal, ties.method = "min")) ||
    max(panel$semana_ord) - min(panel$semana_ord) != max(semana_cal)) {
  message("Recomputing semana_ord as a calendar-week index (input counted only observed weeks).")
}
panel$semana_ord <- semana_cal

# ---- Coverage check -----------------------------------------------------------
# A year with far fewer station-weeks than the rest means raw files were lost
# or misparsed when the panel was built; every downstream number would be wrong.
cobertura_anual <- panel %>% count(year, name = "obs")
print(cobertura_anual, n = Inf)
interior <- cobertura_anual %>% filter(year > min(year), year < max(year))
# Benchmark is the best-covered year: when most years are broken, the median is too.
huecos <- interior %>% filter(obs < 0.25 * max(cobertura_anual$obs))
if (nrow(huecos) > 0 && !isTRUE(getOption("sc.allow_gaps", FALSE))) {
  stop("Panel coverage collapses in: ", paste(huecos$year, collapse = ", "),
       ". Check data/raw_file_report.csv (python scripts/build_panel.py --report-only). ",
       "Set options(sc.allow_gaps = TRUE) to run anyway.", call. = FALSE)
}

cat(sprintf("Clean observations: %s | stations: %d | weeks: %d | period: %s to %s\n",
            format(nrow(panel), big.mark = ","), n_distinct(panel$codigo),
            n_distinct(panel$year_week), min(panel$fecha), max(panel$fecha)))

# ---- Stations that change brand (excluded from event definitions) -----------
cambios_marca <- panel %>%
  group_by(codigo) %>%
  summarise(n_marcas = n_distinct(distribuidor), .groups = "drop") %>%
  filter(n_marcas > 1) %>%
  pull(codigo)
cat(sprintf("Stations with brand changes: %d (%.1f%%)\n", length(cambios_marca),
            100 * length(cambios_marca) / n_distinct(panel$codigo)))

# ---- One row per station ----------------------------------------------------
ubicaciones <- panel %>%
  group_by(codigo) %>%
  summarise(lat = first(latitud), lon = first(longitud),
            nom_comuna = first(nom_comuna), nom_region = first(nom_region),
            distribuidor = first(distribuidor), razon_social = first(razon_social),
            .groups = "drop")

# ---- Station life on the weekly index ---------------------------------------
vida <- panel %>%
  group_by(codigo) %>%
  summarise(prim = min(semana_ord), ult = max(semana_ord), nobs = n(),
            prim_fecha = min(fecha), ult_fecha = max(fecha), .groups = "drop") %>%
  mutate(span = ult - prim + 1,
         faltantes = span - nobs,
         share_faltante = faltantes / span)

censurados <- vida %>%
  filter(ult_fecha >= ARCHIVE_SEAM[1], ult_fecha <= ARCHIVE_SEAM[2]) %>% pull(codigo)
cat(sprintf("Stations censored at the December 2022 archive seam: %d\n", length(censurados)))

s_min <- min(panel$semana_ord)
s_max <- max(panel$semana_ord)

# ---- Event definitions ------------------------------------------------------
# Entry = first appearance at least BUF_WEEKS after the start of the sample and
#         not before ENTRY_START (platform onboarding in 2012);
# exit  = last appearance at least BUF_WEEKS before the end of the sample,
#         excluding stations censored at the 2022 archive seam.
entradas <- vida %>%
  filter(prim > s_min + BUF_WEEKS, prim_fecha >= ENTRY_START, nobs >= MIN_OBS_EV,
         !(codigo %in% cambios_marca)) %>%
  transmute(codigo, sem_evento = prim)

salidas <- vida %>%
  filter(ult < s_max - BUF_WEEKS, nobs >= MIN_OBS_EV, !(codigo %in% cambios_marca),
         !(codigo %in% censurados)) %>%
  transmute(codigo, sem_evento = ult)

incumbentes <- vida %>%
  filter(!(codigo %in% entradas$codigo), !(codigo %in% salidas$codigo),
         !(codigo %in% censurados), nobs >= MIN_OBS_INC) %>%
  left_join(ubicaciones, by = "codigo")

cat(sprintf("Entries: %d | Exits: %d | Incumbents: %d\n",
            nrow(entradas), nrow(salidas), nrow(incumbentes)))

ev_entrada       <- nearest_events(incumbentes, entradas, ubicaciones)
ev_salida        <- nearest_events(incumbentes, salidas,  ubicaciones)
ev_entrada_rival <- nearest_events(incumbentes, entradas, ubicaciones, rival_only = TRUE)
ev_salida_rival  <- nearest_events(incumbentes, salidas,  ubicaciones, rival_only = TRUE)

cat(sprintf("Incumbents with a nearby entry: %d | exit: %d | rival-brand entry: %d | rival-brand exit: %d\n",
            nrow(ev_entrada), nrow(ev_salida), nrow(ev_entrada_rival), nrow(ev_salida_rival)))

# ---- Calendar-date event definition (Table 3 of the paper) -------------------
# The baseline entry/exit DiD in the paper uses this definition: events are
# dated in calendar time, with a 180-day edge buffer and fixed cut-off dates.
fecha_min_panel <- min(panel$fecha)
fecha_max_panel <- max(panel$fecha)

vida_fecha <- panel %>%
  group_by(codigo) %>%
  summarise(primera_fecha = min(fecha), ultima_fecha = max(fecha), n_obs = n(), .groups = "drop")

entradas_cal <- vida_fecha %>%
  filter(primera_fecha >= ENTRY_START, primera_fecha > fecha_min_panel + 180,
         n_obs >= MIN_OBS_EV, !(codigo %in% cambios_marca)) %>%
  select(codigo, fecha_entrada = primera_fecha)

salidas_cal <- vida_fecha %>%
  filter(ultima_fecha < as.Date("2025-12-31"), ultima_fecha < fecha_max_panel - 180,
         n_obs >= MIN_OBS_EV, !(codigo %in% cambios_marca), !(codigo %in% censurados)) %>%
  select(codigo, fecha_salida = ultima_fecha)

incumbentes_cal <- vida_fecha %>%
  filter(!(codigo %in% entradas_cal$codigo), !(codigo %in% salidas_cal$codigo),
         !(codigo %in% censurados), n_obs >= MIN_OBS_INC) %>%
  left_join(ubicaciones %>% select(codigo, lat, lon, nom_comuna, nom_region, distribuidor),
            by = "codigo")

nearest_events_cal <- function(events, date_col, type) {
  inc <- incumbentes_cal %>% select(codigo_inc = codigo, lat_inc = lat, lon_inc = lon)
  geo <- events %>%
    left_join(ubicaciones %>% select(codigo, lat, lon, nom_comuna, nom_region, distribuidor),
              by = "codigo") %>%
    rename(codigo_ev = codigo, lat_ev = lat, lon_ev = lon, fecha_ev = all_of(date_col))
  inc %>%
    crossing(geo) %>%
    mutate(distancia = haversine(lat_inc, lon_inc, lat_ev, lon_ev)) %>%
    filter(distancia <= RADIUS_KM, distancia > 0) %>%
    group_by(codigo_inc) %>% arrange(fecha_ev) %>% slice(1) %>% ungroup() %>%
    select(codigo = codigo_inc, fecha_evento = fecha_ev, distancia) %>%
    mutate(tipo_evento = type)
}

eventos_cal <- bind_rows(
  nearest_events_cal(entradas_cal, "fecha_entrada", "entrada"),
  nearest_events_cal(salidas_cal,  "fecha_salida",  "salida"))

# Number of competitors within 1 km just before the event (for heterogeneity)
comp_al_evento <- eventos_cal %>%
  left_join(panel %>% select(codigo, fecha, n_comp_1km), by = "codigo",
            relationship = "many-to-many") %>%
  filter(fecha <= fecha_evento) %>%
  group_by(codigo, tipo_evento) %>% filter(fecha == max(fecha)) %>% ungroup() %>%
  select(codigo, tipo_evento, n_comp_inicial = n_comp_1km) %>% distinct()
eventos_cal <- eventos_cal %>% left_join(comp_al_evento, by = c("codigo", "tipo_evento"))

cat(sprintf("Calendar definition: entries %d, exits %d, incumbents %d; exposed to entry %d, to exit %d\n",
            nrow(entradas_cal), nrow(salidas_cal), nrow(incumbentes_cal),
            sum(eventos_cal$tipo_evento == "entrada"), sum(eventos_cal$tipo_evento == "salida")))

# ---- Save ---------------------------------------------------------------------
saveRDS(panel, path_panel)
saveRDS(list(cambios_marca = cambios_marca, ubicaciones = ubicaciones, vida = vida,
             entradas = entradas, salidas = salidas, incumbentes = incumbentes,
             ev_entrada = ev_entrada, ev_salida = ev_salida,
             ev_entrada_rival = ev_entrada_rival, ev_salida_rival = ev_salida_rival,
             entradas_cal = entradas_cal, salidas_cal = salidas_cal, eventos_cal = eventos_cal),
        file.path(dir_derived, "eventos.rds"))
unlink(path_results)   # results of a previous run are no longer valid
guardar(
  n_raw = nrow(panel_raw), n_drop = n_high + n_low + n_na,
  n_obs = nrow(panel), n_estaciones = n_distinct(panel$codigo),
  n_semanas = n_distinct(panel$year_week),
  anio_ini = year(min(panel$fecha)), anio_fin = year(max(panel$fecha)),
  fecha_fin = max(panel$fecha),
  n_cambios_marca = length(cambios_marca),
  pct_cambios_marca = 100 * length(cambios_marca) / n_distinct(panel$codigo),
  n_censurados = length(censurados),
  n_entradas = nrow(entradas_cal), n_salidas = nrow(salidas_cal),
  n_incumbentes = nrow(incumbentes_cal),
  n_exp_entrada = sum(eventos_cal$tipo_evento == "entrada"),
  n_exp_salida  = sum(eventos_cal$tipo_evento == "salida"))
cat("Saved data/derived/panel_limpio.rds and data/derived/eventos.rds\n")
