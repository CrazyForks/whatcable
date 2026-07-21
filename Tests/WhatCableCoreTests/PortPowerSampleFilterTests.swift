import Testing
import WhatCableCore

/// `[PortPowerSample].droppingStaleContracted(onBattery:)` is the DAR-219 gate:
/// on battery it drops a lingering incoming charging contract but keeps genuine
/// throughput (SMC-measured and PowerOutDetails power-out, both of which carry
/// `isContractedFallback == false`).
@Suite("PortPowerSample stale-contract filter (DAR-219)")
struct PortPowerSampleFilterTests {

    private func sample(_ key: String, watts: Int, contracted: Bool = false, smc: Bool = false) -> PortPowerSample {
        PortPowerSample(
            portIndex: 1, portKey: key, current: 100, watts: watts,
            configuredVoltage: 5000, configuredCurrent: 100,
            adapterVoltage: 0, vconnCurrent: 0, vconnPower: 0,
            isContractedFallback: contracted, isSMCMeasured: smc
        )
    }

    @Test("On battery, drops only the incoming contract; keeps SMC and power-out")
    func onBatteryDropsOnlyContracted() {
        let samples = [
            sample("2/1", watts: 60000, contracted: true),   // stale incoming contract -> drop
            sample("2/2", watts: 5000),                       // PowerOutDetails throughput -> keep
            sample("2/3", watts: 4500, smc: true),            // live SMC -> keep
        ]
        let kept = samples.droppingStaleContracted(onBattery: true)
        // Exactly the two non-contracted samples survive, in order. If the
        // filter were a no-op this would be all three; if it dropped everything,
        // none. Both would fail, so the assertion is non-vacuous.
        #expect(kept.map(\.portKey) == ["2/2", "2/3"])
    }

    @Test("Off battery, keeps everything including the contract")
    func offBatteryKeepsAll() {
        let samples = [
            sample("2/1", watts: 60000, contracted: true),
            sample("2/2", watts: 5000),
        ]
        #expect(samples.droppingStaleContracted(onBattery: false).map(\.portKey) == ["2/1", "2/2"])
    }

    @Test("An SMC-measured non-contracted sample is kept on battery")
    func smcMeasuredNonContractedIsKept() {
        // The watcher never sets both flags; isContractedFallback drives the
        // drop, so this asserts the real invariant: an SMC sample (contracted
        // == false) survives on battery.
        let samples = [sample("2/1", watts: 4500, smc: true)]
        #expect(samples.droppingStaleContracted(onBattery: true).count == 1)
    }
}
