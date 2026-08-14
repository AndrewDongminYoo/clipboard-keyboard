import Carbon.HIToolbox
import Foundation

struct GlobalShortcutModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt32

    static let command = Self(rawValue: UInt32(cmdKey))
    static let option = Self(rawValue: UInt32(optionKey))
    static let shift = Self(rawValue: UInt32(shiftKey))
    static let control = Self(rawValue: UInt32(controlKey))
}

struct GlobalShortcutDefinition: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: GlobalShortcutModifiers

    static let defaultPalette = Self(keyCode: UInt32(kVK_ANSI_V), modifiers: [.command, .option])
}

enum GlobalShortcutRegistrationResult: Sendable {
    case success
    case conflict
}

@MainActor
protocol GlobalShortcutRegistering: AnyObject {
    func register(
        _ definition: GlobalShortcutDefinition,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> GlobalShortcutRegistrationResult
    func unregister()
}

@MainActor
final class GlobalPaletteShortcut: ObservableObject {
    @Published private(set) var current: GlobalShortcutDefinition = .defaultPalette
    @Published private(set) var conflictMessage: String?

    private let registrar: any GlobalShortcutRegistering
    private var handler: @MainActor @Sendable () -> Void = {}

    init(registrar: any GlobalShortcutRegistering = CarbonGlobalShortcutRegistrar()) {
        self.registrar = registrar
    }

    func setHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
    }

    @discardableResult
    func registerDefault() -> Bool {
        register(.defaultPalette)
    }

    @discardableResult
    func update(to definition: GlobalShortcutDefinition) -> Bool {
        register(definition)
    }

    private func register(_ definition: GlobalShortcutDefinition) -> Bool {
        switch registrar.register(definition, handler: handler) {
        case .success:
            current = definition
            conflictMessage = nil
            return true
        case .conflict:
            conflictMessage = "Shortcut is already in use"
            return false
        }
    }

    deinit {
        MainActor.assumeIsolated { registrar.unregister() }
    }
}

private final class HotKeyCallbackBox: @unchecked Sendable {
    let handler: @MainActor @Sendable () -> Void
    init(handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
    }
}

private let carbonHotKeyHandler: EventHandlerUPP = { _, _, context in
    guard let context else { return noErr }
    let box = Unmanaged<HotKeyCallbackBox>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { box.handler() }
    return noErr
}

@MainActor
final class CarbonGlobalShortcutRegistrar: GlobalShortcutRegistering {
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var callbackBox: Unmanaged<HotKeyCallbackBox>?

    func register(
        _ definition: GlobalShortcutDefinition,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> GlobalShortcutRegistrationResult {
        let newBox = Unmanaged.passRetained(HotKeyCallbackBox(handler: handler))
        var newEventHandler: EventHandlerRef?
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyHandler,
            1,
            &eventType,
            newBox.toOpaque(),
            &newEventHandler
        )
        guard handlerStatus == noErr else {
            newBox.release()
            return .conflict
        }

        var newHotKey: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x434B_504C), id: 1)
        let registrationStatus = RegisterEventHotKey(
            definition.keyCode,
            definition.modifiers.rawValue,
            identifier,
            GetApplicationEventTarget(),
            0,
            &newHotKey
        )
        guard registrationStatus == noErr, let newHotKey else {
            if let newEventHandler {
                RemoveEventHandler(newEventHandler)
            }
            newBox.release()
            return .conflict
        }

        unregister()
        eventHandler = newEventHandler
        hotKey = newHotKey
        callbackBox = newBox
        return .success
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        callbackBox?.release()
        hotKey = nil
        eventHandler = nil
        callbackBox = nil
    }

    deinit {
        MainActor.assumeIsolated { unregister() }
    }
}
