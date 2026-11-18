// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PDFKit

enum PlanError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

struct PaperSettings {
    enum Binding: String, CaseIterable { case long, short }
    enum Face: String, CaseIterable { case down, up }
    enum Head: String, CaseIterable { case inside, outside }

    let binding: Binding
    let outputFace: Face
    let reloadFace: Face
    let head: Head

    init(_ values: ArraySlice<String>) throws {
        let fields = Array(values)
        guard fields.count == 4,
              let binding = Binding(rawValue: fields[0]),
              let output = Face(rawValue: fields[1]),
              let reload = Face(rawValue: fields[2]),
              let head = Head(rawValue: fields[3]) else {
            throw PlanError.invalid("长短边或纸张朝向设置无效。")
        }
        self.binding = binding
        self.outputFace = output
        self.reloadFace = reload
        self.head = head
    }

    var flipStack: Bool { outputFace != reloadFace }
    var rotateSecond: Bool { (binding == .short) != (head == .outside) }
}

struct SheetLayout {
    let pagesPerSide: Int
    let columns: Int
    let rows: Int
    let order: String
    let border: String
    let copies: Int
    let collated: Bool

    init(_ fields: ArraySlice<String>) throws {
        let values = Array(fields)
        let grids = [1: (1, 1), 2: (1, 2), 4: (2, 2), 6: (2, 3), 9: (3, 3), 16: (4, 4)]
        let orders = ["btlr", "btrl", "lrbt", "lrtb", "rlbt", "rltb", "tblr", "tbrl"]
        let borders = ["none", "single", "single-thick", "double", "double-thick"]
        guard values.count == 5, let nup = Int(values[0]), let (columns, rows) = grids[nup],
              orders.contains(values[1]), borders.contains(values[2]),
              let copies = Int(values[3]), copies > 0,
              ["true", "false"].contains(values[4]) else {
            throw PlanError.invalid("每面页数、布局顺序、页框或份数设置无效。")
        }
        pagesPerSide = nup
        self.columns = columns
        self.rows = rows
        order = values[1]
        border = values[2]
        self.copies = copies
        collated = values[4] == "true"
    }

    func cell(_ slot: Int, on sheet: CGRect) -> CGRect {
        let acrossFirst = order.hasPrefix("lr") || order.hasPrefix("rl")
        let column = acrossFirst ? slot % columns : slot / rows
        let row = acrossFirst ? slot / columns : slot % rows
        let x = order.contains("rl") ? columns - 1 - column : column
        let y = order.contains("bt") ? row : rows - 1 - row
        let width = sheet.width / CGFloat(columns)
        let height = sheet.height / CGFloat(rows)
        return CGRect(x: CGFloat(x) * width, y: CGFloat(y) * height, width: width, height: height)
    }
}

struct PrintPlan {
    let first: [Int]
    let second: [Int]

    init(pages: Int, layout: SheetLayout, paper: PaperSettings) throws {
        let sides = (pages - 1) / layout.pagesPerSide + 1
        let sheets = (sides - 1) / 2 + 1
        let (total, overflow) = sheets.multipliedReportingOverflow(by: layout.copies)
        guard !overflow, total <= Int(Int32.max) else {
            throw PlanError.invalid("这次打印的张数过多。")
        }
        let sheetAt = (0..<total).map { layout.collated ? $0 % sheets : $0 / layout.copies }
        // The last sheet printed ends up on top. A whole-stack turn reverses its feed order.
        let finalOrder = paper.outputFace == .down ? sheetAt : Array(sheetAt.reversed())
        let firstOrder = paper.flipStack ? finalOrder : Array(finalOrder.reversed())
        // Sides are zero-based. An out-of-range final back is drawn as a full blank sheet.
        first = firstOrder.map { 2 * $0 + 1 }
        second = finalOrder.map { 2 * $0 }
    }
}

struct PassPDFs {
    let document: CGPDFDocument
    let sheet: CGRect
    let layout: SheetLayout

