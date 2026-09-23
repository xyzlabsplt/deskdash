import Foundation
import Network

/// Indoor air, from the Dyson purifier's own sensors.
struct IndoorReading: Equatable, Sendable {
    var temperature: Double?  // °C
    var humidity: Double?  // %
    var pm25: Double?  // µg/m³
    var pm10: Double?  // µg/m³
    var voc: Double?  // Dyson index, 0-10
    var no2: Double?  // Dyson index, 0-10
    var co2: Double?  // ppm
    var hcho: Double?  // formaldehyde, mg/m³ (Formaldehyde models only)
    var sensorsOff = false  // the purifier is off and Continuous Monitoring is off
    var updated = Date()

    /// ENVIRONMENTAL-CURRENT-SENSOR-DATA fields, as libdyson reads them: numbers as strings, or "OFF", "INIT",
    /// "FAIL", "NONE" when a sensor has nothing to say. tact is tenths of a kelvin, va10 and noxl are tenths
    /// of an index point, hchr is thousandths of a mg/m³.
    init(sensorData data: [String: Any]) {
        func value(_ key: String, _ divisor: Double = 1) -> Double? {
            var raw = data[key]
            if let pair = raw as? [Any] { raw = pair.last }  // change messages carry [old, new]
            return (raw as? String).flatMap(Double.init).map { $0 / divisor }
        }
        temperature = value("tact", 10).map { $0 - 273.15 }
        humidity = value("hact")
        pm25 = value("p25r") ?? value("pm25")
        pm10 = value("p10r") ?? value("pm10")
        voc = value("va10", 10)
        no2 = value("noxl", 10)
        co2 = value("co2r")
        hcho = value("hchr", 1000)
        sensorsOff = ["tact", "hact", "p25r", "va10"].contains { (data[$0] as? String)?.uppercased() == "OFF" }
    }
}

/// What Settings → Purifier and `deskdash dyson setup` save: enough to log in to the purifier's local MQTT broker.
struct DysonCredentials: Codable, Equatable, Sendable {
    var name: String
    var serial: String  // also the MQTT username
    var productType: String  // "664" for the Big+Quiet (BP02/BP03/BP04)
    var credential: String  // the local MQTT password: base64(sha512(Wi-Fi sticker password)), or from the Dyson cloud

    static func load(from url: URL) -> DysonCredentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DysonCredentials.self, from: data)
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    var statusTopic: String { "\(productType)/\(serial)/status/current" }
    var commandTopic: String { "\(productType)/\(serial)/command" }

    /// The purifier by its Bonjour name (it advertises `<type>_<serial>` as _dyson_mqtt._tcp), so a new DHCP
    /// address does not matter; or a fixed "host" or "host:port" from config.
    func endpoint(host: String) -> NWEndpoint {
        guard !host.isEmpty else {
            return .service(name: "\(productType)_\(serial)", type: "_dyson_mqtt._tcp", domain: "local.", interface: nil)
        }
        if let colon = host.lastIndex(of: ":"), let port = NWEndpoint.Port(String(host[host.index(after: colon)...])) {
            return .hostPort(host: NWEndpoint.Host(String(host[..<colon])), port: port)
        }
        return .hostPort(host: NWEndpoint.Host(host), port: 1883)
    }

    /// Read-only requests; deskdash never sends STATE-SET, so it cannot change what the purifier does. Built by
    /// hand so "msg" comes first, byte for byte what libdyson sends.
    static func request(_ message: String) -> Data {
        Data(#"{"msg": "\#(message)", "time": "\#(Date.now.ISO8601Format())"}"#.utf8)
    }

    static let requestSensors = "REQUEST-PRODUCT-ENVIRONMENT-CURRENT-SENSOR-DATA"
    static let requestState = "REQUEST-CURRENT-STATE"
}

/// Keeps a connection to the purifier's MQTT broker and asks for its sensor data every 30 seconds.
@MainActor
final class DysonService {
    private let dash: Dashboard
    private var config: Config.Dyson?
    private var device: DysonCredentials?
    private var client: MQTTClient?
    private var loop: Task<Void, Never>?
    private var backoff = 5.0
    private var lastProblem = ""
    private var connectedAt: Date?

