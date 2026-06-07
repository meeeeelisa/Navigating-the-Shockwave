# Visualization Big Data G7.R

library(readr)
library(dplyr)
library(tidyr)
library(tibble)
library(stringr)
library(lubridate)
library(ggplot2)

## ---- Load Data ----

data_path <- "data"

# 圖表輸出改為 PDF
pdf_path <- file.path(dirname(data_path), "visualization_big_data_g7_plots.pdf")
pdf(pdf_path, width = 11, height = 7)

all_inport_df <- read_csv(file.path(data_path, "cleaned_all_inport.csv"))
print(head(all_inport_df))
str(all_inport_df)

# 注意：CSV 中以字面字串 "None" 表示缺值（pandas read_csv 預設會將其視為 NaN，
# 但 readr::read_csv 不會），這裡明確將其視為 NA，以符合原始 Python 中
# event_name.isna() / dropna(subset=['event_name']) 的行為
final_port_month_df <- read_csv(
  file.path(data_path, "final_port_month.csv"),
  na = c("", "NA", "None", "NULL", "null", "NaN", "nan", "N/A", "n/a")
)
print(head(final_port_month_df))
str(final_port_month_df)

## ---- Vessel Type Composition Per Port ----
## 分析每個港口的船型組成分佈

port_vessel_composition <- all_inport_df %>%
  count(port, vessel_type_group) %>%
  pivot_wider(names_from = vessel_type_group, values_from = n, values_fill = 0)

comp_mat <- as.matrix(port_vessel_composition %>% select(-port))
rownames(comp_mat) <- port_vessel_composition$port

# 計算每個港口的百分比
port_vessel_percentage <- comp_mat / rowSums(comp_mat) * 100
print(round(port_vessel_percentage, 2))

port_map_en <- c(
  '基隆港' = 'Keelung',
  '臺北港' = 'Taipei',
  '花蓮港' = 'Hualien',
  '高雄港' = 'Kaohsiung'
)

port_vessel_percentage_plot <- as.data.frame(port_vessel_percentage) %>%
  rownames_to_column("port") %>%
  mutate(port_en = port_map_en[port]) %>%
  pivot_longer(-c(port, port_en), names_to = "vessel_type_group", values_to = "percentage")

# 堆疊長條圖
print(
  ggplot(port_vessel_percentage_plot, aes(x = port_en, y = percentage, fill = vessel_type_group)) +
    geom_col() +
    scale_fill_viridis_d() +
    labs(
      title = 'Vessel Type Composition by Port (Percentage)',
      x = 'Port', y = 'Percentage (%)', fill = 'Vessel Type Group'
    ) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1))
)

## ---- Overall Port Sensitivity to Oil Shocks ----
## 分析每個港口在油價衝擊期間，平均每月到港量的整體變化

port_overall_shock_stats <- final_port_month_df %>%
  group_by(port, oil_shock) %>%
  summarise(mean_arrivals = mean(arrivals, na.rm = TRUE), .groups = "drop") %>%
  pivot_wider(names_from = oil_shock, values_from = mean_arrivals, names_prefix = "shock_") %>%
  mutate(pct_change = (shock_1 - shock_0) / shock_0 * 100)

cat("Overall Port Sensitivity to Oil Shocks (Percentage Change in Average Monthly Arrivals):\n")
print(port_overall_shock_stats)

## ---- Sensitivity Analysis: Impact of Oil Shocks by Port and Vessel Type ----

# 1. 從 all_inport_df 準備每月各港口、各船型的到港數量
vessel_type_monthly <- all_inport_df %>%
  count(port, year_month, vessel_type_group, name = "arrival_count") %>%
  mutate(year_month = as.character(year_month))

# 2. 合併 final_port_month_df 中的油價衝擊指標
final_port_month_df <- final_port_month_df %>% mutate(year_month = as.character(year_month))
shock_info <- final_port_month_df %>%
  select(port, year_month, oil_shock) %>%
  distinct()

merged_vessel_type_shock_df <- vessel_type_monthly %>%
  left_join(shock_info, by = c("port", "year_month")) %>%
  mutate(oil_shock = ifelse(is.na(oil_shock), 0, oil_shock))  # 缺值視為無衝擊

# 3. 計算每個港口、每種船型在衝擊 vs 非衝擊期間的平均到港量
port_vessel_type_shock_stats <- merged_vessel_type_shock_df %>%
  group_by(port, vessel_type_group, oil_shock) %>%
  summarise(mean_count = mean(arrival_count, na.rm = TRUE), .groups = "drop") %>%
  pivot_wider(names_from = oil_shock, values_from = mean_count, names_prefix = "shock_") %>%
  mutate(pct_change = (shock_1 - shock_0) / shock_0 * 100)

