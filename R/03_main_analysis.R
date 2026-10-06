# =============================================================================
# 03_main_analysis.R
# Descriptives, TWFE by radius, pre/post MEPCO, TWFE robustness, distance
# validation, baseline entry/exit DiD (Taylor & Muehlegger 2025 design),
# heterogeneity by concentration, weekly event study and inference robustness.
# Paper: Tables 1-4, Section 6.1-6.3, Figures A1-A2.
# =============================================================================

source(here::here("R", "00_setup.R"))
library(modelsummary)

panel <- load_clean()
ev    <- load_events()
cambios_marca <- ev$cambios_marca
ubicaciones   <- ev$ubicaciones

# =============================================================================
# 1. Descriptive statistics
# =============================================================================
section("1. Descriptive statistics")

print(summary(panel$precio))
panel %>%
  group_by(year) %>%
  summarise(n = n(), mean = mean(precio), sd = sd(precio),
            min = min(precio), max = max(precio), .groups = "drop") %>%
  print(n = 20)

panel %>%
  summarise(across(c(n_comp_1km, n_comp_2km, n_comp_3km, n_comp_5km),
                   list(mean = ~mean(., na.rm = TRUE), sd = ~sd(., na.rm = TRUE),
                        min = ~min(., na.rm = TRUE), median = ~median(., na.rm = TRUE),
                        max = ~max(., na.rm = TRUE)))) %>%
  pivot_longer(everything(), names_to = c("variable", "stat"), names_sep = "_(?=[^_]+$)") %>%
  pivot_wider(names_from = stat, values_from = value) %>%
  print()

panel %>% distinct(codigo, nom_region)   %>% count(nom_region, sort = TRUE)   %>% print(n = 20)
panel %>% distinct(codigo, distribuidor) %>% count(distribuidor, sort = TRUE) %>% print(n = 15)

# =============================================================================
# 2. TWFE: number of competitors by radius (Table 1)
# =============================================================================
section("2. TWFE by radius")

modelo_1km <- feols(log_precio ~ n_comp_1km | codigo + year_week, data = panel, cluster = ~codigo)
modelo_2km <- feols(log_precio ~ n_comp_2km | codigo + year_week, data = panel, cluster = ~codigo)
modelo_3km <- feols(log_precio ~ n_comp_3km | codigo + year_week, data = panel, cluster = ~codigo)
modelo_5km <- feols(log_precio ~ n_comp_5km | codigo + year_week, data = panel, cluster = ~codigo)
etable(modelo_1km, modelo_2km, modelo_3km, modelo_5km, headers = c("1 km", "2 km", "3 km", "5 km"))

# =============================================================================
# 3. Pre vs post MEPCO (descriptive split; not a causal estimate of MEPCO)
# =============================================================================
section("3. Pre vs post MEPCO")

pre_mepco  <- panel %>% filter(fecha <  MEPCO_DATE)
post_mepco <- panel %>% filter(fecha >= MEPCO_DATE)

modelo_pre_1km  <- feols(log_precio ~ n_comp_1km | codigo + year_week, data = pre_mepco,  cluster = ~codigo)
modelo_post_1km <- feols(log_precio ~ n_comp_1km | codigo + year_week, data = post_mepco, cluster = ~codigo)
modelo_pre_2km  <- feols(log_precio ~ n_comp_2km | codigo + year_week, data = pre_mepco,  cluster = ~codigo)
modelo_post_2km <- feols(log_precio ~ n_comp_2km | codigo + year_week, data = post_mepco, cluster = ~codigo)
modelo_pre_3km  <- feols(log_precio ~ n_comp_3km | codigo + year_week, data = pre_mepco,  cluster = ~codigo)
modelo_post_3km <- feols(log_precio ~ n_comp_3km | codigo + year_week, data = post_mepco, cluster = ~codigo)
etable(modelo_pre_1km, modelo_post_1km, modelo_pre_2km, modelo_post_2km,
       modelo_pre_3km, modelo_post_3km,
       headers = c("Pre 1km", "Post 1km", "Pre 2km", "Post 2km", "Pre 3km", "Post 3km"))
