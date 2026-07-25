# Bounds a ripgrep-style line stream to byteCap/lineCap/perLineBytes while
# writing accepted lines straight to `out` (PLAN15). Never buffers the full
# input: each line is checked and either written or the stream is abandoned.
#
# Reads one line beyond each limit before deciding "capped" so an input that
# ends exactly at the cap is not falsely reported as capped (the extra line,
# if any, is inspected but never written).
#
# Vars (set with -v): byteCap lineCap perLineBytes out
# Reports on stderr: capped=0|1 reason=<code|empty> lines=N bytes=N anyLineTruncated=0|1

BEGIN {
  total = 0
  lines = 0
  capped = 0
  reason = ""
  any_trunc = 0
}

{
  line = $0
  if (length(line) > perLineBytes) {
    line = substr(line, 1, perLineBytes)
    any_trunc = 1
  }
  line_bytes = length(line) + 1

  if (lines + 1 > lineCap) {
    capped = 1
    reason = "line_cap"
    exit
  }
  if (total + line_bytes > byteCap) {
    capped = 1
    reason = "byte_cap"
    exit
  }

  print line >> out
  total += line_bytes
  lines += 1
}

END {
  close(out)
  printf "capped=%d\n", capped > "/dev/stderr"
  printf "reason=%s\n", reason > "/dev/stderr"
  printf "lines=%d\n", lines > "/dev/stderr"
  printf "bytes=%d\n", total > "/dev/stderr"
  printf "anyLineTruncated=%d\n", any_trunc > "/dev/stderr"
}
