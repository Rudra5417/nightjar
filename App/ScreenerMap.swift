import SwiftUI
import MapKit
import NightjarCore

struct MapPin: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let named: Bool
    let title: String
    let rssi: Int
}

/// The screener: where a device has been heard, and whether you're getting closer.
///
/// Pins are positions *you* occupied when the device was heard, never a computed position for
/// the device — a single radio cannot give a bearing, and drawing a fake one would be a lie the
/// map makes easy to believe.
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

                ForEach(pins) { pin in
                    Annotation(pin.title, coordinate: pin.coordinate) {
                        pinView(pin)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 10) {
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
    }

    // MARK: - pins

    private var pins: [MapPin] {
        if let key = model.selectedKey {
            return model.points(for: key).map { d in
                MapPin(id: d.id.uuidString, coordinate: d.coordinate, named: true, title: "", rssi: d.rssi)
            }
        }
        // Nothing selected: one pin per device, at the last place it was heard. Titles stay
        // empty — 85 labels on one map is not a map.
        return model.rows.compactMap { row in
            guard let last = model.points(for: row.id).last else { return nil }
            return MapPin(id: row.id, coordinate: last.coordinate, named: !row.hits.isEmpty,
                          title: "", rssi: last.rssi)
        }
    }

    private func pinView(_ pin: MapPin) -> some View {
        Circle()
            .fill(fill(pin))
            .frame(width: model.selectedKey == nil ? 11 : 13,
                   height: model.selectedKey == nil ? 11 : 13)
            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }

    private func fill(_ pin: MapPin) -> Color {
        guard pin.rssi <= 0 else { return .gray }
        // Closer = warmer. -95 dBm is the outer edge of usable, -40 is in your pocket.
        let t = Double(max(0, min(1, (Double(pin.rssi) + 95) / 55)))
        return Color(hue: 0.52 - 0.52 * t, saturation: 0.85, brightness: 0.95)
    }

    // MARK: - overlays

    private var controls: some View {
        VStack(spacing: 8) {
            Button {
                camera = .automatic
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(9)
                    .background(Circle().fill(ink.opacity(0.85)))
                    .foregroundStyle(cyan)
            }
            Button {
                showTrail.toggle()
            } label: {
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
                    camera = .automatic
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
        .padding(.top, 12)
    }

    private var hint: some View {
        HStack(spacing: 8) {
            Image(systemName: location.isAvailable ? "map" : "location.slash")
                .font(.system(size: 13))
                .foregroundStyle(location.isAvailable ? cyan : .white.opacity(0.4))
            Text(location.isAvailable
                 ? "Tap a radio to see every place you heard it"
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
