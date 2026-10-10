import AppKit

let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(srgbRed: 0.06, green: 0.13, blue: 0.25, alpha: 1).setFill()
NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
NSColor(srgbRed: 0.37, green: 0.84, blue: 0.90, alpha: 1).setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 65
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 512, y: 765))
arrow.line(to: NSPoint(x: 512, y: 370))
arrow.move(to: NSPoint(x: 350, y: 530))
arrow.line(to: NSPoint(x: 512, y: 368))
arrow.line(to: NSPoint(x: 674, y: 530))
arrow.stroke()
NSColor.white.setStroke()
let tray = NSBezierPath()
tray.lineWidth = 55
tray.lineCapStyle = .round
tray.lineJoinStyle = .round
tray.move(to: NSPoint(x: 260, y: 330))
tray.line(to: NSPoint(x: 260, y: 240))
tray.line(to: NSPoint(x: 764, y: 240))
tray.line(to: NSPoint(x: 764, y: 330))
tray.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
