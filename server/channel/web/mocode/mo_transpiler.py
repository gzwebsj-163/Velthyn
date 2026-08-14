# -*- coding: utf-8 -*-
"""Mocode (Mo) -> Python 通用转译器。

将 Mo 核心业务层源码（channel/web/mocode/*.mo）转译为等效 Python 模块：

  python mo_transpiler.py <mo_dir> [out_dir]

规则（对齐 mocode-lab/_mo_transpile.py 既有实现）：
  - class / fn / 构造函数 / try / catch / finally / else 使用 { } 块
  - static fn -> @staticmethod，class fn -> @classmethod（注入 cls）
  - if / for / while / with 使用冒号 + 缩进（Mo 源码自带缩进）
  - void 成员声明 / 局部声明 -> 去掉 void
  - this. -> self.，独立 this -> self
  - null -> None，true/false -> True/False
  - enum { A, B } -> class E(Enum): A=1 B=2
  - const NAME = v -> NAME = v
"""
import os
import re
import sys

# 块起始行（class/fn/try 用 { }，仅这些开头算块；if/for/with 用冒号缩进不入栈）
_BLOCK_RE = re.compile(
    r"^(?:abstract\s+)?(?:class|fn)\s+\w+.*\{\s*$|"
    r"^(?:try|finally|else)\b.*\{\s*$"
)
_CATCH_RE = re.compile(r"^}\s*(catch|finally|else)\b(.*)$")
_CLASS_RE = re.compile(r"(?:abstract\s+)?class\s+(\w+)(?:\s+extends\s+(\w+))?\s*\{")
_ENUM_RE = re.compile(r"enum\s+(\w+)\s*\{")


def _split_top_level(text: str):
    """顶层逗号切分（括号 / 字符串内逗号不切；lambda 参数区内的逗号不切）。"""
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


def _strip_annot(p: str) -> str:
    """x: dict = None -> x=None；x: Callable[[dict], None] = f -> x=f；无注解原样。
    lambda 体冒号与字符串内冒号（"https://"）不是注解冒号。"""
    p = p.strip()
    depth = 0
    colon = -1
    in_lambda = False
    state = None
    i, n = 0, len(p)
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
                in_lambda = False
            else:
                colon = i
                break
        elif depth == 0 and not in_lambda and c == 'l' and p.startswith("lambda", i) and (i == 0 or not (p[i - 1].isalnum() or p[i - 1] == '_')):
            in_lambda = True
        i += 1
    if colon == -1:
        return p
    left = p[:colon].strip()
    rest = p[colon + 1:]
    depth = 0
    eq = -1
    for j, c in enumerate(rest):
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif c == '=' and depth == 0:
            eq = j
            break
    if eq != -1:
        return left + rest[eq:]
    return left


def _clean_params(params: str) -> str:
    if not params.strip():
        return ""
    parts = []
    for p in _split_top_level(params):
        p = _strip_annot(p)
        p = p.replace("null", "None")
        p = re.sub(r"\bfalse\b", "False", p)
        p = re.sub(r"\btrue\b", "True", p)
        parts.append(p)
    return ", ".join(parts)


def _parse_fn(line: str):
    """Mo fn 行 -> (kind, name, params) 或 None。
    kind ∈ {"static","class","abstract","async","fn"}；括号按深度平衡解析。"""
    s = line
    kind = "fn"
    for pre in ("abstract ", "static ", "class ", "async "):
        if s.startswith(pre):
            kind = pre.strip()
            s = s[len(pre):]
            break
    m = re.match(r"fn\s+([A-Za-z_]\w*)\s*\(", s)
    if not m:
        return None
    name = m.group(1)
    i = m.end() - 1  # '('
    depth = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return kind, name, s[m.end():i]
        i += 1
    return kind, name, ""


def _enclosing_kind(stack, indent):
    """最近的 class/fn 包围块类型：'class'=方法 / 'fn'=闭包 / None=模块级。"""
    iw = len(indent)
    for entry in reversed(stack):
        if len(entry[0]) < iw and entry[1] in ("class", "fn"):
            return entry[1]
    return None


_MAP = {"this": "self", "null": "None", "true": "True", "false": "False"}


