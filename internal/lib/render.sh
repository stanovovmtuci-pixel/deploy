#!/usr/bin/env bash
# render.sh - template rendering engine
# Sourced by phases. Substitutes {{VAR}} placeholders with env vars.

# render_template SRC DST
# Reads SRC, substitutes all {{VAR}} with $VAR from env, writes to DST.
# Fails if any placeholder is not in env.
render_template() {
    local src="$1"
    local dst="$2"

    [ -f "$src" ] || fail "render_template: source not found: $src"

    # Use python for robust substitution (avoids sed escape issues)
    python3 - "$src" "$dst" <<'PYEOF'
import os, re, sys

src_path, dst_path = sys.argv[1], sys.argv[2]

with open(src_path, 'r', encoding='utf-8') as f:
    content = f.read()

undefined = []

def sub_var(m):
    name = m.group(1)
    if name not in os.environ:
        undefined.append(name)
        return m.group(0)  # leave as-is for now
    return os.environ[name]

result = re.sub(r'\{\{([A-Z_0-9]+)\}\}', sub_var, content)

if undefined:
    sys.stderr.write("UNDEFINED placeholders: " + ", ".join(sorted(set(undefined))) + "\n")
    sys.exit(1)

# Ensure destination directory exists
os.makedirs(os.path.dirname(dst_path), exist_ok=True)

with open(dst_path, 'w', encoding='utf-8', newline='\n') as f:
    f.write(result)

print("rendered: " + dst_path)
PYEOF

    if [ "$?" -ne 0 ]; then
        fail "render_template failed: $src -> $dst"
    fi
}

# render_template_inline SRC DST
# Like render_template, but missing placeholders become empty string instead of failing.
# Useful for templates where some optional fields may be absent.
render_template_inline() {
    local src="$1"
    local dst="$2"

    [ -f "$src" ] || fail "render_template_inline: source not found: $src"

    python3 - "$src" "$dst" <<'PYEOF'
import os, re, sys

src_path, dst_path = sys.argv[1], sys.argv[2]

with open(src_path, 'r', encoding='utf-8') as f:
    content = f.read()

def sub_var(m):
    return os.environ.get(m.group(1), '')

result = re.sub(r'\{\{([A-Z_0-9]+)\}\}', sub_var, content)

os.makedirs(os.path.dirname(dst_path), exist_ok=True)

with open(dst_path, 'w', encoding='utf-8', newline='\n') as f:
    f.write(result)

print("rendered (lenient): " + dst_path)
PYEOF
}

# list_placeholders FILE -> echoes unique placeholders found in file
list_placeholders() {
    local file="$1"
    [ -f "$file" ] || fail "list_placeholders: file not found: $file"
    grep -ohE '\{\{[A-Z_0-9]+\}\}' "$file" 2>/dev/null | sort -u
}

# verify_no_placeholders FILE
# Checks that all placeholders in file are resolvable from env. Returns 0 ok, 1 fail.
verify_no_placeholders() {
    local file="$1"
    [ -f "$file" ] || fail "verify_no_placeholders: file not found: $file"

    local missing=""
    while IFS= read -r ph; do
        local name="${ph#\{\{}"
        name="${name%\}\}}"
        if [ -z "${!name:-}" ]; then
            missing="${missing}${name} "
        fi
    done < <(list_placeholders "$file")

    if [ -n "$missing" ]; then
        warn "Missing env vars for placeholders in $file: $missing"
        return 1
    fi
    return 0
}