# 4. 整理顯示與繪圖用資料
port_vessel_type_results <- port_vessel_type_shock_stats %>%
  mutate(port_en = port_map_en[port])

print(port_vessel_type_results %>% select(port_en, vessel_type_group, pct_change))

# 5. 視覺化
print(
  ggplot(port_vessel_type_results, aes(x = port_en, y = pct_change, fill = vessel_type_group)) +
    geom_col(position = "dodge") +
    geom_hline(yintercept = 0, color = "black") +
    labs(
      title = 'Percentage Change in Arrivals During Oil Shocks by Port and Vessel Type',
      x = 'Port', y = 'Change in Arrivals (%)', fill = 'Vessel Type Group'
    ) +
    theme(panel.grid.major.y = element_line(linetype = "dashed"))
)

## ---- 共用函式：標記 Shock / Recovery 區間（與每月到港量趨勢圖共用）----

# 依時間序列標記 Shock / Recovery / Normal 區間（3 個月復原窗口）
label_regimes <- function(df, n_recovery = 3) {
  df <- df %>% arrange(date)
  df$regime <- "Normal"
  df$regime[df$oil_shock == 1] <- "Shock"

  shock_mask <- df$oil_shock == 1
  prev_shock <- c(FALSE, head(shock_mask, -1))
  starts <- which(shock_mask & !prev_shock)

  for (start_idx in starts) {
    end_idx <- start_idx
    while (end_idx + 1 <= nrow(df) && isTRUE(df$oil_shock[end_idx + 1] == 1)) {
      end_idx <- end_idx + 1
    }
    for (k in seq_len(n_recovery)) {
      pos <- end_idx + k
      if (pos > nrow(df)) break
      if (df$regime[pos] == "Normal") {
        df$regime[pos] <- "Recovery"
      }
    }
  }
  df
}

# 找出連續 regime 區段的日期範圍，供 geom_rect 繪製陰影使用
get_regime_ranges <- function(df, regime_name) {
  mask <- df$regime == regime_name
  if (!any(mask)) return(tibble(xmin = as.Date(character()), xmax = as.Date(character())))
  rl <- rle(mask)
  ends <- cumsum(rl$lengths)
  starts <- ends - rl$lengths + 1
  tibble(start = starts, end = ends, value = rl$values) %>%
    filter(value) %>%
    transmute(xmin = df$date[start], xmax = df$date[end])
}

# 畫出帶有 Shock(紅) / Recovery(綠) 陰影區間的時間序列折線圖
plot_with_regimes <- function(sub, y_col, title, ylab, line_color = "#008080") {
  shock_ranges <- get_regime_ranges(sub, "Shock")
  recovery_ranges <- get_regime_ranges(sub, "Recovery")

  g <- ggplot(sub, aes(x = date, y = .data[[y_col]]))
  if (nrow(shock_ranges) > 0) {
    g <- g + geom_rect(data = shock_ranges, aes(xmin = xmin, xmax = xmax), ymin = -Inf, ymax = Inf,
                       fill = "red", alpha = 0.15, inherit.aes = FALSE)
  }
  if (nrow(recovery_ranges) > 0) {
    g <- g + geom_rect(data = recovery_ranges, aes(xmin = xmin, xmax = xmax), ymin = -Inf, ymax = Inf,
                       fill = "green", alpha = 0.10, inherit.aes = FALSE)
  }
  g + geom_line(color = line_color, linewidth = 1) +
    labs(title = title, x = "Date", y = ylab) +
    theme_minimal() +
    theme(panel.grid.minor = element_blank())
}

## ---- Arrival Frequency Trends by Vessel Type with Shock/Recovery ----

vt_plot_df <- vessel_type_monthly %>%
  mutate(date = ymd(paste0(year_month, "-01")))

shock_info_subset <- final_port_month_df %>%
  select(port, year_month, oil_shock) %>%
  distinct() %>%
  mutate(date = ymd(paste0(year_month, "-01")))

vt_plot_df <- vt_plot_df %>%
  left_join(shock_info_subset %>% select(port, date, oil_shock), by = c("port", "date")) %>%
  group_by(port, vessel_type_group) %>%
  group_modify(~ label_regimes(.x)) %>%
  ungroup()

