import SwiftUI
import TetherCore

struct BrandGuidesView: View {
    var body: some View {
        List {
            Section {
                ForEach(BrandGuide.all) { guide in
                    NavigationLink(value: AppRoute.brandGuide(guide.vendor)) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(guide.vendor.displayName).font(.headline)
                                Spacer()
                                transportBadges(guide.vendor)
                            }
                            Text(guide.summary).font(.footnote).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } footer: {
                Text("Any other PTP camera imports over USB: Open Tether watches for new files and downloads them, without remote capture.")
            }
        }
        .tetherList()
        .navigationTitle("Setup guides")
    }

    private func transportBadges(_ vendor: CameraVendor) -> some View {
        HStack(spacing: 4) {
            if vendor.supportsWiredControl { Image(systemName: "cable.connector").accessibilityLabel("USB") }
            if vendor.supportsWirelessControl { Image(systemName: "wifi").accessibilityLabel("Wi-Fi") }
        }
        .font(.caption).foregroundStyle(Theme.textSecondary)
    }
}

struct BrandGuideDetailView: View {
    var vendor: CameraVendor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let guide = BrandGuide.guide(for: vendor) {
                    Text(guide.summary).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    if !guide.wired.isEmpty { steps("USB-C", "cable.connector", guide.wired) }
                    if !guide.wireless.isEmpty { steps("Wi-Fi", "wifi", guide.wireless) }
                    if !guide.notes.isEmpty {
                        SectionCard(title: "Good to know", systemImage: "lightbulb") {
                            ForEach(guide.notes, id: \.self) { Text("• \($0)").font(.footnote) }
                        }
                    }
                } else {
                    EmptyState(systemImage: "book", title: "No guide yet", message: "This brand connects as a generic PTP camera over USB.")
                }
            }
            .padding(16)
        }
        .tetherScreen()
        .navigationTitle(vendor.displayName)
    }

    private func steps(_ title: String, _ icon: String, _ steps: [BrandGuide.Step]) -> some View {
        SectionCard(title: title, systemImage: icon) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    // Placeholder for a menu photo.
                    RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceRaised).frame(width: 56, height: 42)
                        .overlay(Image(systemName: step.symbol).foregroundStyle(Theme.accent))
                        .accessibilityHidden(true)
                    Text("\(index + 1). \(step.text)").font(.subheadline)
                }
            }
        }
    }
}
