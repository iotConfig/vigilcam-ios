import Foundation

/// Drop-in replacement for print() that compiles away to nothing in Release builds.
/// Usage: dlog("something happened")
///
/// The @autoclosure + @inline(__always) combination means the string
/// interpolation is never even evaluated in production — zero cost.
@inline(__always)
func dlog(
    _ message: @autoclosure () -> String,
    file: StaticString = #file,
    line: UInt = #line
) {
#if DEBUG
    let filename = (file.description as NSString).lastPathComponent
    print("[\(filename):\(line)] \(message())")
#endif
}