for (p in sort(unique(vt_plot_df$port))) {
  port_en <- if (p %in% names(port_map_en)) port_map_en[[p]] else p
  vts <- sort(unique(vt_plot_df$vessel_type_group[vt_plot_df$port == p]))
  for (vt in vts) {
    sub <- vt_plot_df %>% filter(port == p, vessel_type_group == vt) %>% arrange(date)
    if (nrow(sub) == 0 || sum(sub$arrival_count) == 0) next

    print(plot_with_regimes(
      sub, "arrival_count",
      sprintf('%s Arrivals Trends with Shock / Recovery - %s', vt, port_en),
      "Arrival Count", line_color = "#008080"
    ))
  }
}

## ---- Detailed Analysis by Vessel Type: Lagged Effects and Specific Event Impact ----

shock_info <- final_port_month_df %>%
  select(port, year_month, oil_shock, event_name) %>%
  distinct()

# 1. 各船型對滯後油價變動的相關性
vt_lag_df <- merged_vessel_type_shock_df
oil_data <- final_port_month_df %>% select(port, year_month, oil_change) %>% distinct()
vt_lag_df <- vt_lag_df %>%
  left_join(oil_data, by = c("port", "year_month")) %>%
  arrange(port, vessel_type_group, year_month)

for (lag_n in 1:3) {
  vt_lag_df <- vt_lag_df %>%
    group_by(port, vessel_type_group) %>%
    mutate(!!paste0("oil_change_lag_", lag_n) := lag(oil_change, lag_n)) %>%
    ungroup()
}

vt_lagged_corrs <- vt_lag_df %>%
  group_by(vessel_type = vessel_type_group) %>%
  summarise(
    lag_0 = cor(arrival_count, oil_change, use = "complete.obs"),
    lag_1 = cor(arrival_count, oil_change_lag_1, use = "complete.obs"),
    lag_2 = cor(arrival_count, oil_change_lag_2, use = "complete.obs"),
    lag_3 = cor(arrival_count, oil_change_lag_3, use = "complete.obs"),
    .groups = "drop"
  )

cat("Vessel Type Arrivals vs Lagged Oil Changes (Correlations):\n")
print(vt_lagged_corrs)

# 2. 特定事件對各船型的影響
event_vt_df <- merged_vessel_type_shock_df %>%
  left_join(shock_info %>% select(port, year_month, event_name), by = c("port", "year_month"))

event_vt_summary <- event_vt_df %>%
  filter(!is.na(event_name)) %>%
  group_by(event_name, vessel_type_group) %>%
  summarise(avg_event_arrivals = mean(arrival_count, na.rm = TRUE), .groups = "drop")

# 3. 非衝擊期基準值
normal_vt_avg <- event_vt_df %>%
  filter(oil_shock == 0, is.na(event_name)) %>%
  group_by(vessel_type_group) %>%
  summarise(avg_normal_arrivals = mean(arrival_count, na.rm = TRUE), .groups = "drop")

# 4. 比較表
comparison_vt <- event_vt_summary %>%
  left_join(normal_vt_avg, by = "vessel_type_group") %>%
  mutate(pct_change = (avg_event_arrivals - avg_normal_arrivals) / avg_normal_arrivals * 100)

cat("\nPercentage Change: Specific Events vs Normal (By Vessel Type):\n")
print(
  comparison_vt %>%
    select(event_name, vessel_type_group, pct_change) %>%
    pivot_wider(names_from = vessel_type_group, values_from = pct_change) %>%
    mutate(across(-event_name, ~ round(.x, 2)))
)

# 視覺化
print(
  ggplot(comparison_vt, aes(x = event_name, y = pct_change, fill = vessel_type_group)) +
    geom_col(position = "dodge") +
    geom_hline(yintercept = 0, color = "black") +
    labs(
      title = 'Vessel Type Sensitivity: Impact of Specific Events vs Normal Periods',
      x = NULL, y = 'Percentage Change (%)', fill = 'Vessel Type Group'
    ) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1))
)

## ---- Unsupervised Learning Clustering Analysis ----
## Features: vessel_type_group（船舶種類）, gross_tonnage（噸位）, berth_wait_hours（停留時長）

df_clustering <- all_inport_df

median_impute <- function(x) { x[is.na(x)] <- median(x, na.rm = TRUE); x }
mode_impute <- function(x) {
  ux <- x[!is.na(x)]
  mode_val <- names(sort(table(ux), decreasing = TRUE))[1]
  x[is.na(x)] <- mode_val
  x
}

# 數值型管線：以中位數補值後標準化；類別型管線：以眾數補值後 one-hot 編碼
gt_scaled <- as.numeric(scale(median_impute(df_clustering$gross_tonnage)))
bw_scaled <- as.numeric(scale(median_impute(df_clustering$berth_wait_hours)))
vt_imputed <- factor(mode_impute(df_clustering$vessel_type_group))
vt_dummies <- model.matrix(~ vessel_type_group - 1, data.frame(vessel_type_group = vt_imputed))

