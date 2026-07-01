import Foundation
import AppKit

let args = CommandLine.arguments
if args.contains("--search") || args.contains("-s") {
    // Top-level code is @MainActor-isolated, so the Task below is scheduled on
    // the main actor, whose executor is the main thread's run loop. We must keep
    // that run loop alive for the task to start; blocking it (e.g. a semaphore
    // wait) starves the main actor and deadlocks the task. CLIRunner calls exit()
    // when the search finishes, which tears the process down.
    Task {
        await CLIRunner.run(arguments: args)
        exit(0)
    }
    RunLoop.current.run()
} else {
    OpenFindApp.main()
}
