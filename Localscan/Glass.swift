// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

/// Скляна картка: на macOS 26 — справжнє Liquid Glass, на старіших — розмитий матеріал
struct GlassCard: ViewModifier {
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.10)))
        }
    }
}

extension View {
    func glassCard(_ radius: CGFloat = 14) -> some View { modifier(GlassCard(radius: radius)) }
}

struct Chip: View {
    let text: String
    var tint: Color = .primary
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(tint.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.3)))
    }
}

/// Колір, що залежить від теми: у темній — пастельний, у світлій — насичений,
/// інакше на світлому склі текст не видно
private func adaptive(dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let c = isDark ? dark : light
        return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    })
}

let warm = adaptive(dark: (1.0, 0.70, 0.48), light: (0.80, 0.38, 0.05))
let cool = adaptive(dark: (0.62, 0.85, 1.0), light: (0.10, 0.45, 0.80))
let accent = adaptive(dark: (0.44, 0.89, 0.82), light: (0.05, 0.55, 0.50))
let danger = adaptive(dark: (0.95, 0.42, 0.42), light: (0.80, 0.15, 0.15))
