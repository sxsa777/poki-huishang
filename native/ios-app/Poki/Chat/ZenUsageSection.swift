import SwiftUI

/// The 会上数的羊 allowance, under Approvals: the five-hour rolling window, this week and this month,
/// each a bar with what is left and when it starts again. It reads the gateway with the account's key
/// and says plainly when the key cannot read an allowance.
struct ZenUsageSection: View {
    @State private var usage: ZenUsage?
    @State private var problem: String?
    @State private var loading = false
    @State private var version = ModelKeys.saved

    private var key: String? { ModelKeys.key(.huishang) }

    var body: some View {
        Section {
            if key == nil {
                Text("添加「会上数的羊」的密钥后，这里显示 5 小时、每周和每月的额度。")
                    .font(.footnote)
                    .foregroundStyle(Color(.secondaryLabel))
            } else if let usage, !usage.windows.isEmpty {
                ForEach(usage.windows) { window in
                    ZenUsageRow(window: window)
                }
            } else if loading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取额度…").foregroundStyle(Color(.secondaryLabel))
                }
            } else {
                Text(problem ?? "没有读到额度。")
                    .font(.footnote)
                    .foregroundStyle(Color(.systemOrange))
                Button("重试") { Task { await load() } }
            }
        } header: {
            HStack {
                Text("用量情况")
                Spacer()
                if loading, usage != nil { ProgressView().controlSize(.mini) }
            }
        } footer: {
            if usage != nil {
                Text("百分比是已经用掉的额度：5 小时是滚动窗口，每周、每月按周和月重置。")
            }
        }
        .task(id: version) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in version = ModelKeys.saved }
    }

    private func load() async {
        guard let key else {
            usage = nil
            problem = nil
            return
        }
        loading = true
        problem = nil
        do {
            usage = try await ZenUsage.fetch(key: key)
        } catch {
            usage = nil
            problem = error.localizedDescription
        }
        loading = false
    }
}

private struct ZenUsageRow: View {
    var window: ZenUsage.Window

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.title)
                Spacer()
                Text("\(Int(window.meter.percent.rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            ProgressView(value: window.meter.percent, total: 100)
                .tint(tint)
            if let reset = resetText {
                Text(verbatim: reset)
                    .font(.caption)
                    .foregroundStyle(Color(.secondaryLabel))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(window.title) 已用 \(Int(window.meter.percent.rounded()))%"))
    }

    private var tint: Color {
        if window.meter.limited || window.meter.percent >= 90 { return .red }
        if window.meter.percent >= 70 { return .orange }
        return .accentColor
    }

    private var resetText: String? {
        guard let date = window.meter.resetsAt else {
            return window.meter.limited ? "额度已用完" : nil
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let when = formatter.localizedString(for: date, relativeTo: Date())
        return window.meter.limited ? "额度已用完，\(when)重置" : "\(when)重置"
    }
}
