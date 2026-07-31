import Foundation

/// Which source, if any, gets to speak for a port this tick, and why not when
/// nothing does.
///
/// This is the "reason code" half of the split: the precedence decision is data
/// and lives here where it can be tested; turning a reason into words stays in
/// the view, where the localised strings already are and where the l10n gate
/// already covers them.
public enum PortPowerOutcome: Equatable, Sendable {
    /// Nothing is plugged in. No source may speak for this port, including a
    /// cached contract that outlived the unplug.
    case notInUse
    /// A live per-port reading: an SMC channel, or `PowerOutDetails`
    /// throughput. The most trustworthy thing available.
    case live(PortPowerSample)
    /// The negotiated contract from the `IOPortFeaturePowerSource` tree. Not a
    /// measurement: what the charger and the Mac agreed to.
    case contracted(PortPowerSample)
    /// A contracted sample that arrived keyed by array offset rather than by
    /// the port tree, on machines that publish no `IOPortFeaturePowerSource`.
    /// Kept separate from `contracted` because its attribution is weaker and a
    /// future phase may want to treat it differently.
    case legacyContracted(PortPowerSample)
    /// The port is in use but nothing has reported a figure for it. The view
    /// decides what to say, which is where the "a charger on another port won"
    /// and "this port is driving a display" explanations get added.
    case awaitingData

    /// The sample to show, or nil when there is nothing to show.
    public var sample: PortPowerSample? {
        switch self {
        case .live(let s), .contracted(let s), .legacyContracted(let s): return s
        case .notInUse, .awaitingData: return nil
        }
    }

    /// Whether the port has something plugged into it, regardless of whether
    /// any figure arrived.
    public var portInUse: Bool {
        if case .notInUse = self { return false }
        return true
    }
}

/// The per-port precedence ladder, lifted out of the Power Monitor's view layer.
///
/// It lived inside `PortPowerDisplay.resolve` in a SwiftUI file, which is why
/// the app and the CLI could only share it by both calling into the Pro plugin,
/// and why nothing could unit-test the ordering directly. The ordering itself
/// is unchanged; see `PortPowerResolveCharacterisationTests`, which recorded
/// every port's decision across 396 real machines before this moved and
/// compares against that recording after.
public enum PortPowerPrecedence {

    /// One port's decision, with the port kept alongside so the view can reach
    /// its native labels without a second lookup.
    /// Not Sendable: it holds an `AppleHPMInterface`, which is not. Marking it
    /// so would be a promise the compiler cannot keep, and nothing here crosses
    /// an isolation boundary: the resolve call and its result both stay on the
    /// main actor with the view that asked for them.
    public struct Resolution: Equatable {
        public let identity: PortIdentity
        public let port: AppleHPMInterface
        public let outcome: PortPowerOutcome

        public init(identity: PortIdentity, port: AppleHPMInterface, outcome: PortPowerOutcome) {
            self.identity = identity
            self.port = port
            self.outcome = outcome
        }
    }

