# -*- coding: utf-8 -*-
"""Python -> Mo (Mocode) 自动转换器。

将任意 Python 源码转换为 Mo 方言（可被 mo_transpiler.py 转译回等效 Python）：

  - class / def / try 块 -> 花括号 { }（if/for/while/with 保持冒号缩进）
  - def __init__ -> fn ClassName；def -> fn；async def -> async fn
  - @staticmethod/@classmethod -> static fn / class fn；其他装饰器保留
  - self. -> this.，None -> null，True/False -> true/false（字符串内不替换）
  - # 注释 -> // 注释（多行字面量内部注释丢弃）
  - 多行 () [] {} 字面量合并为单行（字符串 / 三引号内容除外）
  - except X as e: -> } catch X as e {，finally: -> } finally {，else(接 try) -> } else {
  - 参数/返回类型注解丢弃（转译器不依赖，避免嵌套泛型破坏解析）

用法：
  python py_to_mo.py <file.py> ...              # 在 .py 旁生成 .mo
  python py_to_mo.py <dir> [--out <dir>]        # 递归转换目录（镜像到 --out）
"""
import os
import re
import sys

# ---------------------------------------------------------------------------
# 1) 多行字面量合并 + 逻辑行切分
# ---------------------------------------------------------------------------

def compact_lines(src: str):
    """按括号平衡与字符串状态，把源码切成「逻辑行」；
    多行 () [] {} 字面量 / 反斜杠续行合并为单行。"""
    lines = []
    line = ""
    stack = []
    state = None          # None | '"' | "'" | '"""' | "'''"
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        nxt = src[i:i + 3]
        if state is None:
            if c in '"\'':
                if nxt in ('"""', "'''"):
                    state = nxt
                    line += nxt
                    i += 3
                    continue
                state = c
                line += c
                i += 1
                continue
            if c == '#':
                if stack:
                    # 括号续行内注释直接丢弃（合并后会破坏行）
                    while i < n and src[i] != '\n':
                        i += 1
                else:
                    while i < n and src[i] != '\n':
                        line += src[i]
                        i += 1
                continue
            if c in '([{':
                stack.append(c)
                line += c
                i += 1
                continue
            if c in ')]}':
                if stack:
                    stack.pop()
                line += c
                i += 1
                continue
            if c == '\\' and i + 1 < n and src[i + 1] == '\n':
                line += ' '
                i += 2
                continue
            if c == '\n':
                if not stack:
                    lines.append(line.rstrip())
                    line = ""
                else:
                    line += ' '
                    # 跳过续行前导空白，合并后保持单空格
                    while i + 1 < n and src[i + 1] in ' \t':
                        i += 1
                i += 1
                continue
            line += c
            i += 1
            continue
        # 字符串内部
        line += c
        if state in ('"""', "'''"):
            if nxt == state:
                line += state[1:]
                i += 3
                state = None
                continue
            i += 1
            continue
        if c == '\\':
            if i + 1 < n:
                line += src[i + 1]
                i += 2
                continue
            i += 1
            continue
        if c == state:
            state = None
        i += 1
    if line.strip():
        lines.append(line.rstrip())
    return lines


def split_comment(code: str):
    """返回 (代码, 注释文本)。# 在字符串内不视为注释。"""
    out = []
    i, n = 0, len(code)
    state = None
    while i < n:
        c = code[i]
        nxt = code[i:i + 3]
        if state is None:
            if c in '"\'':
                if nxt in ('"""', "'''"):
                    state = nxt
                    out.append(nxt)
                    i += 3
                    continue
                state = c
                out.append(c)
                i += 1
                continue
            if c == '#':
                return "".join(out), code[i + 1:].strip()
            out.append(c)
            i += 1
            continue
        if state in ('"""', "'''"):
            if nxt == state:
                out.append(state)
                i += 3
                state = None
                continue
            out.append(c)
            i += 1
            continue
        if c == '\\':
            if i + 1 < n:
                out.append(code[i:i + 2])
                i += 2
                continue
            out.append(c)
            i += 1
            continue
        if c == state:
            state = None
        out.append(c)
        i += 1
    return "".join(out), ""


# ---------------------------------------------------------------------------
# 2) 标识符级替换（字符串安全）
# ---------------------------------------------------------------------------

_WORD = {"self": "this", "None": "null", "True": "true", "False": "false"}


