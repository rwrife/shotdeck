import Testing
@testable import ShotDeckKit

@Suite("Bootstrap contract")
struct BootstrapContractTests {
    @Test("domain namespace is reachable")
    func domainNamespace() {
        #expect(ShotDeckKit.domain == "ShotDeckKit")
    }

    @Test("milestone identifies the native bootstrap")
    func milestoneMarker() {
        #expect(ShotDeckKit.milestone == "M1-native-bootstrap")
    }
}
