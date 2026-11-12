import AppKit
import Carbon.HIToolbox

enum Shortcut: Int, CaseIterable {
    case overlay = 100
    case next
    case archive
    case jumpNumber
    case details
    case one = 1, two, three, four, five, six, seven, eight, nine

    static let numbers = one.rawValue...nine.rawValue

    var keyCode: Int {
        switch self {
        case .overlay: kVK_Space
        case .next: kVK_Return
        case .archive: kVK_ANSI_A
        case .jumpNumber: kVK_ANSI_0
        case .details: kVK_ANSI_D
        case .one: kVK_ANSI_1
        case .two: kVK_ANSI_2
        case .three: kVK_ANSI_3
        case .four: kVK_ANSI_4
        case .five: kVK_ANSI_5
        case .six: kVK_ANSI_6
        case .seven: kVK_ANSI_7
        case .eight: kVK_ANSI_8
        case .nine: kVK_ANSI_9
        }
    }

    var glyph: String {
        switch self {
        case .overlay: "Space"
        case .next: "↵"
        case .archive: "A"
        case .jumpNumber: "0"
        case .details: "D"
        default: String(rawValue)
        }
    }
}

@MainActor
final class Hotkeys {
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private let receive: (Shortcut) -> Void
    private(set) var unavailable: [Shortcut] = []

    init(receive: @escaping (Shortcut) -> Void) {
        self.receive = receive
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let error = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard error == noErr, identifier.signature == 0x52454C59,
                  let key = Shortcut(rawValue: Int(identifier.id)) else { return OSStatus(eventNotHandledErr) }
            let receiver = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { receiver.receive(key) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { unavailable = Shortcut.allCases; return }

        let target = GetApplicationEventTarget()
        for shortcut in Shortcut.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x52454C59, id: UInt32(shortcut.rawValue))
            let error = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(controlKey | optionKey), id, target, 0, &ref)
            if error == noErr, let ref { registrations.append(ref) }
            else { unavailable.append(shortcut) }
        }
    }

    func stop() {
        for ref in registrations { UnregisterEventHotKey(ref) }
        registrations.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
