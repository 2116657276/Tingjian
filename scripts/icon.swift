import AppKit
// 绘制简单图标:暖白底、墨色笺纸与一条声波
let dir = CommandLine.arguments[1]
func render(_ px: Int) -> Data {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let s = CGFloat(px)
    NSColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: s*0.06, y: s*0.06, width: s*0.88, height: s*0.88), xRadius: s*0.2, yRadius: s*0.2).fill()
    NSColor(red: 0.75, green: 0.22, blue: 0.17, alpha: 1).setStroke()
    let p = NSBezierPath(); p.lineWidth = s*0.045; p.lineCapStyle = .round
    let hs: [CGFloat] = [0.14, 0.32, 0.5, 0.26, 0.38, 0.18]
    for (i, h) in hs.enumerated() {
        let x = s*(0.22 + 0.112*CGFloat(i))
        p.move(to: NSPoint(x: x, y: s*0.5 - s*h/2)); p.line(to: NSPoint(x: x, y: s*0.5 + s*h/2))
    }
    p.stroke()
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
let sizes = [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
  ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),
  ("icon_512x512",512),("icon_512x512@2x",1024)]
for (name, px) in sizes {
    try render(px).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}
