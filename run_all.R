# =============================================================================
# run_all.R
# Reproduces the full analysis and compiles the paper.
#
#   source("run_all.R")
#
# Requires the input files described in data/README.md. Console output of
# each step is written to output/logs/.
# =============================================================================

if (!requireNamespace("here", quietly = TRUE)) install.packages("here")
if (file.exists(here::here("renv.lock")) && requireNamespace("renv", quietly = TRUE)) {
  renv::restore(prompt = FALSE)
}

steps <- c(
  "R/00_setup.R",          # 1. packages, paths, helpers
  "R/01_build_panel.R",    # 2. station-week panel from raw CNE data
  "R/02_clean_data.R",     # 3. cleaning and event definitions
  "R/03_main_analysis.R",  # 4. TWFE, baseline entry/exit DiD, heterogeneity
  "R/04_event_study.R",    # 5. event-study dynamics, HonestDiD
  "R/05_robustness.R",     # 6. selection in exits, brand heterogeneity
  "R/06_mechanisms.R"      # 7. variance decomposition, margins, pass-through
)

log_dir <- here::here("output", "logs")
dir.create(log_dir, showWarnings = FALSE, recursive = TRUE)

for (s in steps) {
  message(sprintf("[%s] Running %s", format(Sys.time(), "%H:%M:%S"), s))
  log_file <- file.path(log_dir, sub("\\.R$", ".log", basename(s)))
  con <- file(log_file, open = "wt")
  sink(con, split = TRUE)
  tryCatch(
    source(here::here(s), local = new.env(), echo = FALSE, print.eval = TRUE),
    finally = { sink(); close(con) })
}

# 8. Compile the paper
message("Compiling paper/paper_competencia_espacial.Rmd")
rmarkdown::render(here::here("paper", "paper_competencia_espacial.Rmd"), quiet = TRUE)
message("Done. Paper: paper/paper_competencia_espacial.pdf | Tables and figures: output/ | README figures: figures/")
