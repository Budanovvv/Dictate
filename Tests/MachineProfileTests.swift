import XCTest

/// The hardware gates as pure functions of a machine profile — the matrix
/// from internal/PLAN-machine-profile.md, one row per Mac the app is likely
/// to meet. The point of the table: an 8 GB Apple Silicon Mac is never
/// offered the meeting model and never runs one that is somehow installed,
/// whatever chip generation it has, and the agent is available on every row.
final class MachineProfileTests: XCTestCase {
    // The copy under test is localized; the assertions read it in English.
    // The picker's language is real app state — saved and put back.
    private var savedLanguage: AppLanguage = .system

    override func setUp() {
        super.setUp()
        savedLanguage = Localization.shared.language
        Localization.shared.setLanguage(.en)
    }

    override func tearDown() {
        Localization.shared.setLanguage(savedLanguage)
        super.tearDown()
    }

    private func mac(_ gb: Int, appleSilicon: Bool = true, chip: String = "Apple M2") -> MachineProfile {
        MachineProfile(modelIdentifier: "Mac14,2", chipName: chip, isAppleSilicon: appleSilicon,
                       memoryBytes: Int64(gb) << 30,
                       macOSVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0))
    }

    // MARK: - The floor

    func testEightGigabytesIsBelowTheFloorWhateverTheChip() {
        for chip in ["Apple M1", "Apple M2", "Apple M3", "Apple M4", "Apple M5"] {
            let profile = mac(8, chip: chip)
            XCTAssertFalse(LocalTextModelFile.hasEnoughMemory(profile.memoryBytes), chip)
            XCTAssertFalse(LocalTextModelFile.isRunnable(memory: profile.memoryBytes, supported: true), chip)
            if case .unavailable(let reason, let instead) =
                LocalTextModelFile.verdict(on: profile, supported: true, appleIntelligence: .on) {
                XCTAssertTrue(reason.contains("16"), reason)
                XCTAssertTrue(reason.contains("8"), reason)
                XCTAssertFalse(instead.isEmpty)
            } else {
                XCTFail("an 8 GB Mac must not be offered the model (\(chip))")
            }
        }
    }

    func testExactlySixteenGigabytesPasses() {
        XCTAssertTrue(LocalTextModelFile.hasEnoughMemory(16 << 30))
        XCTAssertTrue(LocalTextModelFile.isMemoryTight(16 << 30))
        XCTAssertTrue(LocalTextModelFile.isMemoryTight(18 << 30))
        XCTAssertTrue(LocalTextModelFile.isMemoryTight(24 << 30))
        XCTAssertFalse(LocalTextModelFile.isMemoryTight(32 << 30))
    }

    func testSixteenGigabytesIsAvailableWithTheCostStated() {
        guard case .availableWithCost(let cost) =
            LocalTextModelFile.verdict(on: mac(16), supported: true, appleIntelligence: .on) else {
            return XCTFail("16 GB is offered, with its cost")
        }
        XCTAssertTrue(cost.contains("GB"), cost)
    }

    func testLargeMemoryIsSimplyAvailable() {
        XCTAssertEqual(LocalTextModelFile.verdict(on: mac(48), supported: true, appleIntelligence: .on),
                       .available)
        XCTAssertEqual(LocalTextModelFile.verdict(on: mac(32), supported: true, appleIntelligence: .on),
                       .available)
    }

    func testIntelIsOfferedWithTheCPUCaveat() {
        guard case .availableWithCost(let cost) =
            LocalTextModelFile.verdict(on: mac(16, appleSilicon: false, chip: "Intel Core i7"),
                                       supported: true, appleIntelligence: .unavailableOS) else {
            return XCTFail("a 16 GB Intel Mac is offered the model")
        }
        XCTAssertTrue(cost.contains("CPU"), cost)
    }

    func testNoHelperInTheBuildIsUnavailable() {
        guard case .unavailable = LocalTextModelFile.verdict(on: mac(48), supported: false,
                                                             appleIntelligence: .on) else {
            return XCTFail("no helper binary, nothing to run")
        }
    }

    // MARK: - The helper plan

    func testPlanKeepsTheFullWindowOnTightMemoryByQuantisingTheCache() {
        let plan = LocalTextModelFile.helperPlan(for: mac(16))
        XCTAssertEqual(plan.contextSize, 16384)
        XCTAssertEqual(plan.kvCache, .q8_0)
        XCTAssertTrue(plan.flashAttention)
        XCTAssertEqual(plan.briefLimit, 45_000)
        XCTAssertEqual(plan.idleTimeout, 60)
        // Weights 2.33 GiB + q8 cache 1.2 GiB + compute: about 3.9 GiB.
        XCTAssertEqual(Double(plan.expectedResidentBytes) / Double(1 << 30), 3.9, accuracy: 0.2)
    }

    func testPlanRunsFullSizeOnLargeMemory() {
        let plan = LocalTextModelFile.helperPlan(for: mac(48))
        XCTAssertEqual(plan.contextSize, 16384)
        XCTAssertEqual(plan.kvCache, .f16)
        XCTAssertFalse(plan.flashAttention)
        XCTAssertEqual(plan.idleTimeout, 180)
        // The measured 4.7 GB (decimal) is 4.4 GiB; the estimate lands near it.
        XCTAssertEqual(Double(plan.expectedResidentBytes) / Double(1 << 30), 4.9, accuracy: 0.3)
    }

    func testPlanShrinksTheWindowAndTheBriefOnIntel() {
        let plan = LocalTextModelFile.helperPlan(for: mac(32, appleSilicon: false, chip: "Intel"))
        XCTAssertEqual(plan.contextSize, 8192)
        XCTAssertEqual(plan.briefLimit, 18_000)
        XCTAssertLessThan(plan.briefLimit, 45_000)
    }

    func testNeededHeadroomLeavesAGigabyteAndAHalfForTheRestOfTheMac() {
        let plan = LocalTextModelFile.helperPlan(for: mac(16))
        XCTAssertEqual(plan.neededHeadroomBytes - plan.expectedResidentBytes, (1 << 30) + (1 << 29))
    }

    // MARK: - The profile itself

    func testHeadlineAndLogLineNameTheMachine() {
        let profile = mac(8)
        XCTAssertEqual(profile.memoryGB, 8)
        XCTAssertTrue(profile.headline.contains("Apple M2"), profile.headline)
        XCTAssertTrue(profile.headline.contains("8 GB"), profile.headline)
        XCTAssertTrue(profile.headline.contains("26.1"), profile.headline)
        XCTAssertTrue(profile.logLine.hasPrefix("machine: Mac14,2"), profile.logLine)
        XCTAssertTrue(profile.logLine.hasSuffix("arm64"), profile.logLine)
        XCTAssertTrue(mac(16, appleSilicon: false).logLine.hasSuffix("x86_64"))
    }

    func testMemoryTextIsBinaryLikeAppleLabelsIt() {
        XCTAssertEqual(MachineProfile.memoryText(8 << 30), "8 GB")
        XCTAssertEqual(MachineProfile.memoryText(48 << 30), "48 GB")
    }

    func testTheRealMachineReportsSomething() {
        let live = MachineProfile.current
        XCTAssertGreaterThan(live.memoryBytes, 0)
        XCTAssertFalse(live.modelIdentifier.isEmpty)
        XCTAssertGreaterThan(MachineProfile.memoryHeadroom(), 0)
        XCTAssertGreaterThanOrEqual(MachineProfile.memoryPressureLevel(), 1)
    }

    // MARK: - Every row keeps the agent

    func testTheAgentIsAvailableOnEveryMac() {
        // The agent runs on the user's key in the vendor's cloud; no gate
        // here may touch it. `agentLine` is the whole of its verdict.
        for profile in [mac(8), mac(16), mac(48), mac(16, appleSilicon: false)] {
            XCTAssertEqual(TextModelRowCopy.agentLine(productName: "Claude"), "Agent: Claude, on your key.",
                           profile.headline)
        }
    }
}
