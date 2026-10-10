import AppKit
import IOKit

/// The dock screen's own power, over DDC/CI: the panel's "power mode" (VCP 0xD6) set to off turns its backlight off,
/// where drawing black leaves the backlight burning. For `display.powerOff`.
///
/// On Apple silicon DDC goes through IOKit's IOAVService, which is private: MonitorControl and BetterDisplay use it the
/// same way. If the panel does not answer, or a macOS update changes the API, nothing happens and the screen is only
/// drawn black. Each call waits on the I²C bus (tens of milliseconds), so callers keep it off the main thread.
enum DDC {
    typealias Service = CFTypeRef

    @_silgen_name("IOAVServiceCreateWithService")
    private static func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<Service>?
    @_silgen_name("IOAVServiceReadI2C")
    private static func IOAVServiceReadI2C(_ service: Service, _ chip: UInt32, _ offset: UInt32,
                                           _ buffer: UnsafeMutableRawPointer, _ length: UInt32) -> IOReturn
    @_silgen_name("IOAVServiceWriteI2C")
    private static func IOAVServiceWriteI2C(_ service: Service, _ chip: UInt32, _ address: UInt32,
                                            _ buffer: UnsafeMutableRawPointer, _ length: UInt32) -> IOReturn

    private static let powerMode: UInt8 = 0xD6

    /// Turns the panel on or off. True when the panel took the command.
    static func setPower(_ on: Bool, display: CGDirectDisplayID) -> Bool {
        guard let service = service(for: display) else { return false }
        return write(service, powerMode, on ? 1 : 4)  // 4: "DPM off", backlight out, woken by the next command
    }

    /// Whether the panel answers DDC at all, by reading its power mode.
    static func answers(display: CGDirectDisplayID) -> Bool {
        guard let service = service(for: display) else { return false }
        return read(service, powerMode) != nil
    }

    // MARK: finding the display's DDC channel

    /// The display's framebuffer (an IOMobileFramebufferShim, whose DisplayAttributes carry the EDID's numbers) hangs
    /// under a node like "dispext0", and its DDC channel (a DCPAVServiceProxy) under one named "dispext0:dcpav-service-
    /// epic:0". Match the two by that prefix. With a single external display there is no ambiguity, and its channel is
    /// used even when the names do not line up.
    private static func service(for display: CGDirectDisplayID) -> Service? {
        let channels = externalChannels()
        if let unit = framebufferUnit(for: display), let match = channels.first(where: { $0.unit == unit }) {
            return match.service
        }
        return channels.count == 1 ? channels[0].service : nil
    }

    private static func externalChannels() -> [(unit: String, service: Service)] {
        var out: [(String, Service)] = []
        each("DCPAVServiceProxy") { entry in
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External",
                  let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue()
            else { return }
            out.append((unitName(parentOf: entry, separator: ":"), service))
        }
        return out
    }

    private static func framebufferUnit(for display: CGDirectDisplayID) -> String? {
        let (vendor, model, serial) = (CGDisplayVendorNumber(display), CGDisplayModelNumber(display), CGDisplaySerialNumber(display))
        var unit: String?
        each("IOMobileFramebufferShim") { entry in
            guard unit == nil,
                  let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                      .takeRetainedValue() as? [String: Any],
                  let product = attributes["ProductAttributes"] as? [String: Any],
                  (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value == vendor,
                  (product["ProductID"] as? NSNumber)?.uint32Value == model,
                  serial == 0 || (product["SerialNumber"] as? NSNumber)?.uint32Value == serial
            else { return }
            unit = unitName(parentOf: entry, separator: "@")
        }
        return unit
    }

    /// The parent node's name up to `separator`: "dispext0" from "dispext0@28000000" or "dispext0:dcpav-service-epic:0".
    private static func unitName(parentOf entry: io_registry_entry_t, separator: Character) -> String {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return "" }
        defer { IOObjectRelease(parent) }
        var name = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(parent, &name)
        let full = String(cString: name)
        return String(full.split(separator: separator).first ?? Substring(full))
    }

    private static func each(_ className: String, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            body(entry)
            IOObjectRelease(entry)
        }
    }

    // MARK: DDC/CI over I²C (address 0x37, host 0x51, checksum seeded with the display's 0x6E)

    private static func write(_ service: Service, _ vcp: UInt8, _ value: UInt16) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = packet[0..<5].reduce(0x6E ^ 0x51) { $0 ^ $1 }
        for _ in 0..<3 {
            usleep(10_000)
            if IOAVServiceWriteI2C(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess { return true }
        }
        return false
    }

    private static func read(_ service: Service, _ vcp: UInt8) -> UInt16? {
        var request: [UInt8] = [0x82, 0x01, vcp, 0]
        request[3] = request[0..<3].reduce(0x6E ^ 0x51) { $0 ^ $1 }
        var reply = [UInt8](repeating: 0, count: 12)
        for _ in 0..<4 {
            usleep(10_000)
            guard IOAVServiceWriteI2C(service, 0x37, 0x51, &request, UInt32(request.count)) == kIOReturnSuccess else { continue }
            usleep(50_000)
            if IOAVServiceReadI2C(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess, reply[4] == vcp {
                return UInt16(reply[8]) << 8 | UInt16(reply[9])
            }
        }
        return nil
    }
}
