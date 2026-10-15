import CoreBluetooth
import Foundation

/// Re-advertises the gym bike's data as a standard BLE indoor bike so another device
/// (e.g. MyWhoosh on a second phone) can pair with this iPhone:
/// - Fitness Machine Service (0x1826): Indoor Bike Data, Feature, Status, Training
///   Status and a Control Point that accepts session commands but cannot change
///   resistance (the Discover SE4 exposes no control point).
/// - Cycling Power Service (0x1818): power plus crank revolutions derived from cadence.
final class FTMSBridge: NSObject, ObservableObject {
    static let fitnessMachineService = CBUUID(string: "1826")
    static let indoorBikeData = CBUUID(string: "2AD2")
    static let fitnessMachineFeature = CBUUID(string: "2ACC")
    static let trainingStatus = CBUUID(string: "2AD3")
    static let fitnessMachineStatus = CBUUID(string: "2ADA")
    static let controlPoint = CBUUID(string: "2AD9")
    static let cyclingPowerService = CBUUID(string: "1818")
    static let cyclingPowerMeasurement = CBUUID(string: "2A63")
    static let cyclingPowerFeature = CBUUID(string: "2A65")
    static let sensorLocation = CBUUID(string: "2A5D")

    @Published var enabled = false {
        didSet { enabled ? start() : stop() }
    }
    @Published var status = "off"
    @Published var subscriberCount = 0
    @Published var forwardedPackets = 0
    @Published var localName = "LF Bridge"

    /// Log sink provided by the owner.
    var log: (String) -> Void = { print($0) }

    private var manager: CBPeripheralManager?
    private var servicesPending = 0
    private var characteristics: [CBUUID: CBMutableCharacteristic] = [:]
    private var subscribers: Set<UUID> = []
    /// Latest notification per characteristic that could not be sent yet (queue full).
    private var backlog: [CBUUID: Data] = [:]

    // Values served on read; updated from the bike.
    private var featureValue = Data([0x87, 0x76, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    private var trainingStatusValue = Data([0x00, 0x01]) // flags 0, status "Idle"

    // Crank revolution synthesis for the Cycling Power Measurement.
    private var crankRevolutions = 0.0
    private var lastCrankEventTime: UInt16 = 0
    private var lastSampleUptime: TimeInterval?

    // MARK: Inputs from the bike

    func setFeature(_ value: Data) {
        featureValue = value
    }

    func forwardIndoorBikeData(_ raw: Data, parsed: IndoorBikeData?) {
        var fixed = raw
        // The Discover SE4 omits the instantaneous-cadence flag although the field is
        // present; set it so receivers parse the rest of the packet correctly.
        if parsed?.cadenceFlagQuirk == true, fixed.count >= 2 {
            fixed[fixed.startIndex] |= 0x04
        }
        send(fixed, to: Self.indoorBikeData)
        if let parsed {
            send(cyclingPowerMeasurement(from: parsed), to: Self.cyclingPowerMeasurement)
        }
        forwardedPackets += 1
    }

    func forwardMachineStatus(_ raw: Data) {
        send(raw, to: Self.fitnessMachineStatus)
    }

    func forwardTrainingStatus(_ raw: Data) {
        trainingStatusValue = raw
        send(raw, to: Self.trainingStatus)
    }

    // MARK: Lifecycle

    private func start() {
        status = "starting"
        if let manager, manager.state == .poweredOn {
            publishServices(on: manager)
        } else if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: .main)
        }
    }

    private func stop() {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        characteristics.removeAll()
        subscribers.removeAll()
        subscriberCount = 0
        backlog.removeAll()
        status = "off"
        log("Bridge stopped")
    }

    private func publishServices(on manager: CBPeripheralManager) {
        manager.removeAllServices()
        characteristics.removeAll()

        func make(_ uuid: CBUUID, _ properties: CBCharacteristicProperties,
                  _ permissions: CBAttributePermissions) -> CBMutableCharacteristic {
            let characteristic = CBMutableCharacteristic(type: uuid, properties: properties, value: nil,
                                                         permissions: permissions)
            characteristics[uuid] = characteristic
            return characteristic
        }

        let fitnessMachine = CBMutableService(type: Self.fitnessMachineService, primary: true)
        fitnessMachine.characteristics = [
            make(Self.fitnessMachineFeature, [.read], [.readable]),
            make(Self.indoorBikeData, [.notify], [.readable]),
            make(Self.trainingStatus, [.read, .notify], [.readable]),
            make(Self.fitnessMachineStatus, [.notify], [.readable]),
            make(Self.controlPoint, [.write, .indicate], [.writeable]),
        ]

        let cyclingPower = CBMutableService(type: Self.cyclingPowerService, primary: true)
        cyclingPower.characteristics = [
            make(Self.cyclingPowerMeasurement, [.notify], [.readable]),
            make(Self.cyclingPowerFeature, [.read], [.readable]),
            make(Self.sensorLocation, [.read], [.readable]),
        ]

        servicesPending = 2
        manager.add(fitnessMachine)
        manager.add(cyclingPower)
    }

