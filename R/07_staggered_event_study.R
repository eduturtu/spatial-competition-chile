# =============================================================================
# 07_staggered_event_study.R
# Event studies robust to staggered timing (Sun and Abraham 2021).
#
# The TWFE event studies in 03-04 use only incumbents that are eventually
# treated, so stations already treated serve as controls for stations treated
# later. When effects grow over time this biases both the post-event estimates
# and the pre-event coefficients (Goodman-Bacon 2021; Sun and Abraham 2021).
# Here the control group is never-treated incumbents: stations with no event of
# the same type within NEVER_RADIUS_KM during the whole sample, and the
# estimator interacts cohort (quarter of the event) with relative quarter.
#
# Two specifications for entry and for exit:
#   base: station and week fixed effects
#   fe:   + region x year and brand x year fixed effects (regional shocks and
#         chain-level pricing decisions)
# Each is followed by Rambachan-Roth (HonestDiD) sensitivity analysis.
# Paper: Section "Tratamiento escalonado"; README figure sa_event_study.png.
# =============================================================================

source(here::here("R", "00_setup.R"))

NEVER_RADIUS_KM <- 5      # never-treated: no event of the same type within 5 km
WINDOW_WEEKS    <- 52     # treated observations within +-52 weeks of their event
PERIOD_WEEKS    <- 13     # relative time in quarters
REL_KEEP        <- -4:3   # relative quarters reported (ref = -1)

panel <- load_clean()
ev    <- load_events()

# ---- Sample: treated incumbents + never-treated incumbents -------------------
build_sample <- function(events_all, events_near) {
  geo <- events_all %>% left_join(ev$ubicaciones %>% select(codigo, lat, lon), by = "codigo")
  near5 <- ev$incumbentes %>%
    transmute(ci = codigo, la = lat, lo = lon) %>%
    crossing(geo %>% transmute(le = lat, oe = lon)) %>%
    mutate(d = haversine(la, lo, le, oe)) %>%
    filter(d > 0, d <= NEVER_RADIUS_KM) %>%
    distinct(ci) %>% pull(ci)
  nunca <- setdiff(ev$incumbentes$codigo, near5)
  trat  <- events_near %>% select(codigo, sem_evento)

  p <- panel %>%
    filter(codigo %in% c(trat$codigo, nunca)) %>%
    left_join(trat, by = "codigo") %>%
    mutate(t = semana_ord - sem_evento) %>%
    filter(is.na(sem_evento) | abs(t) <= WINDOW_WEEKS) %>%
    mutate(rel = ifelse(is.na(t), NA_integer_, as.integer(floor(t / PERIOD_WEEKS))),
           coh = ifelse(is.na(sem_evento), 10000L, as.integer(sem_evento %/% PERIOD_WEEKS)),
           q   = ifelse(is.na(sem_evento), semana_ord %/% PERIOD_WEEKS, coh + rel),
           region_anio = paste(nom_region, year),
           marca_anio  = paste(distribuidor, year)) %>%
    select(codigo, semana_ord, log_precio, rel, coh, q, region_anio, marca_anio)  # keep memory low
  list(p = p, n_trat = nrow(trat), n_nunca = length(nunca))
}

# ---- Aggregate cohort x relative-period coefficients (Sun-Abraham weights) ----
# Each relative period is the average of the cohort-specific coefficients,
# weighted by the cohort's share of treated observations at that period. The
# vcov is propagated with the same weights, so HonestDiD can use it.
aggregate_sa <- function(m, p) {
  bf <- m$coefficients
  Vf <- vcov(m)
  nmf <- names(bf)
  rel <- as.numeric(sub("^q::(-?[0-9]+):cohort::.*$", "\\1", nmf))
  coh <- sub("^.*:cohort::", "", nmf)
  tr  <- p[p$coh != 10000L, ]
  freq <- as.data.frame(table(rel = tr$rel, coh = tr$coh), stringsAsFactors = FALSE)
  per <- sort(unique(rel))
  per <- per[per %in% REL_KEEP]
  W <- t(sapply(per, function(r) {
    idx <- which(rel == r)
    n <- freq$Freq[match(paste(r, coh[idx]), paste(freq$rel, freq$coh))]
    w <- numeric(length(bf)); w[idx] <- n / sum(n); w
  }))
  b <- as.numeric(W %*% bf)
  V <- W %*% Vf %*% t(W)
  post <- per >= 0
  l <- as.numeric(post) / sum(post)
  list(per = per, b = b, se = sqrt(diag(V)), V = V,
       att = sum(l * b), att_se = sqrt(as.numeric(t(l) %*% V %*% l)))
}