def _tok(line: str) -> str:
    """Mo -> Python 标识符替换（字符串内不替换；f-string {..} 代码区内替换）。"""
    out = []
    i, n = 0, len(line)
    state = None
    is_f = False
    f_brace = 0
    while i < n:
        c = line[i]
        if state is None:
            if c in '"\'':
                nxt = line[i:i + 3]
                prev = line[i - 1] if i > 0 else ""
                is_f = prev in ("f", "F") and (i < 2 or not (line[i - 2].isalnum() or line[i - 2] == '_'))
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
            if c.isalpha() or c == '_':
                j = i
                while j < n and (line[j].isalnum() or line[j] == '_'):
                    j += 1
                out.append(_MAP.get(line[i:j], line[i:j]))
                i = j
                continue
            out.append(c)
            i += 1
            continue
        # 字符串内
        if is_f:
            if c == '{':
                f_brace += 1
            elif c == '}' and f_brace > 0:
                f_brace -= 1
            elif f_brace > 0 and (c.isalpha() or c == '_'):
                j = i
                while j < n and (line[j].isalnum() or line[j] == '_'):
                    j += 1
                out.append(_MAP.get(line[i:j], line[i:j]))
                i = j
                continue
        if state in ('"""', "'''"):
            if line[i:i + 3] == state:
                out.append(state)
                i += 3
                state = None
                continue
            out.append(c)
            i += 1
            continue
        if c == '\\':
            if i + 1 < n:
                out.append(line[i:i + 2])
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


def _unclosed_triple(line: str):
    """若行内出现未在本行闭合的三引号，返回 (opener, 开引号下标)；否则 None。"""
    i, n = 0, len(line)
    state = None
    while i < n:
        c = line[i]
        if state is None:
            if c in '"\'':
                nxt = line[i:i + 3]
                if nxt in ('"""', "'''"):
                    j = line.find(nxt, i + 3)
                    if j == -1:
                        return nxt, i
                    i = j + 3
                    continue
                state = c
                i += 1
                continue
        else:
            if c == '\\':
                i += 2
                continue
            if c == state:
                state = None
            i += 1
            continue
        i += 1
    return None


