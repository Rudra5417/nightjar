import SwiftUI
import MapKit
import CoreLocation
import NightjarCore

struct MapPin: Identifiable {
    let id: String
    /// Where the marker is drawn. May be nudged off the true spot so stacked pins stay visible.
    let coordinate: CLLocationCoordinate2D
    let named: Bool
    let label: String
    let rssi: Int
    let isLatest: Bool
}

/// The screener: where a device has been heard, and whether you're getting closer.
///
/// Pins mark the positions *you* occupied when a device was heard, never a computed position for
/// the device — one radio gives a range, not a bearing, and a fabricated pin is the kind of lie a
/// map makes easy to believe. When several devices are heard from the same spot their pins are
/// fanned out so they can be seen at all, and the footnote says so rather than hiding it.
struct ScreenerMap: View {

    @ObservedObject var model: AppModel
    @ObservedObject var location: LocationTracker
    @State private var camera: MapCameraPosition = .automatic
    @State private var showTrail = true

    private let cyan = Color(red: 0.176, green: 0.831, blue: 0.969)
    private let violet = Color(red: 0.545, green: 0.361, blue: 0.965)
    private let ink = Color(red: 0.04, green: 0.05, blue: 0.07)

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera, interactionModes: [.pan, .zoom, .rotate]) {
                if showTrail, location.path.count > 1 {
                    MapPolyline(coordinates: location.path)
                        .stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }

                if let me = location.path.last {
                    Annotation("you", coordinate: me) {
                        Circle()
                            .fill(cyan)
                            .frame(width: 13, height: 13)
                            .overlay(Circle().stroke(.white, lineWidth: 2.5))
                            .shadow(color: cyan.opacity(0.7), radius: 5)
                    }
                }

                ForEach(pins) { pin in
                    Annotation(pin.label, coordinate: pin.coordinate) {
                        pinView(pin)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 8) {
                summary
                if model.selectedRow == nil {
                    hint
                } else if let row = model.selectedRow {
                    card(row)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .overlay(alignment: .topTrailing) { controls }
        .onAppear { camera = fit() }
        .onChange(of: model.selectedKey) { _, _ in camera = fit() }
    }

    // MARK: - pins

    private var pins: [MapPin] {
        if let key = model.selectedKey {
            let points = model.points(for: key)
            let fanned = PinSpread.spread(points.map(\.coordinate))
            return zip(points, fanned).enumerated().map { index, pair in
                MapPin(id: pair.0.id.uuidString,
                       coordinate: pair.1,
                       named: true,
                       label: index == points.count - 1 ? "now" : "\(index + 1)",
                       rssi: pair.0.rssi,
                       isLatest: index == points.count - 1)
            }
        }
        // Nothing selected: one pin per device, at the last place it was heard. Devices heard
        // from the same spot are fanned out, because sixteen markers on one point look exactly
        // like no markers at all.
        let rows = model.rows.filter { !model.points(for: $0.id).isEmpty }
        let fanned = PinSpread.spread(rows.compactMap { model.points(for: $0.id).last?.coordinate })
        return zip(rows, fanned).map { row, coordinate in
            MapPin(id: row.id,
                   coordinate: coordinate,
                   named: !row.hits.isEmpty,
                   label: short(row.title),
                   rssi: model.points(for: row.id).last?.rssi ?? Observation.unknownRssi,
                   isLatest: false)
        }
    }

    private var isSpread: Bool {
        PinSpread.needsSpreading(pins.map(\.coordinate))
    }

    private func short(_ title: String) -> String {
        title.count <= 16 ? title : String(title.prefix(15)) + "…"
    }

    private func pinView(_ pin: MapPin) -> some View {
        Circle()
            .fill(fill(pin))
            .frame(width: pin.isLatest ? 18 : 14, height: pin.isLatest ? 18 : 14)
            .overlay(Circle().stroke(pin.isLatest ? .white : .white.opacity(0.85),
                                     lineWidth: pin.isLatest ? 2.5 : 1.5))
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
    }

    private func fill(_ pin: MapPin) -> Color {
        guard pin.rssi <= 0 else { return .gray }
        // Closer = warmer: -95 dBm is the usable edge, -40 is in your pocket.
        let t = Double(max(0, min(1, (Double(pin.rssi) + 95) / 55)))
        return Color(hue: 0.52 - 0.52 * t, saturation: 0.85, brightness: 0.95)
    }

    // MARK: - camera

    /// Fit the view to the pins instead of trusting `.automatic`. With every pin sitting on one
    /// point there is no extent to fit, and `.automatic` leaves the map somewhere else entirely —
    /// which is how a map full of radios looks empty.
    private func fit() -> MapCameraPosition {
        var coords = pins.map(\.coordinate)
        if let me = location.path.last { coords.append(me) }
        guard !coords.isEmpty else { return .automatic }

        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        // A floor on the span, so a single point still opens onto a neighbourhood.
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.9, 0.0035),
                                    longitudeDelta: max((maxLon - minLon) * 1.9, 0.0035))
        return .region(MKCoordinateRegion(center: center, span: span))
    }

    // MARK: - overlays

    private var summary: some View {
        HStack(spacing: 6) {
            Image(systemName: model.selectedKey == nil ? "dot.radiowaves.left.and.right" : "mappin.and.ellipse")
                .font(.system(size: 11))
                .foregroundStyle(cyan)
            Text(summaryText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(ink.opacity(0.9)))
    }

    private var summaryText: String {
        let suffix = isSpread ? " · fanned to stay visible" : ""
        if model.selectedKey != nil {
            let n = pins.count
            return "\(n) place\(n == 1 ? "" : "s") heard\(suffix)"
        }
        let devices = pins.count
        guard devices > 0 else { return "no located radios yet" }
        let places = Set(pins.map { "\(($0.coordinate.latitude * 20000).rounded())|\(($0.coordinate.longitude * 20000).rounded())" }).count
        return "\(devices) device\(devices == 1 ? "" : "s") · \(places) place\(places == 1 ? "" : "s")\(suffix)"
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Button { camera = fit() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(9)
                    .background(Circle().fill(ink.opacity(0.85)))
                    .foregroundStyle(cyan)
            }
            Button { showTrail.toggle() } label: {
                Image(systemName: showTrail ? "point.topleft.down.to.point.bottomright.curvepath.fill"
                                            : "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(9)
                    .background(Circle().fill(ink.opacity(0.85)))
                    .foregroundStyle(showTrail ? cyan : .white.opacity(0.5))
            }
            if model.selectedKey != nil {
                Button {
                    model.selectedKey = nil
                    camera = fit()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(9)
                        .background(Circle().fill(ink.opacity(0.85)))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(.trailing, 12)
        .padding(.top, 10)
    }

    private var hint: some View {
        HStack(spacing: 8) {
            Image(systemName: location.isAvailable ? "hand.tap" : "location.slash")
                .font(.system(size: 13))
                .foregroundStyle(location.isAvailable ? cyan : .white.opacity(0.4))
            Text(location.isAvailable
                 ? "Tap any radio in Live to map every place you heard it"
                 : location.statusLabel)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(ink.opacity(0.9)))
    }

    private func card(_ row: RadioRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Text(row.rssiLabel == "—" ? "no reading" : "\(row.rssiLabel) dBm")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(row.hits.isEmpty ? .white.opacity(0.6) : cyan)
            }

            if !row.hits.isEmpty {
                Text(row.hits.map { $0.fleet.name }.joined(separator: " · "))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(cyan)
            }

            HStack(spacing: 12) {
                Label("\(model.points(for: row.id).count) places", systemImage: "mappin.and.ellipse")
                Label(model.trend(for: row.id).label, systemImage: model.trend(for: row.id).symbol)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.6))

            Text(row.address)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(ink.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(row.hits.isEmpty ? .clear : cyan.opacity(0.35), lineWidth: 1))
        )
    }
}
