import ServiceManagement
import XCTest
@testable import LinkGate

// Acceptance Contract mapping:
// Task 1: ServiceManagement status is mapped into LinkGate's domain status; registration is
// requested only when needed; operation outcomes are observed by querying the service again;
// and a noncanonical copy cannot mutate the installed application's registration.
@MainActor
final class LaunchAtLoginServiceTests: XCTestCase {
    func testMapsEveryServiceManagementStatusIntoTheDomainStatus() {
        let cases: [(SMAppService.Status, LaunchAtLoginStatus)] = [
            (.notRegistered, .disabled),
            (.enabled, .enabled),
            (.requiresApproval, .requiresApproval),
            (.notFound, .unavailable),
        ]

        for (rawStatus, expectedStatus) in cases {
            let adapter = LaunchAtLoginAdapterFake(status: rawStatus)
            let service = makeService(adapter: adapter)

            XCTAssertEqual(service.status, expectedStatus, "Unexpected mapping for \(rawStatus).")
        }
    }

    func testEnableWhileDisabledRegistersAndARequeryReportsTheActualNewStatus() throws {
        let adapter = LaunchAtLoginAdapterFake(status: .notRegistered)
        adapter.statusAfterRegister = .enabled
        let service = makeService(adapter: adapter)

        XCTAssertEqual(service.status, .disabled)
        try service.enable()

        XCTAssertEqual(adapter.registerCalls, 1)
        XCTAssertEqual(adapter.unregisterCalls, 0)
        XCTAssertEqual(service.status, .enabled)
        XCTAssertGreaterThanOrEqual(adapter.statusQueryCount, 2)
    }

    func testEnableWhileAlreadyEnabledIsANoOp() throws {
        let adapter = LaunchAtLoginAdapterFake(status: .enabled)
        let service = makeService(adapter: adapter)

        try service.enable()

        XCTAssertEqual(adapter.registerCalls, 0)
        XCTAssertEqual(adapter.unregisterCalls, 0)
        XCTAssertEqual(service.status, .enabled)
    }

    func testDisableWhileEnabledUnregistersAndARequeryReportsTheActualNewStatus() throws {
        let adapter = LaunchAtLoginAdapterFake(status: .enabled)
        adapter.statusAfterUnregister = .notRegistered
        let service = makeService(adapter: adapter)

        XCTAssertEqual(service.status, .enabled)
        try service.disable()

        XCTAssertEqual(adapter.registerCalls, 0)
        XCTAssertEqual(adapter.unregisterCalls, 1)
        XCTAssertEqual(service.status, .disabled)
        XCTAssertGreaterThanOrEqual(adapter.statusQueryCount, 2)
    }

    func testDisableWhileAlreadyDisabledIsANoOp() throws {
        let adapter = LaunchAtLoginAdapterFake(status: .notRegistered)
        let service = makeService(adapter: adapter)

        try service.disable()

        XCTAssertEqual(adapter.registerCalls, 0)
        XCTAssertEqual(adapter.unregisterCalls, 0)
        XCTAssertEqual(service.status, .disabled)
    }

    func testEnableFailureIsSurfacedAndDoesNotPretendRegistrationSucceeded() {
        let expectedError = LaunchAtLoginTestError.registerFailed
        let adapter = LaunchAtLoginAdapterFake(status: .notRegistered, registerError: expectedError)
        let service = makeService(adapter: adapter)

        XCTAssertThrowsError(try service.enable()) { error in
            XCTAssertEqual(error as? LaunchAtLoginTestError, expectedError)
        }

        XCTAssertEqual(adapter.registerCalls, 1)
        XCTAssertEqual(service.status, .disabled)
    }

    func testDisableFailureIsSurfacedAndDoesNotPretendUnregistrationSucceeded() {
        let expectedError = LaunchAtLoginTestError.unregisterFailed
        let adapter = LaunchAtLoginAdapterFake(status: .enabled, unregisterError: expectedError)
        let service = makeService(adapter: adapter)

        XCTAssertThrowsError(try service.disable()) { error in
            XCTAssertEqual(error as? LaunchAtLoginTestError, expectedError)
        }

        XCTAssertEqual(adapter.unregisterCalls, 1)
        XCTAssertEqual(service.status, .enabled)
    }

    func testStatusAlwaysReflectsAnExternalChangeInsteadOfCachingAnEarlierValue() {
        let adapter = LaunchAtLoginAdapterFake(status: .notRegistered)
        let service = makeService(adapter: adapter)

        XCTAssertEqual(service.status, .disabled)
        adapter.rawStatus = .requiresApproval

        XCTAssertEqual(service.status, .requiresApproval)
        XCTAssertEqual(adapter.statusQueryCount, 2)
    }

    func testNoncanonicalCopyCanReportStatusButNeverMutatesRegistration() throws {
        let disabledAdapter = LaunchAtLoginAdapterFake(status: .notRegistered)
        let disabledService = SMAppServiceLaunchAtLoginService(
            adapter: disabledAdapter,
            applicationURL: URL(fileURLWithPath: "/Users/developer/DerivedData/LinkGate.app")
        )
        let enabledAdapter = LaunchAtLoginAdapterFake(status: .enabled)
        let enabledService = SMAppServiceLaunchAtLoginService(
            adapter: enabledAdapter,
            applicationURL: URL(fileURLWithPath: "/Users/developer/DerivedData/LinkGate.app")
        )

        XCTAssertFalse(disabledService.canChangeRegistration)
        XCTAssertEqual(disabledService.status, .disabled)
        XCTAssertNoThrow(try disabledService.enable())
        XCTAssertEqual(disabledAdapter.registerCalls, 0)

        XCTAssertFalse(enabledService.canChangeRegistration)
        XCTAssertEqual(enabledService.status, .enabled)
        XCTAssertNoThrow(try enabledService.disable())
        XCTAssertEqual(enabledAdapter.unregisterCalls, 0)
    }

    func testCanonicalInstalledCopyMayChangeRegistrationAfterPathStandardization() {
        let service = SMAppServiceLaunchAtLoginService(
            adapter: LaunchAtLoginAdapterFake(status: .notRegistered),
            applicationURL: URL(fileURLWithPath: "/Applications/Current/../LinkGate.app")
        )

        XCTAssertTrue(service.canChangeRegistration)
    }

    private func makeService(adapter: LaunchAtLoginAdapterFake) -> SMAppServiceLaunchAtLoginService {
        SMAppServiceLaunchAtLoginService(
            adapter: adapter,
            applicationURL: URL(fileURLWithPath: "/Applications/LinkGate.app")
        )
    }
}

@MainActor
private final class LaunchAtLoginAdapterFake: SMAppServiceAdapter {
    var rawStatus: SMAppService.Status
    var statusAfterRegister: SMAppService.Status?
    var statusAfterUnregister: SMAppService.Status?
    var registerError: Error?
    var unregisterError: Error?
    private(set) var statusQueryCount = 0
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(
        status: SMAppService.Status,
        registerError: Error? = nil,
        unregisterError: Error? = nil
    ) {
        rawStatus = status
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    var status: SMAppService.Status {
        statusQueryCount += 1
        return rawStatus
    }

    func register() throws {
        registerCalls += 1
        if let registerError { throw registerError }
        if let statusAfterRegister { rawStatus = statusAfterRegister }
    }

    func unregister() throws {
        unregisterCalls += 1
        if let unregisterError { throw unregisterError }
        if let statusAfterUnregister { rawStatus = statusAfterUnregister }
    }

    func openLoginItemsSettings() {}
}

private enum LaunchAtLoginTestError: Error, Equatable {
    case registerFailed
    case unregisterFailed
}