def trans(src: str) -> str:
    out = []
    current_class = None
    current_enum = None
    enum_counter = 0
    block_stack = []
    in_export = False
    ml_state = None  # 跨行三引号字符串状态（None | '"""' | "'''"）

    for raw in src.split("\n"):
        indent = raw[: len(raw) - len(raw.lstrip())]
        line = raw.strip()

        # 处于跨行字符串中：整行原样输出，直至本行出现闭合引号
        if ml_state:
            ci = raw.find(ml_state)
            if ci == -1:
                out.append(raw.replace("\x01", "//"))
                continue
            # 本行闭合：字符串部分原样，闭合引号之后的代码部分做转换并接回本行
            after = _tok(raw[ci + 3:].replace("\x01", "//"))
            out.append(raw[:ci + 3].replace("\x01", "//") + after)
            ml_state = None
            continue

        # 本行开启未闭合三引号：前缀按代码转换，字符串部分原样
        u = _unclosed_triple(line)
        if u:
            opener, idx = u
            out.append(_tok(indent + line[:idx]) + line[idx:].replace("\x01", "//"))
            ml_state = opener
            continue

        if line.startswith("//"):
            out.append(indent + "#" + line[2:])
            continue
        # 行内注释： // -> # （保护整除 a // b）
        line = re.sub(r"(\d)\s*//\s*([A-Za-z0-9_(])", lambda m: m.group(1) + "\x01" + m.group(2), line)
        line = re.sub(r"\s//", "  #", line)
        line = line.replace("\x01", "//")

        # 枚举声明
        m = _ENUM_RE.match(line)
        if m:
            current_enum = m.group(1)
            enum_counter = 0
            out.append(indent + f"class {current_enum}(Enum):")
            continue

        # fn（static/class/abstract/async/普通；构造函数 fn 同名 -> __init__）
        parsed = _parse_fn(line)
        if parsed:
            kind, fname, params_raw = parsed
            params = _clean_params(params_raw)
            enclosing = _enclosing_kind(block_stack, indent)
            if kind == "static":
                sig = f"def {fname}({params}):" if params else f"def {fname}():"
                block_stack.append((indent, "fn", False))
                out.append(indent + "@staticmethod")
                out.append(indent + sig)
                continue
            if kind == "class":
                sig = f"def {fname}(cls, {params}):" if params else f"def {fname}(cls):"
                block_stack.append((indent, "fn", False))
                out.append(indent + "@classmethod")
                out.append(indent + sig)
                continue
            if kind == "abstract":
                if enclosing == "class":
                    sig = f"def {fname}(self, {params}):" if params else f"def {fname}(self):"
                else:
                    sig = f"def {fname}({params}):" if params else f"def {fname}():"
                block_stack.append((indent, "fn", False))
                out.append(indent + sig)
                out.append(indent + "    raise NotImplementedError")
                continue
            if fname == "__new__" and enclosing == "class":
                # __new__ 隐式静态方法：补回 cls 首参
                sig = f"def __new__(cls, {params}):" if params else "def __new__(cls):"
            elif fname == current_class and enclosing == "class":
                sig = f"def __init__(self, {params}):" if params else "def __init__(self):"
            elif enclosing == "class":
                sig = f"def {fname}(self, {params}):" if params else f"def {fname}(self):"
            else:
                sig = f"def {fname}({params}):" if params else f"def {fname}():"
            if kind == "async":
                sig = "async " + sig
            block_stack.append((indent, "fn", False))
            out.append(indent + sig)
            continue

        # 类声明（Mo extends -> Python 继承）
        m = _CLASS_RE.match(line)
        if m:
            current_class = m.group(1)
            current_enum = None
            block_stack.append((indent, "class", False))
            parent = m.group(2)
            sig = f"class {current_class}:" if not parent else f"class {current_class}({parent}):"
            out.append(indent + sig)
            continue

        # 冒号直通类声明（多父类 / 复杂基类）：跟踪 current_class 并压栈供方法判定
        m = re.match(r"^class\s+([A-Za-z_]\w*)\s*(?:\(.*\))?\s*:\s*$", line)
        if m:
            current_class = m.group(1)
            current_enum = None
            # 虚拟栈项：冒号直通类不产生 } 闭合，仅用于方法/构造函数判定
            block_stack.append((indent, "class", True))
            out.append(indent + line)
            continue

        # try / finally / else 块（{ } -> 冒号缩进）
        if _BLOCK_RE.match(line):
            block_stack.append((indent, "try", False))
            line = line.rstrip()
            if line.endswith("{"):
                line = line[:-1].rstrip() + ":"
            out.append(indent + line)
            continue

        # } catch / } finally / } else -> except / finally / else:
        m = _CATCH_RE.match(line)
        if m:
            kw = m.group(1)
            rest = m.group(2).strip().rstrip(":{").strip()
            if kw == "catch":
                if not rest:
                    line = "except Exception:"
                elif " as " in rest:
                    line = f"except {rest}:"
                elif rest.isidentifier():
                    # 单标识符约定为绑定异常变量：catch e -> except Exception as e
                    line = f"except Exception as {rest}:"
                else:
                    # 异常类型元组 / 表达式：catch (A, B) -> except (A, B):
                    line = f"except {rest}:"
            else:
                line = kw + ":"
            out.append(indent + line)
            continue

        # 闭合 }
        if line == "}":
            if current_enum is not None:
                current_enum = None
                continue
            # 弹出缩进更深的所有栈项（虚拟冒号直通类在此被清掉）
            while block_stack and len(block_stack[-1][0]) > len(indent):
                block_stack.pop()
            if not indent:
                if block_stack:
                    block_stack.pop()
                current_class = None
                continue
            if block_stack and indent == block_stack[-1][0]:
                block_stack.pop()
                continue
            out.append(indent + "}")
            continue

        # 枚举成员
        if current_enum is not None:
            m = re.match(r"([A-Za-z_]\w*)\s*(,.*)?(#.*)?$", line)
            if m and line != "}":
                enum_counter += 1
                out.append(indent + f"{m.group(1)} = {enum_counter}")
                continue

        # void 声明
        if re.match(r"void\s", line):
            line = line[len("void"):].strip()

        # const NAME = value
        m = re.match(r"const\s+([A-Za-z_]\w*)\s*=\s*(.*)$", line)
        if m:
            line = f"{m.group(1)} = {m.group(2)}"

        line = _tok(line)
        line = re.sub(r'super\(\s*"[^"]+"\s*,\s*"[^"]+"\s*\)', 'super().__init__("_", "_")', line)

        if line.startswith("export"):
            in_export = line.rstrip().endswith(",")
            continue
        if in_export:
            if not line.rstrip().endswith(","):
                in_export = False
            continue

        out.append(indent + line)

    return "\n".join(out)


def main() -> int:
    args = [a for a in sys.argv[1:] if a and not a.startswith("-")]
    if not args:
        print(__doc__)
        return 1
    src = os.path.abspath(args[0])
    out_dir = os.path.abspath(args[1]) if len(args) > 1 else src
    os.makedirs(out_dir, exist_ok=True)
    count = 0
    for dp, dn, fn in os.walk(src):
        dn[:] = [d for d in dn if d not in ("__pycache__", "generated", "mocode")]
        for name in sorted(fn):
            if not name.endswith(".mo"):
                continue
            mo_path = os.path.join(dp, name)
            rel = os.path.relpath(mo_path, src)
            dst = os.path.join(out_dir, rel[:-3] + ".py")
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(mo_path, encoding="utf-8") as f:
                mo_src = f.read()
            py = trans(mo_src)
            # 仅在源码确实使用 enum 关键字时注入 Enum 导入（避免破坏 from __future__ 前置规则）
            if re.search(r"(^|\n)\s*enum\s+[A-Za-z_]\w*\s*\{", mo_src):
                py = "from enum import Enum\n" + py
            with open(dst, "w", encoding="utf-8") as f:
                f.write(py)
            count += 1
            print(f"[ok] {rel} -> {os.path.relpath(dst)}")
    print(f"done, {count} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
