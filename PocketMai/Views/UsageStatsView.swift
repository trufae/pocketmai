import MaiCore
import SwiftUI

/// Settings → Statistics: lifetime token consumption, generation speed, time
/// in use, and efficiency for every provider/model that has been used. A bar
/// chart on top ranks the models by the chosen metric; tapping a bar names it
/// below the chart. The numbers, rankings, descriptions, and provider colors
/// come from MaiCore, the same code behind the pmai REPL's `/stats`.
struct UsageStatsView: View {
  private typealias Metric = ModelUsageReport.Metric

  @ObservedObject private var stats = UsageStatsStore.shared
  @State private var metric: Metric = .speed
  @State private var selectedID: String?
  @State private var selectedModelIDs: Set<String> = []
  @State private var selectedProviderLabels: Set<String> = []
  @State private var hasInitializedSelections = false
  @State private var confirmingReset = false
  @State private var detailEntry: ModelUsageTotals?
  @State private var deletingProvider: ProviderUsageTotals?

  private static let chartHeight: CGFloat = 120

  /// The models and providers ticked in the lists are the ones the chart
  /// and the totals cover.
  private var filteredLedger: ModelUsageLedger {
    ModelUsageLedger(
      totals: stats.totals.filter {
        selectedProviderLabels.contains($0.providerLabel) && selectedModelIDs.contains($0.id)
      })
  }

  private var report: ModelUsageReport { ModelUsageReport(filteredLedger) }

  /// Rows with a number for the chosen metric, best first.
  private var chartRows: [ModelUsageReport.Row] {
    report.rows(for: metric).filter { ($0.number(metric) ?? 0) > 0 }
  }

  private var selectedRow: ModelUsageReport.Row? {
    chartRows.first { $0.id == selectedID } ?? chartRows.first
  }

  private var allModelTotals: [ModelUsageTotals] { stats.ledger.sortedByLastUsed }

  private var providerTotals: [ProviderUsageTotals] { stats.ledger.providerTotals }

  var body: some View {
    List {
      if stats.totals.isEmpty {
        ContentUnavailableView(
          "No Usage Yet",
          systemImage: "chart.bar",
          description: Text("Statistics appear here after the first model response."))
      } else if report.isEmpty {
        ContentUnavailableView(
          "No Statistics Selected",
          systemImage: "line.3.horizontal.decrease.circle",
          description: Text("Select at least one model and provider to show statistics."))
      } else {
        Section {
          Picker("Metric", selection: $metric) {
            ForEach(Metric.allCases, id: \.self) { Text($0.label).tag($0) }
          }
          .pickerStyle(.segmented)
          chart
          Text(report.headline)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(maxWidth: .infinity)
          tokenSummary
        } header: {
          Text(metric.title)
        } footer: {
          Text("\(metric.title): \(metric.explanation).")
        }
      }
      if !allModelTotals.isEmpty {
        Section {
          ForEach(allModelTotals) { entry in
            modelRow(entry)
          }
        } header: {
          Text("Models")
        } footer: {
          if stats.ledger.estimatedCallCount > 0 {
            Text("~ marks token counts estimated from text length (~4 characters per token).")
          }
        }
      }
      if !providerTotals.isEmpty {
        Section {
          ForEach(providerTotals) { provider in
            providerRow(provider)
          }
        } header: {
          Text("Providers")
        } footer: {
          Text(
            "Select models and providers to include them in the chart and totals. Long-press a row for every recorded fact."
          )
        }
      }
      if !stats.totals.isEmpty {
        Section {
          Button(role: .destructive) {
            confirmingReset = true
          } label: {
            Label("Reset Statistics", systemImage: "trash")
          }
        }
      }
    }
    .navigationTitle("Statistics")
    .onAppear {
      guard !hasInitializedSelections else { return }
      selectedModelIDs = Set(allModelTotals.map(\.id))
      selectedProviderLabels = Set(providerTotals.map(\.providerLabel))
      hasInitializedSelections = true
    }
    .confirmationDialog(
      "Reset all usage statistics?",
      isPresented: $confirmingReset,
      titleVisibility: .visible
    ) {
      Button("Reset Statistics", role: .destructive) {
        stats.reset()
        selectedID = nil
        selectedModelIDs = []
        selectedProviderLabels = []
      }
    }
    .confirmationDialog(
      detailEntry?.title ?? "",
      isPresented: Binding(
        get: { detailEntry != nil },
        set: { if !$0 { detailEntry = nil } }
      ),
      titleVisibility: .visible,
      presenting: detailEntry
    ) { entry in
      Button("Delete Statistics", role: .destructive) {
        stats.remove(id: entry.id)
        selectedModelIDs.remove(entry.id)
      }
    } message: { entry in
      Text(entry.detailLines.joined(separator: "\n"))
    }
    .confirmationDialog(
      deletingProvider.map { "Delete all statistics for \($0.providerLabel)?" } ?? "",
      isPresented: Binding(
        get: { deletingProvider != nil },
        set: { if !$0 { deletingProvider = nil } }
      ),
      titleVisibility: .visible,
      presenting: deletingProvider
    ) { provider in
      Button("Delete Statistics", role: .destructive) {
        let removedIDs = Set(
          stats.totals.filter { $0.providerLabel == provider.providerLabel }.map(\.id))
        stats.remove(providerLabel: provider.providerLabel)
        selectedModelIDs.subtract(removedIDs)
        selectedProviderLabels.remove(provider.providerLabel)
      }
    } message: { provider in
      Text(provider.summary)
    }
  }