X_processed <- cbind(gross_tonnage = gt_scaled, berth_wait_hours = bw_scaled, vt_dummies)

cat("Shape of processed data:", dim(X_processed)[1], dim(X_processed)[2], "\n")
print(head(as.data.frame(X_processed)))

set.seed(42)
kmeans_k4 <- kmeans(X_processed, centers = 4, nstart = 10)
df_clustering$cluster <- kmeans_k4$cluster - 1L  # 對齊 Python 從 0 開始的群組編號

cat(sprintf("Number of vessels per cluster (k=4):\n"))
print(table(df_clustering$cluster))

cat("\n--- Cluster Characteristics (k=4) ---\n")
cluster_char <- df_clustering %>%
  group_by(cluster) %>%
  summarise(gross_tonnage = mean(gross_tonnage, na.rm = TRUE),
            berth_wait_hours = mean(berth_wait_hours, na.rm = TRUE),
            .groups = "drop")
print(cluster_char)

for (cluster_id in sort(unique(df_clustering$cluster))) {
  cat(sprintf("\nCluster %d - Top Vessel Types:\n", cluster_id))
  print(
    df_clustering %>%
      filter(cluster == cluster_id) %>%
      count(vessel_type_group) %>%
      mutate(proportion = n / sum(n)) %>%
      arrange(desc(proportion)) %>%
      slice_head(n = 5) %>%
      select(vessel_type_group, proportion)
  )
}

# 動態判定原本 Colab 中的「Cluster 3：極端營運異常群」
# （平均停留時間最長、樣本數通常極少的群組），而不寫死群組編號
outlier_cluster <- cluster_char$cluster[which.max(cluster_char$berth_wait_hours)]
cat(sprintf("\n判定為「極端操作異常群」的 cluster id：%d（後續敏感度分析將排除此群組）\n", outlier_cluster))

## ---- Cluster Structure Analysis Per Port ----

port_map_en <- c(
  '臺北港' = 'Taipei',
  '花蓮港' = 'Hualien',
  '高雄港' = 'Kaohsiung',
  '基隆港' = 'Keelung'
)

port_cluster_dist <- df_clustering %>%
  count(port, cluster) %>%
  pivot_wider(names_from = cluster, values_from = n, values_fill = 0) %>%
  mutate(port_en = port_map_en[port])

cat("Vessel Count per Cluster by Port:\n")
print(port_cluster_dist)

## ---- Oil Shock Sensitivity Analysis ----
## 分析 4 個分群在 oil_shock == 1 的月份，到港量如何變化

cluster_monthly <- df_clustering %>%
  count(port, year_month, cluster, name = "arrival_count")

final_port_month_df <- final_port_month_df %>% mutate(year_month = as.character(year_month))
shock_info <- final_port_month_df %>%
  select(port, year_month, oil_shock, event_name) %>%
  distinct()

merged_shock_df <- cluster_monthly %>%
  left_join(shock_info, by = c("port", "year_month"))

# 排除 Cluster 3（樣本數過少、不具統計代表性）
analysis_df <- merged_shock_df %>% filter(cluster != outlier_cluster)

shock_stats <- analysis_df %>%
  group_by(cluster, oil_shock) %>%
  summarise(mean_count = mean(arrival_count, na.rm = TRUE), .groups = "drop") %>%
  pivot_wider(names_from = oil_shock, values_from = mean_count, names_prefix = "shock_") %>%
  mutate(pct_change = (shock_1 - shock_0) / shock_0 * 100)

cat("Sensitivity Analysis: Arrival Changes during Oil Shocks\n")
print(shock_stats)

## ---- 敏感度分析：分港口與分群之油價衝擊影響 ----

port_shock_stats <- analysis_df %>%
  group_by(port, cluster, oil_shock) %>%
  summarise(mean_count = mean(arrival_count, na.rm = TRUE), .groups = "drop") %>%
  pivot_wider(names_from = oil_shock, values_from = mean_count, names_prefix = "shock_") %>%
  mutate(pct_change = (shock_1 - shock_0) / shock_0 * 100)

port_shock_results <- port_shock_stats %>%
  mutate(port_en = port_map_en[port])

cat("分港口各分群之油價敏感度數據：\n")
print(port_shock_results %>% select(port_en, cluster, pct_change))

