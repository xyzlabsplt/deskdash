import CommonCrypto
import CryptoKit
import Foundation
import Network

/// Connecting the Dyson purifier: find it on the network, get its local MQTT password (from the Wi-Fi sticker, or a
/// one-time Dyson account login), prove it by reading the sensors once, and save it to secrets/dyson.json. Settings →
/// Purifier runs these steps with the secrets typed into its window; `deskdash dyson setup | test [--host HOST]` runs
/// them in a terminal. The account password and login token are used once and never stored, printed or logged.
@MainActor
enum DysonSetup {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func main(_ args: [String]) async -> Int32 {
        var args = args[...]
        let command = args.popFirst() ?? "help"
        var host = "", configPath: String?
        while let arg = args.popFirst() {
            switch (arg, args.popFirst()) {
            case ("--host", let value?): host = value
            case ("--config", let value?): configPath = value
            default:
                print("usage: deskdash dyson setup | test [--host HOST[:PORT]] [--config FILE]")
                return 2
            }
        }
        let config = ConfigStore(path: configPath).load().config ?? Config()
        let file = Paths.resolve(config.dyson.credentials)
        do {
            switch command {
            case "setup": try await setup(file: file, host: host.isEmpty ? config.dyson.host : host)
            case "test": try await test(file: file, host: host.isEmpty ? config.dyson.host : host)
            default:
                print("usage: deskdash dyson setup | test [--host HOST]")
                return 2
            }
            return 0
        } catch {
            print("\n\(error)")
            return 1
        }
    }

    // MARK: setup

    private static func setup(file: URL, host: String) async throws {
        print("Looking for Dyson devices on this network...")
        let found = await discover()
        for device in found { print("  found \(device.productType) \(device.serial)") }
        if found.isEmpty { print("  none answered (Bonjour). The Wi-Fi sticker route still works; so does --host.") }

        print("""

        deskdash needs the purifier's local password. Two ways to get it:
          1. From the Wi-Fi sticker on the purifier (also on the back of the manual). No Dyson account involved.
          2. From your Dyson account: your email, a one-time code Dyson emails you, and your account password,
             which is used once for that login and never saved.
        """)
        var device: DysonCredentials
        switch ask("Choose 1 or 2: ") {
        case "1": device = try fromSticker(found)
        case "2": device = try await fromAccount(found)
        default: throw Failure("Nothing chosen; nothing saved.")
        }

        print("Testing the connection to \(device.serial)...")
        let result = await testAndSave(device, host: host, to: file)
        guard result.saved else { throw Failure(result.message) }
        print(result.message)
        print("Saved \(file.path) (readable only by you). The dashboard picks it up within 10 seconds.")
    }

    private static func test(file: URL, host: String) async throws {
        guard let device = DysonCredentials.load(from: file) else {
            throw Failure("No credentials at \(file.path). Connect the purifier in Settings → Purifier, or run: deskdash dyson setup")
        }
        print("Reading \(device.name) (\(device.serial))...")
        switch await probe(device, host: host) {
        case .reading(let reading): print(summary(reading))
        case .loggedInNoData(let seen):
            throw Failure("Logged in, but no sensor readings within 30 s"
                + (seen.isEmpty ? "; the purifier sent nothing." : "; it sent: \(seen.joined(separator: ", ")).")
                + " If it is switched off, turn on Continuous Monitoring in the Dyson app.")
        case .refused(let code): throw Failure("The purifier refused the saved password (MQTT code \(code)). Connect it again in Settings → Purifier, or run: deskdash dyson setup")
        case .unreachable(let reason): throw Failure("Could not reach the purifier: \(reason).")
        }
    }

    private static func fromSticker(_ found: [DysonCredentials]) throws -> DysonCredentials {
        var target = found.count == 1 ? found[0] : nil
        if target == nil {
            let ssid = ask("Product Wi-Fi name (SSID) from the sticker, like DYSON-XXX-XX-XXXXXXXX-664: ")
            guard let named = device(ssid: ssid) else { throw Failure("That does not look like a Dyson SSID.") }
            target = named
        }
        guard var device = target else { throw Failure("No device.") }
        guard let password = secret("Product Wi-Fi password from the sticker (typing is hidden): "), !password.isEmpty else {
            throw Failure("No password entered; nothing saved.")
        }
        device.credential = credential(stickerPassword: password)
        return device
    }

