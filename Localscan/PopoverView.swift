// Localscan — монітор локальних серверів у рядку меню macOS.
// Copyright (C) 2026 Golens
//
// Вільна програма: ви можете поширювати й змінювати її на умовах
// GNU General Public License версії 3 або, на ваш вибір, будь-якої
// пізнішої версії. Повний текст — у файлі LICENSE.
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import Combine

struct PopoverView: View {
    @EnvironmentObject var monitor: Monitor
    @State private var tab = 0
    @State private var selection = RowSelection()   // одна розкрита картка / одне підтвердження за раз
    @State private var showInfo = false
    @State private var showProcesses = false
    @State private var hogs: [MemoryHog] = []
    @State private var breakdown: MemoryBreakdown?
    @State private var listHeight: CGFloat = 0
    @State private var windowVisible = false  // вигляд живе ще до першого відкриття і після закриття; анімацію вмикаємо лише коли вікно справді на екрані

    var body: some View {
        ZStack {
        VStack(spacing: 14) {
            header
            if monitor.hasTrouble { troubleBanner }
            statCards
            sparkline

            Picker("", selection: Binding(get: { tab }, set: { tab = $0; selection.reset() })) {
                Text("Running · \(monitor.servers.count)").tag(0)
                Text("Stopped · \(monitor.stoppedProjects.count)").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()

            list

            if let err = monitor.lastError {
                Text(err).font(.caption).foregroundStyle(warm)
            }
            footer
        }
        .padding(16)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selection.reset(); showInfo = false; showProcesses = false } }   // клік по порожньому місцю все згортає

            if showInfo { infoOverlay }
            if showProcesses { processesOverlay }
        }
        .background(WindowVisibility { visible in
            guard visible != windowVisible else { return }
            windowVisible = visible
            if !visible {                 // вікно закрили — наступного разу відкриється «чистим»
                selection.reset()
                showInfo = false
                showProcesses = false
            }
        })
        .frame(width: 400)
    }

    /// Список споживачів пам'яті: збирається у фоні, оновлюється раз на 10 с,
    /// і лише поки накладка відкрита — таймер живе всередині неї
    private func loadHogs() {
        Task.detached(priority: .utility) {
            let found = MemoryHogs.top()
            let system = SystemMemory.breakdown()
            await MainActor.run {
                hogs = found
                breakdown = system
            }
        }
    }

    private var processesOverlay: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.38))
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showProcesses = false } }
            ProcessesCard(hogs: hogs, breakdown: breakdown, physical: monitor.physicalMemory) {
                withAnimation(.easeOut(duration: 0.15)) { showProcesses = false }
            }
            .padding(.horizontal, 18)
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in loadHogs() }
        }
        .transition(.opacity)
    }

    /// Пояснення лежить поверх вмісту, а не в потоці, тому вікно не змінює висоти.
    /// Системне спливне вікно тут не годиться: воно забирає фокус, і вікно рядка меню закривається.
    private var infoOverlay: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.38))
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showInfo = false } }
            InfoCard { withAnimation(.easeOut(duration: 0.15)) { showInfo = false } }
                .padding(.horizontal, 18)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        }
        .transition(.opacity)
    }

    /// Прихована діагностика: правий клік на заголовку. Потрібна, щоб зібрати назви
    /// датчиків із Mac інших поколінь — на видимому інтерфейсі нічого не з'являється.
    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.text(monitor.temps), forType: .string)
    }

    private func revealReport() {
        let url = Diagnostics.write(monitor.temps)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Підказка до чіпа температури: що це за число, миттєве значення і пік за 15 секунд
    private func tempHelp(_ s: Smoother, now: Double?, what: String) -> String {
        var text = what
        if let now { text += " " + String(localized: "Right now: \(Int(now.rounded()))°.") }
        if let peak = s.peak { text += " " + String(localized: "Peak: \(Int(peak.rounded()))°.") }
        text += " " + String(localized: "Apple chip cores heat up and cool down by tens of degrees within seconds, so the instant reading jumps.")
        return text
    }

    /// Збирається як звичайний рядок: у .help() частини склеюються, тому кожну перекладаємо окремо
    private func caseHelp(battery: Double?) -> String {
        var s = String(localized: "Estimated surface temperature of the case (TVS sensors). This is what your hand feels. It lags by minutes and keeps rising after the load ends.")
        if let b = battery { s += " " + String(localized: "Battery: \(Int(b))°.") }
        return s
    }

    /// Коротке попередження під назвою. Складаємо з двох частин, щоб не мати
    /// справи з різними формами множини в українській.
    private var troubleBanner: some View {
        let counts = monitor.trouble
        var parts: [String] = []
        if counts.silent > 0 { parts.append(String(localized: "not responding: \(counts.silent)")) }
        if counts.busy > 0 { parts.append(String(localized: "heavy CPU: \(counts.busy)")) }
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
            Text(parts.joined(separator: " · ")).font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(warm)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(warm.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
    }

    private var rowCount: Int { tab == 0 ? monitor.servers.count : monitor.stoppedProjects.count }

    @ViewBuilder private var rows: some View {
        if tab == 0 {
            if monitor.servers.isEmpty {
                Text("Nothing is running").foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(monitor.servers) { ServerRow(server: $0, selection: $selection).id($0.id) }
        } else {
            if monitor.stoppedProjects.isEmpty {
                Text("No stopped projects yet").foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(monitor.stoppedProjects) { StoppedRow(project: $0, selection: $selection) }
        }
    }

    /// Виміряна висота рівно шести згорнутих рядків. Далі список прокручується,
    /// щоб вікно не росло нескінченно — ні від кількості серверів, ні від розкритої картки.
    private let maxListHeight: CGFloat = 342

    /// У вікні MenuBarExtra ScrollView без явної висоти стискається до нуля,
    /// тому висоту доводиться міряти самому: беремо справжню висоту вмісту
    /// і обмежуємо її стелею. Поки вимір не прийшов, використовуємо оцінку.
    private var list: some View {
        let estimate = CGFloat(max(rowCount, 1)) * 60
        let height = min(listHeight > 0 ? listHeight : estimate, maxListHeight)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 6) { rows }
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ListHeightKey.self, value: geo.size.height)
                    })
            }
            .frame(height: max(height, 1))
            .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            // смужка під рядком унизу списку інакше відкривалась би за межами видимого,
            // і здавалося, що хрестик не спрацював
            .onChange(of: selection.confirmStopID) { id in reveal(id, proxy) }
            .onChange(of: monitor.stubborn) { id in reveal(id, proxy) }
        }
    }

    private func reveal(_ id: String?, _ proxy: ScrollViewProxy) {
        guard let id else { return }
        // чекаємо, поки смужка з'явиться в розкладці, тоді прокручуємо низ рядка у видиму зону
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            // .id перестворює знак при зміні видимості: інакше вічна анімація
            // хвилі крутилась би й у закритому вікні, з'їдаючи ~10% процесора
            Wordmark(size: 18, animated: windowVisible)
                .id(windowVisible)
                .frame(maxWidth: .infinity)
                .contextMenu {
                    Button("Copy sensor report", action: copyReport)
                    Button("Show report in Finder", action: revealReport)
                }
                .overlay(alignment: .trailing) {
                    Button { withAnimation(.easeOut(duration: 0.15)) { showInfo.toggle() } } label: {
                        Image(systemName: showInfo ? "exclamationmark.circle.fill" : "exclamationmark.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(showInfo ? accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("How this works")
                }
            let t = monitor.temps
            if t.cpu != nil || t.gpu != nil || t.caseTemp != nil || t.ssd != nil {
                HStack(spacing: 6) {
                    if let c = monitor.cpuTemp.average {
                        Chip(text: "\(t.cpuLabel) \(Int(c.rounded()))°", tint: warm)
                            .help(tempHelp(monitor.cpuTemp, now: t.cpu, what: t.cpuLabel == "CPU"
                                ? String(localized: "Hottest CPU core, averaged over the last 15 seconds.")
                                : String(localized: "Hottest die sensor, averaged over the last 15 seconds (CPU and GPU share one chip).")))
                    }
                    if let g = monitor.gpuTemp.average {
                        Chip(text: "GPU \(Int(g.rounded()))°", tint: cool)
                            .help(tempHelp(monitor.gpuTemp, now: t.gpu,
                                           what: String(localized: "Hottest GPU sensor, averaged over the last 15 seconds.")))
                    }
                    if let k = t.caseTemp {
                        Chip(text: String(localized: "Case \(Int(k))°"), tint: accent)
                            .help(caseHelp(battery: t.battery))
                    }
                    if let s = t.ssd { Chip(text: "SSD \(Int(s))°").help("Drive temperature") }
                }
                .frame(maxWidth: .infinity)   // по центру
            }
        }
    }

    private var statCards: some View {
        HStack(spacing: 8) {
            stat("Running", "\(monitor.servers.count)")
            stat("Memory", formatBytes(monitor.totalBytes))
            stat("CPU", "\(Int(monitor.totalCPU))%")
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .bold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassCard()
    }

    private var sparkline: some View {
        // Дві криві в одному полі. У кожної своя шкала: системі віддано всю висоту
        // і весь обсяг пам'яті, localhost — нижню половину і власний пік. Інакше наші
        // сотні мегабайтів проти десятків гігабайтів лягли б у рівну лінію на дні.
        let localPeak = monitor.samples.map(\.totalBytes).max() ?? 1
        return VStack(spacing: 6) {
            HStack {
                Text("Memory, last hour").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if let p = monitor.peakSample, p.totalBytes > 0 {
                    Text("peak \(formatBytes(p.totalBytes)) at \(p.at.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(warm)
                }
            }
            HStack(spacing: 12) {
                if let system = monitor.systemUsed { legend(cool, "System", formatBytes(system)) }
                legend(accent, "Localhost", formatBytes(monitor.totalBytes))
                Spacer(minLength: 0)
                Button {
                    loadHogs()
                    withAnimation(.easeOut(duration: 0.15)) { showProcesses = true }
                } label: {
                    HStack(spacing: 3) {
                        Text("Processes").font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(cool)
                }
                .buttonStyle(.plain)
                .help("Which apps hold the most memory")
            }
            ZStack {
                MemoryCurve(values: monitor.samples.map(\.systemBytes),
                            maxValue: monitor.physicalMemory, tint: cool, filled: true)
                MemoryCurve(values: monitor.samples.map { $0.totalBytes },
                            maxValue: localPeak, tint: accent, filled: false,
                            heightFraction: 0.5, peakDot: true)
            }
            .frame(height: 64)
            Text("Different scales: the system up to \(formatBytes(monitor.physicalMemory)), localhost up to its own peak.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassCard()
    }

    private func legend(_ color: Color, _ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: 11))
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at login", isOn: Binding(
                get: { monitor.launchAtLogin },
                set: { monitor.setLaunchAtLogin($0) }))
            .toggleStyle(.checkbox).font(.system(size: 12))
            Spacer()
            Button("Refresh") { monitor.refresh() }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(.top, 10)
        .overlay(Divider(), alignment: .top)
    }
}

/// Крива на графіку пам'яті.
/// values може містити порожні значення — це точки, збережені до появи системного графіка;
/// лінія просто починається з першої заповненої.
/// heightFraction обмежує криву часткою висоти, щоб друга шкала не вилазила над першою.
struct MemoryCurve: View {
    let values: [UInt64?]
    let maxValue: UInt64
    let tint: Color
    var filled = true
    var heightFraction: CGFloat = 1
    var peakDot = false

    var body: some View {
        GeometryReader { geo in
            let total = max(values.count - 1, 1)
            let top = max(Double(maxValue), 1)
            let pts: [CGPoint] = values.enumerated().compactMap { i, v in
                guard let v else { return nil }
                let share = min(Double(v) / top, 1)
                return CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(total),
                               y: geo.size.height - (geo.size.height * heightFraction * 0.94) * CGFloat(share) - 2)
            }
            if pts.count > 1 {
                if filled {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.26), tint.opacity(0.03)],
                                         startPoint: .top, endPoint: .bottom))
                }
                Path { p in p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) } }
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if peakDot, let peak = pts.min(by: { $0.y < $1.y }) {
                    Circle().fill(warm).frame(width: 7, height: 7).position(peak)
                }
            }
        }
    }
}

/// Передає справжню висоту списку вгору, щоб обмежити її стелею
struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