print(
  ggplot(port_shock_results, aes(x = port_en, y = pct_change, fill = factor(cluster))) +
    geom_col(position = "dodge") +
    geom_hline(yintercept = 0, color = "black") +
    scale_fill_viridis_d() +
    labs(
      title = 'Percentage Change in Arrivals During Oil Shocks: By Port and Cluster',
      x = 'Port', y = 'Change in Arrivals (%)', fill = 'Cluster ID'
    ) +
    theme(panel.grid.major.y = element_line(linetype = "dashed"))
)

## ---- Lagged Effects of Oil Price Changes (by Cluster) ----
## 計算各分群到港量與滯後 1~3 個月油價變動的相關性

lag_analysis_df <- merged_shock_df %>% arrange(port, cluster, year_month)

oil_data <- final_port_month_df %>% select(port, year_month, oil_change) %>% distinct()
lag_analysis_df <- lag_analysis_df %>% left_join(oil_data, by = c("port", "year_month"))

for (lag_n in 1:3) {
  lag_analysis_df <- lag_analysis_df %>%
    group_by(port, cluster) %>%
    mutate(!!paste0("oil_change_lag_", lag_n) := lag(oil_change, lag_n)) %>%
    ungroup()
}

lagged_correlations <- lag_analysis_df %>%
  group_by(cluster) %>%
  summarise(
    corr_lag_0 = cor(arrival_count, oil_change, use = "complete.obs"),
    corr_lag_1 = cor(arrival_count, oil_change_lag_1, use = "complete.obs"),
    corr_lag_2 = cor(arrival_count, oil_change_lag_2, use = "complete.obs"),
    corr_lag_3 = cor(arrival_count, oil_change_lag_3, use = "complete.obs"),
    .groups = "drop"
  ) %>%
  arrange(cluster)

cat("Correlations between Arrival Counts and Lagged Oil Price Changes:\n")
print(lagged_correlations)

corr_long <- lagged_correlations %>%
  pivot_longer(-cluster, names_to = "lag", values_to = "correlation") %>%
  mutate(lag = factor(lag, levels = c("corr_lag_0", "corr_lag_1", "corr_lag_2", "corr_lag_3")))

print(
  ggplot(corr_long, aes(x = factor(cluster), y = correlation, fill = lag)) +
    geom_col(position = "dodge") +
    geom_hline(yintercept = 0, color = "black") +
    labs(
      title = 'Correlation of Arrivals with Lagged Oil Price Changes by Cluster',
      x = "Cluster", y = "Correlation Coefficient", fill = "Lag (Months)"
    ) +
    theme(panel.grid.major.y = element_line(linetype = "dashed"))
)

## ---- Analyzing Impact of Specific Oil Shock Events (by Cluster) ----

specific_events_df <- merged_shock_df %>% filter(!is.na(event_name))

event_impact <- NULL
if (nrow(specific_events_df) > 0) {
  event_impact <- specific_events_df %>%
    filter(cluster != outlier_cluster) %>%
    group_by(event_name, cluster) %>%
    summarise(avg_arrivals = mean(arrival_count, na.rm = TRUE), .groups = "drop")

  cat("Average Cluster Arrivals during Specific Oil Shock Events:\n")
  print(event_impact %>% pivot_wider(names_from = cluster, values_from = avg_arrivals))

  print(
    ggplot(event_impact, aes(x = event_name, y = avg_arrivals, fill = factor(cluster))) +
      geom_col(position = "dodge", width = 0.8) +
      labs(
        title = 'Impact of Specific Geopolitical Events on Cluster Arrivals',
        x = 'Disruption Event', y = 'Average Monthly Arrivals', fill = 'Cluster ID'
      ) +
      theme(axis.text.x = element_text(angle = 45, hjust = 1),
            panel.grid.major.y = element_line(linetype = "dashed"))
  )
}

## ---- Average Cluster Arrivals During 'Non-Event' Periods ----

non_event_arrivals <- merged_shock_df %>% filter(oil_shock == 0, is.na(event_name))
non_event_arrivals_filtered <- non_event_arrivals %>% filter(cluster != outlier_cluster)

avg_non_event_cluster_arrivals <- non_event_arrivals_filtered %>%
  group_by(cluster) %>%
  summarise(avg_non_event_arrivals = mean(arrival_count, na.rm = TRUE), .groups = "drop")

cat("Average Cluster Arrivals during 'Non-Event' Periods:\n")
print(avg_non_event_cluster_arrivals)

## ---- Comparison: Average Cluster Arrivals (Non-Event vs. Specific Oil Shocks) ----

