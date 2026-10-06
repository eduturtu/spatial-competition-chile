# =============================================================================
# 05_robustness.R
#   A. Selection in exits: do exiting stations fade out before they exit?
#   B. Heterogeneity by the entrant's brand (major vs independent)
#   C. Multi-station operator proxy (from razon_social; exploratory)
#   D. Weekly co-movement within comuna (descriptive; NOT a leadership measure)
# Paper: Section 7.3.
# =============================================================================

source(here::here("R", "00_setup.R"))

panel <- load_clean()
ev    <- load_events()
vida  <- ev$vida

pe_entrada <- event_panel(panel, ev$ev_entrada, window = 52)
pe_salida  <- event_panel(panel, ev$ev_salida,  window = 52)

# =============================================================================
# A. Selection in exits
# =============================================================================
section("A. Selection in exits")

# (a) Cross-section: do exiting stations report less often over their life?
#     (nobs and span are mechanically shorter for exiters, so use the share of
#     missing weeks instead.)
comparables <- vida %>%
  filter(nobs >= MIN_OBS_EV, !(codigo %in% ev$cambios_marca)) %>%
  mutate(sale = codigo %in% ev$salidas$codigo)
comparables %>% group_by(sale) %>%
  summarise(n = n(), mean = mean(share_faltante), median = median(share_faltante), .groups = "drop") %>%
  print()
cat(sprintf("t-test p-value (share of missing weeks, exiters vs others): %.4f\n",
            t.test(share_faltante ~ sale, data = comparables)$p.value))

# (b) Pre-exit fade-out, net of the end-of-sample coverage drop: reporting
#     rate of the exiter in its last 26 weeks vs. contemporaneous coverage of
#     all active stations in the same calendar weeks.
cobertura <- vida %>%
  transmute(codigo, semana_ord = map2(prim, ult, seq)) %>%
  unnest(semana_ord) %>%
  left_join(panel %>% transmute(codigo, semana_ord, reporto = 1L), by = c("codigo", "semana_ord")) %>%
  mutate(reporto = coalesce(reporto, 0L)) %>%
  group_by(semana_ord) %>% summarise(cob = mean(reporto), .groups = "drop")

obs_set <- panel %>% group_by(codigo) %>%
  summarise(prim = min(semana_ord), ult = max(semana_ord),
            semanas = list(sort(unique(semana_ord))), .groups = "drop")

det <- obs_set %>%
  filter(codigo %in% ev$salidas$codigo, ult - prim + 1 >= 52) %>%
  mutate(rel_exit = pmap_dbl(list(semanas, ult), function(s, u) mean(((u - 25):u) %in% s)))

rel_cont <- det %>% transmute(codigo, ult) %>%
  mutate(semana_ord = map(ult, ~ (.x - 25):.x)) %>% unnest(semana_ord) %>%
  left_join(cobertura, by = "semana_ord") %>%
  group_by(codigo) %>% summarise(rel_cont = mean(cob), .groups = "drop")
det <- det %>% left_join(rel_cont, by = "codigo")

cat(sprintf("Exiters with >= 52 weeks of life: %d\n", nrow(det)))
cat(sprintf("Reporting rate, exiter's last 26 weeks: %.3f | contemporaneous: %.3f | diff: %+.3f\n",
            mean(det$rel_exit), mean(det$rel_cont), mean(det$rel_exit - det$rel_cont)))
cat(sprintf("Paired t-test p-value: %.4f | share reporting below contemporaries: %.1f%%\n",
            t.test(det$rel_exit, det$rel_cont, paired = TRUE)$p.value,
            100 * mean(det$rel_exit < det$rel_cont)))

# (c) Does the exit null survive among "clean" exits (no fade-out)?
salidas_limpias <- det %>% filter(rel_exit >= rel_cont) %>% pull(codigo)
cat(sprintf("Clean exits: %d of %d\n", length(salidas_limpias), nrow(det)))

m_sal_todas   <- feols(log_precio ~ post | codigo + semana_ord, data = pe_salida, cluster = ~codigo)
m_sal_limpias <- feols(log_precio ~ post | codigo + semana_ord,
                       data = filter(pe_salida, codigo_evento %in% salidas_limpias), cluster = ~codigo)
etable(m_sal_todas, m_sal_limpias, headers = c("All exits", "Clean exits"))

# =============================================================================
# B. Entrant / exiter brand
# =============================================================================
section("B. Heterogeneity by brand of the entrant/exiter")

marcas_mayores <- c("COPEC", "SHELL", "PETROBRAS", "ARAMCO")
clasifica_marca <- function(x) ifelse(toupper(x) %in% marcas_mayores, "Major", "Independent")

pe_entrada <- pe_entrada %>% mutate(tipo_entrante = clasifica_marca(marca_evento))
pe_salida  <- pe_salida  %>% mutate(tipo_saliente = clasifica_marca(marca_evento))
pe_entrada %>% distinct(codigo, tipo_entrante) %>% count(tipo_entrante) %>% print()

m_ent_major <- feols(log_precio ~ post | codigo + semana_ord, data = filter(pe_entrada, tipo_entrante == "Major"),       cluster = ~codigo)
m_ent_indep <- feols(log_precio ~ post | codigo + semana_ord, data = filter(pe_entrada, tipo_entrante == "Independent"), cluster = ~codigo)
m_sal_major <- feols(log_precio ~ post | codigo + semana_ord, data = filter(pe_salida,  tipo_saliente == "Major"),       cluster = ~codigo)
m_sal_indep <- feols(log_precio ~ post | codigo + semana_ord, data = filter(pe_salida,  tipo_saliente == "Independent"), cluster = ~codigo)
etable(m_ent_major, m_ent_indep, m_sal_major, m_sal_indep,
       headers = c("Entry: major", "Entry: indep.", "Exit: major", "Exit: indep."))

# =============================================================================
# C. Multi-station operator proxy (razon_social has inconsistent spellings;
#    exploratory only)
# =============================================================================
section("C. Operator proxy")

limpia_rs <- function(x) {
  x <- toupper(x); x <- gsub("[[:punct:]]", " ", x)
  x <- gsub("\\b(LTDA|LIMITADA|S A|SA|SPA|EIRL|E I R L|RED|CIA)\\b", "", x)
  gsub("\\s+", " ", trimws(x))
}
operadores <- ev$ubicaciones %>%
  mutate(operador = limpia_rs(razon_social)) %>%
  filter(!is.na(operador), operador != "", operador != "--") %>%
  add_count(operador, name = "n_estaciones_operador")
operadores %>% count(operador, sort = TRUE) %>% head(12) %>% print()

# =============================================================================
# D. Weekly co-movement within comuna (leave-one-out). The Lemus & Luco (2021)
#    leadership measure needs intra-week price-change timing, which a
#    station-week panel does not have; this is only a descriptive proxy.
# =============================================================================
section("D. Within-comuna co-movement")

sincronia <- panel %>%
  arrange(codigo, semana_ord) %>%
  group_by(codigo) %>% mutate(dprecio = log_precio - lag(log_precio)) %>% ungroup() %>%
  filter(!is.na(dprecio)) %>%
  group_by(nom_comuna, semana_ord) %>%
  mutate(d_mercado = (sum(dprecio) - dprecio) / pmax(n() - 1, 1)) %>%
  ungroup() %>%
  group_by(codigo) %>% filter(n() >= 30) %>%
  summarise(sincronia = cor(dprecio, d_mercado), .groups = "drop")
print(summary(sincronia$sincronia))

cat("Robustness finished.\n")
