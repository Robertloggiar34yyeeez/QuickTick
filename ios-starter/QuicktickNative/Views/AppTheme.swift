import SwiftUI
import CoreImage
import ImageIO
import UIKit

enum AppTheme {
    static let automaticSeasonalKey = "quicktick-seasonal-themes-auto-v1"
    static let activeSeasonalKey = "quicktick-active-seasonal-palette-v1"
    enum AccentPalette: String, CaseIterable, Identifiable {
        case violet, ocean, sunset, mint, rose, cobalt, amber, cherry, teal, lime, indigo, coral, galaxy
        case darkCosmos, auroraNight, solarEclipse, oledBlack, graphite, midnightBlue, emeraldNoir, crimsonNoir
        case nebulaDrift, obsidianGold, polarNight, deSlopified
        case crimson, easter, summer, halloween, christmas, snow
        var id: String { rawValue }
        var isSeasonalPalette: Bool {
            switch self {
            case .easter, .summer, .halloween, .christmas, .snow: true
            default: false
            }
        }
        var name: String {
            switch self {
            case .darkCosmos: "Dark Cosmos"
            case .auroraNight: "Aurora Night"
            case .solarEclipse: "Solar Eclipse"
            case .oledBlack: "OLED Black"
            case .graphite: "Graphite"
            case .midnightBlue: "Midnight Blue"
            case .emeraldNoir: "Emerald Noir"
            case .crimsonNoir: "Crimson Noir"
            case .nebulaDrift: "Nebula Drift"
            case .obsidianGold: "Obsidian Gold"
            case .polarNight: "Polar Night"
            case .deSlopified: "De-slopified"
            case .crimson: "Crimson"
            case .easter: "Easter"
            case .summer: "Summer"
            case .halloween: "Halloween"
            case .christmas: "Christmas"
            case .snow: "Snow"
            default: rawValue.capitalized
            }
        }
        var primary: Color {
            switch self {
            case .violet: Color(red: 0.60, green: 0.43, blue: 1.00)
            case .ocean: Color(red: 0.20, green: 0.65, blue: 1.00)
            case .sunset: Color(red: 1.00, green: 0.46, blue: 0.30)
            case .mint: Color(red: 0.21, green: 0.83, blue: 0.65)
            case .rose: Color(red: 0.98, green: 0.39, blue: 0.69)
            case .cobalt: Color(red: 0.27, green: 0.43, blue: 1.00)
            case .amber: Color(red: 1.00, green: 0.68, blue: 0.20)
            case .cherry: Color(red: 0.93, green: 0.25, blue: 0.43)
            case .teal: Color(red: 0.05, green: 0.76, blue: 0.74)
            case .lime: Color(red: 0.63, green: 0.84, blue: 0.28)
            case .indigo: Color(red: 0.44, green: 0.38, blue: 0.94)
            case .coral: Color(red: 0.99, green: 0.40, blue: 0.42)
            case .galaxy: Color(red: 0.75, green: 0.43, blue: 1.00)
            case .darkCosmos: Color(red: 0.52, green: 0.48, blue: 1.00)
            case .auroraNight: Color(red: 0.22, green: 0.91, blue: 0.73)
            case .solarEclipse: Color(red: 1.00, green: 0.47, blue: 0.28)
            case .oledBlack: Color(red: 0.73, green: 0.64, blue: 1.0)
            case .graphite: Color(red: 0.70, green: 0.76, blue: 0.88)
            case .midnightBlue: Color(red: 0.27, green: 0.59, blue: 1.0)
            case .emeraldNoir: Color(red: 0.19, green: 0.84, blue: 0.67)
            case .crimsonNoir: Color(red: 1.0, green: 0.37, blue: 0.49)
            case .nebulaDrift: Color(red: 0.81, green: 0.46, blue: 0.94)
            case .obsidianGold: Color(red: 0.94, green: 0.69, blue: 0.35)
            case .polarNight: Color(red: 0.37, green: 0.79, blue: 0.98)
            case .deSlopified: Color(red: 0.29, green: 0.49, blue: 0.43)
            case .crimson: Color(red: 0.94, green: 0.14, blue: 0.29)
            case .easter: Color(red: 0.90, green: 0.60, blue: 0.87)
            case .summer: Color(red: 1.00, green: 0.68, blue: 0.22)
            case .halloween: Color(red: 1.00, green: 0.43, blue: 0.11)
            case .christmas: Color(red: 0.82, green: 0.20, blue: 0.30)
            case .snow: Color(red: 0.64, green: 0.85, blue: 1.00)
            }
        }
        var secondary: Color {
            switch self {
            case .violet: Color(red: 0.25, green: 0.62, blue: 0.95)
            case .ocean: Color(red: 0.10, green: 0.84, blue: 0.83)
            case .sunset: Color(red: 1.00, green: 0.72, blue: 0.36)
            case .mint: Color(red: 0.20, green: 0.60, blue: 0.98)
            case .rose: Color(red: 0.65, green: 0.38, blue: 0.98)
            case .cobalt: Color(red: 0.44, green: 0.77, blue: 1.00)
            case .amber: Color(red: 1.00, green: 0.36, blue: 0.31)
            case .cherry: Color(red: 0.83, green: 0.31, blue: 0.74)
            case .teal: Color(red: 0.26, green: 0.55, blue: 0.99)
            case .lime: Color(red: 0.10, green: 0.74, blue: 0.59)
            case .indigo: Color(red: 0.77, green: 0.40, blue: 1.00)
            case .coral: Color(red: 1.00, green: 0.66, blue: 0.36)
            case .galaxy: Color(red: 0.23, green: 0.79, blue: 1.00)
            case .darkCosmos: Color(red: 0.22, green: 0.56, blue: 0.95)
            case .auroraNight: Color(red: 0.29, green: 0.48, blue: 0.98)
            case .solarEclipse: Color(red: 0.77, green: 0.29, blue: 0.72)
            case .oledBlack: Color(red: 0.42, green: 0.68, blue: 1.0)
            case .graphite: Color(red: 0.47, green: 0.60, blue: 0.80)
            case .midnightBlue: Color(red: 0.18, green: 0.84, blue: 0.95)
            case .emeraldNoir: Color(red: 0.20, green: 0.59, blue: 0.91)
            case .crimsonNoir: Color(red: 0.95, green: 0.52, blue: 0.71)
            case .nebulaDrift: Color(red: 0.29, green: 0.64, blue: 0.96)
            case .obsidianGold: Color(red: 0.78, green: 0.48, blue: 0.35)
            case .polarNight: Color(red: 0.62, green: 0.87, blue: 0.73)
            case .deSlopified: primary
            case .crimson: Color(red: 0.65, green: 0.08, blue: 0.32)
            case .easter: Color(red: 0.65, green: 0.87, blue: 0.74)
            case .summer: Color(red: 0.17, green: 0.74, blue: 0.83)
            case .halloween: Color(red: 0.63, green: 0.30, blue: 0.91)
            case .christmas: Color(red: 0.20, green: 0.72, blue: 0.49)
            case .snow: Color(red: 0.58, green: 0.63, blue: 0.95)
            }
        }
        var gradientColors: [Color] {
            switch self {
            case .galaxy:
                [Color(red: 0.95, green: 0.35, blue: 0.82), primary, secondary]
            case .darkCosmos:
                [Color(red: 0.13, green: 0.10, blue: 0.36), primary, secondary]
            case .auroraNight:
                [Color(red: 0.08, green: 0.32, blue: 0.43), primary, secondary]
            case .solarEclipse:
                [Color(red: 0.21, green: 0.06, blue: 0.17), primary, secondary]
            case .oledBlack: [primary, secondary]
            case .graphite: [Color(red: 0.30, green: 0.34, blue: 0.42), primary]
            case .midnightBlue: [Color(red: 0.08, green: 0.23, blue: 0.50), primary, secondary]
            case .emeraldNoir: [Color(red: 0.06, green: 0.30, blue: 0.25), primary, secondary]
            case .crimsonNoir: [Color(red: 0.33, green: 0.06, blue: 0.13), primary, secondary]
            case .nebulaDrift: [Color(red: 0.28, green: 0.10, blue: 0.45), primary, secondary]
            case .obsidianGold: [Color(red: 0.18, green: 0.12, blue: 0.09), primary, secondary]
            case .polarNight: [Color(red: 0.05, green: 0.22, blue: 0.30), primary, secondary]
            // Keep existing gradient-based call sites visually flat: the
            // anti-slop appearance uses one accent, never a decorative blend.
            case .deSlopified: [primary, primary]
            case .crimson: [primary, secondary]
            case .easter: [primary, secondary, Color(red: 0.86, green: 0.84, blue: 0.54)]
            case .summer: [primary, Color(red: 1, green: 0.48, blue: 0.33), secondary]
            case .halloween: [primary, secondary]
            case .christmas: [primary, secondary]
            case .snow: [primary, secondary]
            default: [primary, secondary]
            }
        }
    }
    static var palette: AccentPalette {
        let selected = AccentPalette(rawValue: UserDefaults.standard.string(forKey: "quicktick-accent-palette-v1") ?? "violet") ?? .violet
        let automatic = (UserDefaults.standard.object(forKey: automaticSeasonalKey) as? Bool) ?? true
        guard automatic,
              let active = UserDefaults.standard.string(forKey: activeSeasonalKey),
              let seasonal = AccentPalette(rawValue: active), seasonal.isSeasonalPalette else { return selected }
        return seasonal
    }
    static func refreshSeasonalPalette(now: Date = .now) {
        let value = SeasonalThemeSchedule.palette(for: now)?.rawValue ?? ""
        if UserDefaults.standard.string(forKey: activeSeasonalKey) != value {
            UserDefaults.standard.set(value, forKey: activeSeasonalKey)
        }
    }
    static var modernUI: Bool { (UserDefaults.standard.object(forKey: "quicktick-modern-ui-v1") as? Bool) ?? true }
    static var isGalaxy: Bool { palette == .galaxy }
    static var isDeSlopified: Bool { palette == .deSlopified }
    static var prefersOpaqueChrome: Bool { isCosmic || isSeasonal || isDeSlopified }
    static var isSeasonal: Bool {
        palette.isSeasonalPalette
    }
    static var isCosmic: Bool {
        switch palette {
        case .galaxy, .darkCosmos, .auroraNight, .solarEclipse, .oledBlack, .graphite, .midnightBlue, .emeraldNoir, .crimsonNoir, .nebulaDrift, .obsidianGold, .polarNight: return true
        default: return false
        }
    }
    // Galaxy changes the actual surfaces across menus, not just button tint.
    // Fixed colors avoid animated shaders or heavy effects on feed scrolling.
    static var background: Color {
        switch palette {
        case .galaxy: return Color(red: 0.020, green: 0.021, blue: 0.074)
        case .darkCosmos: return Color(red: 0.009, green: 0.012, blue: 0.036)
        case .auroraNight: return Color(red: 0.009, green: 0.043, blue: 0.052)
        case .solarEclipse: return Color(red: 0.048, green: 0.014, blue: 0.031)
        case .oledBlack: return .black
        case .graphite: return Color(red: 0.032, green: 0.035, blue: 0.041)
        case .midnightBlue: return Color(red: 0.012, green: 0.024, blue: 0.056)
        case .emeraldNoir: return Color(red: 0.010, green: 0.035, blue: 0.030)
        case .crimsonNoir: return Color(red: 0.039, green: 0.013, blue: 0.022)
        case .nebulaDrift: return Color(red: 0.026, green: 0.015, blue: 0.055)
        case .obsidianGold: return Color(red: 0.026, green: 0.019, blue: 0.014)
        case .polarNight: return Color(red: 0.010, green: 0.033, blue: 0.049)
        case .deSlopified: return Color(red: 0.067, green: 0.067, blue: 0.067)
        case .crimson: return Color(red: 0.060, green: 0.010, blue: 0.023)
        case .easter: return Color(red: 0.072, green: 0.048, blue: 0.102)
        case .summer: return Color(red: 0.072, green: 0.035, blue: 0.032)
        case .halloween: return Color(red: 0.040, green: 0.020, blue: 0.058)
        case .christmas: return Color(red: 0.036, green: 0.054, blue: 0.041)
        case .snow: return Color(red: 0.037, green: 0.063, blue: 0.096)
        default: break
        }
        return modernUI ? Color(red: 0.035, green: 0.035, blue: 0.065) : .black
    }
    static var surface: Color {
        switch palette {
        case .galaxy: return Color(red: 0.065, green: 0.052, blue: 0.143)
        case .darkCosmos: return Color(red: 0.035, green: 0.041, blue: 0.093)
        case .auroraNight: return Color(red: 0.028, green: 0.092, blue: 0.103)
        case .solarEclipse: return Color(red: 0.107, green: 0.043, blue: 0.065)
        case .oledBlack: return Color(red: 0.027, green: 0.027, blue: 0.035)
        case .graphite: return Color(red: 0.083, green: 0.091, blue: 0.110)
        case .midnightBlue: return Color(red: 0.040, green: 0.070, blue: 0.120)
        case .emeraldNoir: return Color(red: 0.030, green: 0.079, blue: 0.065)
        case .crimsonNoir: return Color(red: 0.091, green: 0.037, blue: 0.056)
        case .nebulaDrift: return Color(red: 0.086, green: 0.044, blue: 0.126)
        case .obsidianGold: return Color(red: 0.083, green: 0.060, blue: 0.043)
        case .polarNight: return Color(red: 0.034, green: 0.082, blue: 0.099)
        case .deSlopified: return Color(red: 0.105, green: 0.105, blue: 0.105)
        case .crimson: return Color(red: 0.126, green: 0.028, blue: 0.054)
        case .easter: return Color(red: 0.137, green: 0.088, blue: 0.165)
        case .summer: return Color(red: 0.147, green: 0.074, blue: 0.059)
        case .halloween: return Color(red: 0.096, green: 0.052, blue: 0.118)
        case .christmas: return Color(red: 0.068, green: 0.105, blue: 0.081)
        case .snow: return Color(red: 0.073, green: 0.117, blue: 0.153)
        default: break
        }
        return modernUI ? Color(red: 0.073, green: 0.073, blue: 0.11) : Color(white: 0.055)
    }
    static var elevatedSurface: Color {
        switch palette {
        case .galaxy: return Color(red: 0.110, green: 0.078, blue: 0.212)
        case .darkCosmos: return Color(red: 0.067, green: 0.067, blue: 0.160)
        case .auroraNight: return Color(red: 0.053, green: 0.145, blue: 0.146)
        case .solarEclipse: return Color(red: 0.171, green: 0.077, blue: 0.115)
        case .oledBlack: return Color(red: 0.065, green: 0.065, blue: 0.082)
        case .graphite: return Color(red: 0.135, green: 0.143, blue: 0.163)
        case .midnightBlue: return Color(red: 0.075, green: 0.110, blue: 0.177)
        case .emeraldNoir: return Color(red: 0.057, green: 0.120, blue: 0.101)
        case .crimsonNoir: return Color(red: 0.155, green: 0.061, blue: 0.085)
        case .nebulaDrift: return Color(red: 0.132, green: 0.069, blue: 0.184)
        case .obsidianGold: return Color(red: 0.142, green: 0.102, blue: 0.066)
        case .polarNight: return Color(red: 0.057, green: 0.125, blue: 0.143)
        case .deSlopified: return Color(red: 0.15, green: 0.15, blue: 0.15)
        case .crimson: return Color(red: 0.186, green: 0.053, blue: 0.081)
        case .easter: return Color(red: 0.198, green: 0.125, blue: 0.222)
        case .summer: return Color(red: 0.213, green: 0.104, blue: 0.074)
        case .halloween: return Color(red: 0.155, green: 0.072, blue: 0.160)
        case .christmas: return Color(red: 0.103, green: 0.152, blue: 0.110)
        case .snow: return Color(red: 0.115, green: 0.169, blue: 0.205)
        default: break
        }
        return modernUI ? Color(red: 0.10, green: 0.095, blue: 0.15) : Color(red: 0.09, green: 0.09, blue: 0.13)
    }
    static var navigationSurface: Color {
        switch palette {
        case .galaxy: Color(red: 0.040, green: 0.031, blue: 0.114)
        case .darkCosmos: Color(red: 0.020, green: 0.025, blue: 0.061)
        case .auroraNight: Color(red: 0.015, green: 0.069, blue: 0.077)
        case .solarEclipse: Color(red: 0.078, green: 0.026, blue: 0.047)
        case .oledBlack: .black
        case .graphite: Color(red: 0.052, green: 0.058, blue: 0.071)
        case .midnightBlue: Color(red: 0.022, green: 0.046, blue: 0.090)
        case .emeraldNoir: Color(red: 0.016, green: 0.055, blue: 0.045)
        case .crimsonNoir: Color(red: 0.064, green: 0.020, blue: 0.036)
        case .nebulaDrift: Color(red: 0.058, green: 0.028, blue: 0.097)
        case .obsidianGold: Color(red: 0.054, green: 0.039, blue: 0.027)
        case .polarNight: Color(red: 0.018, green: 0.054, blue: 0.069)
        case .deSlopified: Color(red: 0.075, green: 0.075, blue: 0.075)
        case .crimson: Color(red: 0.081, green: 0.018, blue: 0.037)
        case .easter: Color(red: 0.108, green: 0.071, blue: 0.134)
        case .summer: Color(red: 0.105, green: 0.057, blue: 0.045)
        case .halloween: Color(red: 0.074, green: 0.040, blue: 0.094)
        case .christmas: Color(red: 0.047, green: 0.074, blue: 0.058)
        case .snow: Color(red: 0.046, green: 0.083, blue: 0.116)
        default: Color(red: 0.045, green: 0.04, blue: 0.075)
        }
    }
    static var border: Color {
        if isDeSlopified { return Color.white.opacity(0.11) }
        return palette == .oledBlack ? Color.white.opacity(0.13) : (isCosmic ? palette.primary.opacity(0.30) : Color.white.opacity(0.12))
    }
    static var secondaryLabel: Color { Color.white.opacity(prefersOpaqueChrome ? 0.72 : 0.58) }
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
    static var accent: Color { palette.primary }
    static var gradient: LinearGradient {
        LinearGradient(colors: palette.gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    // Feed backgrounds are deliberately translucent only while a user-picked
    // backdrop is enabled. All cards and controls keep opaque readable chrome.
    static var canvas: Color {
        UserDefaults.standard.bool(forKey: BackgroundArtworkStore.enabledKey)
            ? background.opacity(0.58) : background
    }
    static let small: CGFloat = 8
    static let contentMargin: CGFloat = 16
    static let sectionGap: CGFloat = 24
    static let controlHeight: CGFloat = 44
    static var controlRadius: CGFloat { isDeSlopified ? 10 : 14 }
    static var cardRadius: CGFloat { isDeSlopified ? 14 : 22 }
    static var panelRadius: CGFloat { isDeSlopified ? 14 : 22 }
    static let feedWidth: CGFloat = 680
}

/// Automatic appearances have deterministic date windows and never overwrite
/// the user's manually selected palette. Settings can disable the overlay.
enum SeasonalThemeSchedule {
    static func palette(for date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> AppTheme.AccentPalette? {
        let components = calendar.dateComponents([.day, .month, .year], from: date)
        guard let day = components.day, let month = components.month,
              let year = components.year else { return nil }
        if month == 1 || month == 2 || (month == 12 && day >= 27) { return .snow }
        if month == 6 || month == 7 || month == 8 { return .summer }
        if month == 10 && day >= 15 { return .halloween }
        if month == 12 && day <= 26 { return .christmas }
        if month == 3 || month == 4 {
            let easter = easterSunday(year: year, calendar: calendar)
            if let easter,
               let start = calendar.date(byAdding: .day, value: -7, to: easter),
               let end = calendar.date(byAdding: .day, value: 8, to: easter),
               date >= start, date < end { return .easter }
        }
        return nil
    }

    private static func easterSunday(year: Int, calendar: Calendar) -> Date? {
        // Gregorian computus: Easter is movable, so fixed March/April days
        // would turn the seasonal appearance on at the wrong time each year.
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let dayIndex = h + l - 7 * m + 114
        return calendar.date(from: DateComponents(year: year, month: dayIndex / 31,
                                                 day: dayIndex % 31 + 1))
    }
}

enum BackgroundArtworkStore {
    static let enabledKey = "quicktick-custom-background-enabled-v1"
    static let revisionKey = "quicktick-custom-background-revision-v1"
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quicktick/Appearance/background.jpg")
    }

    /// Prepare the photo once at import time. A light blur softens details
    /// without destroying the chosen image, and avoids per-frame GPU filters.
    static func install(_ data: Data) async throws {
        guard !data.isEmpty, data.count <= 30_000_000 else {
            throw APIError.server("Choose an image smaller than 30 MB.")
        }
        try await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1500
                  ] as CFDictionary) else {
                throw APIError.server("This image format is not supported.")
            }
            let input = CIImage(cgImage: thumb)
            let output = input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 5])
                .cropped(to: input.extent)
            guard let blurred = CIContext(options: [.useSoftwareRenderer: false])
                    .createCGImage(output, from: input.extent),
                  let jpeg = UIImage(cgImage: blurred).jpegData(compressionQuality: 0.78) else {
                throw APIError.server("Could not prepare the background image.")
            }
            let destination = fileURL
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jpeg.write(to: destination, options: .atomic)
        }.value
    }
}