def token_replace(code: str) -> str:
    """替换 self/None/True/False，跳过字符串字面量。"""
    out = []
    i, n = 0, len(code)
    while i < n:
        c = code[i]
        if c in '"\'':
            nxt = code[i:i + 3]
            if nxt in ('"""', "'''"):
                j = code.find(nxt, i + 3)
                if j == -1:
                    out.append(code[i:])
                    break
                out.append(code[i:j + 3])
                i = j + 3
                continue
            j = i + 1
            while j < n:
                if code[j] == '\\':
                    j += 2
                    continue
                if code[j] == c:
                    break
                j += 1
            out.append(code[i:j + 1])
            i = j + 1
            continue
        if c.isalpha() or c == '_':
            j = i
            while j < n and (code[j].isalnum() or code[j] == '_'):
                j += 1
            w = code[i:j]
            out.append(_WORD.get(w, w))
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


# ---------------------------------------------------------------------------
# 3) 顶层逗号 / 括号切分辅助
# ---------------------------------------------------------------------------

def _find_matching(code, start):
    """code[start] 必须是 ( [ {；返回与之匹配的闭括号下标。"""
    pairs = {'(': ')', '[': ']', '{': '}'}
    open_c = code[start]
    close_c = pairs[open_c]
    depth = 0
    i = start
    n = len(code)
    while i < n:
        c = code[i]
        if c in '"\'':
            nxt = code[i:i + 3]
            if nxt in ('"""', "'''"):
                j = code.find(nxt, i + 3)
                i = j + 3 if j != -1 else n
                continue
            j = i + 1
            while j < n:
                if code[j] == '\\':
                    j += 2
                    continue
                if code[j] == c:
                    break
                j += 1
            i = j + 1
            continue
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n


def split_top_level(text: str):
    """按顶层逗号切分（括号 / 字符串内逗号不切；lambda 参数区内的逗号不切）。"""
    parts = []
    cur = []
    depth = 0
    i, n = 0, len(text)
    in_lambda = False
    state = None
    while i < n:
        c = text[i]
        if state is None:
            if c in '"\'':
                nxt = text[i:i + 3]
                if nxt in ('"""', "'''"):
                    state = nxt
                    cur.append(nxt)
                    i += 3
                    continue
                state = c
                cur.append(c)
                i += 1
                continue
            if c in '([{':
                depth += 1
            elif c in ')]}':
                depth -= 1
            if depth == 0 and not in_lambda and c == ',':
                parts.append("".join(cur).strip())
                cur = []
                i += 1
                continue
            if depth == 0:
                if not in_lambda:
                    if c == 'l' and text.startswith("lambda", i) and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == '_')):
                        in_lambda = True
                elif c == ':':
                    in_lambda = False
            cur.append(c)
            i += 1
            continue
        # 字符串内
        if state in ('"""', "'''"):
            if text[i:i + 3] == state:
                cur.append(state)
                i += 3
                state = None
                continue
            cur.append(c)
            i += 1
            continue
        if c == '\\':
            if i + 1 < n:
                cur.append(text[i:i + 2])
                i += 2
                continue
            cur.append(c)
            i += 1
            continue
        if c == state:
            state = None
        cur.append(c)
        i += 1
    if cur or parts:
        parts.append("".join(cur).strip())
    return [p for p in parts if p]


def escape_floor_div(code: str) -> str:
    """把代码中的整除 // 替换为 \\x01 占位（转译器恢复为 //）。
    字符串内跳过；f-string 的 {..} 代码区内也替换。"""
    out = []
    i, n = 0, len(code)
    state = None
    is_f = False
    f_brace = 0
    while i < n:
        c = code[i]
        nxt = code[i:i + 3]
        if state is None:
            if c in '"\'':
                prev = code[i - 1] if i > 0 else ""
                is_f = prev in ("f", "F") and (i < 2 or not (code[i - 2].isalnum() or code[i - 2] == '_'))
                if nxt in ('"""', "'''"):
                    state = nxt
                    f_brace = 0
                    out.append(nxt)
                    i += 3
                    continue
                state = c
                f_brace = 0
                out.append(c)
                i += 1
                continue
            if c == '/' and i + 1 < n and code[i + 1] == '/':
                out.append("\x01")
                i += 2
                continue
            out.append(c)
            i += 1
            continue
        # 字符串内（f-string 的 {..} 代码区内也替换整除 //）
        if is_f:
            if c == '{':
                f_brace += 1
            elif c == '}' and f_brace > 0:
                f_brace -= 1
            elif f_brace > 0 and c == '/' and i + 1 < n and code[i + 1] == '/':
                out.append("\x01")
                i += 2
                continue
        if state in ('"""', "'''"):
            if nxt == state:
                out.append(state)
                i += 3
                state = None
                continue
            out.append(c)
            i += 1
            continue
        if c == '\\':
            if i + 1 < n:
                out.append(code[i:i + 2])
                i += 2
                continue
            out.append(c)
            i += 1
            continue
        if c == state:
            state = None
        out.append(c)
        i += 1
    return "".join(out)


