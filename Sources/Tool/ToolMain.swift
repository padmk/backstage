// The command MCP clients run and people use to set the app up. It never uses Accessibility or other grants
// itself: everything that needs them happens in the app, which this command starts through LaunchServices.

import Foundation

@main
enum ToolMain {
  static func main() {
    // A client that goes away must end this process through a failed write, not a signal.
    signal(SIGPIPE, SIG_IGN)
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "mcp" { runMCPServer() }
    exit(runCommand(arguments))
  }
}
