import AppleSiliconDDC
import Carbon.HIToolbox
import Darwin
import Foundation

enum AppError: LocalizedError {
    case usage(String)
    case noDisplays
    case displayNotFound(String)
    case sourceInvalid(String)
    case writeFailed(String)
    case configInvalid(String)
    case hotKeyInvalid(String)
    case hotKeyRegistrationFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .configInvalid(let message), .hotKeyInvalid(let message):
            return message
        case .noDisplays:
            return "No DDC-capable external display service was found."
        case .displayNotFound(let name):
            return "No DDC display matched \"\(name)\". Run `ddc-input-hotkeys list`."
        case .sourceInvalid(let source):
            return "Unknown input source \"\(source)\". Run `ddc-input-hotkeys sources`."
        case .writeFailed(let display):
            return "The display \"\(display)\" rejected the DDC input-source command."
        case .hotKeyRegistrationFailed(let hotKey, let status):
            return "Could not register hotkey \(hotKey) (OSStatus \(status))."
        }
    }
}

struct InputSource: Equatable {
    let name: String
    let value: UInt16

    static let known: [InputSource] = [
        InputSource(name: "vga1", value: 0x01),
        InputSource(name: "vga2", value: 0x02),
        InputSource(name: "dvi1", value: 0x03),
        InputSource(name: "dvi2", value: 0x04),
        InputSource(name: "composite1", value: 0x05),
        InputSource(name: "composite2", value: 0x06),
        InputSource(name: "svideo1", value: 0x07),
        InputSource(name: "svideo2", value: 0x08),
        InputSource(name: "component1", value: 0x0C),
        InputSource(name: "component2", value: 0x0D),
        InputSource(name: "component3", value: 0x0E),
        InputSource(name: "displayport1", value: 0x0F),
        InputSource(name: "displayport2", value: 0x10),
        InputSource(name: "hdmi1", value: 0x11),
        InputSource(name: "hdmi2", value: 0x12),
        InputSource(name: "usbc", value: 0x1B)
    ]

    static func parse(_ rawValue: String) throws -> InputSource {
        let normalized = rawValue
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        if let source = known.first(where: { $0.name == normalized }) {
            return source
        }

        let number: UInt16?
        if normalized.hasPrefix("0x") {
            number = UInt16(normalized.dropFirst(2), radix: 16)
        } else {
            number = UInt16(normalized)
        }
        guard let number else {
            throw AppError.sourceInvalid(rawValue)
        }
        return InputSource(name: String(format: "0x%02X", number), value: number)
    }
}

struct HotKeyConfiguration: Codable {
    let key: String
    let modifiers: [String]
    let source: String
}

struct Configuration: Codable {
    let displayName: String?
    let hotkeys: [HotKeyConfiguration]

    static func load(from url: URL) throws -> Configuration {
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(Configuration.self, from: data)
            guard !config.hotkeys.isEmpty else {
                throw AppError.configInvalid("The config must contain at least one hotkey.")
            }
            return config
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.configInvalid("Could not read config at \(url.path): \(error.localizedDescription)")
        }
    }
}

enum DisplayController {
    static func displays() -> [AppleSiliconDDC.IOregService] {
        AppleSiliconDDC.getIoregServicesForMatching().filter { display in
            display.service != nil
                && (!display.productName.isEmpty
                    || !display.edidUUID.isEmpty
                    || !display.ioDisplayLocation.isEmpty)
        }
    }

    static func findDisplay(named displayName: String?) throws -> AppleSiliconDDC.IOregService {
        let available = displays()
        guard !available.isEmpty else {
            throw AppError.noDisplays
        }
        guard let displayName, !displayName.isEmpty else {
            return available[0]
        }
        guard let display = available.first(where: {
            $0.productName.localizedCaseInsensitiveContains(displayName)
                || $0.edidUUID.localizedCaseInsensitiveContains(displayName)
                || $0.ioDisplayLocation.localizedCaseInsensitiveContains(displayName)
        }) else {
            throw AppError.displayNotFound(displayName)
        }
        return display
    }

