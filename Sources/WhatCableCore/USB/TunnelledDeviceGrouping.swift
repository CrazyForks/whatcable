import Foundation

/// Decides how to present USB devices that match no physical USB-C port and
/// would otherwise be silently dropped. Two cases:
///
/// 1. Devices reached over a Thunderbolt tunnel (issue #274), behind a TB dock
///    or display. The helper nests them under the host port when exactly one
///    Thunderbolt device is connected, else renders flat.
/// 2. Devices behind an internal Apple USB hub (issue #348), the front USB-C
///    and USB-A ports on Mac mini / Studio / Pro. These never nest under a
///    port: front ports have no port-controller silicon to attribute to.
///
/// Safety rule for the TB-tunnelled nesting: only attribute to a port when
/// **exactly one** Thunderbolt device is connected. With one connection there
/// is no ambiguity about what the tunnelled devices are behind, so the
/// attribution is certain without the per-port tunnel join (the
/// `apciec`/`acio` correlation that is not yet confirmed on multi-port
/// hardware). With two or more Thunderbolt devices the helper returns no
/// host port and the caller renders a flat "Other USB devices" section
/// instead of guessing.
///
/// Pure logic, no IOKit. Shared by the menu bar app, the CLI text output, and
/// the JSON output so all three group identically.
public enum TunnelledDeviceGrouping {
    public struct Result: Equatable {
        /// The Thunderbolt-tunnelled devices, in input order. Empty when there
        /// are none, in which case the caller shows no extra section.
        public let devices: [USBDevice]
        /// The `serviceName` of the one connected Thunderbolt port these devices
        /// nest under (e.g. "Port-USB-C@2"), or `nil` to render them flat. Only
        /// set when exactly one Thunderbolt device is connected.
        public let hostPortServiceName: String?
        /// Devices on a desktop Mac's plain-USB front ports (issue #348).
        /// Not attributed to a port (front ports have no port-controller silicon
        /// to attribute to), but may include a hub the user plugged into a front
        /// port, kept so its children nest under it in the rendered tree. This is
        /// the single place the desktop-only policy is applied: it is empty unless
        /// `group` was called
        /// with `isDesktopMac: true`, so every consumer of this array is
        /// laptop-safe without its own check. Also empty when there is no
        /// front-port activity.
        public let internalHubDevices: [USBDevice]

        public init(
            devices: [USBDevice],
            hostPortServiceName: String?,
            internalHubDevices: [USBDevice] = []
        ) {
            self.devices = devices
            self.hostPortServiceName = hostPortServiceName
            self.internalHubDevices = internalHubDevices
        }
    }

    /// Hubs are deliberately kept in both result sets, not filtered out. A hub is
    /// a branch point of the device tree, so dropping it collapses everything
    /// behind it to a flat list and hides which device hangs off which hub. That
    /// flat list is exactly what users kept reporting (issues #106, #280, #375:
    /// "USB2.1 Hub -> Magic Trackpad" should read as the hub with the trackpad
    /// nested under it). `USBDeviceNode.buildTree` needs the hub present to nest
    /// its children, so keeping hubs is what lets the renderers (app, CLI, JSON)
    /// show the real hierarchy. The Mac's own internal front-panel hub is never a
    /// member of either set (it is the boundary the walk stops at, never itself
    /// flagged `isThunderboltTunnelled` or `isBehindInternalHub`), so showing hubs
    /// surfaces the hubs the user attached, never the Mac's internal plumbing.
    ///
    /// - Parameter isDesktopMac: gates the `internalHubDevices` result. The
    ///   front-panel hub ports only exist on Mac mini / Studio / Pro, so on a
    ///   laptop the internal-hub set is forced empty here regardless of the
    ///   per-device structural flag. Defaults to `false` (fail closed): a caller
    ///   that does not opt in gets no front-port devices, never a laptop false
    ///   positive. The `isBehindInternalHub` flag itself stays pure structural
    ///   truth; this is the one place the desktop product policy is applied.
    public static func group(
        devices: [USBDevice],
        ports: [AppleHPMInterface],
        thunderboltSwitches: [IOThunderboltSwitch],
        isDesktopMac: Bool = false
    ) -> Result {
        // Hubs are kept (see the type doc): they are the branch points the tree
        // renderer needs to nest each device under the hub it hangs off.
        let tunnelled = devices.filter { $0.isThunderboltTunnelled }
        // Front-port / internal-hub devices: those the parent walk flagged as
        // behind the Mac's internal hub. Desktop-only: empty on laptops (see
        // isDesktopMac). The tunnelled exclusion is defensive; isBehindInternalHub
        // already implies !tunnelled. Any hub here is one the user attached to a
        // front port (an external hub), kept so its children nest under it; the
        // Mac's own internal hub is the boundary of this set and never a member.
        // Subtract any device now claimed by a real port card via an exact
        // port-name match (issue #456): a named built-in USB-only port
        // (e.g. Port-USB-C@5 on a Mac Studio) attributes its device to the
        // card, so it must not ALSO appear here or it renders twice. Uses the
        // same `claimsInternalHubDevice` predicate `matchingDevices` uses to add
        // it, so the two sides can't drift. Only an active port claims (an
        // inactive port's `matchingDevices` returns nothing), mirroring the card
        // side exactly. USB-A built-in devices are unaffected: no USB-A port
        // card exists to claim them, so they stay here as before.
        let internalHub = isDesktopMac
            ? devices.filter { device in
                device.isBehindInternalHub
                    && !device.isThunderboltTunnelled
                    && !ports.contains { port in
                        port.connectionActive == true
                            && port.claimsInternalHubDevice(device)
                    }
            }
            : []

        guard !tunnelled.isEmpty else {
            return Result(
                devices: [],
                hostPortServiceName: nil,
                internalHubDevices: internalHub
            )
        }

        // Ports that currently have a Thunderbolt device downstream (a dock or
        // display). A single dock fanning out to two displays is still one
        // connection (one port), so this counts physical Thunderbolt links.
        let portsWithDevice = ports.filter { port in
            guard let socketID = ThunderboltTopology.socketID(for: port),
                  let root = ThunderboltTopology.hostRoot(forSocketID: socketID, in: thunderboltSwitches)
            else { return false }
            return !ThunderboltTopology.tree(from: root, in: thunderboltSwitches).isEmpty
        }

        let hostPortServiceName = portsWithDevice.count == 1
            ? portsWithDevice.first?.serviceName
            : nil
        return Result(
            devices: tunnelled,
            hostPortServiceName: hostPortServiceName,
            internalHubDevices: internalHub
        )
    }
}
