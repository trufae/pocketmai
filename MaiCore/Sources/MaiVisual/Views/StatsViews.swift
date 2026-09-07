import Foundation
import MaiCore
import SwiftTUIRuntime

/// Lifetime usage per provider/model, ranked the way PocketMai's Statistics
/// screen ranks it: one colored bar per model for each metric of the shared
/// report — average output speed, time in use, and efficiency. Colors come
/// from the shared palette, so a provider looks the same here as on the phone.
struct StatsScreen: View {
  let workspace: VisualWorkspace

  var body: some View {
    let report = workspace.usageReport
    GeometryReader { proxy in
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 1) {
          if report.isEmpty {
            Text("Model statistics").bold()
            Text(ModelUsageReport.emptyMessage).foregroundStyle(.muted)
          } else {
            HStack(spacing: 1) {
              Text("Model statistics").bold()
              Text(report.headline).foregroundStyle(.muted).lineLimit(1).truncationMode(.tail)
            }
            ForEach(ModelUsageReport.Metric.allCases, id: \.self) { metric in
              UsageBarChart(metric: metric, report: report, width: Int(proxy.size.width) - 2)
            }
            if report.hasEstimates {
              Text(
                "~ marks token counts estimated from text length (about 4 characters per token)."
              )
              .foregroundStyle(.separator)
              .lineLimit(2)
            }
          }
          HStack(spacing: 2) {
            Button("Refresh") { Task { await workspace.refreshUsageStats() } }
            Button("Reset statistics", role: .destructive) { workspace.resetUsageStats() }
              .disabled(report.isEmpty)
          }
          Text(
            "/stats prints the same table in the REPL; /stats rm PROVIDER[:MODEL] drops one row."
          )
          .foregroundStyle(.separator)
          .lineLimit(2)
        }
        .padding(1)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
  }
}

/// One metric of the report: a label, a bar filled relative to the best
/// row, the value, and the row's other facts. Bars share one width so the
/// column reads as a ranking.
private struct UsageBarChart: View {
  let metric: ModelUsageReport.Metric
  let report: ModelUsageReport
  let width: Int

  private var rows: [ModelUsageReport.Row] { report.rows(for: metric) }

  private var labelWidth: Int {
    min(28, rows.map { $0.title.count }.max() ?? 0)
  }

  private var valueWidth: Int {
    rows.map { $0.value(metric).count }.max() ?? 0
  }

  private var barWidth: Int {
    max(6, min(40, width - labelWidth - valueWidth - 8))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(metric.title).bold()
      ForEach(rows) { row in
        HStack(spacing: 1) {
          Text(
            ModelUsageFormat.pad(
              ModelUsageFormat.clip(row.title, to: labelWidth), to: labelWidth)
          )
          .lineLimit(1)
          Text(ModelUsageFormat.bar(fraction: row.fraction(metric), width: barWidth))
            .foregroundStyle(
              Color(red: row.color.red, green: row.color.green, blue: row.color.blue))
          Text(ModelUsageFormat.pad(row.value(metric), to: valueWidth, leading: true)).bold()
          Text(row.detail(metric))
            .foregroundStyle(.muted)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
    }
  }
}