cat("Caveat: SIPCO (2011-2014), the oil price collapse and tax changes overlap with this split.\n")

# =============================================================================
# 4. TWFE robustness
# =============================================================================
section("4. TWFE robustness")

panel_sin_cambios <- panel %>% filter(!codigo %in% cambios_marca)
modelo_1km_limpio <- feols(log_precio ~ n_comp_1km | codigo + year_week,
                           data = panel_sin_cambios, cluster = ~codigo)

modelo_mensual_1km <- feols(log_precio ~ n_comp_1km | codigo + year_month, data = panel, cluster = ~codigo)
modelo_mensual_2km <- feols(log_precio ~ n_comp_2km | codigo + year_month, data = panel, cluster = ~codigo)

panel <- panel %>% mutate(rural = as.integer(n_comp_5km < 2))
modelo_rural       <- feols(log_precio ~ n_comp_1km * rural | codigo + year_week, data = panel, cluster = ~codigo)
modelo_solo_urbano <- feols(log_precio ~ n_comp_1km | codigo + year_week, data = filter(panel, rural == 0), cluster = ~codigo)
modelo_solo_rural  <- feols(log_precio ~ n_comp_1km | codigo + year_week, data = filter(panel, rural == 1), cluster = ~codigo)

etable(modelo_1km, modelo_1km_limpio, modelo_mensual_1km, modelo_mensual_2km,
       headers = c("Baseline", "No brand changes", "Month FE 1km", "Month FE 2km"))
etable(modelo_rural, modelo_solo_urbano, modelo_solo_rural,
       headers = c("Interaction", "Urban", "Rural"))

# =============================================================================
# 5. Validation: Haversine vs Google Maps driving distance (Figure A2)
# =============================================================================
section("5. Distance validation")

if (file.exists(path_pairs)) {
  pares <- read_csv(path_pairs, show_col_types = FALSE) %>%
    filter(!is.na(dist_manejo_km), dist_haversine > 0.01) %>%
    mutate(ratio = dist_manejo_km / dist_haversine)
  cor_dist <- cor(pares$dist_haversine, pares$dist_manejo_km)
  ratio_stats <- pares %>% filter(ratio <= 5) %>%
    summarise(n = n(), mean = mean(ratio), median = median(ratio), sd = sd(ratio),
              p10 = quantile(ratio, 0.10), p90 = quantile(ratio, 0.90))
  cat(sprintf("Pairs: %d | correlation: %.4f\n", nrow(pares), cor_dist))
  print(ratio_stats)

  p_validacion <- pares %>% filter(ratio <= 5) %>%
    ggplot(aes(dist_haversine, dist_manejo_km)) +
    geom_point(alpha = 0.3, size = 1) +
    geom_abline(slope = 1, intercept = 0, color = "red", linetype = "dashed") +
    geom_smooth(method = "lm", se = FALSE, color = "blue") +
    labs(title = "Haversine vs Google Maps driving distance",
         subtitle = sprintf("Correlation: %.3f | Median ratio: %.2f", cor_dist, ratio_stats$median),
         x = "Haversine distance (km)", y = "Driving distance (km)") +
    theme_minimal() + coord_fixed()
  save_plot(p_validacion, "validacion_haversine.png", width = 8, height = 8)
} else {
  cat("data/pares_distancia_manejo.csv not found; skipping validation (optional input).\n")
}

# =============================================================================
# 6. Baseline entry/exit DiD, +-52 weeks (Table 3)
# =============================================================================
section("6. Entry vs exit DiD")

eventos_cal <- ev$eventos_cal

panel_evento <- panel %>%
  filter(codigo %in% eventos_cal$codigo) %>%
  inner_join(eventos_cal, by = "codigo") %>%
  mutate(dias_al_evento = as.numeric(fecha - fecha_evento),
         semanas_al_evento = floor(dias_al_evento / 7),
         post = as.integer(fecha >= fecha_evento)) %>%
  filter(abs(semanas_al_evento) <= 52) %>%
  distinct()

