// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Хто займає пам'ять усієї системи: додатки понад 1 ГБ, від найбільшого.
/// Відкривається посиланням «Процеси» на графіку пам'яті, лежить накладкою поверх вікна.
struct ProcessesCard: View {
    let hogs: [MemoryHog]
    let breakdown: MemoryBreakdown?
    let physical: UInt64
    var onClose: () -> Void = {}

    var body: some View {
        let largest = hogs.first?.bytes ?? 1
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Memory by process").font(.system(size: 12, weight: .bold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Text("Apps holding over 1 GB, counted the same way as Activity Monitor. Helper processes are added to their app.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hogs.isEmpty {
                Text("Nothing above 1 GB right now.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(hogs) { hog in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(hog.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if hog.processes > 1 {
                            Text("· \(hog.processes) processes").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 8)
                        Text(formatBytes(hog.bytes)).font(.system(size: 12, weight: .bold)).monospacedDigit()
                    }
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3).fill(cool)
                            .frame(width: max(geo.size.width * CGFloat(Double(hog.bytes) / Double(largest)), 4))
                    }
                    .frame(height: 6)
                }
            }

            Divider()
            HStack {
                if let b = breakdown {
                    Text("Kernel \(formatBytes(b.wired)) · compressed \(formatBytes(b.compressed))")
                    Spacer(minLength: 8)
                    Text("\(formatBytes(b.used)) of \(formatBytes(physical))").fontWeight(.semibold)
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassCard()
        .onTapGesture { }   // клік усередині картки її не закриває
    }
}
