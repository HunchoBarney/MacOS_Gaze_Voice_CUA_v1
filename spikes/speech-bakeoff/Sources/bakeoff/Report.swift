import Foundation

/// One report implementation, also independently callable from the terminal.
enum Report {
    static func generate(resultsPath: String, outPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            Measure.package.appendingPathComponent("report.py").path,
            "--results", resultsPath, "--output", outPath,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BakeoffError.engine("report recomputation failed")
        }
    }
}