    init(dash: Dashboard) {
        self.dash = dash
    }

    func apply(_ cfg: Config.Dyson) {
        guard cfg != config else { return }
        config = cfg
        restart()
    }

    /// After Settings connects or forgets a purifier: start over with whatever the credentials file now holds.
    func reload() {
        dash.indoor = nil
        restart()
    }

    private func restart() {
        loop?.cancel()
        client?.stop()
        client = nil
        device = nil
        guard let cfg = config, cfg.enabled else {
            dash.indoor = nil
            return
        }
        loop = Task { await run(cfg) }
    }

    /// Waits for credentials (so `deskdash dyson setup` takes effect within seconds), connects, and
    /// reconnects with backoff. While connected, asks for fresh sensor data every 30 s.
    private func run(_ cfg: Config.Dyson) async {
        let file = Paths.resolve(cfg.credentials)
        while !Task.isCancelled {
            if client == nil {
                if let found = DysonCredentials.load(from: file) {
                    if found != device { log("dyson: using \(found.name) (\(found.productType))") }
                    device = found
                    connect(found, host: cfg.host)
                } else {
                    device = nil
                    note("no credentials at \(file.path); connect the purifier in Settings → Purifier")
                }
            } else if client?.isConnected == true, let device {
                client?.publish(device.commandTopic, DysonCredentials.request(DysonCredentials.requestSensors))
                if dash.indoor == nil, let since = connectedAt, Date().timeIntervalSince(since) > 90 {
                    note("logged in to \(device.name), but it sends no sensor data. If it is switched off, turn on "
                        + "Continuous Monitoring in the Dyson app")
                }
            }
            try? await Task.sleep(for: .seconds(client == nil ? max(backoff, 10) : 30))
        }
    }

    private func connect(_ device: DysonCredentials, host: String) {
        let client = MQTTClient(endpoint: device.endpoint(host: host), username: device.serial,
                                password: device.credential) { [weak self] event in
            self?.handle(event, device)
        }
        self.client = client
        client.start()
    }

    private func handle(_ event: MQTTClient.Event, _ device: DysonCredentials) {
        switch event {
        case .connected:
            backoff = 5
            note("")
            log("dyson: connected to \(device.name)")
            connectedAt = Date()
            client?.subscribe(device.statusTopic)
            client?.publish(device.commandTopic, DysonCredentials.request(DysonCredentials.requestState))
            client?.publish(device.commandTopic, DysonCredentials.request(DysonCredentials.requestSensors))
        case .refused(let code):
            note("\(device.name) refused the login (code \(code)); connect it again in Settings → Purifier")
            backoff = 600  // a wrong password will not fix itself; do not hammer the device
        case .message(_, let payload):
            guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  json["msg"] as? String == "ENVIRONMENTAL-CURRENT-SENSOR-DATA",
                  let data = json["data"] as? [String: Any]
            else { return }
            let reading = IndoorReading(sensorData: data)
            if dash.indoor == nil { log("dyson: \(DysonSetup.summary(reading))") }
            dash.indoor = reading
        case .closed(let reason):
            client = nil
            guard reason != "stopped", !reason.hasPrefix("refused") else { return }
            note("lost \(device.name): \(reason); retrying in \(Int(max(backoff, 10))) s")
            backoff = min(backoff * 2, 300)
        }
    }

    /// Logs a problem once, not on every retry.
    private func note(_ problem: String) {
        guard problem != lastProblem else { return }
        lastProblem = problem
        if !problem.isEmpty { log("dyson: \(problem)") }
    }
}

/// Where the checkout lives, so relative paths in config (secrets/dyson.json, config.json) mean the same
/// thing whichever directory deskdash is started from: the nearest folder above the binary with Package.swift.
enum Paths {
    static let root: URL = {
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let d = dir, d.path != "/" {
            if FileManager.default.fileExists(atPath: d.appendingPathComponent("Package.swift").path) { return d }
            dir = d.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }()

    static func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(expanded)
    }
}