    init(source: URL, layout: SheetLayout) throws {
        guard let input = PDFDocument(url: source), !input.isLocked, input.allowsPrinting,
              input.pageCount > 0 else {
            throw PlanError.invalid("无法读取可打印的 PDF 页面。")
        }
        var quartz: CGPDFDocument?
        let pages = (0..<input.pageCount).compactMap { input.page(at: $0) }
        if pages.contains(where: { $0.annotations.contains(where: \.shouldPrint) }) {
            for page in pages {
                for annotation in page.annotations where !annotation.shouldPrint {
                    page.removeAnnotation(annotation)
                }
            }
            if let data = input.dataRepresentation(options: [PDFDocumentWriteOption.burnInAnnotationsOption: true]),
               let provider = CGDataProvider(data: data as CFData) {
                quartz = CGPDFDocument(provider)
            }
        } else {
            quartz = CGPDFDocument(source as CFURL)
        }
        guard let document = quartz, document.numberOfPages == input.pageCount,
              let first = document.page(at: 1) else {
            throw PlanError.invalid("无法读取完整的 PDF 页面或批注。")
        }
        let media = first.getBoxRect(.mediaBox)
        guard Self.valid(media) else { throw PlanError.invalid("无效的 PDF 纸张尺寸。") }
        sheet = CGRect(x: 0, y: 0, width: min(media.width, media.height), height: max(media.width, media.height))
        self.document = document
        self.layout = layout
    }

    private static func valid(_ box: CGRect) -> Bool {
        box.width.isFinite && box.height.isFinite && box.width > 0 && box.height > 0
    }

    func write(_ sides: [Int], rotated: Bool, to url: URL) throws {
        var mediaBox = sheet
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw PlanError.invalid("无法创建打印版 PDF。")
        }
        defer { context.closePDF() }
        for side in sides {
            context.beginPDFPage(nil)
            defer { context.endPDFPage() }
            context.saveGState()
            defer { context.restoreGState() }
            // Draw white explicitly so even an empty back is a real PDF page.
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(sheet)
            if rotated {
                context.translateBy(x: sheet.width, y: sheet.height)
                context.rotate(by: .pi)
            }
            for slot in 0..<layout.pagesPerSide {
                let index = side * layout.pagesPerSide + slot + 1
                if index > document.numberOfPages { break }
                try draw(index, slot: slot, in: context)
            }
        }
    }

    private func draw(_ index: Int, slot: Int, in context: CGContext) throws {
        guard let page = document.page(at: index) else {
            throw PlanError.invalid("无法读取第 \(index) 页。")
        }
        let media = page.getBoxRect(.mediaBox)
        let crop = page.getBoxRect(.cropBox)
        guard Self.valid(media), Self.valid(crop) else {
            throw PlanError.invalid("第 \(index) 页的尺寸无效。")
        }
        let quarterTurn = abs(page.rotationAngle % 180) == 90
        let landscape = quarterTurn ? media.height > media.width : media.width > media.height
        let cell = layout.cell(slot, on: sheet)
        let target = layout.pagesPerSide == 1 ? cell : cell.insetBy(dx: cell.width * 0.03, dy: cell.height * 0.03)
        let transform = page.getDrawingTransform(.mediaBox, rect: target, rotate: landscape ? 90 : 0,
                                                 preserveAspectRatio: true)
        context.saveGState()
        context.clip(to: cell)
        context.concatenate(transform)
        context.clip(to: crop)
        context.drawPDFPage(page)
        context.restoreGState()
        if layout.border != "none" {
            let bounds = media.applying(transform).standardized
            context.setStrokeColor(gray: 0, alpha: 1)
            context.setLineWidth(layout.border.hasSuffix("-thick") ? 1 : 0.5)
            context.stroke(bounds.insetBy(dx: 1, dy: 1))
            if layout.border.hasPrefix("double") {
                context.stroke(bounds.insetBy(dx: 3, dy: 3))
            }
        }
    }
}

