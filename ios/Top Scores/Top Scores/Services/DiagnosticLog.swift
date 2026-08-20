import Foundation

@inline(__always)
nonisolated func diagnosticLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    NSLog("%@", message())
    #endif
}

@inline(__always)
nonisolated func diagnosticLog(_ format: String, _ arguments: CVarArg...) {
    #if DEBUG
    withVaList(arguments) { NSLogv(format, $0) }
    #endif
}

@inline(__always)
nonisolated func diagnosticPrint(_ item: @autoclosure () -> Any) {
    #if DEBUG
    print(item())
    #endif
}
