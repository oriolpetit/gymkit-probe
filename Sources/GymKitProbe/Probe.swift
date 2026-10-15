import CoreBluetooth
import Foundation

/// Tests whether a third-party app can reach a gym bike that iOS (GymKit / healthd)
/// is already connected to. It never writes to the bike: it only retrieves, connects
/// locally, discovers, reads and subscribes.
final class Probe: NSObject, ObservableObject {
    static let ftms = CBUUID(string: "1826")
    static let appleGymKit = CBUUID(string: "FE13")
    static let indoorBikeData = CBUUID(string: "2AD2")
    static let fitnessMachineFeature = CBUUID(string: "2ACC")
    static let fitnessMachineStatus = CBUUID(string: "2ADA")
    static let trainingStatus = CBUUID(string: "2AD3")
    static let subscribable: Set<CBUUID> = [indoorBikeData, fitnessMachineStatus, trainingStatus]
    /// Each service is queried on its own so the log shows which UUID found the bike.
    /// Limited to the bike's services so watches and headphones are left alone.
    static let retrieveServices: [CBUUID] = [ftms, appleGymKit]

    /// Re-advertises the bike's data for apps on other devices (e.g. MyWhoosh).
    let bridge = FTMSBridge()

    @Published var bluetoothState = "unknown"
    @Published var log: [String] = []
    @Published var latest: IndoorBikeData?
    @Published var bikeDataPackets = 0
    @Published var attached: [String] = []
    @Published var polling = false {
        didSet { polling ? startPolling() : stopPolling() }
    }
    @Published var scanning = false {
        didSet { scanning ? startScan() : stopScan() }
    }
    /// When scanning, also try to connect to an advertising "LF-" / FTMS device
    /// (tests whether pairing works without GymKit's NFC data).
    @Published var connectToAdvertised = false

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var pollTimer: Timer?
    private var advertCounts: [String: Int] = [:]
    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        bridge.log = { [weak self] line in self?.add(line) }
    }

    func add(_ line: String) {
        let stamped = "\(clock.string(from: Date())) \(line)"
        log.append(stamped)
        print(stamped)
    }

    func clearLog() {
        log.removeAll()
        advertCounts.removeAll()
    }

    // MARK: Retrieve already-connected peripherals

    func retrieveOnce(verbose: Bool) {
        guard central.state == .poweredOn else {
            if verbose { add("Bluetooth is not powered on (\(bluetoothState))") }
            return
        }
        for service in Self.retrieveServices {
            let found = central.retrieveConnectedPeripherals(withServices: [service])
            if verbose || !found.isEmpty {
                add("retrieveConnectedPeripherals(\(service.uuidString)) -> \(found.count)")
            }
            for peripheral in found {
                attach(peripheral, reason: "retrieved via \(service.uuidString)")
            }
        }
    }

    private func attach(_ peripheral: CBPeripheral, reason: String) {
        guard peripherals[peripheral.identifier] == nil else { return }
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        add("FOUND \(peripheral.name ?? "(no name)") id=\(peripheral.identifier.uuidString.prefix(8)) "
            + "state=\(describe(peripheral.state)) [\(reason)] -> connecting locally")
        central.connect(peripheral, options: nil)
    }

    private func startPolling() {
        add("Polling retrieveConnectedPeripherals every 2 s")
        retrieveOnce(verbose: true)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.retrieveOnce(verbose: false)
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        add("Polling stopped")
    }

    // MARK: Scan for advertisements

    private func startScan() {
        guard central.state == .poweredOn else {
            add("Cannot scan: Bluetooth is \(bluetoothState)")
            return
        }
        add("Scanning (all devices, duplicates allowed); logging LF-/FTMS/FE13 advertisers")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func stopScan() {
        central.stopScan()
        add("Scan stopped")
    }

    private func describe(_ state: CBPeripheralState) -> String {
        switch state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    private func describe(_ properties: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if properties.contains(.read) { parts.append("read") }
        if properties.contains(.write) { parts.append("write") }
        if properties.contains(.writeWithoutResponse) { parts.append("writeNoResp") }
        if properties.contains(.notify) { parts.append("notify") }
        if properties.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: ",")
    }
}

