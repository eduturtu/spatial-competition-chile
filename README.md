# Spatial Competition and Retail Gasoline Prices in Chile

[Read the paper (PDF, in Spanish)](paper/paper_competencia_espacial.pdf)

Does the entry or exit of a nearby gas station change the prices of incumbent stations? I apply the event-study design of Taylor and Muehlegger (2025) to a station-week panel of retail gasoline prices from Chile's National Energy Commission (CNE): about 962,000 observations from 2,032 stations over 743 weeks, 2012–2026.

Methods: two-way fixed effects · event study · spatial competition measures (Haversine, validated against driving distances) · window and block-dynamics diagnostics · Rambachan–Roth (HonestDiD) sensitivity to parallel-trends violations · Conley standard errors

## Main findings

- Exit has a precisely estimated null effect. The exit of a competitor within 1 km leaves incumbent prices unchanged: the 95% confidence interval rules out effects larger than about 0.1% of the retail price. The null survives alternative clustering and a test for selection of exiting stations.
- The apparent entry effect is not robust. A ±52-week DiD gives an entry effect of −0.21%. However, incumbent prices are already falling before entry, the trajectory crosses zero without a break at the event, the effect disappears in narrower windows, and the Rambachan–Roth confidence set includes zero once post-period violations are allowed to be half the size of pre-period ones (M̄ = 0.5).
- Common shocks dominate price variation. Week fixed effects account for 98.4% of the variation in log retail prices, highlighting the importance of common national shocks. This pattern is consistent with the dominant role of common wholesale-cost movements and with pricing mechanisms documented in the Chilean gasoline-market literature (Lemus and Luco 2021; Luco 2019). The decomposition does not by itself identify which common component matters, or tacit coordination.

![Incumbent price around nearby entry](figures/pretrend_bloques.png)

*Incumbent log price around the entry of a station within 1 km, by blocks of relative time (reference: the quarter before entry). The decline starts before entry and continues through it without a break.*

![HonestDiD sensitivity](figures/honestdid_rival.png)

*Rambachan–Roth robust confidence sets for the average post-entry effect (rival-brand entry). The set includes zero from M̄ = 0.5.*

## Reproducing the results

```r
source("run_all.R")
```

This checks dependencies, cleans the data, builds entry and exit events, estimates every model, writes tables and figures to `output/` (README figures to `figures/`) and compiles the paper. Console logs for each step go to `output/logs/`.

Requirements: R ≥ 4.2 and the packages listed in `R/00_setup.R` (`renv::restore()` installs the pinned versions from `renv.lock`). The input data must be placed in `data/` as described in [`data/README.md`](data/README.md).

| Step | Script | Content |
|---|---|---|
| 1 | `R/00_setup.R` | Packages, paths, sample constants, helper functions |
| 2 | `R/01_build_panel.R` | Station-week panel from raw CNE price records |
| 3 | `R/02_clean_data.R` | Price filter, brand changes, entry/exit/incumbent definitions |
| 4 | `R/03_main_analysis.R` | TWFE by radius, pre/post MEPCO, baseline entry/exit DiD, heterogeneity, inference robustness |
| 5 | `R/04_event_study.R` | Window sensitivity, block and weekly event studies, rival-brand entry, HonestDiD |
| 6 | `R/05_robustness.R` | Selection in exits, entrant brand, operator proxy, co-movement |
| 7 | `R/06_mechanisms.R` | Variance decomposition, effects relative to margins, pass-through |

## Repository structure

```
.
├── README.md
├── run_all.R
├── renv.lock
├── R/              analysis scripts (run in order by run_all.R)
├── data/           input data (not versioned; see data/README.md)
├── figures/        main figures shown in this README (versioned)
├── output/         all generated tables, figures and logs (not versioned)
└── paper/          paper (R Markdown + PDF) and bibliography
```

## Data

All inputs are public, from the CNE's *Bencina en Línea* / *Energía Abierta* portal (https://www.energiaabierta.cl). They are not versioned because of their size. The driving-distance sample used to validate Haversine distances comes from the Google Maps API and is optional; the analysis runs without it.

## References

Taylor and Muehlegger (2025, NBER WP 33569) · Lemus and Luco (2021, JIE) · Rambachan and Roth (2023, ReStud) · Hastings (2004, AER) · Houde (2012, AER) · Barron, Taylor and Umbeck (2004, IJIO) · Lewis (2012, IJIO) · Luco (2019, AEJ: Micro)

## Author

Eduardo Munizaga, Facultad de Economía y Negocios, Universidad de Chile. Originally written as a research paper for Microeconomics III.
