import Foundation
import AppKit

let args = CommandLine.arguments
if args.contains("--search") || args.contains("-s") {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await CLIRunner.run(arguments: args)
        semaphore.signal()
    }
    semaphore.wait()
} else {
    OpenFindApp.main()
}