    private static func fromAccount(_ found: [DysonCredentials]) async throws -> DysonCredentials {
        var email = ""
        for _ in 0..<3 where !isEmail(email) {
            if !email.isEmpty { print("That is not a full email address (it needs the @ and domain).") }
            email = ask("Dyson account email: ")
        }
        guard isEmail(email) else { throw Failure("No email address entered; nothing saved.") }
        let entered = ask("Account country code [\(defaultCountry)]: ").uppercased()
        let challenge = try await requestCode(email: email, country: entered.isEmpty ? defaultCountry : entered)
        print("Dyson has emailed a one-time code to \(email).")
        let otp = ask("Code from the email: ")
        guard let password = secret("Dyson account password (typing is hidden): "), !password.isEmpty else {
            throw Failure("No password entered; nothing saved.")
        }
        let token = try await signIn(email: email, password: password, challenge: challenge, code: otp)
        let candidates = try await accountDevices(token: token)
        print("Devices on the account: " + candidates.map { "\($0.name) (\($0.serial))" }.joined(separator: ", "))
        return match(candidates, found: found) ?? candidates[0]
    }

    // MARK: steps, shared with Settings → Purifier

    /// The sticker's product Wi-Fi name, "DYSON-<serial>-<type>", names the purifier: the serial is also its MQTT
    /// username, and the type prefixes its topics.
    static func device(ssid: String) -> DysonCredentials? {
        let parts = ssid.trimmingCharacters(in: .whitespaces).split(separator: "-").map(String.init)
        guard parts.count >= 5, parts[0].uppercased() == "DYSON" else { return nil }
        return DysonCredentials(name: "Dyson \(parts[4])", serial: parts[1...3].joined(separator: "-"),
                                productType: parts[4], credential: "")
    }

    /// The local MQTT password is base64(sha512(the sticker's Wi-Fi password)).
    static func credential(stickerPassword: String) -> String {
        Data(SHA512.hash(data: Data(stickerPassword.utf8))).base64EncodedString()
    }

    static func isEmail(_ text: String) -> Bool { text.contains("@") && text.contains(".") }

    /// The account's country, as Dyson's API wants it: this Mac's region.
    static var defaultCountry: String { Locale.current.region?.identifier ?? "US" }

    /// Dyson's app API, as libdyson-neon uses it: an app check, the account's status, then a one-time code emailed to
    /// the account. Returns the challenge that `signIn` answers.
    static func requestCode(email: String, country: String) async throws -> String {
        let (provisioned, _) = try await call("GET", "/v1/provisioningservice/application/Android/version")
        guard provisioned == 200 else { throw Failure("Dyson's API refused the app check (HTTP \(provisioned)).") }
        let (statusCode, statusBody) = try await call("POST", "/v3/userregistration/email/userstatus",
                                                      query: ["country": country], body: ["email": email])
        let status = json(statusBody)?["accountStatus"] as? String
        guard statusCode == 200, status == "ACTIVE" else {
            throw Failure(statusCode == 400
                ? "Dyson rejected that email address (HTTP 400). Use the full address you sign in to the Dyson app with."
                : "Dyson does not see an active account for that email in \(country) (HTTP \(statusCode), \(status ?? "no status")).")
        }
        let (authCode, authBody) = try await call("POST", "/v3/userregistration/email/auth",
                                                  query: ["country": country, "culture": "en-US"], body: ["email": email])
        if authCode == 429 { throw Failure("Dyson says too many codes were requested. Wait a few minutes and retry.") }
        guard authCode == 200, let challenge = json(authBody)?["challengeId"] as? String else {
            throw Failure("Dyson did not send a code (HTTP \(authCode)).")
        }
        return challenge
    }

    /// Answers `requestCode`'s challenge with the emailed code and the account password; returns a login token.
    static func signIn(email: String, password: String, challenge: String, code: String) async throws -> String {
        let (verifyCode, verifyBody) = try await call("POST", "/v3/userregistration/email/verify", body: [
            "email": email, "password": password, "challengeId": challenge, "otpCode": code,
        ])
        guard verifyCode == 200, let token = json(verifyBody)?["token"] as? String else {
            throw Failure(verifyCode == 400 || verifyCode == 401 || verifyCode == 403
                ? "Dyson rejected the code or the password." : "Dyson login failed (HTTP \(verifyCode)).")
        }
        return token
    }

