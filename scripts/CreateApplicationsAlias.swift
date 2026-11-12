// Uses Foundation bookmark files, which Finder treats as a folder alias on UDF.
// https://developer.apple.com/documentation/foundation/url/writebookmarkdata(_:to:)
import Foundation

var destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: false)
let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
let bookmark = try applications.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
try URL.writeBookmarkData(bookmark, to: destination)
var values = URLResourceValues()
values.hasHiddenExtension = true
try destination.setResourceValues(values)
let resolved = try URL(resolvingAliasFileAt: destination, options: .withoutUI)
guard resolved.standardizedFileURL.path == applications.path else { fatalError("Applications alias could not be resolved") }
