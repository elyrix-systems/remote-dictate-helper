import RemoteDictateCore

private enum TransferProbeError: Error { case injectedFailure, invariant(String) }

private final class TransferProbe: ExplicitClipboardTransferDriver {
    enum Fault: CaseIterable {
        case none, initialValidation, clipboardChangedAfterDisable, disableAppliedThenFailed
        case prepare, send, sendUnavailable, restore, clipboardChangedAfterRestore
    }
    var enabled = true
    var actions: [String] = []
    var sendRequiresPreparation = false
    let fault: Fault
    init(_ fault: Fault = .none) { self.fault = fault }

    func readState() throws -> SharedClipboardMenuState {
        SharedClipboardMenuState(sharedClipboardEnabled: enabled, sendClipboardEnabled:
            !enabled && fault != .sendUnavailable && (!sendRequiresPreparation || actions.contains("prepare")))
    }

    func validateTargetAndClipboard() throws {
        if fault == .initialValidation
            || (fault == .clipboardChangedAfterDisable && !enabled)
            || (fault == .clipboardChangedAfterRestore && actions.contains("on")) {
            throw TransferProbeError.injectedFailure
        }
    }

    func setSharedClipboardEnabled(_ requested: Bool) throws {
        if enabled == requested { return }
        actions.append(requested ? "on" : "off")
        if requested && fault == .restore { throw TransferProbeError.injectedFailure }
        enabled = requested
        if !requested && fault == .disableAppliedThenFailed { throw TransferProbeError.injectedFailure }
    }

    var beforeRestoreSend: (() -> Void)?
    var failRestoredSend = false
    func sendRestoredClipboard(validating validateClipboard: () throws -> Void) throws {
        guard !enabled else { throw TransferProbeError.invariant("Restore send while sharing enabled") }
        beforeRestoreSend?()
        try validateClipboard()
        actions.append("restore-send")
        if failRestoredSend { throw TransferProbeError.injectedFailure }
    }

    func sendClipboard() throws {
        guard !enabled else { throw TransferProbeError.invariant("Send while automatic sharing enabled") }
        actions.append("send")
        if fault == .send { throw TransferProbeError.injectedFailure }
    }

    func prepareClipboard() throws {
        guard !enabled else { throw TransferProbeError.invariant("Clipboard write while sharing enabled") }
        actions.append("prepare")
        if fault == .prepare { throw TransferProbeError.injectedFailure }
    }
}

func testExplicitClipboardTransferRecovery() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw TransferProbeError.invariant(message) }
    }
    let transaction = ExplicitClipboardTransfer()
    for fault in TransferProbe.Fault.allCases {
        let driver = TransferProbe(fault)
        var failure: Error?
        do { try transaction.run(using: driver) } catch { failure = error }
        try check((failure == nil) == (fault == .none), "Unexpected completion for \(fault)")
        try check(driver.actions.filter { $0 == "send" }.count <= 1, "Never retry Send Clipboard")
        if fault == .restore {
            guard let transferError = failure as? ExplicitClipboardTransferError,
                  case .restorationFailed = transferError else {
                throw TransferProbeError.invariant("Failed restoration must be reported explicitly")
            }
            try check(!driver.enabled, "Probe must simulate unsuccessful restore")
        } else {
            try check(driver.enabled, "Original sharing must be restored even after \(fault)")
        }
        if fault == .initialValidation {
            try check(driver.actions.isEmpty, "Invalid initial target/clipboard must not change preferences")
        }
        if [.clipboardChangedAfterDisable, .disableAppliedThenFailed].contains(fault) {
            try check(!driver.actions.contains("send"), "Pre-send failure must not transmit clipboard")
            try check(driver.actions == ["off", "on"], "Ambiguous disable must still restore sharing")
        }
        if fault == .sendUnavailable {
            try check(driver.actions == ["off", "prepare", "on"], "Unavailable Send after preparation must restore sharing without sending")
        }
        if fault == .none {
            try check(driver.actions == ["off", "prepare", "send", "on"], "Write only with sharing off, then send and restore")
        }
        if fault == .prepare {
            try check(driver.actions == ["off", "prepare", "on"], "Write failure must restore sharing without sending")
        }
    }
    let initiallyOff = TransferProbe()
    initiallyOff.enabled = false
    do {
        try transaction.run(using: initiallyOff)
        throw TransferProbeError.invariant("Initially disabled sharing must be rejected")
    } catch ExplicitClipboardTransferError.sharedClipboardInitiallyOff {}
    try check(initiallyOff.actions.isEmpty && !initiallyOff.enabled, "Preserve user's initial off setting")

    let preparedSend = TransferProbe()
    preparedSend.sendRequiresPreparation = true
    try transaction.run(using: preparedSend)
    try check(preparedSend.actions == ["off", "prepare", "send", "on"], "Check Send availability after preparing text")

    // The automatic path keeps sharing off until its caller finishes restoring
    // the local clipboard. Releasing must not validate the old transcript.
    let deferred = TransferProbe(.clipboardChangedAfterRestore)
    let lease = try transaction.begin(using: deferred)
    try check(!deferred.enabled && deferred.actions == ["off", "prepare", "send"], "Keep sharing off through remote paste")
    try lease.restoreSharing()
    try lease.restoreSharing()
    try check(deferred.enabled && deferred.actions == ["off", "prepare", "send", "on"], "Release exactly once without validating the replaced transcript")

    let failedRestore = TransferProbe(.restore)
    let failedLease = try transaction.begin(using: failedRestore)
    for _ in 0..<2 {
        do {
            try failedLease.restoreSharing()
            throw TransferProbeError.invariant("Restoration failure must persist")
        } catch ExplicitClipboardTransferError.restorationFailed {}
    }
    try check(failedRestore.actions == ["off", "prepare", "send", "on"], "Never retry an ambiguous restoration on repeated release")
    try testRestoredClipboardSend()
    try testSharedClipboardSettingTransition()
}

