import XCTest

@testable import Minis

/// [B09-V1 2026-10-22] Regression guard for "who speaks".
///
/// The bug this pins is not one wrong branch — it is that FIVE places each kept
/// their own copy of the chain and drifted apart:
///
///   1. VoiceOutputPlayer.resolvedServiceCandidates()   2 tiers
///   2. VoiceServicesView.summarySection.broken          3 tiers (+ "first enabled service")
///   3. AIChatView.voiceSummary / voiceSummaryIsBroken   3 tiers
///   4. TTSPaper.standingCapability / paperText          3 tiers
///   5. AIChatViewModel.resolvedCloudTTSSelection        2 tiers + model group
///
/// Every fix to one copy turned the other four into a lie ("the UI says it can
/// speak, the speaker stays silent"). S-01 came back three times this way.
///
/// These tests can't reach the private view properties, so they assert the two
/// things that MUST hold for all five: the candidate order is one definition,
/// and the "can this service speak" predicate rejects what playback rejects.
@MainActor
final class VoiceChainTests: XCTestCase {

    private let serviceStore = TTSServiceStore.shared
    private let groupStore = TTSGroupStore.shared

    override func tearDown() async throws {
        VoiceOutputPlayer.shared.stopAll()
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeService(name: String, key: String?, enabled: Bool = true) -> TTSServiceOptions {
        let s = TTSServiceOptions(name: name, kind: .openai, enabled: enabled)
        serviceStore.upsert(s)
        if let key { serviceStore.saveAPIKey(key, for: s) }
        return s
    }

    private func cleanup(_ services: [TTSServiceOptions], groups: [String] = []) {
        for id in groups { groupStore.removeGroup(id: id) }
        for s in services { serviceStore.remove(id: s.id) }
    }

    // MARK: - Order

    /// The explicitly ticked service leads; the default group follows.
    /// This is the ONE order — the player, the bubble composer, the settings
    /// summary, the sheet label and the model paper all read it from here.
    func testSelectedServiceLeadsThenDefaultGroup() {
        let previousSelection = serviceStore.selectedServiceId
        let ticked = makeService(name: "ChainTest Ticked", key: "k")
        let member = makeService(name: "ChainTest Member", key: "k")
        let group = groupStore.createGroup(name: "ChainTest Group")
        var updated = group
        updated.memberServiceIds = [member.id]
        groupStore.updateGroup(updated)
        groupStore.setDefaultGroupId(group.id)
        serviceStore.setSelectedServiceId(ticked.id)
        defer {
            serviceStore.setSelectedServiceId(previousSelection)
            cleanup([ticked, member], groups: [group.id])
        }

        let candidates = VoiceChain.serviceCandidates()
        XCTAssertEqual(candidates.first?.id, ticked.id,
                       "the tick in the services list has to mean something")
        XCTAssertEqual(candidates.dropFirst().first?.id, member.id,
                       "the default group is the fallback, not the leader")
    }

    // MARK: - Eligibility

    /// A service with no key is not a candidate — the chain must not name it.
    func testKeylessServiceIsNotACandidate() {
        let previousSelection = serviceStore.selectedServiceId
        let keyless = makeService(name: "ChainTest Keyless", key: nil)
        serviceStore.setSelectedServiceId(keyless.id)
        defer {
            serviceStore.setSelectedServiceId(previousSelection)
            cleanup([keyless])
        }

        XCTAssertFalse(VoiceChain.canSpeak(keyless))
        XCTAssertNil(VoiceChain.selectedService(),
                     "a selected-but-keyless service must not be treated as the speaker")
        XCTAssertTrue(VoiceChain.serviceCandidates().isEmpty)
        XCTAssertNotNil(VoiceChain.silenceReason(),
                        "the UI has to be able to say WHY nothing will speak")
    }

    /// A disabled service is not a candidate either, even with a key.
    func testDisabledServiceIsNotACandidate() {
        let previousSelection = serviceStore.selectedServiceId
        let off = makeService(name: "ChainTest Off", key: "k", enabled: false)
        serviceStore.setSelectedServiceId(off.id)
        defer {
            serviceStore.setSelectedServiceId(previousSelection)
            cleanup([off])
        }

        XCTAssertFalse(VoiceChain.canSpeak(off))
        XCTAssertNil(VoiceChain.selectedService())
    }

    /// "Can speak" must be the same question playback asks, including the
    /// credential SHAPE (iFlytek saved as one segment cannot build a provider).
    func testMalformedCredentialIsNotUsable() {
        var xunfei = TTSServiceOptions(name: "ChainTest Xunfei", kind: .xunfei)
        serviceStore.upsert(xunfei)
        serviceStore.saveAPIKey("only-one-segment", for: xunfei)
        defer { cleanup([xunfei]) }

        XCTAssertTrue(serviceStore.hasAPIKey(for: xunfei), "the key IS stored")
        XCTAssertFalse(VoiceChain.canSpeak(xunfei),
                       "enabled + key is not enough — the vendor has to be able to build a provider")
    }

    /// The group's "N usable services" count must use the same predicate, or the
    /// number on screen disagrees with what the speaker does.
    func testGroupCountUsesTheSamePredicate() {
        let good = makeService(name: "ChainTest Good", key: "k")
        let bad = makeService(name: "ChainTest NoKey", key: nil)
        let group = groupStore.createGroup(name: "ChainTest CountGroup")
        var updated = group
        updated.memberServiceIds = [good.id, bad.id]
        groupStore.updateGroup(updated)
        defer { cleanup([good, bad], groups: [group.id]) }

        // [04b-2 §7] `createGroup` returns a VALUE snapshot taken before the
        // members were added, so asserting against `group` always read an empty
        // member list and this line failed on every run — for three rounds,
        // because CI only ever built the test target and never executed it.
        // Fetch the stored copy instead.
        let stored = groupStore.group(id: group.id) ?? group
        XCTAssertEqual(groupStore.candidates(for: stored).count, 2)
        XCTAssertEqual(groupStore.usableCandidates(for: stored).map { $0.id }, [good.id],
                       "a keyless member must not be counted as usable")
    }
}