/// Each screen can mount this static image behind its scroll content; opaque
/// NavigationStack/ScrollView backgrounds otherwise hide a root-only image.
struct ThemeBackdrop: View {
    @AppStorage(BackgroundArtworkStore.enabledKey) private var enabled = false
    @AppStorage(BackgroundArtworkStore.revisionKey) private var revision = 0
    @State private var artwork: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppTheme.background
                if !enabled && AppTheme.isSeasonal {
                    SeasonalBackdropMotif()
                }
                if enabled, let artwork {
                    Image(uiImage: artwork)
                        .resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .overlay(.black.opacity(0.18))
                }
            }
        }
        .ignoresSafeArea()
        .task(id: "\(enabled):\(revision)") {
            guard enabled else { artwork = nil; return }
            let saved = await Task.detached(priority: .utility) {
                try? Data(contentsOf: BackgroundArtworkStore.fileURL)
            }.value
            guard !Task.isCancelled else { return }
            artwork = saved.flatMap(UIImage.init(data:))
        }
        .accessibilityHidden(true)
    }
}

/// Seasonal accents are static and inexpensive: no particle loops or live
/// blur, so they do not cost animation frames during feed scrolling.
private struct SeasonalBackdropMotif: View {
    private var symbol: String {
        switch AppTheme.palette {
        case .easter: "sparkles"
        case .summer: "sun.max.fill"
        case .halloween: "moon.stars.fill"
        case .christmas: "gift.fill"
        case .snow: "snowflake"
        default: "sparkles"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RadialGradient(colors: [AppTheme.accent.opacity(0.12), .clear],
                               center: .topTrailing, startRadius: 20,
                               endRadius: max(300, geometry.size.width * 0.9))
                Image(systemName: symbol)
                    .font(.system(size: 140, weight: .ultraLight))
                    .position(x: geometry.size.width * 0.89, y: geometry.size.height * 0.19)
                Image(systemName: symbol)
                    .font(.system(size: 86, weight: .ultraLight))
                    .position(x: geometry.size.width * 0.12, y: geometry.size.height * 0.75)
                if AppTheme.palette == .christmas {
                    Text("🎅")
                        .font(.system(size: 104))
                        .position(x: geometry.size.width * 0.77, y: geometry.size.height * 0.33)
                        .opacity(0.22)
                }
            }
            .foregroundStyle(AppTheme.accent.opacity(0.09))
        }
        .allowsHitTesting(false)
    }
}

