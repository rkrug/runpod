#!/usr/bin/env Rscript
# Plot pod_watch.sh's log as a 4-panel time series: pod_mem%, cpu%, rss GB,
# gpu_mem GB.
#
# pod_watch.sh launches this automatically in the background (--watch mode,
# pointed at its own just-created log) — you don't normally invoke it
# directly. Set PLOT_INTERVAL=0 before running pod_watch.sh to disable that
# and drive this manually instead.
#
# Usage:
#   Rscript scripts/runpod/plot_pod_watch.R                       # plot most recent, once
#   Rscript scripts/runpod/plot_pod_watch.R path/to/log.log       # plot a specific file
#   Rscript scripts/runpod/plot_pod_watch.R --watch               # re-render every 30s
#   Rscript scripts/runpod/plot_pod_watch.R --watch --interval 10 # custom interval (s)
#
# PNG written next to the log file with the same basename + .png. Open it
# in macOS Preview (open output/pod_logs/*.png) — Preview reloads the
# image when the file changes on disk, so combined with --watch you get
# a near-live monitoring view.

args <- commandArgs(trailingOnly = TRUE)

# Flag parsing — minimal.
watch <- any(args == "--watch")
ival_idx <- which(args == "--interval")
interval_s <- if (length(ival_idx)) as.numeric(args[ival_idx + 1L]) else 30
# Remaining positional args = log file selector.
positional <- args[!args %in% c("--watch") &
                   !(seq_along(args) %in% c(ival_idx, ival_idx + 1L))]

pick_log <- function() {
  if (length(positional)) return(positional[[1]])
  files <- list.files(
    "output/pod_logs", "^pod_watch_.*\\.log$", full.names = TRUE
  )
  if (!length(files)) stop("No pod_watch_*.log in output/pod_logs/")
  files[which.max(file.mtime(files))]
}

# Convert etime ("MM:SS" or "HH:MM:SS") to minutes.
etime_to_min <- function(s) {
  p <- as.numeric(strsplit(s, ":")[[1]])
  if (length(p) == 2L) p[1] + p[2] / 60
  else if (length(p) == 3L) p[1] * 60 + p[2] + p[3] / 60
  else NA_real_
}

render <- function(log_file) {
  text <- readLines(log_file, warn = FALSE)

  ps_rx <- "etime=([0-9:]+).*cpu=\\s*([0-9.]+)%.*pod_mem=\\s*([0-9.]+)%.*rss=\\s*([0-9.]+)GB"
  m <- regmatches(text, regexec(ps_rx, text))
  ps_idx <- which(lengths(m) == 5L)
  if (!length(ps_idx)) {
    cat("(no ps lines yet in", basename(log_file), ")\n")
    return(invisible(NULL))
  }

  gpu_rx <- "([0-9]+)\\s*%,\\s*([0-9]+)\\s*MiB"
  g <- regmatches(text[ps_idx + 1L], regexec(gpu_rx, text[ps_idx + 1L]))

  df <- data.frame(
    min     = vapply(vapply(m[ps_idx], `[`, character(1), 2), etime_to_min, numeric(1)),
    cpu     = as.numeric(vapply(m[ps_idx], `[`, character(1), 3)),
    pod_mem = as.numeric(vapply(m[ps_idx], `[`, character(1), 4)),
    rss     = as.numeric(vapply(m[ps_idx], `[`, character(1), 5)),
    gpu     = as.numeric(vapply(g, function(x) if (length(x) == 3L) x[2] else NA_character_,
                                character(1))),
    gpu_gib = as.numeric(vapply(g, function(x) if (length(x) == 3L) x[3] else NA_character_,
                                character(1))) / 1024
  )

  out_png <- sub("\\.log$", ".png", log_file)
  # Atomic write: render to .tmp.png then rename. Prevents Preview/Positron
  # from reading a half-written file.
  tmp_png <- paste0(out_png, ".tmp.png")
  png(tmp_png, width = 1400, height = 900, res = 110)
  op <- par(mfrow = c(2, 2), mar = c(4, 4, 2, 1), oma = c(0, 0, 2, 0))

  plot(df$min, df$pod_mem, type = "l", lwd = 2, col = "steelblue",
       xlab = "elapsed (min)", ylab = "pod_mem (%)", ylim = c(0, 100),
       main = "Pod memory")
  abline(h = 90, lty = 2, col = "red")
  text(par("usr")[2], 92, "90% danger ", col = "red", cex = 0.8, adj = c(1, 0))

  plot(df$min, df$cpu, type = "l", lwd = 2, col = "darkgreen",
       xlab = "elapsed (min)", ylab = "cpu (%)",
       main = "CPU")

  plot(df$min, df$rss, type = "l", lwd = 2, col = "purple",
       xlab = "elapsed (min)", ylab = "rss (GB)",
       main = "Resident set size")

  plot(df$min, df$gpu_gib, type = "l", lwd = 2, col = "darkorange",
       xlab = "elapsed (min)", ylab = "gpu_mem (GB)",
       main = "GPU memory")

  mtext(basename(log_file), outer = TRUE, line = 0.5, cex = 1.1)

  par(op)
  invisible(dev.off())
  file.rename(tmp_png, out_png)

  cat(sprintf("[%s] %d points → %s\n",
              format(Sys.time(), "%H:%M:%S"), nrow(df), out_png))
}

if (watch) {
  cat(sprintf("watching every %s s (Ctrl-C to exit)\n", interval_s))
  while (TRUE) {
    log_file <- pick_log()
    render(log_file)
    Sys.sleep(interval_s)
  }
} else {
  log_file <- pick_log()
  cat("reading:", log_file, "\n")
  render(log_file)
}