    static func setInput(_ source: InputSource, displayName: String?) throws {
        let display = try findDisplay(named: displayName)
        let success = AppleSiliconDDC.write(
            service: display.service,
            command: 0x60,
            value: source.value
        )
        guard success else {
            throw AppError.writeFailed(display.productName)
        }
        let displayLabel = display.productName.isEmpty ? display.ioDisplayLocation : display.productName
        print("\(iso8601Now()) set \(displayLabel) input to \(source.name) (\(hex(source.value)))")
        fflush(stdout)
    }
}

struct RegisteredAction {
    let source: InputSource
    let displayName: String?
    let label: String
}

final class HotKeyDaemon {
    static let shared = HotKeyDaemon()

    private var actions: [UInt32: RegisteredAction] = [:]
    private var hotKeyReferences: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    private init() {}

    func run(configuration: Configuration) throws -> Never {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                HotKeyDaemon.shared.handle(event: event)
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard handlerStatus == noErr else {
            throw AppError.hotKeyRegistrationFailed("event handler", handlerStatus)
        }

        for (index, hotKey) in configuration.hotkeys.enumerated() {
            let keyCode = try Self.keyCode(for: hotKey.key)
            let modifiers = try Self.modifierFlags(for: hotKey.modifiers)
            let source = try InputSource.parse(hotKey.source)
            let id = UInt32(index + 1)
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
            var hotKeyReference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyReference
            )
            let label = Self.hotKeyLabel(key: hotKey.key, modifiers: hotKey.modifiers)
            guard status == noErr, let hotKeyReference else {
                throw AppError.hotKeyRegistrationFailed(label, status)
            }
            hotKeyReferences.append(hotKeyReference)
            actions[id] = RegisteredAction(
                source: source,
                displayName: configuration.displayName,
                label: label
            )
            print("Registered \(label) -> \(source.name) (\(hex(source.value)))")
        }
        print("DDC input hotkeys are active. Press Control-C to stop.")
        fflush(stdout)
        RunLoop.main.run()
        fatalError("RunLoop exited unexpectedly")
    }

    private func handle(event: EventRef?) -> OSStatus {
        guard let event else {
            return OSStatus(eventNotHandledErr)
        }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr,
              hotKeyID.signature == Self.signature,
              let action = actions[hotKeyID.id] else {
            return OSStatus(eventNotHandledErr)
        }
        do {
            try DisplayController.setInput(action.source, displayName: action.displayName)
        } catch {
            fputs("\(iso8601Now()) \(action.label): \(error.localizedDescription)\n", stderr)
            fflush(stderr)
        }
        return noErr
    }

    private static let signature: OSType = 0x44444349 // "DDCI"

    static func keyCode(for key: String) throws -> UInt32 {
        let normalized = key.lowercased()
        let keys: [String: Int] = [
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
            "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
            "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
            "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15,
            "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19,
            "f20": kVK_F20
        ]
        guard let value = keys[normalized] else {
            throw AppError.hotKeyInvalid("Unsupported hotkey key \"\(key)\".")
        }
        return UInt32(value)
    }

    static func modifierFlags(for modifiers: [String]) throws -> UInt32 {
        var flags = 0
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "command", "cmd": flags |= cmdKey
            case "control", "ctrl": flags |= controlKey
            case "option", "alt": flags |= optionKey
            case "shift": flags |= shiftKey
            default:
                throw AppError.hotKeyInvalid("Unsupported hotkey modifier \"\(modifier)\".")
            }
        }
        guard flags != 0 else {
            throw AppError.hotKeyInvalid("A global hotkey must have at least one modifier.")
        }
        return UInt32(flags)
    }

    static func hotKeyLabel(key: String, modifiers: [String]) -> String {
        let symbols = modifiers.map { modifier -> String in
            switch modifier.lowercased() {
            case "command", "cmd": return "⌘"
            case "control", "ctrl": return "⌃"
            case "option", "alt": return "⌥"
            case "shift": return "⇧"
            default: return modifier
            }
        }
        return symbols.joined() + key.uppercased()
    }
}