def strip_param_annotations(param: str) -> str:
    """x: dict = None -> x = None；x: int -> x；*args / **kwargs 原样。
    lambda 体内的冒号（lambda x: body）与字符串内的冒号（"https://"）都不是注解冒号。"""
    p = param.strip()
    if not p:
        return p
    depth = 0
    i, n = 0, len(p)
    colon_at = -1
    in_lambda = False
    state = None
    while i < n:
        c = p[i]
        if state is not None:
            if c == '\\':
                i += 2
                continue
            if c == state:
                state = None
            i += 1
            continue
        if c in '"\'':
            state = c
            i += 1
            continue
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif c == ':' and depth == 0:
            if in_lambda:
                # lambda 体冒号，非注解；后续冒号（如 dict 内）有括号保护
                in_lambda = False
            else:
                colon_at = i
                break
        elif depth == 0 and not in_lambda and c == 'l' and p.startswith("lambda", i) and (i == 0 or not (p[i - 1].isalnum() or p[i - 1] == '_')):
            in_lambda = True
        i += 1
    if colon_at == -1:
        return p
    left = p[:colon_at].strip()
    rest = p[colon_at + 1:]
    # 取注解后的默认值（顶层 =）
    depth = 0
    eq_at = -1
    for i2, c in enumerate(rest):
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif c == '=' and depth == 0:
            eq_at = i2
            break
    if eq_at != -1:
        return left + " " + rest[eq_at:].strip()
    return left


# ---------------------------------------------------------------------------
# 4) 行分类
# ---------------------------------------------------------------------------

_DEF_RE = re.compile(r"^(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\(")
_CLASS_RE = re.compile(r"^class\s+([A-Za-z_]\w*)\s*")
_TRY_RE = re.compile(r"^try\s*:\s*$")
_EXCEPT_RE = re.compile(r"^except(?:\s+([^:]+?))?\s*:\s*$")
_ELSE_RE = re.compile(r"^else\s*:\s*$")
_FINALLY_RE = re.compile(r"^finally\s*:\s*$")
_SIMPLE_BASE = re.compile(r"^[A-Za-z_]\w*$")


# ---------------------------------------------------------------------------
# 5) 主转换
# ---------------------------------------------------------------------------

