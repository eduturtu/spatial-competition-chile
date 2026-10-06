# =============================================================================
# 04_event_study.R
# Dynamics of the entry effect and parallel-trends diagnostics:
#   A. Sensitivity of the entry and exit effects to the event window
#   B. Event study by blocks of relative time (+-52 weeks), with and without
#      comuna-specific linear trends
#   C. Weekly event study (+-26 weeks)
#   D. Rival-brand entry: quarterly event study + Rambachan-Roth (HonestDiD)
#   E. Rival-brand exit DiD
# Paper: Tables 5-7, Section 6.4-7.2, Figures A3-A5.
# =============================================================================

source(here::here("R", "00_setup.R"))
library(HonestDiD)   # also needs spacefillr (loaded internally for robust CIs)

panel <- load_clean()
ev    <- load_events()

pe_ent <- event_panel(panel, ev$ev_entrada, window = 52)
pe_sal <- event_panel(panel, ev$ev_salida,  window = 52)
cat(sprintf("Incumbents exposed to entry: %d | to exit: %d\n",
            n_distinct(pe_ent$codigo), n_distinct(pe_sal$codigo)))

# =============================================================================
# A. Window sensitivity
# =============================================================================
section("A. Window sensitivity")

window_table <- map_dfr(c("Entry" = "ent", "Exit" = "sal"), function(k) {
  d0 <- if (k == "ent") pe_ent else pe_sal
  map_dfr(c(52, 39, 26, 13), function(W) {
    m <- feols(log_precio ~ post | codigo + semana_ord, data = filter(d0, abs(t) <= W), cluster = ~codigo)
    ci <- confint(m)["post", ]
    tibble(window = W, coef_pct = coef(m)["post"] * 100, se_pct = se(m)["post"] * 100,
           ci_low_pct = ci[[1]] * 100, ci_high_pct = ci[[2]] * 100,
           p = pvalue(m)["post"], nobs = nobs(m))
  })
}, .id = "event")
print(window_table, n = Inf)
write_csv(window_table, file.path(dir_output, "sensibilidad_ventana.csv"))

# =============================================================================
# B. Event study by blocks (reference: [-13, -1])
# =============================================================================
section("B. Event study by blocks")

peb <- pe_ent %>%
  mutate(pre_far   = as.integer(t >= -52 & t <= -27),
         pre_mid   = as.integer(t >= -26 & t <= -14),
         post_near = as.integer(t >=   0 & t <=  13),
         post_mid  = as.integer(t >=  14 & t <=  26),
         post_far  = as.integer(t >=  27 & t <=  52))

m_base  <- feols(log_precio ~ pre_far + pre_mid + post_near + post_mid + post_far |
                   codigo + semana_ord, data = peb, cluster = ~codigo)
m_trend <- feols(log_precio ~ pre_far + pre_mid + post_near + post_mid + post_far +
                   i(nom_comuna, semana_ord) | codigo + semana_ord,
                 data = peb, cluster = ~codigo)
etable(m_base, m_trend, headers = c("No trends", "Comuna trends"),
       keep = c("pre_far", "pre_mid", "post_near", "post_mid", "post_far"))

bloques <- tibble(term   = c("pre_far", "pre_mid", "ref", "post_near", "post_mid", "post_far"),
                  centro = c(-39, -20, -7, 6, 20, 39))
cf <- as.data.frame(coeftable(m_base)) %>% rownames_to_column("term")
names(cf)[2:3] <- c("beta", "se")
plotb <- bloques %>%
  left_join(cf %>% select(term, beta, se), by = "term") %>%
  mutate(beta = ifelse(term == "ref", 0, beta),
         se   = ifelse(term == "ref", 0, se),
         lo = (beta - 1.96 * se) * 100, hi = (beta + 1.96 * se) * 100, beta = beta * 100)