// Native SwiftUI interpretation of beUI's spring-press interaction.
// No React Native runtime or JavaScript dependency is required.
struct QuicktickPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.955 : 1))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// Keep native vertical paging, AVPlayer controls and comic zoom gestures intact:
// only an intentional rightward swipe from the extreme left edge exits.
struct QuicktickEdgeBack: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragX: CGFloat = 0
    @State private var exiting = false
    let onBack: () -> Void

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                AppTheme.canvas
                Image(systemName: "chevron.left")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 48, height: 48)
                    .opacity(min(1, dragX / 90))
                    .padding(.leading, 15)
                    .accessibilityHidden(true)
                content
                    .offset(x: dragX)
                    .shadow(color: .black.opacity(dragX > 0 ? 0.24 : 0), radius: 16, x: -6)
                Color.clear
                    .frame(width: 32)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 12)
                        .onChanged { gesture in
                            guard !exiting, gesture.translation.width > 0,
                                  abs(gesture.translation.height) < max(28, gesture.translation.width * 0.7) else { return }
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                dragX = min(geometry.size.width, gesture.translation.width)
                            }
                        }
                        .onEnded { gesture in
                            guard !exiting else { return }
                            let dx = gesture.translation.width
                            let dy = gesture.translation.height
                            let predicted = gesture.predictedEndTranslation.width
                            let horizontal = dx > 0 && abs(dy) < max(55, dx * 0.7)
                            guard horizontal && (dx > 80 || predicted > 150) else {
                                withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.3, dampingFraction: 0.88)) { dragX = 0 }
                                return
                            }
                            exiting = true
                            withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.3, dampingFraction: 0.93)) {
                                dragX = geometry.size.width
                            }
                            Task { @MainActor in
                                if !reduceMotion { try? await Task.sleep(for: .milliseconds(220)) }
                                onBack()
                                dragX = 0
                                exiting = false
                            }
                        })
                    .padding(.top, 64)
                    .accessibilityHidden(true)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }
}

