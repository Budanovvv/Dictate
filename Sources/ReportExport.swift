import AppKit
import UniformTypeIdentifiers

/// A report, out of the meeting's file and into one of its own: Markdown,
/// plain text or PDF — one meeting from its ⋯ menu, many from the editor,
/// where the many can also come as one CSV table with a column per field,
/// which is what a sales lead actually opens. The report stays in the
/// meeting's file either way; this makes a copy.
@MainActor
enum ReportExport {

    enum Format: String, CaseIterable {
        case markdown, plainText, pdf

        var label: String {
            switch self {
            case .markdown: return L("Markdown")
            case .plainText: return L("Plain text")
            case .pdf: return L("PDF")
            }
        }
        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .plainText: return "txt"
            case .pdf: return "pdf"
            }
        }
        var type: UTType {
            switch self {
            case .markdown: return UTType(filenameExtension: "md") ?? .plainText
            case .plainText: return .plainText
            case .pdf: return .pdf
            }
        }
    }

    /// The last format chosen, so the dialog opens on it next time.
    private static var lastFormat: Format = .markdown

    // MARK: - The Reports folder of earlier versions

    /// Versions up to this one wrote a PDF of every report into a Reports
    /// folder inside the archive. Dictate no longer writes files on its
    /// own (design turn 33): the report is kept in the meeting's file, and
    /// Export… makes a copy on request. The folder is named once, in
    /// About › Storage, and never touched — those files are the person's.
    static let lastVersionWritingPDFs = "3.3.1"

    static var reportsDirectory: URL {
        MeetingArchive.directory.appendingPathComponent("Reports", isDirectory: true)
    }

    // MARK: - One meeting

    static func exportOne(_ meeting: ArchivedMeeting, report: MeetingReport) {
        let panel = NSSavePanel()
        panel.title = Lf("Export the “%@” report", report.templateName)
        panel.message = Lf("%@ · %@. The report stays in the meeting’s file either way; this makes a copy.",
                           MeetingReports.name(of: meeting), dateLine(meeting))
        panel.canCreateDirectories = true
        let chooser = FormatChooser(initial: lastFormat, csv: nil)
        panel.accessoryView = chooser
        chooser.onChange = { [weak panel] format in
            panel?.allowedContentTypes = [format.type]
            let base = panel?.nameFieldStringValue.split(separator: ".").first.map(String.init) ?? ""
            panel?.nameFieldStringValue = base + "." + format.fileExtension
        }
        panel.allowedContentTypes = [lastFormat.type]
        panel.nameFieldStringValue = fileName(for: meeting, report: report) + "." + lastFormat.fileExtension
        // The same manners as the transcript export: activate first, then
        // open — a save panel from a non-activating window otherwise lands
        // behind everything.
        NSApp.activate()
        Log.d("export: report “\(report.templateName)” — opening the save panel")
        DispatchQueue.main.async {
            panel.begin { response in
                Log.d("export: panel closed response=\(response.rawValue) url=\(panel.url?.lastPathComponent ?? "-")")
                guard response == .OK, let url = panel.url else { return }
                let format = chooser.format
                lastFormat = format
                let ok = write(meeting, report: report, format: format, to: url)
                Log.d("export: \(format.fileExtension) written=\(ok)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                Log.d("export: panel visible=\(panel.isVisible) key=\(panel.isKeyWindow) level=\(panel.level.rawValue) app active=\(NSApp.isActive)")
            }
        }
    }

    // MARK: - Many meetings

    /// Every meeting with a report from `template`, one file each, in a
    /// folder the person chooses. Reads the archive first, so the dialog can
    /// say how many.
    /// Every report written with the template, from the meetings the
    /// library already holds — no second read of the archive, which on an
    /// iCloud folder could keep the panel from ever appearing. By id or by
    /// name: the collection groups by name, and a report written before
    /// the template was recreated carries another id.
    static func exportAll(_ archive: [ArchivedMeeting], template: ReportTemplate) {
        let meetings = archive.filter {
            $0.reports.contains { $0.templateID == template.id || $0.templateName == template.name }
        }
        exportWritten(meetings, template: template)
    }

    private static func exportWritten(_ meetings: [ArchivedMeeting], template: ReportTemplate) {
        guard !meetings.isEmpty else {
            Log.d("export: “\(template.name)” — nothing written with it")
            TopNotice.show(Lf("No reports written with “%@” yet.", template.name))
            return
        }
        let panel = NSOpenPanel()
        panel.title = Lf("Export %d “%@” reports", meetings.count, template.name)
        panel.message = L("One file per meeting, named by date and title, in a folder you choose. Transcripts are not included.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose folder…")
        let chooser = FormatChooser(initial: lastFormat,
                                    csv: L("Also one table (CSV): a row per meeting, a column per field"))
        panel.accessoryView = chooser
        panel.isAccessoryViewDisclosed = true
        NSApp.activate()
        Log.d("export: “\(template.name)” × \(meetings.count) — opening the folder panel")
        DispatchQueue.main.async {
            panel.begin { response in
                Log.d("export: folder panel closed response=\(response.rawValue)")
                guard response == .OK, let folder = panel.url else { return }
                let format = chooser.format
                lastFormat = format
                var written = 0
                for meeting in meetings {
                    guard let report = meeting.reports.first(where: { $0.templateID == template.id || $0.templateName == template.name }) else { continue }
                    let url = folder.appendingPathComponent(
                        fileName(for: meeting, report: report) + "." + format.fileExtension)
                    if write(meeting, report: report, format: format, to: url) { written += 1 }
                }
                if chooser.wantsCSV {
                    let url = folder.appendingPathComponent(safe(template.name) + ".csv")
                    try? csv(meetings, template: template).write(to: url, atomically: true, encoding: .utf8)
                }
                Log.d("report: exported \(written) as \(format.rawValue)")
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
    }

    // MARK: - Rendering

    @discardableResult
    private static func write(_ meeting: ArchivedMeeting, report: MeetingReport,
                              format: Format, to url: URL) -> Bool {
        switch format {
        case .markdown:
            return (try? markdown(meeting, report: report).write(to: url, atomically: true, encoding: .utf8)) != nil
        case .plainText:
            return (try? plainText(meeting, report: report).write(to: url, atomically: true, encoding: .utf8)) != nil
        case .pdf:
            return pdf(meeting, report: report, to: url)
        }
    }

    static func fileName(for meeting: ArchivedMeeting, report: MeetingReport) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = f.string(from: meeting.started)
        let name = meeting.title.map { " — " + $0 } ?? ""
        return safe(stamp + name + " — " + report.templateName)
    }

    private static func safe(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return name.components(separatedBy: bad).joined(separator: "-")
    }

    static func dateLine(_ meeting: ArchivedMeeting) -> String {
        var line = meeting.started.formatted(date: .long, time: .shortened)
        if let duration = meeting.duration, duration >= 60 {
            line += " · " + Lf("%d min", Int(duration / 60))
        }
        return line
    }

    static func markdown(_ meeting: ArchivedMeeting, report: MeetingReport) -> String {
        var lines = ["# \(MeetingReports.name(of: meeting))", "_\(dateLine(meeting))_", "",
                     "## \(L("Report")) · \(report.templateName)", ""]
        for answer in report.answers {
            lines.append("### \(answer.field)")
            lines.append("")
            lines.append(answer.isEmpty ? "_\(L("Not discussed"))_" : ReportText.markdown(answer.text))
            lines.append("")
        }
        lines.append("_\(L("Written by Dictate on this Mac from the transcript"))_")
        return lines.joined(separator: "\n") + "\n"
    }

    static func plainText(_ meeting: ArchivedMeeting, report: MeetingReport) -> String {
        var lines = [MeetingReports.name(of: meeting), dateLine(meeting),
                     "\(L("Report")) · \(report.templateName)", ""]
        for answer in report.answers {
            lines.append(answer.field)
            lines.append(answer.isEmpty ? L("Not discussed") : ReportText.plain(answer.text))
            lines.append("")
        }
        lines.append(L("Written by Dictate on this Mac from the transcript"))
        return lines.joined(separator: "\n") + "\n"
    }

    /// One row per meeting, a column per field of the template. Fields keep
    /// their full text; nothing is shortened.
    static func csv(_ meetings: [ArchivedMeeting], template: ReportTemplate) -> String {
        let fields = template.usableFields.map(\.name)
        func cell(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var rows = [([L("Meeting"), L("Date")] + fields).map(cell).joined(separator: ",")]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        for meeting in meetings {
            guard let report = meeting.reports.first(where: { $0.templateID == template.id || $0.templateName == template.name }) else { continue }
            var row = [cell(MeetingReports.name(of: meeting)), cell(f.string(from: meeting.started))]
            for field in fields {
                let answer = report.answers.first { $0.field == field }
                row.append(cell(answer.map { $0.isEmpty ? L("Not discussed") : ReportText.plain($0.text) } ?? ""))
            }
            rows.append(row.joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// The report in the app's reading typography: title and date, the
    /// fields as headings with their text, a one-line footer. No logo.
    static func attributed(_ meeting: ArchivedMeeting, report: MeetingReport) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                 color: NSColor = .textColor, italic: Bool = false, after: CGFloat = 6,
                 bullet: Bool = false) {
            var font = NSFont.systemFont(ofSize: size, weight: weight)
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = after
            paragraph.lineHeightMultiple = 1.15
            var line = text
            if bullet {
                // A hanging indent: the bullet in the margin, wrapped lines
                // aligned under the first word.
                paragraph.headIndent = 14
                paragraph.firstLineHeadIndent = 0
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
                line = "•\t" + text
            }
            out.append(NSAttributedString(string: line + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ]))
        }
        /// A field's text as its blocks: paragraphs, and lists item by item.
        func addField(_ text: String) {
            let blocks = ReportText.blocks(text)
            for (index, block) in blocks.enumerated() {
                let last = index == blocks.count - 1
                switch block {
                case .paragraph(let paragraph):
                    add(paragraph, size: 12, after: last ? 14 : 6)
                case .list(let items):
                    for (i, item) in items.enumerated() {
                        add(item, size: 12, after: last && i == items.count - 1 ? 14 : 2, bullet: true)
                    }
                }
            }
        }
        add(MeetingReports.name(of: meeting), size: 18, weight: .semibold, after: 2)
        add(dateLine(meeting) + " · " + L("Report") + " · " + report.templateName,
            size: 11, color: .secondaryLabelColor, after: 16)
        for answer in report.answers {
            add(answer.field, size: 13, weight: .semibold, after: 4)
            if answer.isEmpty {
                add(L("Not discussed"), size: 12, color: .secondaryLabelColor, italic: true, after: 14)
            } else {
                addField(answer.text)
            }
        }
        add(L("Written by Dictate on this Mac from the transcript"), size: 10,
            color: .secondaryLabelColor, after: 0)
        return out
    }

    private static func pdf(_ meeting: ArchivedMeeting, report: MeetingReport, to url: URL) -> Bool {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.topMargin = 56; info.bottomMargin = 56
        info.leftMargin = 60; info.rightMargin = 60
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.isEditable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(attributed(meeting, report: report))
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let height = view.layoutManager?.usedRect(for: view.textContainer!).height ?? 10
        view.frame.size.height = ceil(height) + 1
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run()
    }
}

/// The accessory under a save or open panel: the format, and for the many
/// case the CSV checkbox.
private final class FormatChooser: NSView {
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let csvBox: NSButton?
    var onChange: ((ReportExport.Format) -> Void)?

    var format: ReportExport.Format {
        ReportExport.Format.allCases[max(0, popup.indexOfSelectedItem)]
    }
    var wantsCSV: Bool { csvBox?.state == .on }

    init(initial: ReportExport.Format, csv: String?) {
        csvBox = csv.map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: csv == nil ? 36 : 64))
        let label = NSTextField(labelWithString: L("Format:"))
        label.alignment = .right
        for format in ReportExport.Format.allCases { popup.addItem(withTitle: format.label) }
        popup.selectItem(at: ReportExport.Format.allCases.firstIndex(of: initial) ?? 0)
        popup.target = self
        popup.action = #selector(changed)
        popup.sizeToFit()
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        var views: [NSView] = [row]
        if let csvBox { views.append(csvBox) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func changed() { onChange?(format) }
}