panel_entradas <- panel_evento %>% filter(tipo_evento == "entrada")
panel_salidas  <- panel_evento %>% filter(tipo_evento == "salida")
cat(sprintf("Entry panel: %s obs, %d stations | Exit panel: %s obs, %d stations\n",
            format(nrow(panel_entradas), big.mark = ","), n_distinct(panel_entradas$codigo),
            format(nrow(panel_salidas),  big.mark = ","), n_distinct(panel_salidas$codigo)))

modelo_entrada <- feols(log_precio ~ post | codigo + fecha, data = panel_entradas, cluster = ~codigo)
modelo_salida  <- feols(log_precio ~ post | codigo + fecha, data = panel_salidas,  cluster = ~codigo)
etable(modelo_entrada, modelo_salida, headers = c("Entry", "Exit"))

# 95% CI for the exit effect, in percent of price
ci_sal <- confint(modelo_salida)["post", ] * 100
cat(sprintf("Exit effect 95%% CI: [%.3f%%, %.3f%%] of price\n", ci_sal[1], ci_sal[2]))

# Saved for 06_mechanisms.R (effects relative to the retail margin)
efectos_principales <- map_dfr(list(entrada = modelo_entrada, salida = modelo_salida), function(m) {
  ci <- confint(m)["post", ]
  tibble(coef_pct = coef(m)[["post"]] * 100, ci_low_pct = ci[[1]] * 100, ci_high_pct = ci[[2]] * 100)
}, .id = "evento")
write_csv(efectos_principales, file.path(dir_output, "efectos_principales.csv"))

# =============================================================================
# 7. Heterogeneity by market concentration at the time of the event (Table 4)
# =============================================================================
section("7. Heterogeneity by concentration")

clasifica_mercado <- function(n) case_when(n <= 2 ~ "Pocos (0-2)", n <= 4 ~ "Medio (3-4)", TRUE ~ "Muchos (5+)")
panel_entradas <- panel_entradas %>% mutate(mercado = clasifica_mercado(n_comp_inicial))
panel_salidas  <- panel_salidas  %>% mutate(mercado = clasifica_mercado(n_comp_inicial))

fit_or_null <- function(d) tryCatch(
  feols(log_precio ~ post | codigo + fecha, data = d, cluster = ~codigo),
  error = function(e) { message("Skipped: ", e$message); NULL })

modelos_het <- list(
  "Ent (0-2)" = fit_or_null(filter(panel_entradas, mercado == "Pocos (0-2)")),
  "Ent (3-4)" = fit_or_null(filter(panel_entradas, mercado == "Medio (3-4)")),
  "Ent (5+)"  = fit_or_null(filter(panel_entradas, mercado == "Muchos (5+)")),
  "Sal (0-2)" = fit_or_null(filter(panel_salidas,  mercado == "Pocos (0-2)")),
  "Sal (3-4)" = fit_or_null(filter(panel_salidas,  mercado == "Medio (3-4)")),
  "Sal (5+)"  = fit_or_null(filter(panel_salidas,  mercado == "Muchos (5+)")))
modelos_het <- compact(modelos_het)
if (length(modelos_het) > 0) print(etable(modelos_het))

# =============================================================================
# 8. Weekly event study, +-26 weeks
# =============================================================================
section("8. Weekly event study")

panel_es_ent <- panel_entradas %>% filter(abs(semanas_al_evento) <= 26) %>% mutate(semana_rel = factor(semanas_al_evento))
panel_es_sal <- panel_salidas  %>% filter(abs(semanas_al_evento) <= 26) %>% mutate(semana_rel = factor(semanas_al_evento))
modelo_es_ent <- feols(log_precio ~ i(semana_rel, ref = "-1") | codigo + fecha, data = panel_es_ent, cluster = ~codigo)
modelo_es_sal <- feols(log_precio ~ i(semana_rel, ref = "-1") | codigo + fecha, data = panel_es_sal, cluster = ~codigo)

