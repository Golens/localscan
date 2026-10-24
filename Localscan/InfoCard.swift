// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Пояснення, чому поля бувають порожні, і куди писати про помилки під час бета-тесту.
/// Відкривається кнопкою з кружечком праворуч від назви.
struct InfoCard: View {
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("How this works").font(.system(size: 12, weight: .bold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Text("Localscan sees only what is listening on local ports: development servers, databases, containers. Memory and CPU are counted for those alone, the rest of the system is not included.")
            Text("An empty list and zeros mean nothing is running on a local port right now. That is not a fault.")
                .foregroundStyle(.secondary)
            Text("On the chart the blue line is the whole system, shown for comparison, and the teal one is your local servers.")
                .foregroundStyle(.secondary)
            Divider()
            // Посилання всередині тексту, щоб рядок нормально переносився
            Text("The app is in beta testing. If something goes wrong, write to [@al_abramenko](https://t.me/al_abramenko) on Telegram.")
                .tint(accent)
            Text("Briefly describe what happened and attach the report file: right-click the name above, then «Show report in Finder».")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassCard()
        .onTapGesture { }   // клік усередині картки її не закриває
    }
}
