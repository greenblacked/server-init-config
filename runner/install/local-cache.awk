# Remove only empty distributed-cache placeholders; preserve configured adapters.
function flush() {
  if (keep) printf "%s", block
  block = ""
  keep = 0
}
{
  line = $0
  sub(/^[[:space:]]+/, "", line)
  sub(/[[:space:]]+$/, "", line)
  header = (line ~ /^\[runners\.cache(\.(s3|gcs|azure))?\]$/)
  if (line ~ /^\[/ && !header) { flush(); active = 0 }
  if (header) active = 1
  if (!active) { print; next }
  block = block $0 ORS
  if (header || line == "" || line ~ /^#/) next
  if (line ~ /^(MaxUploadedArchiveSize|AssumeRoleMaxConcurrency)[[:space:]]*=[[:space:]]*0([[:space:]]*#.*)?$/) next
  keep = 1
}
END { flush() }