extraer_coefs <- function(modelo, tipo) {
  as.data.frame(coeftable(modelo)) %>%
    rownames_to_column("term") %>%
    filter(grepl("semana_rel", term)) %>%
    mutate(semana = as.numeric(gsub("semana_rel::(-?\\d+)", "\\1", term)),
           ci_lower = Estimate - 1.96 * `Std. Error`,
           ci_upper = Estimate + 1.96 * `Std. Error`,
           tipo = tipo) %>%
    select(semana, Estimate, ci_lower, ci_upper, tipo) %>%
    add_row(semana = -1, Estimate = 0, ci_lower = 0, ci_upper = 0, tipo = tipo) %>%
    arrange(semana)
}
coefs_plot <- bind_rows(extraer_coefs(modelo_es_ent, "Entry"),
                        extraer_coefs(modelo_es_sal, "Exit"))

p_es <- ggplot(coefs_plot, aes(semana, Estimate, color = tipo, fill = tipo)) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
  geom_vline(xintercept = -0.5, linetype = "dashed", color = "red", alpha = 0.5) +
  geom_ribbon(aes(ymin = ci_lower, ymax = ci_upper), alpha = 0.15, color = NA) +
  geom_line(linewidth = 1) + geom_point(size = 2) +
  labs(title = "Event study: nearby entry and exit (1 km)",
       x = "Weeks relative to event", y = "Effect on log(price)",
       color = NULL, fill = NULL,
       caption = "Station and week fixed effects. 95% CIs clustered by station. Reference: week -1.") +
  theme_minimal() +
  theme(legend.position = "bottom", panel.grid.minor = element_blank()) +
  scale_color_manual(values = c("steelblue", "darkgreen")) +
  scale_fill_manual(values = c("steelblue", "darkgreen"))
save_plot(p_es, "event_study_TM.png", readme = TRUE)

# =============================================================================
# 9. Inference robustness: cluster by comuna and Conley (5 km)
# =============================================================================
section("9. Inference robustness")

modelo_1km_comuna <- feols(log_precio ~ n_comp_1km | codigo + year_week, data = panel, cluster = ~nom_comuna)

add_geo <- function(d) d %>%
  left_join(ubicaciones %>% select(codigo, lat, lon, comuna = nom_comuna), by = "codigo") %>%
  distinct()
panel_entradas_geo <- add_geo(panel_entradas)
panel_salidas_geo  <- add_geo(panel_salidas)

modelo_entrada_comuna <- feols(log_precio ~ post | codigo + fecha, data = panel_entradas_geo, cluster = ~comuna)
modelo_salida_comuna  <- feols(log_precio ~ post | codigo + fecha, data = panel_salidas_geo,  cluster = ~comuna)
etable(modelo_entrada, modelo_entrada_comuna, modelo_salida, modelo_salida_comuna,
       headers = c("Ent (station)", "Ent (comuna)", "Exit (station)", "Exit (comuna)"))

tryCatch({
  modelo_1km_conley     <- feols(log_precio ~ n_comp_1km | codigo + year_week, data = panel,
                                 vcov = vcov_conley(lat = "latitud", lon = "longitud", cutoff = 5))
  modelo_entrada_conley <- feols(log_precio ~ post | codigo + fecha, data = panel_entradas_geo,
                                 vcov = vcov_conley(lat = "lat", lon = "lon", cutoff = 5))
  modelo_salida_conley  <- feols(log_precio ~ post | codigo + fecha, data = panel_salidas_geo,
                                 vcov = vcov_conley(lat = "lat", lon = "lon", cutoff = 5))
  print(etable(modelo_1km, modelo_1km_comuna, modelo_1km_conley,
               headers = c("Station", "Comuna", "Conley 5km")))
  print(etable(modelo_entrada, modelo_entrada_comuna, modelo_entrada_conley,
         modelo_salida, modelo_salida_comuna, modelo_salida_conley,
         headers = c("Ent (st)", "Ent (com)", "Ent (Conley)", "Exit (st)", "Exit (com)", "Exit (Conley)")))
}, error = function(e) message("Conley SEs failed: ", e$message))