@main
struct DuplexPlanTool {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            switch arguments.first {
            case "choose" where arguments.count == 9 && ["print", "settings"].contains(arguments[1]):
                let paper = try PaperSettings(arguments[3...6])
                if !choose(paper, printer: arguments[2], printing: arguments[1] == "print",
                           engine: arguments[7], queue: arguments[8]) { exit(2) }
            case "prepare" where arguments.count == 12:
                let paper = try PaperSettings(arguments[3...6])
                let layout = try SheetLayout(arguments[7...11])
                let source = URL(fileURLWithPath: arguments[1])
                let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
                let pdfs = try PassPDFs(source: source, layout: layout)
                let plan = try PrintPlan(pages: pdfs.document.numberOfPages, layout: layout, paper: paper)
                let first = directory.appendingPathComponent("first.pdf")
                let second = directory.appendingPathComponent("second.pdf")
                try pdfs.write(plan.first, rotated: false, to: first)
                try pdfs.write(plan.second, rotated: paper.rotateSecond, to: second)
                guard plan.first.count == plan.second.count,
                      CGPDFDocument(first as CFURL)?.numberOfPages == plan.second.count,
                      CGPDFDocument(second as CFURL)?.numberOfPages == plan.second.count else {
                    throw PlanError.invalid("两趟 PDF 张数校验失败。")
                }
                print(plan.second.count)
            default:
                throw PlanError.invalid("无效的 Print Two-Sided 命令。")
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    @MainActor
    private static func choose(_ paper: PaperSettings, printer: String, printing: Bool,
                               engine: String, queue: String) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = "手动双面打印"
        alert.informativeText = printer
        if let icon = NSImage(contentsOfFile: NSHomeDirectory() + "/.config/manual-duplex/manual-duplex.icns") {
            alert.icon = icon
        }
        alert.addButton(withTitle: printing ? "打印" : "保存配置")
        if printing { alert.addButton(withTitle: "保存配置") }
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 168))
        func row(_ title: String, _ choices: [String], _ selection: Int, y: CGFloat) -> NSPopUpButton {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 0, y: y + 3, width: 122, height: 20)
            view.addSubview(label)
            let popup = NSPopUpButton(frame: NSRect(x: 124, y: y, width: 236, height: 25))
            popup.addItems(withTitles: choices)
            popup.selectItem(at: selection)
            popup.setAccessibilityLabel(title)
            view.addSubview(popup)
            return popup
        }
        let binding = row("翻转方式", ["沿长边翻转", "沿短边翻转"], paper.binding == .long ? 0 : 1, y: 139)
        let output = row("出纸时已印面", ["朝下", "朝上"], paper.outputFace == .down ? 0 : 1, y: 107)
        let reload = row("放回时已印面", ["朝下（空白面朝上）", "朝上（空白面朝下）"],
                         paper.reloadFace == .down ? 0 : 1, y: 75)
        let head = row("出纸时页首（竖版）", ["靠机身", "朝外"], paper.head == .inside ? 0 : 1, y: 43)
        let hint = NSTextField(wrappingLabelWithString: "奇数面自动补白，两趟张数相同。放回时请保持整叠页序。")
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 0, y: 0, width: 360, height: 34)
        view.addSubview(hint)
        alert.accessoryView = view
        func selection() -> String {
            [PaperSettings.Binding.allCases[binding.indexOfSelectedItem].rawValue,
             PaperSettings.Face.allCases[output.indexOfSelectedItem].rawValue,
             PaperSettings.Face.allCases[reload.indexOfSelectedItem].rawValue,
             PaperSettings.Head.allCases[head.indexOfSelectedItem].rawValue].joined(separator: " ")
        }
        app.activate(ignoringOtherApps: true)
        var response = alert.runModal()
        while printing && response == .alertSecondButtonReturn {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [engine, "--save-paper", queue, printer, selection()]
            do {
                try process.run()
                process.waitUntilExit()
                hint.stringValue = process.terminationStatus == 0 ? "配置已保存。" : "保存失败，请重试。"
            } catch {
                hint.stringValue = "保存失败，请重试。"
            }
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return false }
        print(selection())
        return true
    }
}