    /// Resolve every real physical port.
    ///
    /// - Parameters:
    ///   - ports: the HPM port enumeration. Ports with no number are dropped:
    ///     nothing can be keyed to them.
    ///   - samples: this tick's per-port samples, not yet stale-filtered.
    ///   - powerSources: the whole `IOPortFeaturePowerSource` set, filtered per
    ///     port here by canonical identity.
    ///   - chargerAttached: the live system adapter. See
    ///     `PowerMonitorSnapshot.chargerAttached`, and note it reads false on
    ///     every desktop.
    ///   - onBattery: a battery is installed and no external power is connected.
    ///   - batteryInstalled: whether this Mac has a battery at all. Without it
    ///     the stale-contract gate is permanently true on a desktop.
    public static func resolve(
        ports: [AppleHPMInterface],
        samples: [PortPowerSample],
        powerSources: [PowerSource],
        chargerAttached: Bool,
        onBattery: Bool,
        batteryInstalled: Bool
    ) -> [Resolution] {
        // One gate, matching `PowerMonitorSnapshot.externalPowerAbsent`. Drop
        // lingering incoming-contract samples up front so every branch below is
        // gated from one place rather than each remembering to check.
        let externalPowerAbsent = batteryInstalled && (onBattery || !chargerAttached)
        let samples = samples.droppingStaleContracted(externalPowerAbsent: externalPowerAbsent)

        return ports.compactMap { port -> Resolution? in
            guard let number = port.portNumber else { return nil }
            // Built from the description alone, with no reported type code,
            // because that is what this path has always done. `port.identity`
            // consults `PortType` as well and can differ on a connector neither
            // has seen; keeping them apart preserves the sample lookup below,
            // which matches on exactly this key.
            let identity = PortIdentity.from(
                typeDescription: port.portTypeDescription ?? "USB-C",
                reportedTypeCode: nil,
                number: number
            )
            let key = identity.key
            let portSources = powerSources.filter { $0.canonicallyMatches(port: port) }

            // A live SMC reading is itself proof the port is in use: a dead
            // port reads 0 V / 0 A and is never emitted, and a desktop has no
            // power-source tree for `isPortLive` to corroborate with.
            let smcLive = samples.contains {
                $0.portKey == key && $0.isSMCMeasured && ($0.watts > 0 || $0.current > 0)
            }
            let live = smcLive || isPortLive(
                port: port, powerSources: portSources,
                identities: [], matchingDevices: [], chargerAttached: chargerAttached
            )
            guard live else {
                return Resolution(identity: identity, port: port, outcome: .notInUse)
            }

            // 1. A live per-port reading wins outright.
            if let liveSample = samples.first(where: { $0.portKey == key && !$0.isContractedFallback }) {
                return Resolution(identity: identity, port: port, outcome: .live(liveSample))
            }

            // 2. The negotiated contract, attributed by the port tree's own
            //    identity rather than by array position. Only the agreed
            //    (winning) option, never the advertised menu: showing what the
            //    charger offered as though it were struck describes a deal that
            //    never happened.
            if !externalPowerAbsent,
               let source = PowerSource.preferredChargingSource(in: portSources) ?? portSources.first,
               let contract = source.winning,
               contract.maxPowerMW > 0 {
                let sample = PortPowerMerge.contractedSample(
                    portNumber: number,
                    watts: contract.maxPowerMW,
                    voltageMV: contract.voltageMV,
                    currentMA: contract.maxCurrentMA
                )
                return Resolution(identity: identity, port: port, outcome: .contracted(sample))
            }

            // 3. An offset-keyed contracted sample, for machines with no port
            //    tree. No gate needed: the filter above already removed every
            //    contracted sample when external power is absent.
            if let legacy = samples.first(where: { $0.portKey == key && $0.isContractedFallback && $0.watts > 0 }) {
                return Resolution(identity: identity, port: port, outcome: .legacyContracted(legacy))
            }

            return Resolution(identity: identity, port: port, outcome: .awaitingData)
        }
    }

    /// The one port the Mac is actually drawing through, or nil when that
    /// cannot be said without guessing.
    ///
    /// Requires EXACTLY ONE live port holding a positive winning contract. A
    /// charger handover can leave a second cached contract briefly present, and
    /// IOKit enumeration order is undefined, so a bare "first" could name the
    /// wrong port. With zero or several the answer is ambiguous and silence
    /// beats pointing somewhere wrong.
    ///
    /// Liveness here is deliberately `isPortLive` and not the SMC measured
    /// signal: a winning charge contract is a connection-negotiated fact, and
    /// gating on the connection also drops a stale cached contract on a port
    /// that was just unplugged.
    public static func activeChargingPort(
        ports: [AppleHPMInterface],
        powerSources: [PowerSource],
        chargerAttached: Bool
    ) -> AppleHPMInterface? {
        let winning = ports.filter { port in
            let portSources = powerSources.filter { $0.canonicallyMatches(port: port) }
            return portSources.contains { ($0.winning?.maxPowerMW ?? 0) > 0 }
                && isPortLive(port: port, powerSources: portSources,
                              identities: [], matchingDevices: [], chargerAttached: chargerAttached)
        }
        return winning.count == 1 ? winning.first : nil
    }
}
