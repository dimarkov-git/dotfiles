# Yazi wrapper: a child process can't mutate its parent's PWD, so yazi writes
# its final cwd to --cwd-file and we cd there ourselves. `def --env` is
# required for that cd to reach the caller.
#
# Press `Q` inside yazi to exit without writing the file (stay put).

def --env y [...args] {
    let tmp = (mktemp -t "yazi-cwd.XXXXXX")
    yazi ...$args --cwd-file $tmp
    let cwd = (open $tmp | str trim)
    if ($cwd != "" and $cwd != $env.PWD) {
        cd $cwd
    }
    rm -fp $tmp
}