p_bloques <- ggplot(plotb, aes(centro, beta)) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
  geom_vline(xintercept = -0.5, linetype = "dashed", color = "red", alpha = .5) +
  geom_ribbon(aes(ymin = lo, ymax = hi), alpha = .15, fill = "steelblue") +
  geom_line(color = "steelblue", linewidth = 1) +
  geom_point(size = 3, color = "steelblue") +
  labs(title = "Incumbent price around nearby entry, by blocks of relative time",
       x = "Weeks relative to entry (block midpoint)",
       y = "Effect on log(price), % (ref = [-13, -1])",
       caption = "Station and week fixed effects. 95% CIs clustered by station.") +
  theme_minimal()
save_plot(p_bloques, "pretrend_bloques.png", width = 9, height = 5.5, readme = TRUE)

# =============================================================================
# C. Weekly event study (+-26)
# =============================================================================
section("C. Weekly event study")

m_dyn <- feols(log_precio ~ i(t, ref = -1) | codigo + semana_ord,
               data = filter(pe_ent, abs(t) <= 26), cluster = ~codigo)
save_base_plot({
  iplot(m_dyn, main = "Weekly event study: nearby entry (ref = -1)",
        xlab = "Weeks relative to entry", ylab = "Effect on log(price)")
  abline(v = -0.5, col = "red", lty = 2)
}, "pretrend_semanal.png")

# =============================================================================
# D. Rival-brand entry: quarterly event study + HonestDiD
# The weekly specification is too sparse to estimate precisely, so relative
# time is aggregated to quarters (13 weeks).
# =============================================================================
section("D. Rival-brand entry and HonestDiD")

pe_rival <- panel %>%
  inner_join(ev$ev_entrada_rival, by = "codigo") %>%
  mutate(t = as.integer(semana_ord - sem_evento)) %>%
  filter(t >= -52, t <= 51) %>%
  mutate(rel_q = floor(t / 13))          # -4..-1 pre, 0..3 post; ref = -1
cat(sprintf("Incumbents with rival-brand entry within 1 km: %d\n", nrow(ev$ev_entrada_rival)))

es <- feols(log_precio ~ i(rel_q, ref = -1) | codigo + semana_ord, data = pe_rival, cluster = ~codigo)
print(coeftable(es))

save_base_plot({
  iplot(es, main = "Rival-brand entry: quarterly event study",
        xlab = "Quarters relative to entry", ylab = "Effect on log(price)")
  abline(v = -0.5, col = "red", lty = 2)
}, "es_rival_trimestral.png")

cn  <- names(coef(es))
per <- as.numeric(gsub("rel_q::", "", cn))
ord <- order(per)
b   <- coef(es)[ord]
V   <- vcov(es)[ord, ord]
per <- per[ord]
numPre  <- sum(per < 0)
numPost <- sum(per >= 0)
l_vec   <- rep(1 / numPost, numPost)     # average post-period effect

orig <- constructOriginalCS(betahat = b, sigma = V, numPrePeriods = numPre,
                            numPostPeriods = numPost, l_vec = l_vec)
rm_sens <- createSensitivityResults_relativeMagnitudes(
  betahat = b, sigma = V, numPrePeriods = numPre, numPostPeriods = numPost,
  l_vec = l_vec, Mbarvec = seq(0, 1.5, by = 0.5))
print(orig)
print(rm_sens)
write_csv(bind_rows(mutate(as_tibble(orig), Mbar = 0, method = "Original"),
                    as_tibble(rm_sens)), file.path(dir_output, "honestdid_rival.csv"))

p_honest <- createSensitivityPlot_relativeMagnitudes(rm_sens, orig)
save_plot(p_honest, "honestdid_rival.png", readme = TRUE)

# =============================================================================
# E. Rival-brand exit DiD
# =============================================================================
section("E. Rival-brand exit")

pe_sal_rival <- event_panel(panel, ev$ev_salida_rival, window = 52)
m_sal_rival  <- feols(log_precio ~ post | codigo + semana_ord, data = pe_sal_rival, cluster = ~codigo)
etable(m_sal_rival, headers = "Rival-brand exit")

cat("Event study finished.\n")
