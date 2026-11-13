import XCTest
import AppKit
import Carbon

final class LifecycleTests: XCTestCase {
    func testDefaultWindowTracksAvailableScreenAndOccupiesAboutTwoThirds() {
        for visible in [CGRect(x:0,y:40,width:1512,height:900),CGRect(x:-2560,y:80,width:2560,height:1360)] {
            let frame = WindowSizing.frame(visible:visible,restored:nil,minimum:CGSize(width:760,height:582),upgrade:false)
            XCTAssertEqual(frame.width,visible.width*sqrt(0.65),accuracy:0.001)
            XCTAssertEqual(frame.height,visible.height*sqrt(0.65),accuracy:0.001)
            XCTAssertEqual(frame.midX,visible.midX,accuracy:0.001); XCTAssertEqual(frame.midY,visible.midY,accuracy:0.001)
            XCTAssertTrue(visible.contains(frame)); XCTAssertEqual(frame.width*frame.height/(visible.width*visible.height),0.65,accuracy:0.0001)
        }
    }
    func testWindowSizingUpgradeEnlargesOnlyUndersizedDimensionsOnce() {
        let visible = CGRect(x:0,y:50,width:1800,height:1100), old = CGRect(x:40,y:100,width:1550,height:600)
        let new = WindowSizing.frame(visible:visible,restored:old,minimum:CGSize(width:760,height:582),upgrade:true)
        XCTAssertEqual(new.width,1550); XCTAssertEqual(new.height,1100*sqrt(0.65),accuracy:0.001)
        let manual = CGRect(x:0,y:50,width:900,height:650)
        XCTAssertEqual(WindowSizing.frame(visible:visible,restored:manual,minimum:CGSize(width:760,height:582),upgrade:false),manual)
    }
    func testDisconnectedScreenAndOversizedWindowAreClampedToCurrentScreen() {
        let visible = CGRect(x:100,y:40,width:1200,height:760)
        let frame = WindowSizing.frame(visible:visible,restored:CGRect(x:-3000,y:2000,width:2500,height:1800),minimum:CGSize(width:760,height:582),upgrade:false)
        XCTAssertTrue(visible.contains(frame)); XCTAssertEqual(frame.size,visible.size)
    }
    func testUpgradeDoesNotShrinkAnAlreadyLargeValidCustomWindow() {
        let visible = CGRect(x:0,y:40,width:1600,height:1000)
        let custom = CGRect(x:5,y:45,width:1590,height:990)
        XCTAssertEqual(WindowSizing.frame(visible:visible,restored:custom,minimum:CGSize(width:760,height:582),upgrade:true),custom)
    }
    func testSmallScreensStillContainDefaultFrameWithDesktopMargin() {
        let visible = CGRect(x:0,y:24,width:900,height:650)
        let frame = WindowSizing.frame(visible:visible,restored:nil,minimum:CGSize(width:760,height:582),upgrade:false)
        XCTAssertTrue(visible.contains(frame)); XCTAssertGreaterThan(frame.minX,visible.minX)
        XCTAssertGreaterThan(frame.minY,visible.minY)
    }
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