    /// The account's devices from its device manifest, whose LocalCredentials hold each one's MQTT password.
    static func accountDevices(token: String) async throws -> [DysonCredentials] {
        let (manifestCode, manifestBody) = try await call("GET", "/v2/provisioningservice/manifest", token: token)
        guard manifestCode == 200,
              let devices = (try? JSONSerialization.jsonObject(with: manifestBody)) as? [[String: Any]]
        else { throw Failure("Could not read the devices on the account (HTTP \(manifestCode)).") }

        let candidates: [DysonCredentials] = devices.compactMap { raw in
            guard let serial = raw["Serial"] as? String, let secret = raw["LocalCredentials"] as? String,
                  let credential = decryptLocalCredentials(secret)
            else { return nil }
            return DysonCredentials(name: raw["Name"] as? String ?? serial, serial: serial,
                                    productType: raw["ProductType"] as? String ?? "", credential: credential)
        }
        guard !candidates.isEmpty else { throw Failure("No devices with local credentials on this account.") }
        return candidates
    }

    /// The account's device that answered on this network, with the type it advertises there, which is what the
    /// MQTT topics use.
    static func match(_ candidates: [DysonCredentials], found: [DysonCredentials]) -> DysonCredentials? {
        guard var device = candidates.first(where: { c in found.contains { $0.serial == c.serial } }) else { return nil }
        device.productType = found.first { $0.serial == device.serial }?.productType ?? device.productType
        return device
    }

    /// Proves `device`'s password by reading the sensors once, then saves it to `file`, unless the purifier refused
    /// it. One that cannot be reached is saved anyway: the dashboard keeps trying, and says in its log if the
    /// purifier ever refuses it.
    static func testAndSave(_ device: DysonCredentials, host: String, to file: URL) async -> (saved: Bool, message: String) {
        let message: String
        switch await probe(device, host: host) {
        case .reading(let reading):
            message = "Connected. \(summary(reading))"
        case .loggedInNoData(let seen):
            message = "Logged in, so the password works. But the purifier sent no sensor readings within 30 s"
                + (seen.isEmpty ? " (it sent nothing at all)." : " (it sent: \(seen.joined(separator: ", "))).")
                + "\nIf it is switched off, turn on Continuous Monitoring in the Dyson app so its sensors keep"
                + " reporting. The dashboard asks again every 30 s."
        case .refused(let code):
            return (false, "The purifier refused the password (MQTT code \(code)). Nothing saved. If you used the"
                + " sticker, check it for typos, or try the Dyson account route.")
        case .unreachable(let reason):
            message = "Could not reach the purifier to test the password: \(reason). Saved it anyway: the dashboard"
                + " keeps trying, and its log says if the purifier ever refuses it."
        }
        do {
            try device.save(to: file)
        } catch {
            return (false, "Could not save \(file.path): \(error.localizedDescription)")
        }
        return (true, message)
    }

    // MARK: pieces

