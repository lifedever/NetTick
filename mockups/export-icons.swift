// 把设计稿要用的 App 图标导成 64px PNG：swift export-icons.swift
import AppKit
let items: [(String, String)] = [
  ("chrome", "/Applications/Google Chrome.app"),
  ("wechat", "/Applications/WeChat.app"),
  ("uu", "/Applications/UURemote.app"),
  ("viscosity", "/Applications/Viscosity.app"),
  ("wps", "/Applications/wpsoffice.app"),
  ("1password", "/Applications/1Password.app"),
  ("tabflick", "/Applications/TabFlick.app"),
  ("terminal", "/System/Applications/Utilities/Terminal.app"),
  ("system", "/System/Applications/System Settings.app"),
  ("exec", "/bin/ls"),
  ("surge", "/Applications/Surge.app"),
  ("ollama", "/bin/zsh"),
]
for (name, path) in items {
  let icon = NSWorkspace.shared.icon(forFile: path)
  let size = NSSize(width: 64, height: 64)
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  icon.draw(in: NSRect(origin: .zero, size: size))
  NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icons/\(name).png"))
}
print("ok")
