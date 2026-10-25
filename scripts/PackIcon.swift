import Foundation

// ICNS is a big-endian container of standard PNG representations; artwork stays unchanged.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: PackIcon.swift <iconset directory> <output.icns>")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let representations = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png")
]
func length(_ value: Int) -> Data {
    var big = UInt32(value).bigEndian
    return withUnsafeBytes(of: &big) { Data($0) }
}
var contents = Data()
for (type, file) in representations {
    let png = try Data(contentsOf: input.appendingPathComponent(file))
    contents.append(Data(type.utf8))
    contents.append(length(png.count + 8))
    contents.append(png)
}
var icon = Data("icns".utf8)
icon.append(length(contents.count + 8))
icon.append(contents)
try icon.write(to: output, options: .atomic)