comparison_df <- event_impact %>%
  rename(avg_event_arrivals = avg_arrivals) %>%
  left_join(avg_non_event_cluster_arrivals, by = "cluster") %>%
  mutate(pct_change_from_non_event = (avg_event_arrivals - avg_non_event_arrivals) / avg_non_event_arrivals * 100)

cat("Comparison of Average Cluster Arrivals (Non-Event vs. Specific Events) and Percentage Change:\n")
print(comparison_df %>% arrange(cluster, event_name))

print(
  ggplot(comparison_df, aes(x = event_name, y = pct_change_from_non_event, fill = factor(cluster))) +
    geom_col(position = "dodge") +
    geom_hline(yintercept = 0, color = "black") +
    labs(
      title = 'Percentage Change in Cluster Arrivals During Specific Events vs. Non-Event Periods',
      x = 'Specific Oil Shock Event', y = 'Percentage Change in Arrivals (%)', fill = 'Cluster ID'
    ) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1),
          panel.grid.major.y = element_line(linetype = "dashed"))
)

## ---- TEU DIAGNOSTIC ANALYSIS (WORK 1) ----

cat("================ WORK 1: TEU ANALYSIS (CHINESE ALIGN) ================\n")

# 1. 讀取資料（路徑改為本機 data 資料夾）
teu_raw <- read_csv(file.path(data_path, "臺灣國際商港貨櫃裝卸量.csv"))

# 2. 自動偵測欄位
port_col <- names(teu_raw)[str_detect(names(teu_raw), "港") | str_detect(tolower(names(teu_raw)), "port")][1]
time_col <- names(teu_raw)[str_detect(names(teu_raw), "年|月") |
                             str_detect(tolower(names(teu_raw)), "date|time")][1]
teu_col <- names(teu_raw)[sapply(names(teu_raw), function(col) {
  cl <- tolower(col)
  any(sapply(c('總計', '合計', 'teu', 'total', '裝卸量'), function(k) str_detect(cl, fixed(k))))
})][1]

teu_cleaned <- teu_raw %>%
  select(all_of(c(port_col, time_col, teu_col))) %>%
  rename(port = !!port_col, year_month = !!time_col, teu = !!teu_col)

# 3. 修正：對齊成與油價主表一樣的「中文港口名稱」
port_code_to_zh <- c('TWKEL' = '基隆港', 'TWTPE' = '臺北港', 'TWKHH' = '高雄港', 'TWTXG' = '臺中港')

teu_cleaned <- teu_cleaned %>%
  mutate(port = port_code_to_zh[str_trim(as.character(port))]) %>%
  filter(!is.na(port))

# 4. 時間格式清洗 (對齊為 YYYY-MM)
convert_to_west_year <- function(val) {
  tryCatch({
    parts <- strsplit(val, "-")[[1]]
    if (nchar(parts[1]) <= 3) {  # 民國年
      parts[1] <- as.character(as.integer(parts[1]) + 1911)
    }
    sprintf("%s-%s", parts[1], formatC(as.integer(parts[2]), width = 2, flag = "0"))
  }, error = function(e) val)
}

teu_cleaned <- teu_cleaned %>%
  mutate(
    year_month = str_replace_all(as.character(year_month), "/", "-"),
    year_month = vapply(year_month, convert_to_west_year, character(1))
  )

# 5. 清理 TEU 數值（去掉千分位逗號）
teu_cleaned <- teu_cleaned %>%
  mutate(teu = as.numeric(str_replace_all(as.character(teu), ",", ""))) %>%
  filter(!is.na(teu))

# 6. 讀取並重塑油價主表，確保兩邊字串都沒有隱藏空格
final_df <- final_port_month_df %>%
  mutate(port = str_trim(as.character(port)), year_month = str_trim(as.character(year_month)))

teu_cleaned <- teu_cleaned %>%
  mutate(port = str_trim(as.character(port)), year_month = str_trim(as.character(year_month)))

# 7. 合併資料
model_teu_df <- teu_cleaned %>%
  inner_join(
    final_df %>% select(port, year_month, oil_change, oil_change_pct, oil_shock),
    by = c("port", "year_month")
  )

cat(sprintf(" 中文字串對齊成功 合併完成後的資料筆數為 %d 筆。\n", nrow(model_teu_df)))

