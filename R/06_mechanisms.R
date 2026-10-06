# =============================================================================
# 06_mechanisms.R
# Why local entry and exit do not move incumbent prices.
#   A. Variance decomposition of log prices (common time component vs rest)
#   B. Alternative decompositions that remove the long-run price level
#   C. Between vs within: competition and price levels vs within-station effect
#   D. Effect sizes relative to the retail margin
#   E. Cost pass-through (descriptive time-series context only)
# Paper: Section 8.
# =============================================================================

source(here::here("R", "00_setup.R"))
library(readxl)

panel <- load_clean()

# =============================================================================
# A. Share of total variance explained by week fixed effects
# =============================================================================
section("A. Variance decomposition")

gm  <- mean(panel$log_precio)
SST <- sum((panel$log_precio - gm)^2)

panel <- panel %>%
  group_by(semana_ord) %>% mutate(media_semana   = mean(log_precio)) %>%
  group_by(codigo)     %>% mutate(media_estacion = mean(log_precio)) %>%
  group_by(year)       %>% mutate(media_anio     = mean(log_precio)) %>%
  ungroup()

R2_semana   <- 1 - sum((panel$log_precio - panel$media_semana)^2)   / SST
R2_estacion <- 1 - sum((panel$log_precio - panel$media_estacion)^2) / SST
cat(sprintf("R2, week FE only:    %.4f\n", R2_semana))
cat(sprintf("R2, station FE only: %.4f\n", R2_estacion))

# =============================================================================
# B. Removing the long-run level
# Over 2012-2026 most of the variance in nominal log prices is the secular
# level (oil cycles, inflation, taxes). These statistics describe the
# variation that is relevant at the horizon of an entry/exit event.
# =============================================================================
section("B. Decompositions net of the long-run level")

# (1) Within-year variance explained by week FE
SST_anio <- sum((panel$log_precio - panel$media_anio)^2)
R2_semana_intra_anio <- 1 - sum((panel$log_precio - panel$media_semana)^2) / SST_anio

# (2) Share of the residual (net of week FE) explained by station levels
panel <- panel %>%
  mutate(res_sin_tiempo = log_precio - media_semana) %>%
  group_by(codigo) %>% mutate(media_res_estacion = mean(res_sin_tiempo)) %>% ungroup()
R2_estacion_en_residuo <- 1 - sum((panel$res_sin_tiempo - panel$media_res_estacion)^2) /
                              sum(panel$res_sin_tiempo^2)

# (3) Cross-sectional dispersion within a week vs. time-series dispersion of the weekly mean
disp <- panel %>%
  group_by(semana_ord) %>%
  summarise(sd_cs = sd(log_precio), media = first(media_semana), .groups = "drop")
sd_cross_section <- mean(disp$sd_cs, na.rm = TRUE)
sd_weekly_change <- sd(diff(disp$media), na.rm = TRUE)

varianza <- tibble(
  statistic = c("R2 week FE (total variance)",
                "R2 station FE (total variance)",
                "R2 week FE (within-year variance)",
                "R2 station FE (residual net of week FE)",
                "Mean within-week cross-sectional SD of log price",
                "SD of week-to-week change in mean log price"),
  value = c(R2_semana, R2_estacion, R2_semana_intra_anio, R2_estacion_en_residuo,
            sd_cross_section, sd_weekly_change))
print(varianza)
write_csv(varianza, file.path(dir_output, "mecanismo_varianza.csv"))

# =============================================================================
# C. Between vs within
# =============================================================================
section("C. Between vs within")

cat(sprintf("Corr(price net of week FE, n_comp_1km) = %+.4f  (levels / cross-section)\n",
            cor(panel$res_sin_tiempo, panel$n_comp_1km)))
m_within <- feols(log_precio ~ n_comp_1km | codigo + semana_ord, data = panel, cluster = ~codigo)
cat(sprintf("Within-station TWFE effect of n_comp_1km: %+.5f (within R2 = %.5f)\n",
            coef(m_within)["n_comp_1km"], r2(m_within, "wr2")))

# =============================================================================
# D/E. Margin and pass-through from the Metropolitan Region weekly series
# =============================================================================
if (!file.exists(path_margins)) {
  cat("\ndata/sh_precios_margenes_semanales_rm.xlsx not found; skipping D and E.\n")
} else {
  # Values come as a single ';'-separated text column; sub-peso decimals are
  # stored in another column and ignored (they do not affect changes).
  raw <- read_excel(path_margins, sheet = "in", col_names = FALSE)
  mg <- tibble(s = as.character(raw[[1]])) %>%
    separate(s, c("fecha", "item", "tipo", "entero"), sep = ";", extra = "merge", fill = "right") %>%
    mutate(fecha = dmy(fecha), val = as.numeric(entero)) %>%
    filter(!is.na(fecha), !is.na(val))

  costo  <- mg %>% filter(str_detect(item, "Paridad"), tipo == "Gasolina")    %>% transmute(fecha, costo = val)
  retail <- mg %>% filter(str_detect(item, "Venta"),   tipo == "Gasolina 93") %>% transmute(fecha, retail = val)
  margen <- mg %>% filter(str_detect(item, regex("margen", ignore_case = TRUE)),
                          str_detect(tipo, "93")) %>% transmute(fecha, margen = val)

  # ---- D. Effects relative to the gross retail margin ------------------------
  section("D. Effects relative to the retail margin")
  path_ef <- file.path(dir_output, "efectos_principales.csv")
  if (nrow(margen) > 0 && file.exists(path_ef)) {
    margin_share <- retail %>% inner_join(margen, by = "fecha") %>%
      filter(year(fecha) >= 2012) %>%
      summarise(s = mean(margen / retail, na.rm = TRUE)) %>% pull(s)
    cat(sprintf("Mean gross margin as a share of the retail price (RM, 2012+): %.3f\n", margin_share))
    efectos <- read_csv(path_ef, show_col_types = FALSE) %>%
      mutate(across(c(coef_pct, ci_low_pct, ci_high_pct), ~ .x / margin_share,
                    .names = "{.col}_of_margin"))
    print(efectos)
    write_csv(efectos, file.path(dir_output, "efectos_relativos_margen.csv"))
  } else {
    cat("Margin series or main effects not found. Items available in the file:\n")
    print(distinct(mg, item, tipo), n = 50)
  }

  # ---- E. Pass-through (descriptive; time-series, not part of identification) -
  section("E. Cost pass-through (descriptive)")
  serie <- retail %>% inner_join(costo, by = "fecha") %>%
    distinct(fecha, .keep_all = TRUE) %>% arrange(fecha) %>%
    mutate(dlret  = log(retail) - log(lag(retail)),
           dlcost = log(costo)  - log(lag(costo))) %>%
    filter(!is.na(dlret), abs(dlcost) < 0.5) %>%      # drops parsing jumps
    mutate(up = pmax(dlcost, 0), dn = pmin(dlcost, 0))
  cat(sprintf("Weekly series %d-%d, n = %d\n", year(min(serie$fecha)), year(max(serie$fecha)), nrow(serie)))

  m_pt <- lm(dlret ~ dlcost, data = serie)
  m_as <- lm(dlret ~ up + dn, data = serie)
  cat(sprintf("Contemporaneous pass-through: %.3f\n", coef(m_pt)["dlcost"]))
  cat(sprintf("Asymmetry: cost up = %.3f | cost down = %.3f | diff = %+.3f\n",
              coef(m_as)["up"], coef(m_as)["dn"], coef(m_as)["up"] - coef(m_as)["dn"]))
}

cat("Mechanisms finished.\n")
