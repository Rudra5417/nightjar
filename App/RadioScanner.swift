import Foundation
import CoreBluetooth
import NightjarCore

/// Node link identifiers, matching firmware/fieldwatch_node. File scope so the
/// nonisolated CoreBluetooth delegate callbacks can read them without actor hops.
enum NodeLink {
    static let service = CBUUID(string: "6f776300-1b2c-4d5e-8a90-000000000001")
    static let tx = CBUUID(string: "6f776301-1b2c-4d5e-8a90-000000000002")
    static let rx = CBUUID(string: "6f776302-1b2c-4d5e-8a90-000000000003")
}

/// CoreBluetooth front end.
///
/// Three jobs, in priority order:
///  1. Listen for every BLE advertisement in range (foreground, duplicates on, so RSSI moves).
///  2. Keep a link to our own sensor node and fold its frames in — that link is what makes
///     Wi-Fi access points and real MAC addresses available on iOS at all.
///  3. Restart the scan with a service filter when the app backgrounds. iOS only delivers
///     background results for services declared in Info.plist (`bluetooth-central`), so an
///     unfiltered background scan silently returns nothing. The node keeps scanning; the
///     phone just holds the link.
///
/// iOS 26 upgrade path: an instantiated `CBManager` plus a running Live Activity retains
/// unfiltered scanning with duplicate reporting in the background. See docs/ios-limits.md.
@MainActor
final class RadioScanner: NSObject, ObservableObject {

    @Published private(set) var radios: [String: Observation] = [:]
    @Published private(set) var nodeState = "no node"
    @Published private(set) var nodeId: String?
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var nodeScanning = false

    /// Called for every fresh observation so the session log can keep up.
    var onObservation: ((Observation) -> Void)?

    private var central: CBCentralManager!
    private var node: CBPeripheral?
    private var nodeRxChar: CBCharacteristic?
    private var nodeSession = NodeSession()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: nil)
    }

    // MARK: - control

    func start() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
    }

    func stop() {
        central.stopScan()
        isScanning = false
    }

    /// iOS will not deliver unfiltered background results; switch to a node-filtered scan.
    func setForeground(_ value: Bool) {
        guard central.state == .poweredOn else { return }
        central.stopScan()
        if value {
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else {
            central.scanForPeripherals(withServices: [NodeLink.service], options: nil)
        }
        isScanning = true
    }

    private func ingest(_ obs: Observation) {
        let key = obs.identityKey
        if var existing = radios[key] {
            // Keep the last real reading: 127 means "no reading this time", not a signal.
            if obs.rssiIsKnown { existing.rssi = obs.rssi }
            existing.heardCount += 1
            existing.lastSeenMs = obs.lastSeenMs ?? existing.lastSeenMs
            if existing.name.isEmpty { existing.name = obs.name }
            if existing.manufacturerId == nil { existing.manufacturerId = obs.manufacturerId }
            if existing.manufacturerDataHex.isEmpty { existing.manufacturerDataHex = obs.manufacturerDataHex }
            if existing.serviceData.isEmpty { existing.serviceData = obs.serviceData }
            if existing.serviceUuids.isEmpty { existing.serviceUuids = obs.serviceUuids }
            if existing.vendorIeOuis.isEmpty { existing.vendorIeOuis = obs.vendorIeOuis }
            radios[key] = existing
        } else {
            radios[key] = obs
        }
        onObservation?(obs)
    }

    // MARK: - advertisement -> Observation

    /// Pure: no instance state touched, so it can run inside a nonisolated delegate callback.
    nonisolated static func observation(from peripheral: CBPeripheral,
                                        advertisementData: [String: Any],
                                        rssi: NSNumber) -> Observation {
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map { $0.uuidString }

        var manufacturerId: Int?
        var manufacturerHex = ""
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 2 {
            // Bluetooth SIG company id: first two bytes, little-endian.
            manufacturerId = Int(mfg[mfg.startIndex]) | (Int(mfg[mfg.startIndex + 1]) << 8)
            manufacturerHex = mfg.dropFirst(2).map { String(format: "%02X", $0) }.joined()
        }

        var serviceData: [ServiceDataRecord] = []
        if let map = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            serviceData = map.map {
                ServiceDataRecord(uuid: $0.key.uuidString,
                                  hex: $0.value.map { String(format: "%02X", $0) }.joined())
            }
        }

        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        return Observation(kind: .ble,
                           mac: nil,                       // iOS never exposes the MAC
                           name: peripheral.name ?? localName ?? "",
                           serviceUuids: serviceUUIDs,
                           manufacturerId: manufacturerId,
                           manufacturerDataHex: manufacturerHex,
                           serviceData: serviceData,
                           rssi: rssi.intValue,
                           platformId: peripheral.identifier.uuidString,
                           lastSeenMs: Int(Date().timeIntervalSince1970 * 1000))
    }

    nonisolated static func isNodeAdvertisement(_ advertisementData: [String: Any]) -> Bool {
        (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).contains(NodeLink.service)
    }

    // MARK: - node commands

    func sendNode(_ command: String) {
        guard let node, let chr = nodeRxChar, let data = command.data(using: .utf8) else { return }
        node.writeValue(data, for: chr, type: .withResponse)
    }

    func startNode() {
        sendNode(NodeFrameDecoder.startCommand(bands: ["2.4", "5"], passive: true))
        nodeScanning = true
    }

    func stopNode() {
        sendNode(NodeFrameDecoder.stopCommand())
        nodeScanning = false
    }
}

// MARK: - CBCentralManagerDelegate

extension RadioScanner: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            self.bluetoothState = state
            if state == .poweredOn { self.start() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let isNode = Self.isNodeAdvertisement(advertisementData)
        let obs = isNode ? nil : Self.observation(from: peripheral,
                                                  advertisementData: advertisementData,
                                                  rssi: RSSI)
        Task { @MainActor in
            if isNode {
                guard self.node == nil else { return }
                self.nodeState = "linking…"
                self.node = peripheral
                peripheral.delegate = self
                central.connect(peripheral, options: nil)
                return
            }
            if let obs { self.ingest(obs) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([NodeLink.service])
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.nodeState = "node dropped — reconnecting"
            self.node = nil
            self.nodeRxChar = nil
            self.nodeScanning = false
            central.connect(peripheral, options: nil)
        }
    }
}

// MARK: - CBPeripheralDelegate (node link)

extension RadioScanner: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == NodeLink.service {
            peripheral.discoverCharacteristics([NodeLink.tx, NodeLink.rx], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        for chr in service.characteristics ?? [] {
            if chr.uuid == NodeLink.tx {
                peripheral.setNotifyValue(true, for: chr)
            } else if chr.uuid == NodeLink.rx {
                Task { @MainActor in self.nodeRxChar = chr }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard characteristic.uuid == NodeLink.tx,
              let data = characteristic.value,
              let text = String(data: data, encoding: .utf8) else { return }
        Task { @MainActor in
            self.nodeSession.feed(text)
            if let info = self.nodeSession.node {
                self.nodeId = info.id
                self.nodeState = "node \(info.id) · fw \(info.fw ?? "?")"
            }
            for obs in self.nodeSession.observations { self.ingest(obs) }
        }
    }
}
