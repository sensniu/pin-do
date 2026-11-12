import XCTest
import AppKit
import Carbon

final class LifecycleTests: XCTestCase {
    @MainActor
    private func qEvent(_ type: NSEvent.EventType, time: TimeInterval) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: time,
                         windowNumber: 0, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!
    }
    @MainActor
    func testNativeQuitEventsRequireConfirmationAndPreserveLongRelease() {
        var exits = 0, prompts = 0
        let controller = QuitController(prompt: { prompts += 1 })
        controller.confirmed = { exits += 1 }
        XCTAssertNil(controller.handle(qEvent(.keyDown, time: 10)))
        XCTAssertNotNil(controller.handle(qEvent(.keyUp, time: 10.1)))
        XCTAssertEqual(exits, 0); XCTAssertEqual(prompts, 1)
        XCTAssertNil(controller.handle(qEvent(.keyDown, time: 11)))
        XCTAssertEqual(exits, 1)
        XCTAssertNil(controller.handle(qEvent(.keyDown, time: 20)))
        XCTAssertNil(controller.handle(qEvent(.keyUp, time: 21.4)))
        XCTAssertEqual(exits, 2)
        controller.cancel()
    }
    @MainActor
    func testNativeQuitHoldTimerConfirmsWithoutSecondPress() async throws {
        var exits = 0
        let controller = QuitController(prompt: {})
        controller.confirmed = { exits += 1 }
        _ = controller.handle(qEvent(.keyDown, time: ProcessInfo.processInfo.systemUptime))
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(exits, 1)
        controller.cancel()
    }
    func testQuitRequiresDistinctSecondPressWithinInterval() {
        var gesture = QuitGesture()
        XCTAssertFalse(gesture.press(at: 10))
        XCTAssertFalse(gesture.press(at: 10.1, isRepeat: true))
        XCTAssertFalse(gesture.press(at: 10.2)) // Not released, so still the same physical press.
        gesture.release()
        XCTAssertTrue(gesture.press(at: 11))
        XCTAssertNil(gesture.armedUntil)
        XCTAssertNil(gesture.pressedAt)
    }
    func testQuitTimeoutStartsNewAttemptAndReleasingStopsHold() {
        var gesture = QuitGesture()
        XCTAssertFalse(gesture.press(at: 1))
        XCTAssertFalse(gesture.heldLongEnough(at: 1.9))
        gesture.release()
        XCTAssertFalse(gesture.heldLongEnough(at: 10))
        XCTAssertFalse(gesture.press(at: 3))
        XCTAssertTrue(gesture.heldLongEnough(at: 4))
        gesture.cancel()
        XCTAssertFalse(gesture.heldLongEnough(at: 100))
        XCTAssertFalse(gesture.press(at: 4.1)) // Focus loss/cancellation disarms the double press too.
    }
    func testOnlyExplicitAndLoginBackgroundLaunchesHideWindow() {
        XCTAssertTrue(ApplicationLaunchPolicy.showsWindow(isLoginItem: false, backgroundRequested: false))
        XCTAssertFalse(ApplicationLaunchPolicy.showsWindow(isLoginItem: true, backgroundRequested: false))
        XCTAssertFalse(ApplicationLaunchPolicy.showsWindow(isLoginItem: false, backgroundRequested: true))
    }
    func testReleaseConfirmsLongHoldEvenWhenTimerWasDelayed() {
        var gesture = QuitGesture()
        XCTAssertFalse(gesture.press(at: 10))
        XCTAssertTrue(gesture.release(at: 11.3))
        gesture.cancel()
        XCTAssertFalse(gesture.press(at: 20))
        XCTAssertFalse(gesture.release(at: 20.4))
        XCTAssertFalse(gesture.heldLongEnough(at: 21.3))
    }
    @MainActor
    func testLoginAppleEventIsDistinguishedFromOrdinaryOpen() {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertFalse(ApplicationLaunchPolicy.isLoginEvent(event))
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertTrue(ApplicationLaunchPolicy.isLoginEvent(event))
        XCTAssertFalse(ApplicationLaunchPolicy.isLoginEvent(nil))
    }

    @MainActor
    final class LoginService: LoginItemService {
        var status: LoginItemStatus = .off
        var registrations = 0, removals = 0
        var requiresApproval = false, fails = false
        func register() throws {
            registrations += 1
            if fails { throw CocoaError(.featureUnsupported) }
            status = requiresApproval ? .requiresApproval : .enabled
        }
        func unregister() throws { removals += 1; status = .off }
    }
    @MainActor
    func testLoginDefaultsOffAndMerelyOpeningDoesNotRegister() {
        let service = LoginService()
        let controller = LoginItemController(service: service, canConfigure: true)
        controller.refresh()
        XCTAssertEqual(controller.status, .off)
        XCTAssertEqual(service.registrations, 0)
        controller.setEnabled(true); controller.setEnabled(true)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertEqual(service.registrations, 1)
        controller.setEnabled(false)
        XCTAssertEqual(controller.status, .off)
        XCTAssertEqual(service.removals, 1)
    }
    @MainActor
    func testLoginReportsApprovalAndFailureWithoutPretendingEnabled() {
        let service = LoginService(); service.requiresApproval = true
        let controller = LoginItemController(service: service, canConfigure: true)
        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .requiresApproval)
        controller.setEnabled(false)
        service.fails = true; controller.setEnabled(true)
        XCTAssertEqual(controller.status, .off)
        XCTAssertNotNil(controller.error)
    }
    @MainActor
    func testPreviewAndUninstalledBuildNeverChangeSystemLoginItems() {
        let service = LoginService()
        let controller = LoginItemController(service: service, canConfigure: false)
        controller.setEnabled(true)
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(controller.status, .off)
        XCTAssertNotNil(controller.error)
    }
}
