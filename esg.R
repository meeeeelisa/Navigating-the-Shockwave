# ESG.R
# 由 Google Colab 匯出的 ESG.ipynb (esg.py) 轉換為 R script
# 原始 Colab 連結: https://colab.research.google.com/drive/1didcFxwP3_Ekjxv5s3gHXaaCgPITE-5L

library(readr)
library(dplyr)
library(ggplot2)

data_path <- "data"

all_inport_df <- read_csv(file.path(data_path, "cleaned_all_inport.csv"))
print(head(all_inport_df))
str(all_inport_df)

final_port_month_df <- read_csv(file.path(data_path, "final_port_month.csv"))
print(head(final_port_month_df))
str(final_port_month_df)

## 依據 IMO 標準，定義碳排計算函數

estimate_vessel_co2 <- function(gross_tonnage, vessel_type_group, berth_wait_hours, anchor_wait_hours) {
  gt <- gross_tonnage
  v_type <- tolower(as.character(vessel_type_group))

  # 預設值（若無法辨識船型時使用）
  ae_power <- if (gt > 0) 2.12 * (gt ^ 0.55) else 0
  load_berth <- 0.4
  load_anchor <- 0.2

  # 依據船型給定不同的 IMO 功率迴歸公式與負載因子
  if (grepl("container", v_type)) {                 # 貨櫃船 (耗電極大)
    ae_power <- 0.45 * (gt ^ 0.85)
    load_berth <- 0.55
    load_anchor <- 0.25
  } else if (grepl("bulk", v_type)) {                # 散裝船
    ae_power <- 2.12 * (gt ^ 0.55)
    load_berth <- 0.40
    load_anchor <- 0.20
  } else if (grepl("tanker", v_type)) {              # 油輪
    ae_power <- 14.7 * (gt ^ 0.42)
    load_berth <- 0.45
    load_anchor <- 0.20
  } else if (grepl("passenger", v_type)) {           # 客輪/郵輪 (生活用電高)
    ae_power <- 0.25 * (gt ^ 0.90)
    load_berth <- 0.60
    load_anchor <- 0.30
  }

  # 國際標準常數
  sfc <- 210   # 燃油消耗率 (g/kWh)
  cf <- 3.114  # 碳轉換因子 (每噸油產生 3.114 噸 CO2)

  # 讀取時間 (若為 NA 則補 0)
  b_hours <- ifelse(is.na(berth_wait_hours), 0, berth_wait_hours)
  a_hours <- ifelse(is.na(anchor_wait_hours), 0, anchor_wait_hours)

  # 分別計算碼頭與錨區的碳排放 (單位：公噸)
  co2_berth <- b_hours * ae_power * load_berth * sfc * cf / 1000000
  co2_anchor <- a_hours * ae_power * load_anchor * sfc * cf / 1000000

  co2_berth + co2_anchor
}

# 執行計算：建立新欄位 estimated_co2
all_inport_df$estimated_co2 <- mapply(
  estimate_vessel_co2,
  all_inport_df$gross_tonnage,
  all_inport_df$vessel_type_group,
  all_inport_df$berth_wait_hours,
  all_inport_df$anchor_wait_hours
)

cat("碳排放估算完成！前三筆結果：\n")
print(head(all_inport_df[, c("vessel_type_group", "gross_tonnage", "berth_wait_hours",
                             "anchor_wait_hours", "estimated_co2")], 3))

## 將油價與衝擊資訊合併

# 1. 取出第一份資料的背景特徵，並去除重複值
oil_meta <- final_port_month_df %>%
  select(port, year_month, oil_price, oil_change_pct, any_shock, event_name) %>%
  distinct()

# 2. 以 port 和 year_month 為 Key 進行合併
analysis_df <- all_inport_df %>%
  left_join(oil_meta, by = c("port", "year_month"))

cat("資料合併完成，目前總筆數：", nrow(analysis_df), "\n")

## 開始進行數據分析與視覺化

# 為了避免極端異常值影響視覺化，限制 y 軸在 95 百分位數內
y_limit <- quantile(analysis_df$estimated_co2, 0.95, na.rm = TRUE)

p <- ggplot(
  data = analysis_df %>% filter(estimated_co2 <= y_limit),
  aes(x = oil_price, y = estimated_co2, color = factor(any_shock))
) +
  geom_point(alpha = 0.4) +
  labs(
    title = "Relationship between Oil Price and Vessel CO2 Emissions in Ports",
    x = "Oil Price",
    y = "Estimated CO2 per Arrival (Tons)",
    color = "any_shock"
  )
print(p)

## 統計迴歸分析

# 排除缺失值
regression_data <- analysis_df %>%
  filter(!is.na(estimated_co2), !is.na(oil_price), !is.na(gross_tonnage),
         !is.na(vessel_type_group), !is.na(port))

# 建立迴歸模型，控制船隻大小(gross_tonnage)與港口結構、船型定義
# factor(port) 與 factor(vessel_type_group) 會自動轉為虛擬變數（控制固定效應）
model <- lm(
  estimated_co2 ~ oil_price + gross_tonnage + factor(port) + factor(vessel_type_group),
  data = regression_data
)
print(summary(model))

# 排除缺失值，並確保 year 和 month 存在以控制時間固定效應
regression_data_v2 <- analysis_df %>%
  filter(!is.na(estimated_co2), !is.na(oil_price), !is.na(any_shock),
         !is.na(gross_tonnage), !is.na(vessel_type_group), !is.na(port),
         !is.na(year), !is.na(month))

# 建立交互項迴歸模型
# oil_price * any_shock 會自動拆解為三個部分：
# 1. oil_price 獨立效應
# 2. any_shock 獨立效應
# 3. oil_price:any_shock 交互作用效應 (這最關鍵！)
# 同時加入 factor(year) + factor(month) 來控制時間固定效應，提升 R平方 (解釋力)
model_v2 <- lm(
  estimated_co2 ~ oil_price * any_shock + gross_tonnage + factor(port) +
    factor(vessel_type_group) + factor(year) + factor(month),
  data = regression_data_v2
)
print(summary(model_v2))

## 戰爭衝擊月份 vs 正常月份油價 — T 檢定

# 分割成有戰爭衝擊與沒衝擊的月份油價
shock_oil <- final_port_month_df %>% filter(any_shock == 1) %>% pull(oil_price) %>% na.omit()
normal_oil <- final_port_month_df %>% filter(any_shock == 0) %>% pull(oil_price) %>% na.omit()

t_result <- t.test(shock_oil, normal_oil, var.equal = FALSE)

cat(sprintf("戰爭月份平均油價: %.2f 美元\n", mean(shock_oil)))
cat(sprintf("正常月份平均油價: %.2f 美元\n", mean(normal_oil)))
cat(sprintf("T檢定 P值: %.4f\n", t_result$p.value))