func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func hex(_ value: UInt16) -> String {
    String(format: "0x%02X", value)
}

func optionValue(_ option: String, in arguments: [String]) throws -> String? {
    guard let index = arguments.firstIndex(of: option) else {
        return nil
    }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex else {
        throw AppError.usage("Missing value after \(option).")
    }
    return arguments[valueIndex]
}

func defaultConfigURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DDCInputHotkeys/config.json")
}

let usage = """
Lightweight DDC/CI input-source hotkeys for Apple Silicon Macs.

Usage:
  ddc-input-hotkeys list
  ddc-input-hotkeys sources
  ddc-input-hotkeys set <source-or-code> [--display <name>]
  ddc-input-hotkeys daemon [--config <path>]
  ddc-input-hotkeys self-test

Examples:
  ddc-input-hotkeys set hdmi1 --display RV100mini
  ddc-input-hotkeys set displayport1 --display RV100mini
  ddc-input-hotkeys set 0x1B --display RV100mini

The daemon defaults to:
  ~/Library/Application Support/DDCInputHotkeys/config.json
"""

@main
struct DDCInputHotkeysApp {
    static func main() {
        do {
            try run()
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            throw AppError.usage(usage)
        }

        switch command {
        case "help", "--help", "-h":
            print(usage)
        case "list":
            let displays = DisplayController.displays()
            guard !displays.isEmpty else {
                throw AppError.noDisplays
            }
            for display in displays {
                print("name: \(display.productName.isEmpty ? "(unknown)" : display.productName)")
                print("  vendor: \(display.manufacturerID.isEmpty ? "(unknown)" : display.manufacturerID)")
                print("  transport: \(display.transportUpstream) -> \(display.transportDownstream)")
                print("  edid: \(display.edidUUID)")
            }
        case "sources":
            for source in InputSource.known {
                let paddedName = source.name.padding(
                    toLength: 14,
                    withPad: " ",
                    startingAt: 0
                )
                print("\(paddedName) \(hex(source.value))")
            }
            print("A raw decimal or hexadecimal value such as 0x11 is also accepted.")
        case "set":
            guard arguments.count >= 2 else {
                throw AppError.usage("`set` requires an input source.\n\n\(usage)")
            }
            let source = try InputSource.parse(arguments[1])
            let displayName = try optionValue("--display", in: arguments)
            try DisplayController.setInput(source, displayName: displayName)
        case "daemon":
            let configPath = try optionValue("--config", in: arguments)
            let configURL = configPath.map { URL(fileURLWithPath: $0) } ?? defaultConfigURL()
            let config = try Configuration.load(from: configURL)
            try HotKeyDaemon.shared.run(configuration: config)
        case "self-test":
            try selfTest()
        default:
            throw AppError.usage("Unknown command \"\(command)\".\n\n\(usage)")
        }
    }

    static func selfTest() throws {
        guard try InputSource.parse("HDMI-1").value == 0x11,
              try InputSource.parse("DisplayPort_1").value == 0x0F,
              try InputSource.parse("usb-c").value == 0x1B,
              try InputSource.parse("0x12").value == 0x12,
              try HotKeyDaemon.keyCode(for: "1") == UInt32(kVK_ANSI_1),
              try HotKeyDaemon.modifierFlags(for: ["control", "option"])
                  == UInt32(controlKey | optionKey) else {
            throw AppError.configInvalid("Self-test failed.")
        }

        let json = #"{"displayName":"RV100mini","hotkeys":[{"key":"1","modifiers":["control","option"],"source":"hdmi1"}]}"#
        let config = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
        guard config.displayName == "RV100mini", config.hotkeys.count == 1 else {
            throw AppError.configInvalid("Configuration self-test failed.")
        }
        print("All self-tests passed.")
    }
}
