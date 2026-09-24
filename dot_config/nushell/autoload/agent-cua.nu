# `--cua` opts one run into cmux's computer-use MCP, off by default in env.nu.

def run-with-cua [cmd: string, args: list<string>] {
    let rest = ($args | where $it != "--cua")
    if ($rest | length) == ($args | length) { run-external $cmd ...$rest; return }
    with-env { CMUX_COMPUTER_USE_MCP_DISABLED: "0" } { run-external $cmd ...$rest }
}

def --wrapped claude [...args: string] { run-with-cua claude $args }

def --wrapped codex [...args: string] { run-with-cua codex $args }
