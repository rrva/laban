import Foundation

let result = LabanArgumentParser.parse(Array(CommandLine.arguments.dropFirst()))
switch result {
case .success(let command):
  let outcome = LabanCLI.run(command: command)
  let formatted = LabanCLI.formattedOutput(outcome)
  if !formatted.stdout.isEmpty {
    fputs(formatted.stdout, stdout)
  }
  if !formatted.stderr.isEmpty {
    fputs(formatted.stderr, stderr)
  }
  exit(outcome.exitCode)
case .failure(let error):
  fputs("laban: \(error)\n", stderr)
  fputs("Run 'laban help' for usage.\n", stderr)
  exit(2)
}