private func testRestoredClipboardSend() throws {
    let driver = TransferProbe()
    let lease = try ExplicitClipboardTransfer().begin(using: driver)
    var validations = 0
    try lease.restoreSharing(sendingRestoredClipboard: { validations += 1 })
    try lease.restoreSharing(sendingRestoredClipboard: { fatalError("No repeated send on release") })
    precondition(validations >= 2)
    precondition(driver.actions == ["off", "prepare", "send", "restore-send", "on"])

    for changedInsideDriver in [false, true] {
        let changed = TransferProbe()
        let lease = try ExplicitClipboardTransfer().begin(using: changed)
        var valid = changedInsideDriver
        changed.beforeRestoreSend = { valid = false }
        do {
            try lease.restoreSharing(sendingRestoredClipboard: {
                if !valid { throw TransferProbeError.injectedFailure }
            })
            fatalError("Changed restore snapshot must not be sent")
        } catch ExplicitClipboardTransferError.restoredClipboardSendFailed {}
        precondition(changed.enabled && changed.actions == ["off", "prepare", "send", "on"])
    }

    for restoreFails in [false, true] {
        let failed = TransferProbe(restoreFails ? .restore : .none)
        failed.failRestoredSend = true
        let lease = try ExplicitClipboardTransfer().begin(using: failed)
        for _ in 0..<2 {
            do {
                try lease.restoreSharing(sendingRestoredClipboard: {})
                fatalError("Failed Send must remain visible")
            } catch let error as ExplicitClipboardTransferError {
                if restoreFails {
                    guard case .restorationFailed = error else { throw error }
                } else {
                    guard case .restoredClipboardSendFailed = error else { throw error }
                }
                precondition(!error.description.contains("No paste shortcut sent"))
            }
        }
        precondition(failed.enabled == !restoreFails)
        precondition(failed.actions == ["off", "prepare", "send", "restore-send", "on"], "No retry after ambiguous Send or restore")
    }
}

private func testSharedClipboardSettingTransition() throws {
    let transition = SharedClipboardSettingTransition()
    var enabled = true
    var toggles = 0
    // An off checkmark is confirmed even while Send remains disabled.
    try transition.run(enabled: false, readState: {
        SharedClipboardMenuState(sharedClipboardEnabled: enabled, sendClipboardEnabled: false)
    }, toggleOnce: { enabled = false; toggles += 1 }, pause: { _ in
        fatalError("Do not wait for Send availability while confirming the setting")
    })
    precondition(!enabled && toggles == 1)
    try transition.run(enabled: false, readState: {
        SharedClipboardMenuState(sharedClipboardEnabled: false, sendClipboardEnabled: false)
    }, toggleOnce: { fatalError("Already-correct setting must not toggle") })

    var time = 0.0
    toggles = 0
    do {
        try transition.run(enabled: false, readState: {
            SharedClipboardMenuState(sharedClipboardEnabled: true, sendClipboardEnabled: false)
        }, toggleOnce: { toggles += 1 }, timeout: 0.04, now: { time }, pause: { time += $0 })
        throw TransferProbeError.invariant("Unconfirmed checkmark must fail")
    } catch let error as SharedClipboardSettingError {
        guard case let .unconfirmed(expected, state) = error else { throw error }
        precondition(!expected && state.sharedClipboardEnabled && !state.sendClipboardEnabled)
        precondition(error.description.contains("requested=false, observed=true"))
    }
    precondition(toggles == 1 && time == 0.04, "Never retry an ambiguous toggle")

    time = 0
    try transition.run(enabled: true, readState: {
        SharedClipboardMenuState(sharedClipboardEnabled: time >= 0.02, sendClipboardEnabled: time < 0.02)
    }, toggleOnce: {}, timeout: 0.04, now: { time }, pause: { time += $0 })
    precondition(time == 0.02, "Confirm an observed restoration as soon as it appears")
}
