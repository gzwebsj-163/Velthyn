# -*- coding: utf-8 -*-
"""往返等价验证：比较原始 .py 与转译产物 .py 的 AST 结构。
归一化：剥离类型注解、异常绑定名、docstring 差异不算（docstring 保留）。"""
import ast
import os
import sys

ROOT = r"channel\web\mocode\_mo_roundtrip"


def normalize(tree):
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            node.returns = None
            for a in node.args.args + node.args.kwonlyargs + node.args.posonlyargs:
                a.annotation = None
            if node.args.vararg:
                node.args.vararg.annotation = None
            if node.args.kwarg:
                node.args.kwarg.annotation = None
        elif isinstance(node, ast.AnnAssign):
            node.annotation = None
        elif isinstance(node, ast.ExceptHandler):
            node.name = None
            if isinstance(node.type, ast.Name) and node.type.id == "Exception":
                node.type = None
    return tree


mismatch = []
total = 0
for dp, dn, fn in os.walk(ROOT):
    for f in fn:
        if not f.endswith(".py"):
            continue
        rt = os.path.join(dp, f)
        rel = os.path.relpath(rt, ROOT)
        orig = os.path.join(r"C:\Users\gzwebsj\Desktop\mocode-cli\CowAgent-master", rel)
        if not os.path.exists(orig):
            continue
        total += 1
        try:
            t1 = normalize(ast.parse(open(orig, encoding="utf-8-sig").read()))
            t2 = normalize(ast.parse(open(rt, encoding="utf-8-sig").read()))
            # dump with docstrings preserved but comments/positions stripped
            d1 = ast.dump(t1, include_attributes=False)
            d2 = ast.dump(t2, include_attributes=False)
            if d1 != d2:
                mismatch.append(rel)
        except Exception as e:
            mismatch.append(rel + " :: " + str(e).splitlines()[0])
print(f"AST equivalence: {total - len(mismatch)}/{total} match")
for m in mismatch:
    print("DIFF", m)