def to_mo(src: str) -> str:
    lines = compact_lines(src)
    out = []
    stack = []            # [(indent, kind, virtual)] kind in {"cls","fn","try"}；virtual 类不输出 } 闭合
    pending_deco = []     # 待定的装饰器行（@staticmethod/@classmethod 折叠）
    cur_class = None

    def w(level):
        return len(level)

    def close_above(indent):
        iw = w(indent)
        while stack and w(stack[-1][0]) >= iw:
            entry = stack.pop()
            if not entry[2]:
                out.append(entry[0] + "}")

    for raw in lines:
        indent = raw[: len(raw) - len(raw.lstrip())]
        body = raw.lstrip()
        code, comment = split_comment(body)
        code = code.rstrip()

        # 空行 / 纯注释行（注释保持 # 直通，避免与整除 // 冲突）
        if not code:
            if comment:
                out.append(indent + "# " + comment)
            else:
                out.append("")
            continue

        # try-compound 续行：} catch / } finally / } else（不弹栈）
        if stack and w(stack[-1][0]) == w(indent) and stack[-1][1] == "try":
            m = _EXCEPT_RE.match(code)
            if m:
                rest = m.group(1)
                if rest:
                    r = rest.strip()
                    if re.search(r"\bas\b", r):
                        out.append(indent + "} catch " + r + " {")
                    else:
                        # 显式绑定 e，避免与「单标识符 = 绑定」的转译约定冲突
                        out.append(indent + "} catch " + r + " as e {")
                else:
                    out.append(indent + "} catch {")
                continue
            if _FINALLY_RE.match(code):
                out.append(indent + "} finally {")
                continue
            if _ELSE_RE.match(code):
                out.append(indent + "} else {")
                continue

        close_above(indent)

        # -------- def --------
        m = _DEF_RE.match(code)
        if m:
            name = m.group(1)
            paren = code.find("(", m.end() - 1)
            close = _find_matching(code, paren)
            params_raw = code[paren + 1:close]
            params = [strip_param_annotations(p) for p in split_top_level(params_raw)]

            static_flag = False
            class_flag = False
            deco_lines = []
            for d in pending_deco:
                if d == "@staticmethod":
                    static_flag = True
                elif d == "@classmethod":
                    class_flag = True
                else:
                    deco_lines.append(d)
            pending_deco = []

            if static_flag:
                sig = "static fn " + name
            elif class_flag:
                # 丢弃首参 cls
                if params and params[0] in ("cls", "self"):
                    params = params[1:]
                sig = "class fn " + name
            elif cur_class and name == "__init__":
                if params and params[0] in ("self", "cls"):
                    params = params[1:]
                sig = "fn " + cur_class
            else:
                # 仅类直接方法丢弃首参 self；闭包/模块级函数保留（self 可能是普通参数名）
                is_method = bool(stack) and stack[-1][1] == "cls"
                if is_method and params and params[0] == "self":
                    params = params[1:]
                # __new__ 隐式静态方法，首参 cls 由转译器补回
                if name == "__new__" and params and params[0] == "cls":
                    params = params[1:]
                async_flag = code.lstrip().startswith("async")
                sig = ("async fn " if async_flag else "fn ") + name

            for d in deco_lines:
                out.append(indent + escape_floor_div(d))
            out.append(indent + escape_floor_div(sig + "(" + ", ".join(params) + ") {"))
            stack.append((indent, "fn", False))
            continue

        # -------- class --------
        m = _CLASS_RE.match(code)
        if m:
            name = m.group(1)
            rest = code[m.end():]
            bases = []
            if rest.startswith("("):
                close = _find_matching(code, m.end())
                base_text = code[m.end() + 1:close]
                bases = [b for b in split_top_level(base_text) if b]
            brace_ok = len(bases) <= 1 and (not bases or _SIMPLE_BASE.match(bases[0]))
            cur_class = name
            for d in pending_deco:
                out.append(indent + escape_floor_div(d))
            pending_deco = []
            if brace_ok:
                parent = bases[0] if bases else ""
                out.append(indent + escape_floor_div(f"class {name} {{" if not parent else f"class {name} extends {parent} {{"))
                stack.append((indent, "cls", False))
            else:
                # 多父类 / 复杂基类：保持冒号直通（转译器原样保留）；虚拟压栈供方法判定，不输出 }
                out.append(indent + escape_floor_div(code))
                stack.append((indent, "cls", True))
            continue

        # -------- try --------
        if _TRY_RE.match(code):
            out.append(indent + "try {")
            stack.append((indent, "try", False))
            continue

        # -------- 装饰器 --------
        if code.startswith("@"):
            pending_deco.append(code)
            continue

        # -------- 其他语句 --------
        line = indent + escape_floor_div(token_replace(code))
        if comment:
            line += "  # " + comment
        out.append(line)

    # 文件结束：闭合剩余块（跳过虚拟直通类）
    while stack:
        entry = stack.pop()
        if not entry[2]:
            out.append(entry[0] + "}")
    return "\n".join(out)


# ---------------------------------------------------------------------------
# 6) 入口
# ---------------------------------------------------------------------------

def convert_file(py_path, mo_path):
    with open(py_path, "r", encoding="utf-8") as f:
        src = f.read()
    mo = to_mo(src)
    with open(mo_path, "w", encoding="utf-8") as f:
        f.write(mo)
    return mo_path


def main() -> int:
    args = sys.argv[1:]
    out_dir = None
    if "--out" in args:
        i = args.index("--out")
        out_dir = args[i + 1]
        args = args[:i] + args[i + 2:]
    if not args:
        print(__doc__)
        return 1
    targets = []
    for a in args:
        if os.path.isdir(a):
            for dp, dn, fn in os.walk(a):
                dn[:] = [d for d in dn if d not in (".git", "node_modules", "__pycache__", "generated", "mocode")]
                for f in fn:
                    if f.endswith(".py"):
                        targets.append(os.path.join(dp, f))
        elif a.endswith(".py"):
            targets.append(a)
    count = 0
    failed = []
    for py_path in sorted(targets):
        if py_path.endswith("py_to_mo.py"):
            continue
        if out_dir:
            mo_path = os.path.join(out_dir, os.path.relpath(py_path))[:-3] + ".mo"
        else:
            mo_path = py_path[:-3] + ".mo"
        try:
            os.makedirs(os.path.dirname(mo_path), exist_ok=True)
            convert_file(py_path, mo_path)
            count += 1
            print(f"[mo] {py_path} -> {mo_path}")
        except Exception as e:
            failed.append((py_path, str(e)))
            print(f"[FAIL] {py_path}: {e}")
    print(f"done, {count} file(s), {len(failed)} failed")
    for p, e in failed:
        print(f"  - {p}: {e}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
