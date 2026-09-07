import PastePalLocalization
import AppKit
import Darwin

let arguments = ProcessInfo.processInfo.arguments
if arguments.contains("--render-website-previews") {
    guard let output = ProcessInfo.processInfo.environment["PASTEPAL_PREVIEW_OUTPUT"],
          let image = ProcessInfo.processInfo.environment["PASTEPAL_PREVIEW_IMAGE"] else {
        fputs(L("请通过 scripts/render-website-previews.sh 导出官网素材。\n"), stderr)
        exit(EXIT_FAILURE)
    }
    do {
        try WebsitePreviewRenderer.render(output: URL(fileURLWithPath: output), imageURL: URL(fileURLWithPath: image))
        exit(EXIT_SUCCESS)
    } catch {
        fputs(L("官网素材导出失败：\(error.localizedDescription)\n"), stderr)
        exit(EXIT_FAILURE)
    }
}
let smoke = arguments.contains("--smoke-test")
let migrationOnly = arguments.contains("--migrate-storage-only")
var migrationReport: AppStorageMigrationReport?
if !smoke {
    do {
        migrationReport = try AppStorageMigration.live().run()
    } catch {
        if migrationOnly {
            fputs(L("PastePal 迁移失败：\(error.localizedDescription)\n"), stderr)
        } else {
            _ = NSApplication.shared
            let alert = NSAlert()
            alert.messageText = L("PastePal 未能迁移数据")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L("退出"))
            alert.runModal()
        }
        exit(EXIT_FAILURE)
    }
}
if migrationOnly, let report = migrationReport {
    print(L("数据迁移：\(report.data.description)；设置迁移：\(report.preferences.description)"))
    exit(EXIT_SUCCESS)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