extension Probe: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: bluetoothState = "on"
        case .poweredOff: bluetoothState = "off"
        case .unauthorized: bluetoothState = "unauthorized (allow Bluetooth in Settings)"
        case .unsupported: bluetoothState = "unsupported"
        case .resetting: bluetoothState = "resetting"
        case .unknown: bluetoothState = "unknown"
        @unknown default: bluetoothState = "state \(central.state.rawValue)"
        }
        add("Bluetooth state: \(bluetoothState)")
        if central.state == .poweredOn && scanning { startScan() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let interesting = name.hasPrefix("LF") || services.contains(Self.ftms) || services.contains(Self.appleGymKit)
            || serviceData[Self.ftms] != nil
        guard interesting else { return }

        let key = "\(peripheral.identifier.uuidString)|\(name)"
        let count = (advertCounts[key] ?? 0) + 1
        advertCounts[key] = count
        if count == 1 || count % 50 == 0 {
            let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
            let ftmsData = serviceData[Self.ftms].map { $0.map { String(format: "%02X", $0) }.joined() } ?? "-"
            add("ADVERT #\(count) '\(name)' id=\(peripheral.identifier.uuidString.prefix(8)) rssi=\(RSSI) "
                + "services=\(services.map(\.uuidString)) ftmsData=\(ftmsData) connectable=\(connectable.map { $0 ? "yes" : "no" } ?? "?")")
        }
        if connectToAdvertised {
            attach(peripheral, reason: "advertised as '\(name)'")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        add("Local connection OK: \(peripheral.name ?? "(no name)") -> discovering all services")
        attached.append("\(peripheral.name ?? "(no name)") \(peripheral.identifier.uuidString.prefix(8))")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        add("Connect FAILED: \(peripheral.name ?? "(no name)") error=\(error?.localizedDescription ?? "nil")")
        peripherals[peripheral.identifier] = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        add("Disconnected: \(peripheral.name ?? "(no name)") error=\(error?.localizedDescription ?? "nil")")
        peripherals[peripheral.identifier] = nil
        attached.removeAll { $0.hasSuffix(String(peripheral.identifier.uuidString.prefix(8))) }
    }
}

extension Probe: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            add("Service discovery error: \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        add("Services visible to this app: \(services.map(\.uuid.uuidString))")
        if !services.contains(where: { $0.uuid == Self.ftms }) {
            add("FTMS 0x1826 NOT visible to this app")
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            add("Characteristic discovery error in \(service.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] {
            add("  \(service.uuid.uuidString) / \(characteristic.uuid.uuidString) [\(describe(characteristic.properties))]")
            if characteristic.uuid == Self.fitnessMachineFeature && characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
            if Self.subscribable.contains(characteristic.uuid)
                && (characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        add("Subscribe \(characteristic.uuid.uuidString): notifying=\(characteristic.isNotifying) "
            + "error=\(error?.localizedDescription ?? "nil")")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            add("Value error \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }
        let hex = value.map { String(format: "%02X", $0) }.joined()
        switch characteristic.uuid {
        case Self.indoorBikeData:
            bikeDataPackets += 1
            latest = IndoorBikeData.parse(value)
            bridge.forwardIndoorBikeData(value, parsed: latest)
            if bikeDataPackets <= 3 || bikeDataPackets % 30 == 0 {
                add("BIKE DATA #\(bikeDataPackets) \(hex) -> \(latest?.summary ?? "unparsed")")
            }
        case Self.fitnessMachineFeature:
            bridge.setFeature(value)
            add("Value \(characteristic.uuid.uuidString): \(hex)")
        case Self.fitnessMachineStatus:
            bridge.forwardMachineStatus(value)
            add("Value \(characteristic.uuid.uuidString): \(hex)")
        case Self.trainingStatus:
            bridge.forwardTrainingStatus(value)
            add("Value \(characteristic.uuid.uuidString): \(hex)")
        default:
            add("Value \(characteristic.uuid.uuidString): \(hex)")
        }
    }
}