# =============================================================================
# 10. Export tables and descriptive figures
# =============================================================================
section("10. Export")

ms <- function(models, file, title) modelsummary(models, output = file.path(dir_output, file),
                                                 stars = stars_ms, title = title)
ms(list("1 km" = modelo_1km, "2 km" = modelo_2km, "3 km" = modelo_3km, "5 km" = modelo_5km),
   "tabla1_twfe_radios.docx", "Effect of local competition by radius (TWFE)")
ms(list("Pre 1km" = modelo_pre_1km, "Post 1km" = modelo_post_1km,
        "Pre 2km" = modelo_pre_2km, "Post 2km" = modelo_post_2km),
   "tabla2_pre_post_mepco.docx", "Pre vs post MEPCO")
ms(list("Entry" = modelo_entrada, "Exit" = modelo_salida),
   "tabla3_entrada_salida.docx", "Entry vs exit (DiD)")
if (length(modelos_het) > 0) ms(modelos_het, "tabla4_heterogeneidad.docx", "Heterogeneity by concentration")
ms(list("Baseline" = modelo_1km, "No brand changes" = modelo_1km_limpio,
        "Month FE" = modelo_mensual_1km, "Cluster comuna" = modelo_1km_comuna),
   "tabla5_robustez_twfe.docx", "TWFE robustness")
ms(list("Ent (station)" = modelo_entrada, "Ent (comuna)" = modelo_entrada_comuna,
        "Exit (station)" = modelo_salida, "Exit (comuna)" = modelo_salida_comuna),
   "tabla6_robustez_cluster.docx", "DiD robustness to clustering")

p_dist <- panel %>%
  select(n_comp_1km, n_comp_3km, n_comp_5km) %>%
  pivot_longer(everything(), names_to = "radio", values_to = "n_comp") %>%
  mutate(radio = factor(radio, levels = c("n_comp_1km", "n_comp_3km", "n_comp_5km"),
                        labels = c("1 km", "3 km", "5 km"))) %>%
  ggplot(aes(n_comp)) +
  geom_histogram(bins = 30, fill = "steelblue", alpha = 0.7, color = "white") +
  facet_wrap(~radio, scales = "free_y") +
  labs(title = "Number of competitors by radius", x = "Competitors", y = "Station-weeks") +
  theme_minimal()
save_plot(p_dist, "dist_competidores.png", height = 4)

p_precio <- panel %>%
  group_by(fecha) %>% summarise(precio_mean = mean(precio), .groups = "drop") %>%
  ggplot(aes(fecha, precio_mean)) +
  geom_line(color = "steelblue", linewidth = 0.5) +
  geom_vline(xintercept = MEPCO_DATE, linetype = "dashed", color = "red") +
  annotate("text", x = MEPCO_DATE, y = max(panel$precio) * 0.85, label = "MEPCO",
           color = "red", hjust = -0.1, size = 3) +
  labs(title = "Average retail gasoline price", x = NULL, y = "CLP per litre") +
  theme_minimal()
save_plot(p_precio, "evolucion_precios.png", height = 5)

p_eventos <- bind_rows(
  ev$entradas_cal %>% transmute(anio = year(fecha_entrada), tipo = "Entries"),
  ev$salidas_cal  %>% transmute(anio = year(fecha_salida),  tipo = "Exits")) %>%
  count(anio, tipo) %>%
  ggplot(aes(anio, n, fill = tipo)) +
  geom_col(position = "dodge", alpha = 0.8) +
  labs(title = "Station entries and exits by year", x = NULL, y = "Events", fill = NULL) +
  theme_minimal() + scale_fill_manual(values = c("steelblue", "darkgreen"))
save_plot(p_eventos, "entradas_salidas_anio.png", height = 5)

cat("Main analysis finished.\n")
