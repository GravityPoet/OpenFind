import Foundation
import AppKit
import Dispatch

let args = CommandLine.arguments
if args.contains("--search") || args.contains("-s") {
    // Top-level code is @MainActor-isolated, so the Task below is scheduled on
    // the main actor, whose executor is the main thread's dispatch queue. We must
    // hand the main thread to that queue for the task to run; blocking it (e.g. a
    // semaphore wait) starves the main actor and deadlocks the task. dispatchMain()
    // parks the thread and drains the queue without spinning, and CLIRunner calls
    // exit() when the search finishes, which tears the process down.
    Task {
        await CLIRunner.run(arguments: args)
        exit(0)
    }
    dispatchMain()
} else {
    OpenFindApp.main()
}
