import SwiftUI

struct ContentView: View {
    @StateObject private var probe = Probe()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bluetooth: \(probe.bluetoothState)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Retrieve now") { probe.retrieveOnce(verbose: true) }
                        .buttonStyle(.borderedProminent)
                    Toggle("Poll every 2 s", isOn: $probe.polling)
                }
                Toggle("Scan for LF- / FTMS adverts", isOn: $probe.scanning)
                Toggle("Connect to advertised bike", isOn: $probe.connectToAdvertised)

                bikeData

                if !probe.attached.isEmpty {
                    Text("Attached: " + probe.attached.joined(separator: ", "))
                        .font(.footnote)
                }

                Divider()
                logView
            }
            .padding()
            .navigationTitle("GymKit Probe")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { probe.clearLog() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: probe.log.joined(separator: "\n"))
                }
            }
        }
    }

    @ViewBuilder
    private var bikeData: some View {
        GroupBox("Indoor Bike Data (\(probe.bikeDataPackets) packets)") {
            if let data = probe.latest {
                HStack(spacing: 20) {
                    metric("Power", data.powerW.map { "\($0) W" })
                    metric("Cadence", data.cadenceRpm.map { String(format: "%.0f rpm", $0) })
                    metric("Speed", data.speedKmh.map { String(format: "%.1f km/h", $0) })
                }
            } else {
                Text("No data yet").foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "-").font(.title3.monospacedDigit())
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(probe.log.suffix(500).enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
            }
            .onChange(of: probe.log.count) {
                proxy.scrollTo(min(probe.log.count, 500) - 1, anchor: .bottom)
            }
        }
    }
}