extension View {
    func quicktickEdgeBack(_ onBack: @escaping () -> Void) -> some View {
        modifier(QuicktickEdgeBack(onBack: onBack))
    }
}

struct ActionIcon: View {
    let title: String
    let symbol: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .accessibilityHidden(true) // The enclosing button supplies a meaningful action label.
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.bounce, value: selected)
                .foregroundStyle(selected ? AppTheme.accent : .white.opacity(0.9))
                .frame(width: 42, height: 42)
                .background(selected ? AppTheme.accent.opacity(0.16) : .white.opacity(0.065), in: Circle())
                .overlay(Circle().strokeBorder(selected ? AppTheme.accent.opacity(0.42) : .white.opacity(0.11), lineWidth: 1))
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuicktickPressStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PostTagsView: View {
    @EnvironmentObject private var store: AppStore
    let post: Post
    @Environment(\.dismiss) private var dismiss
    @State private var creditedArtists: [String] = []
    private var remainingTags: [String] {
        let credits = Set(creditedArtists.map(RecommendationTagRules.canonical))
        return Array(Set(post.tags)).filter { tag in
            let canonical = RecommendationTagRules.canonical(tag)
            let bare = canonical.hasPrefix("artist:") ? String(canonical.dropFirst(7)) : canonical
            return !credits.contains(bare)
        }.sorted()
    }

    private func searchArtist(_ artist: String) {
        if let provider = post.providerKey { store.selectedProvider = provider }
        // Rule34 indexes the literal artist tag, not an artist: pseudo-tag.
        store.includeTag(artist)
        dismiss()
    }

    private func blockArtist(_ artist: String) {
        let key = RecommendationTagRules.canonical(artist)
        store.setExclusions(Array(Set(store.exclusions + [key])).sorted())
        Task { await store.refresh(immersive: store.activeTab == 1) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                if !creditedArtists.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Credited artists", systemImage: "paintbrush.pointed.fill")
                            .font(.headline).foregroundStyle(AppTheme.accent)
                        Text("Artist credits come from the provider or its tag index, not an image-based guess.")
                            .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
                        ForEach(creditedArtists, id: \.self) { artist in
                            Menu {
                                Button { searchArtist(artist) } label: { Label("Search this artist", systemImage: "magnifyingglass") }
                                Button { store.preferArtist(artist, from: post) } label: { Label("More from this artist", systemImage: "heart") }
                                Button(role: .destructive) { blockArtist(artist) } label: { Label("Block this artist", systemImage: "nosign") }
                            } label: {
                                Label(artist.replacingOccurrences(of: "_", with: " "), systemImage: "paintbrush")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .background(AppTheme.accent.opacity(0.16), in: Capsule())
                            }
                            .accessibilityLabel("Artist \(artist)")
                        }
                    }
                    .padding(14)
                    .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16).padding(.top, 16)
                }
                let actions = ActionSemantics.facets(post.tags).sorted()
                if !actions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Recognized actions", systemImage: "figure.stand")
                            .font(.subheadline.weight(.semibold))
                        Text(actions.map { $0.replacingOccurrences(of: ":", with: " · ").replacingOccurrences(of: "_", with: " ") }
                            .joined(separator: "   •   "))
                            .font(.caption).foregroundStyle(AppTheme.accent)
                        Text("Based on provider tags; visual checking happens separately when enabled.")
                            .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    ForEach(remainingTags, id: \.self) { tag in
                        let blocked = store.exclusions.map(RecommendationTagRules.canonical)
                            .contains(RecommendationTagRules.canonical(tag))
                        Menu {
                            Button("Add to search") { store.includeTag(tag) }
                            Button("Exclude from search") { store.excludeTag(tag) }
                            if FurryTagAliases.explicit.contains(RecommendationTagRules.canonical(tag))
                                || FurryTagAliases.artSpecies.contains(RecommendationTagRules.canonical(tag)) {
                                Button(role: .destructive) {
                                    store.setExclusions(Array(Set(store.exclusions + ["furry"])).sorted())
                                    Task { await store.refresh(immersive: store.activeTab == 1) }
                                } label: { Label("Block furry and related tags", systemImage: "nosign") }
                            }
                            Button(blocked ? "Remove persistent block" : "Block in all feeds", role: blocked ? .cancel : .destructive) {
                                let key = RecommendationTagRules.canonical(tag)
                                let result = blocked
                                    ? store.exclusions.filter { RecommendationTagRules.canonical($0) != key }
                                    : store.exclusions + [key]
                                store.setExclusions(Array(Set(result)).sorted())
                                Task { await store.refresh(immersive: store.activeTab == 1) }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: blocked ? "nosign" : "number")
                                    .font(.caption)
                                Text(tag.replacingOccurrences(of: "_", with: " "))
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                            .font(.subheadline)
                            .foregroundStyle(blocked ? Color.orange : .white.opacity(0.84))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.horizontal, 8)
                            .background(blocked ? Color.orange.opacity(0.15) : AppTheme.elevatedSurface, in: Capsule())
                            .overlay(Capsule().stroke(blocked ? Color.orange.opacity(0.5) : AppTheme.border))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("#\(tag)")
                    }
                }.padding()
                if post.tags.isEmpty { Text("No tags available").foregroundStyle(.secondary).padding() }
            }.background(AppTheme.canvas).navigationTitle("Tags")
                .toolbar { Button("Done") { dismiss() } }
                .task(id: post.stableID) {
                    let taxonomy = await store.visual.metadataTaxonomy()
                    creditedArtists = ArtistAttribution.credited(in: post, taxonomy: taxonomy)
                }
        }.tint(AppTheme.accent)
    }
}

struct SettingsLauncher: View {
    @Binding var isPresented: Bool
    var body: some View {
        Button { isPresented = true } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white).frame(width: 44, height: 44)
                .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.border, lineWidth: 1))
        }.buttonStyle(QuicktickPressStyle()).accessibilityLabel("Settings").accessibilityIdentifier("open-settings")
    }
}
