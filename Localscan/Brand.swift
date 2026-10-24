// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Фірмовий знак: ті самі кільця, що на іконці додатка.
/// Зовнішня хвиля розходиться від центра — так виглядає сканування.
struct ScanMark: View {
    var size: CGFloat = 22
    var animated = true
    @State private var ping = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(accent, lineWidth: size * 0.07)
                .scaleEffect(ping ? 1.0 : 0.34)
                .opacity(ping ? 0 : 0.75)
            Circle()
                .strokeBorder(accent.opacity(0.8), lineWidth: size * 0.085)
                .frame(width: size * 0.58, height: size * 0.58)
            Circle()
                .fill(accent)
                .frame(width: size * 0.22, height: size * 0.22)
            Circle()                                   // знайдений порт, як на іконці
                .fill(warm)
                .frame(width: size * 0.16, height: size * 0.16)
                .offset(x: size * 0.205, y: -size * 0.205)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) { ping = true }
        }
    }
}

/// Знак і назва разом — те, що стоїть у шапці віконця
struct Wordmark: View {
    var size: CGFloat = 18
    var animated = true

    var body: some View {
        HStack(spacing: size * 0.55) {
            ScanMark(size: size * 1.45, animated: animated)
            HStack(spacing: 0) {
                Text("LOCAL")
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .tracking(size * 0.12)
                Text("SCAN")
                    .font(.system(size: size, weight: .heavy, design: .rounded))
                    .tracking(size * 0.12)
                    .foregroundStyle(accent)
            }
        }
    }
}