    /// Dyson devices advertise `<type>_<serial>` as _dyson_mqtt._tcp over Bonjour.
    static func discover(seconds: Double = 4) async -> [DysonCredentials] {
        let results = Results()
        let browser = NWBrowser(for: .bonjour(type: "_dyson_mqtt._tcp", domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { found, _ in
            MainActor.assumeIsolated {
                results.names = found.compactMap { result in
                    if case .service(let name, _, _, _) = result.endpoint { return name }
                    return nil
                }
            }
        }
        browser.start(queue: .main)
        try? await Task.sleep(for: .seconds(seconds))
        browser.cancel()
        return results.names.compactMap { name in
            guard let cut = name.firstIndex(of: "_") else { return nil }
            let type = String(name[..<cut]), serial = String(name[name.index(after: cut)...])
            return DysonCredentials(name: "Dyson \(type)", serial: serial, productType: type, credential: "")
        }
    }

    @MainActor private final class Results {
        var names: [String] = []
    }

    enum ProbeOutcome {
        case reading(IndoorReading)
        case loggedInNoData(seen: [String])  // the password works; the sensors said nothing
        case refused(UInt8)
        case unreachable(String)
    }

    /// Logs in, asks for state and sensor data (as libdyson does), and reports how far it got.
    static func probe(_ device: DysonCredentials, host: String, timeout: Double = 30) async -> ProbeOutcome {
        let probe = Probe()
        return await withCheckedContinuation { continuation in
            probe.continuation = continuation
            let client = MQTTClient(endpoint: device.endpoint(host: host), username: device.serial,
                                    password: device.credential) { [probe] event in
                switch event {
                case .connected:
                    probe.loggedIn = true
                    probe.client?.subscribe(device.statusTopic)
                    probe.client?.publish(device.commandTopic, DysonCredentials.request(DysonCredentials.requestState))
                    probe.client?.publish(device.commandTopic, DysonCredentials.request(DysonCredentials.requestSensors))
                case .refused(let code):
                    probe.finish(.refused(code))
                case .message(let topic, let payload):
                    let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
                    let kind = json?["msg"] as? String ?? "\(payload.count) bytes that are not JSON"
                    var label = topic == device.statusTopic ? kind : "\(kind) on \(topic)"
                    if kind == "CURRENT-STATE", let state = json?["product-state"] as? [String: Any] {
                        // fpwr: power, rhtm: Continuous Monitoring; values are "ON"/"OFF" or [old, new].
                        func field(_ key: String) -> String { ((state[key] as? [Any])?.last ?? state[key]) as? String ?? "?" }
                        label += " (power \(field("fpwr")), continuous monitoring \(field("rhtm")))"
                    }
                    probe.seen.append(label)
                    if kind == "ENVIRONMENTAL-CURRENT-SENSOR-DATA", let data = json?["data"] as? [String: Any] {
                        probe.finish(.reading(IndoorReading(sensorData: data)))
                    }
                case .closed(let reason):
                    probe.finish(probe.loggedIn ? .loggedInNoData(seen: probe.seen + ["then it closed: \(reason)"])
                                                : .unreachable(reason))
                }
            }
            probe.client = client
            client.start()
            Task { [probe] in
                try? await Task.sleep(for: .seconds(timeout))
                let stage = probe.client?.progress ?? "not started"
                probe.finish(probe.loggedIn ? .loggedInNoData(seen: probe.seen)
                                            : .unreachable("no answer within \(Int(timeout)) s (\(stage))"))
            }
        }
    }

    @MainActor private final class Probe {
        var continuation: CheckedContinuation<ProbeOutcome, Never>?
        var client: MQTTClient?
        var loggedIn = false
        var seen: [String] = []

        func finish(_ outcome: ProbeOutcome) {
            guard let continuation else { return }
            self.continuation = nil
            let client = self.client
            self.client = nil
            client?.stop()
            continuation.resume(returning: outcome)
        }
    }

    static func summary(_ r: IndoorReading) -> String {
        if r.sensorsOff { return "The sensors are off: turn on Continuous Monitoring in the Dyson app so they report while it is off." }
        var parts: [String] = []
        if let t = r.temperature { parts.append(String(format: "%.1f °C", t)) }
        if let h = r.humidity { parts.append("\(Int(h))% humidity") }
        if let c = r.co2 { parts.append("CO2 \(Int(c)) ppm") }
        if let p = r.pm25 { parts.append("PM2.5 \(Int(p)) µg/m³") }
        if let v = r.voc { parts.append(String(format: "VOC %.1f", v)) }
        if let n = r.no2 { parts.append(String(format: "NO2 %.1f", n)) }
        if let f = r.hcho { parts.append(String(format: "HCHO %.3f mg/m³", f)) }
        return parts.isEmpty ? "No sensor values yet (warming up?)." : "Inside: " + parts.joined(separator: ", ")
    }

    /// LocalCredentials is AES-256-CBC with Dyson's fixed key (bytes 1...32) and a zero IV; the plaintext is
    /// JSON whose apPasswordHash is the MQTT password.
    private static func decryptLocalCredentials(_ base64: String) -> String? {
        guard let encrypted = Data(base64Encoded: base64), encrypted.count % kCCBlockSizeAES128 == 0 else { return nil }
        let key = Data((1...32).map { UInt8($0) })
        let iv = Data(count: kCCBlockSizeAES128)
        var plain = Data(count: encrypted.count)
        var produced = 0
        let status = plain.withUnsafeMutableBytes { out in
            encrypted.withUnsafeBytes { input in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0, k.baseAddress, key.count,
                                v.baseAddress, input.baseAddress, encrypted.count, out.baseAddress, out.count, &produced)
                    }
                }
            }
        }
        guard status == kCCSuccess, produced > 0 else { return nil }
        plain.count = produced
        let pad = Int(plain[plain.count - 1])  // PKCS#7, removed leniently the way libdyson does
        if pad > 0, pad <= plain.count { plain.removeLast(pad) }
        return (json(plain))?["apPasswordHash"] as? String
    }

    private static func call(_ method: String, _ path: String, query: [String: String] = [:],
                             body: [String: String]? = nil, token: String? = nil) async throws -> (Int, Data) {
        var url = URLComponents(string: "https://appapi.cp.dyson.com" + path)!
        if !query.isEmpty { url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: url.url!, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("android client", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            throw Failure("Could not reach Dyson's servers: \(error.localizedDescription)")
        }
    }

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func ask(_ prompt: String) -> String {
        print(prompt, terminator: "")
        fflush(stdout)
        return (readLine() ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// Reads from the terminal with echo off; refuses to read a secret from a pipe.
    private static func secret(_ prompt: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        defer { _ = buffer.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard let line = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) else { return nil }
        return String(cString: line)
    }
}