  /// One bar per model, its height the row's share of the best value for the
  /// chosen metric, in the provider's shared color.
  private var chart: some View {
    let rows = chartRows
    return VStack(spacing: 10) {
      if rows.isEmpty {
        Text("No \(metric.label.lowercased()) recorded for the selected models yet.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack(alignment: .bottom, spacing: 6) {
        ForEach(rows) { row in
          let isSelected = row.id == selectedRow?.id
          Rectangle()
            .fill(Color(row.color).opacity(isSelected ? 1 : 0.35))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
            .frame(maxWidth: 48)
            .frame(height: max(6, Self.chartHeight * row.fraction(metric)))
            .frame(maxWidth: .infinity, maxHeight: Self.chartHeight, alignment: .bottom)
            .contentShape(Rectangle())
            .onTapGesture { selectedID = row.id }
            .accessibilityLabel(row.title)
            .accessibilityValue(row.value(metric))
        }
      }
      .animation(.snappy(duration: 0.2), value: selectedID)
      if let row = selectedRow {
        VStack(spacing: 2) {
          HStack(spacing: 6) {
            Text(row.title)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
            Text(row.value(metric))
              .font(.caption.weight(.semibold))
              .monospacedDigit()
          }
          Text(row.detail(metric))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
      }
    }
    .padding(.vertical, 6)
  }

  private var tokenSummary: some View {
    let ledger = filteredLedger
    return HStack(spacing: 12) {
      Label("~\(ModelUsageFormat.count(ledger.userInputTokens)) sent", systemImage: "arrow.up")
      Label(
        "~\(ModelUsageFormat.count(ledger.receivedTextTokens)) recv", systemImage: "arrow.down")
      if ledger.imageInputs > 0 {
        Label("\(ledger.imageInputs) images", systemImage: "photo")
      }
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.secondary)
    .monospacedDigit()
    .frame(maxWidth: .infinity)
  }

  private func modelRow(_ entry: ModelUsageTotals) -> some View {
    let isSelected = selectedModelIDs.contains(entry.id)
    return Button {
      if isSelected {
        selectedModelIDs.remove(entry.id)
      } else {
        selectedModelIDs.insert(entry.id)
      }
    } label: {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(entry.title)
              .font(.subheadline.weight(.medium))
              .foregroundStyle(.primary)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
            if let number = entry.value(metric), number > 0 {
              Text(metric.text(number))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
          }
          Text(entry.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : .secondary)
      }
    }
    .padding(.vertical, 2)
    .buttonStyle(.plain)
    .listRowBackground(
      isSelected ? Color(providerLabel: entry.providerLabel).opacity(0.14) : Color.clear
    )
    .onLongPressGesture {
      detailEntry = entry
    }
    .accessibilityLabel(entry.title)
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
  }

  private func providerRow(_ provider: ProviderUsageTotals) -> some View {
    let isSelected = selectedProviderLabels.contains(provider.providerLabel)
    return Button {
      if isSelected {
        selectedProviderLabels.remove(provider.providerLabel)
      } else {
        selectedProviderLabels.insert(provider.providerLabel)
      }
    } label: {
      HStack(spacing: 10) {
        Circle()
          .fill(Color(providerLabel: provider.providerLabel))
          .frame(width: 10, height: 10)
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(provider.providerLabel)
              .foregroundStyle(.primary)
            Spacer()
            if let efficiency = provider.efficiency, metric == .efficiency {
              Text(ModelUsageFormat.efficiency(efficiency))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
          }
          Text(provider.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : .secondary)
      }
    }
    .buttonStyle(.plain)
    .onLongPressGesture {
      deletingProvider = provider
    }
    .accessibilityLabel(provider.providerLabel)
    .accessibilityValue("\(isSelected ? "Selected" : "Not selected"), \(provider.summary)")
  }
}

extension Color {
  /// The shared palette's color, so a provider looks the same here as in the
  /// pmai visual workspace.
  fileprivate init(_ color: ModelUsageColor) {
    self.init(red: color.red, green: color.green, blue: color.blue)
  }

  fileprivate init(providerLabel: String) {
    self.init(ModelUsagePalette.color(forProviderLabel: providerLabel))
  }
}