if (nrow(model_teu_df) == 0) {
  cat(" 錯誤：中文字串一樣卻合不起來，檢查時間格式\n")
} else {
  # 8. 排序、建立滯後項、排除空值
  model_teu_df <- model_teu_df %>%
    arrange(port, year_month) %>%
    group_by(port) %>%
    mutate(teu_lag_1 = lag(teu, 1)) %>%
    ungroup() %>%
    filter(!is.na(teu_lag_1), !is.na(oil_change), !is.na(oil_shock))

  # 9. 執行迴歸模型（factor(port) 確保港口為類別型態）
  model_teu <- lm(
    teu ~ teu_lag_1 + oil_change + oil_change_pct + oil_shock + factor(port),
    data = model_teu_df
  )

  cat("\n [工作一] TEU 時間序列分析：\n")
  print(summary(model_teu))
}

## ---- VESSEL CLUSTER ANALYSIS (WORK 2) ----

cat("================ WORK 2: VESSEL CLUSTER ANALYSIS ================\n")

# 1. 確保基礎資料結構正確，並過濾掉異常值群組
reg_df <- lag_analysis_df
names(reg_df) <- tolower(names(reg_df))
reg_df <- reg_df %>% filter(cluster != outlier_cluster)

# 2. 強制將港口字串去空格，確保與 lag_analysis_df 結構對齊
reg_df <- reg_df %>% mutate(port = str_trim(as.character(port)))

# 3. 重新排序並建立油價變動的滯後變數
reg_df <- reg_df %>% arrange(port, cluster, year_month)
for (lag_n in 1:3) {
  reg_df <- reg_df %>%
    group_by(port, cluster) %>%
    mutate(!!paste0("oil_change_lag_", lag_n) := lag(oil_change, lag_n)) %>%
    ungroup()
}

# 4. 建立到港量本身的自相關滯後項（解決序列相關問題）
reg_df <- reg_df %>%
  group_by(port, cluster) %>%
  mutate(arrival_count_lag_1 = lag(arrival_count, 1)) %>%
  ungroup()

# 5. 迴圈跑完三個（非異常）群組
clusters_to_run <- sort(setdiff(unique(reg_df$cluster), outlier_cluster))

for (c_id in clusters_to_run) {
  cat("\n", strrep("=", 70), "\n", sep = "")
  cat(sprintf(" 正在估計模型：Cluster %d\n", c_id))
  cat(strrep("=", 70), "\n", sep = "")

  # 篩選特定分群並剔除缺失值
  sub_df <- reg_df %>%
    filter(cluster == c_id) %>%
    filter(!is.na(arrival_count), !is.na(arrival_count_lag_1), !is.na(oil_change),
           !is.na(oil_change_lag_1), !is.na(oil_change_lag_2), !is.na(oil_shock))

  # 執行包含自相關控制的時間序列固定效應迴歸模型（factor(port) 控制四大港口基準線差異）
  model <- lm(
    arrival_count ~ arrival_count_lag_1 + oil_change + oil_change_lag_1 +
      oil_change_lag_2 + oil_shock + factor(port),
    data = sub_df
  )

  model_summary <- summary(model)
  cat(sprintf(" 模型解釋力 R-squared: %.4f  (Adj. R-squared: %.4f)\n",
              model_summary$r.squared, model_summary$adj.r.squared))

  # 計算殘差的 Durbin-Watson 統計量： DW = sum((e_t - e_{t-1})^2) / sum(e_t^2)
  resid_vec <- residuals(model)
  dw_stat <- sum(diff(resid_vec)^2) / sum(resid_vec^2)
  cat(sprintf(" 殘差自相關 Durbin-Watson 指標: %.3f (接近 2 代表完全無序列相關，模型穩健)\n", dw_stat))

  cat("\n 主要變數估計結果（看 Coef 和 P>|t|）：\n")
  print(model_summary$coefficients)
}

## ---- TEU BEFORE / AFTER IMPACT CHARTS (ENGLISH PORT NAMES) ----

port_map_en <- c(
  '基隆港' = 'Keelung',
  '臺北港' = 'Taipei',
  '高雄港' = 'Kaohsiung',
  '臺中港' = 'Taichung',
  '花蓮港' = 'Hualien'
)

teu_plot_df <- model_teu_df %>%
  mutate(date = ymd(paste0(year_month, "-01")))

shock_info <- final_port_month_df %>%
  select(port, year_month, oil_shock) %>%
  distinct() %>%
  mutate(date = ymd(paste0(year_month, "-01")))

teu_plot_df <- teu_plot_df %>%
  select(-any_of("oil_shock")) %>%
  left_join(shock_info %>% select(port, date, oil_shock), by = c("port", "date")) %>%
  group_by(port) %>%
  group_modify(~ label_regimes(.x)) %>%
  ungroup()