    private func startAdvertising() {
        manager?.startAdvertising([
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [Self.fitnessMachineService, Self.cyclingPowerService],
        ])
    }

    // MARK: Encoding

    private func send(_ value: Data, to uuid: CBUUID) {
        guard enabled, let manager, let characteristic = characteristics[uuid], !subscribers.isEmpty else { return }
        if !manager.updateValue(value, for: characteristic, onSubscribedCentrals: nil) {
            backlog[uuid] = value
        }
    }

    /// Cycling Power Measurement: flags (crank revolution data present), instantaneous
    /// power, cumulative crank revolutions, last crank event time (1/1024 s).
    private func cyclingPowerMeasurement(from data: IndoorBikeData) -> Data {
        let now = ProcessInfo.processInfo.systemUptime
        let cadence = data.cadenceRpm ?? 0
        if let last = lastSampleUptime, cadence > 0 {
            let revolutionsPerSecond = cadence / 60
            let previousWhole = floor(crankRevolutions)
            crankRevolutions += revolutionsPerSecond * (now - last)
            let whole = floor(crankRevolutions)
            if whole > previousWhole {
                // Time at which the most recent whole revolution completed.
                let eventTime = now - (crankRevolutions - whole) / revolutionsPerSecond
                lastCrankEventTime = UInt16(truncatingIfNeeded: Int((eventTime * 1024).rounded()))
            }
        }
        lastSampleUptime = now

        let power = Int16(clamping: data.powerW ?? 0)
        let revolutions = UInt16(truncatingIfNeeded: Int(floor(crankRevolutions)))
        var bytes: [UInt8] = [0x20, 0x00]
        bytes += [UInt8(truncatingIfNeeded: power), UInt8(truncatingIfNeeded: power >> 8)]
        bytes += [UInt8(truncatingIfNeeded: revolutions), UInt8(truncatingIfNeeded: revolutions >> 8)]
        bytes += [UInt8(truncatingIfNeeded: lastCrankEventTime), UInt8(truncatingIfNeeded: lastCrankEventTime >> 8)]
        return Data(bytes)
    }

    private func readValue(for uuid: CBUUID) -> Data? {
        switch uuid {
        case Self.fitnessMachineFeature: return featureValue
        case Self.trainingStatus: return trainingStatusValue
        case Self.cyclingPowerFeature: return Data([0x08, 0x00, 0x00, 0x00]) // crank revolution data supported
        case Self.sensorLocation: return Data([0x00]) // other
        default: return nil
        }
    }

    /// Control Point response: 0x80, request op code, result
    /// (0x01 success, 0x02 op code not supported).
    private func controlPointResponse(for request: Data) -> Data {
        guard let opCode = request.first else { return Data([0x80, 0x00, 0x03]) }
        switch opCode {
        case 0x00, 0x01, 0x07, 0x08: // request control, reset, start/resume, stop/pause
            return Data([0x80, opCode, 0x01])
        default: // targets (power, resistance, simulation): the bike cannot be controlled
            return Data([0x80, opCode, 0x02])
        }
    }
}

extension FTMSBridge: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            if enabled { publishServices(on: peripheral) }
        case .unauthorized:
            status = "Bluetooth not allowed"
        case .poweredOff:
            status = "Bluetooth off"
        default:
            status = "Bluetooth state \(peripheral.state.rawValue)"
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            status = "service error"
            log("Bridge: adding service \(service.uuid.uuidString) failed: \(error.localizedDescription)")
            return
        }
        servicesPending -= 1
        if servicesPending == 0 { startAdvertising() }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            status = "advertising failed"
            log("Bridge: advertising failed: \(error.localizedDescription)")
        } else {
            status = "advertising as '\(localName)'"
            log("Bridge: advertising as '\(localName)' (FTMS 1826 + Cycling Power 1818)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        subscribers.insert(central.identifier)
        subscriberCount = subscribers.count
        log("Bridge: \(central.identifier.uuidString.prefix(8)) subscribed to \(characteristic.uuid.uuidString)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        log("Bridge: \(central.identifier.uuidString.prefix(8)) unsubscribed from \(characteristic.uuid.uuidString)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard let value = readValue(for: request.characteristic.uuid) else {
            peripheral.respond(to: request, withResult: .readNotPermitted)
            return
        }
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        for request in requests where request.characteristic.uuid != Self.controlPoint {
            peripheral.respond(to: request, withResult: .writeNotPermitted)
            return
        }
        peripheral.respond(to: first, withResult: .success)
        for request in requests {
            let value = request.value ?? Data()
            let response = controlPointResponse(for: value)
            log("Bridge: control point \(value.map { String(format: "%02X", $0) }.joined()) -> "
                + response.map { String(format: "%02X", $0) }.joined())
            send(response, to: Self.controlPoint)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        let pending = backlog
        backlog.removeAll()
        for (uuid, value) in pending {
            send(value, to: uuid)
        }
    }
}
