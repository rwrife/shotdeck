import Testing
@testable import ShotDeckKit

@Suite("Bootstrap contract")
struct BootstrapContractTests {
    @Test("domain namespace is reachable")
    func domainNamespace() {
        #expect(ShotDeckKit.domain == "ShotDeckKit")
    }

    @Test("milestone identifies the domain and coverage slice")
    func milestoneMarker() {
        #expect(ShotDeckKit.milestone == "M2-domain-coverage")
    }
}