run_design <- function(tipo, events_all, events_near, mbar = seq(0, 2, by = 0.1)) {
  section(paste("Sun-Abraham:", tipo))
  s <- build_sample(events_all, events_near)
  cat(sprintf("Treated incumbents: %d | never-treated incumbents (no %s within %d km): %d | obs: %s\n",
              s$n_trat, tipo, NEVER_RADIUS_KM, s$n_nunca, format(nrow(s$p), big.mark = ",")))
  out <- list(n_trat = s$n_trat, n_nunca = s$n_nunca, n_obs = nrow(s$p))
  gc(verbose = FALSE)
  specs <- list(
    base = log_precio ~ sunab(coh, q, ref.p = -1) | codigo + semana_ord,
    fe   = log_precio ~ sunab(coh, q, ref.p = -1) | codigo + semana_ord + region_anio + marca_anio)
  for (k in names(specs)) {
    m <- feols(specs[[k]], data = s$p, cluster = ~codigo, mem.clean = TRUE)
    a <- aggregate_sa(m, s$p)
    rm(m); gc(verbose = FALSE)
    cat(sprintf("\n[%s] relative quarter: %s\n", k, paste(a$per, collapse = "  ")))
    cat(sprintf("[%s] coef (%%):         %s\n", k, paste(sprintf("%.3f", 100 * a$b), collapse = " ")))
    cat(sprintf("[%s] se   (%%):         %s\n", k, paste(sprintf("%.3f", 100 * a$se), collapse = " ")))
    cat(sprintf("[%s] ATT (avg q0..3):  %.3f%% (se %.3f)\n", k, 100 * a$att, 100 * a$att_se))

    # Rambachan-Roth sensitivity on the aggregated event study
    a$honest <- tryCatch({
      npre <- sum(a$per < 0); npost <- sum(a$per >= 0)
      rs <- HonestDiD::createSensitivityResults_relativeMagnitudes(
        betahat = a$b, sigma = a$V, numPrePeriods = npre, numPostPeriods = npost,
        l_vec = rep(1 / npost, npost), Mbarvec = mbar)
      rs <- as_tibble(rs) %>% mutate(across(c(lb, ub), ~ as.numeric(.x)))
      # Largest Mbar up to which every robust CI excludes zero
      excl <- rs$lb > 0 | rs$ub < 0
      robusto <- if (!excl[1]) NA_real_ else rs$Mbar[max(which(cumprod(excl) == 1))]
      cat(sprintf("[%s] HonestDiD: robust CI excludes zero up to Mbar = %s\n", k,
                  ifelse(is.na(robusto), "none (includes zero at 0)", robusto)))
      list(tabla = rs, robusto = robusto, mbar_max = max(mbar))
    }, error = function(e) {
      message("HonestDiD skipped for ", tipo, "/", k, ": ", conditionMessage(e))
      NULL
    })
    out[[k]] <- a
  }
  out
}

sa <- list()
sa$entrada <- run_design("entry", ev$entradas, ev$ev_entrada)
gc(verbose = FALSE)
# Exit: pre-event coefficients are already non-zero, so a coarse grid suffices
sa$salida <- run_design("exit", ev$salidas, ev$ev_salida, mbar = c(0, 0.5, 1))
rm(panel); gc(verbose = FALSE)
guardar(sa = sa)

# ---- Figure: entry and exit event studies (spec with region/brand x year FE) --
fig <- bind_rows(lapply(c(Entry = "entrada", Exit = "salida"), function(k) {
  a <- sa[[k]]$fe
  tibble(rel = c(a$per, -1), b = c(a$b, 0), se = c(a$se, 0))
}), .id = "evento") %>%
  arrange(evento, rel) %>%
  mutate(lo = 100 * (b - 1.96 * se), hi = 100 * (b + 1.96 * se), b = 100 * b)

p_sa <- ggplot(fig, aes(rel, b, color = evento, fill = evento)) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
  geom_vline(xintercept = -0.5, linetype = "dashed", color = "red", alpha = 0.5) +
  geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.15, color = NA) +
  geom_line(linewidth = 1) + geom_point(size = 2.5) +
  scale_x_continuous(breaks = REL_KEEP) +
  scale_color_manual(values = c(Entry = "steelblue", Exit = "darkgreen")) +
  scale_fill_manual(values = c(Entry = "steelblue", Exit = "darkgreen")) +
  labs(title = "Incumbent price around nearby entry and exit (Sun-Abraham)",
       x = "Quarters relative to the event", y = "Effect on log(price), %",
       color = NULL, fill = NULL,
       caption = paste0("Controls: never-treated incumbents (no event within ", NEVER_RADIUS_KM,
                        " km). Station, week, region x year and brand x year FE. 95% CIs clustered by station.")) +
  theme_minimal() + theme(legend.position = "bottom", panel.grid.minor = element_blank())
save_plot(p_sa, "sa_event_study.png", width = 10, height = 6, readme = TRUE)

cat("Staggered event study finished.\n")
