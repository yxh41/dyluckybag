import sys

def check(path):
    src = open(path, encoding='utf-8').read()
    i, n = 0, len(src)
    depth = 0
    stack = []
    line = 1
    in_line_comment = in_block_comment = in_string = False
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if c == '\n':
            line += 1
            in_line_comment = False
            i += 1
            continue
        if in_line_comment:
            i += 1
            continue
        if in_block_comment:
            if c == '*' and nxt == '/':
                in_block_comment = False
                i += 2
                continue
            i += 1
            continue
        if in_string:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if c == '/' and nxt == '/':
            in_line_comment = True
            i += 2
            continue
        if c == '/' and nxt == '*':
            in_block_comment = True
            i += 2
            continue
        if c == '@' and nxt == '"':
            in_string = True
            i += 2
            continue
        if c == '"':
            in_string = True
            i += 1
            continue
        if c == '{':
            depth += 1
            stack.append(line)
        elif c == '}':
            depth -= 1
            if stack:
                stack.pop()
        i += 1
    ok = (depth == 0 and not stack)
    print('%-20s depth=%d unclosed=%s %s' % (path, depth, stack, 'OK' if ok else 'MISMATCH'))
    return ok

if __name__ == '__main__':
    sys.exit(0 if all(check(p) for p in sys.argv[1:]) else 1)