for (p in unique(teu_plot_df$port)) {
  sub <- teu_plot_df %>% filter(port == p) %>% arrange(date)
  port_en <- if (p %in% names(port_map_en)) port_map_en[[p]] else p

  print(plot_with_regimes(
    sub, "teu",
    sprintf('TEU Time Series with Oil Shock / Recovery - %s', port_en),
    "TEU", line_color = "black"
  ))
}

## ---- VESSEL ARRIVAL FREQUENCY BEFORE / AFTER IMPACT CHARTS ----

cluster_plot_df <- cluster_monthly %>%
  mutate(date = ymd(paste0(year_month, "-01")))

shock_info <- final_port_month_df %>%
  select(port, year_month, oil_shock) %>%
  distinct() %>%
  mutate(date = ymd(paste0(year_month, "-01")))

cluster_plot_df <- cluster_plot_df %>%
  left_join(shock_info %>% select(port, date, oil_shock), by = c("port", "date")) %>%
  group_by(port, cluster) %>%
  group_modify(~ label_regimes(.x)) %>%
  ungroup()

for (p in sort(unique(cluster_plot_df$port))) {
  port_en <- if (p %in% names(port_map_en)) port_map_en[[p]] else p
  for (c_id in sort(unique(cluster_plot_df$cluster))) {
    sub <- cluster_plot_df %>% filter(port == p, cluster == c_id) %>% arrange(date)
    if (nrow(sub) == 0) next

    print(plot_with_regimes(
      sub, "arrival_count",
      sprintf('Cluster %d Arrivals with Shock / Recovery - %s', c_id, port_en),
      "Arrival Count", line_color = "navy"
    ))
  }
}

## ---- ESG CORRELATION HEATMAP: OIL VS. IDLING / EMISSIONS PROXY ----

cat("===== ESG CORRELATION HEATMAP: OIL VS. IDLING / EMISSIONS PROXY =====\n")

# 1. 確保 year_month 對齊為字串
all_inport_df <- all_inport_df %>% mutate(year_month = str_trim(as.character(year_month)))
final_port_month_df <- final_port_month_df %>% mutate(year_month = str_trim(as.character(year_month)))

# 2. 建立船舶層級的怠速 / 碳排放代理指標：gross_tonnage * berth_wait_hours
all_inport_df <- all_inport_df %>%
  mutate(co2_proxy = coalesce(gross_tonnage, 0) * coalesce(berth_wait_hours, 0))

# 3. 彙整到 (港口, 年月) 層級
esg_monthly <- all_inport_df %>%
  group_by(port, year_month) %>%
  summarise(
    total_co2_proxy = sum(co2_proxy, na.rm = TRUE),
    avg_co2_proxy = mean(co2_proxy, na.rm = TRUE),
    avg_berth_wait = mean(berth_wait_hours, na.rm = TRUE),
    total_vessels = n(),
    .groups = "drop"
  )

# 4. 合併每月油價資料
oil_cols <- intersect(c("oil_price", "oil_change", "oil_change_pct", "oil_shock"), names(final_port_month_df))

esg_merged <- esg_monthly %>%
  inner_join(
    final_port_month_df %>% select(port, year_month, all_of(oil_cols)),
    by = c("port", "year_month")
  )

cat(sprintf("Merged ESG dataset rows: %d\n", nrow(esg_merged)))
print(head(esg_merged))

# 5. 選擇要計算相關係數的變數
corr_vars <- intersect(
  c('oil_price', 'oil_change', 'oil_change_pct',
    'total_co2_proxy', 'avg_co2_proxy', 'avg_berth_wait', 'total_vessels'),
  names(esg_merged)
)

# 6. 計算相關係數矩陣
corr_matrix <- cor(esg_merged[corr_vars], use = "pairwise.complete.obs")

cat("Correlation matrix between oil metrics and ESG proxies:\n")
print(round(corr_matrix, 2))

# 7. 繪製 ESG 相關係數熱力圖
corr_long <- as.data.frame(corr_matrix) %>%
  rownames_to_column("var1") %>%
  pivot_longer(-var1, names_to = "var2", values_to = "correlation")

print(
  ggplot(corr_long, aes(x = var2, y = var1, fill = correlation)) +
    geom_tile() +
    geom_text(aes(label = sprintf("%.2f", correlation))) +
    scale_fill_gradient2(low = "blue", mid = "white", high = "red", midpoint = 0, name = "Correlation") +
    labs(title = 'ESG Correlation Heatmap: Oil vs. Idling / Emissions Proxies', x = NULL, y = NULL) +
    theme_minimal() +
    theme(axis.text.x = element_text(angle = 45, hjust = 1))
)

dev.off()
cat(sprintf("\n所有圖表已輸出至: %s\n", pdf_path))
