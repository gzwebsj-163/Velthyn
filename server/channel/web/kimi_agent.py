# -*- coding: utf-8 -*-
"""
kimi_agent.py - Kimi 桌面应用进程自动化代理
================================================
职责：
  1. 监听 Kimi.exe 进程树（主进程/渲染进程/辅助进程），获取 PID
  2. 枚举指定进程的全部窗口组件（Win32 窗口树）
  3. 注入 kimi_hook.dll 到渲染进程，建立命名管道控制通道
  4. 通过管道发送自动化命令（输入文本/发送/读取/枚举组件）

架构：
  Python 后端(9899) --named pipe--> kimi_hook.dll(渲染进程内)
  注入方式: CreateRemoteThread + LoadLibraryA (x64)

注意：
  - 仅 Windows 桌面端可用，服务器/容器内返回平台不支持
  - 使用 PowerShell Get-CimInstance 获取进程树（tasklist 在隐藏窗口环境不可靠）
"""
import ctypes
import json
import os
import re
import subprocess
import time
from ctypes import wintypes

KIMI_PROCESS = "Kimi.exe"
HOOK_DLL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "kimi_hook.dll")
PIPE_PREFIX = r"\\.\pipe\kimi_agent_"


# ---------------------------------------------------------------- 平台判断
def is_windows():
    return os.name == "nt" and sys_platform_windows()


def sys_platform_windows():
    import sys
    return sys.platform == "win32" or "win" in sys.platform


# ---------------------------------------------------------------- 进程监听器
def _ps(cmd):
    """执行 PowerShell 并返回 stdout（隐藏窗口环境下安全）"""
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-Command", cmd],
            capture_output=True, text=True, timeout=20)
        return r.stdout or ""
    except Exception:
        return ""


def process_tree():
    """枚举 Kimi.exe 进程树，识别角色（main/renderer/gpu/network/crashpad/utility）"""
    out = _ps(
        "Get-CimInstance Win32_Process -Filter \"Name='Kimi.exe'\" | "
        "Select-Object ProcessId,ParentProcessId,ExecutablePath,CommandLine | ConvertTo-Json -Depth 3")
    if not out.strip():
        return {"running": False, "processes": [], "main": None, "renderer": []}
    try:
        data = json.loads(out)
    except Exception:
        data = []
    if isinstance(data, dict):
        data = [data]
    procs = []
    for p in data:
        pid = int(p.get("ProcessId") or 0)
        ppid = int(p.get("ParentProcessId") or 0)
        cmd = p.get("CommandLine") or ""
        path = p.get("ExecutablePath") or ""
        role = _classify_role(cmd, pid)
        procs.append({"pid": pid, "ppid": ppid, "path": path, "cmd": cmd[:200],
                      "role": role, "ts": int(time.time())})
    main = next((p for p in procs if p["role"] == "main"), None)
    renderers = [p for p in procs if p["role"] == "renderer"]
    return {"running": bool(procs), "processes": procs, "main": main, "renderer": renderers}


def _classify_role(cmdline, pid):
    c = cmdline.lower()
    if "--type=renderer" in c:
        return "renderer"
    if "--type=gpu-process" in c:
        return "gpu"
    if "--type=utility" in c:
        return "utility"
    if "--type=crashpad-handler" in c:
        return "crashpad"
    if "--type=zygote" in c:
        return "zygote"
    return "main"


def wait_for_renderer(timeout=20):
    """等待并返回第一个渲染进程 PID（用于注入）"""
    t0 = time.time()
    while time.time() - t0 < timeout:
        tree = process_tree()
        if tree["renderer"]:
            return tree["renderer"][0]["pid"]
        time.sleep(1)
    return None


def is_running(pid):
    """检查 PID 是否存活"""
    out = _ps(f"Get-Process -Id {pid} -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count")
    return out.strip() not in ("", "0")


# ---------------------------------------------------------------- 窗口枚举器
WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

_user32 = ctypes.windll.user32
_user32.EnumWindows.argtypes = [WNDENUMPROC, wintypes.LPARAM]
_user32.EnumChildWindows.argtypes = [wintypes.HWND, WNDENUMPROC, wintypes.LPARAM]
_user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
_user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
_user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
_user32.IsWindowVisible.argtypes = [wintypes.HWND]
_user32.IsWindowVisible.restype = wintypes.BOOL
_user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]


def _hwnd_info(hwnd):
    pid = wintypes.DWORD()
    _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    cls = ctypes.create_unicode_buffer(256)
    _user32.GetClassNameW(hwnd, cls, 256)
    txt = ctypes.create_unicode_buffer(512)
    _user32.GetWindowTextW(hwnd, txt, 512)
    rect = wintypes.RECT()
    _user32.GetWindowRect(hwnd, ctypes.byref(rect))
    return {
        "hwnd": "0x%X" % int(hwnd & 0xFFFFFFFFFFFFFFFF),
        "pid": pid.value,
        "class": cls.value,
        "text": txt.value,
        "visible": bool(_user32.IsWindowVisible(hwnd)),
        "rect": [rect.left, rect.top, rect.right, rect.bottom],
    }


def enum_window_tree(pid=None, root_hwnd=0, max_nodes=600):
    """递归枚举窗口树，可选按 pid 过滤。返回节点列表（含层级）"""
    nodes = []

    def cb(hwnd, lparam):
        if len(nodes) >= max_nodes:
            return False
        info = _hwnd_info(hwnd)
        nodes.append(info)
        _user32.EnumChildWindows(hwnd, WNDENUMPROC(cb), 0)
        return True

    if root_hwnd:
        _user32.EnumChildWindows(root_hwnd, WNDENUMPROC(cb), 0)
    else:
        _user32.EnumWindows(WNDENUMPROC(cb), 0)
    if pid:
        nodes = [n for n in nodes if n["pid"] == pid]
    return nodes


def find_main_window(pid):
    """返回指定进程的顶层窗口（优先可见；全部不可见时退回最大面积窗口，
    便于 FOCUS/SHOT 先恢复再操作）"""
    tree = enum_window_tree(pid=pid)
    tops = [n for n in tree if n["pid"] == pid and n["class"] != "IME"]
    tops.sort(key=lambda n: (n["rect"][2] - n["rect"][0]) * (n["rect"][3] - n["rect"][1]), reverse=True)
    for t in tops:
        if t["visible"]:
            return t
    return tops[0] if tops else None


def ensure_visible(hwnd):
    """恢复并激活窗口（隐藏/最小化都处理），返回 True 表示窗口有效"""
    if not hwnd:
        return False
    try:
        h = int(hwnd, 16) if isinstance(hwnd, str) else int(hwnd)
    except (TypeError, ValueError):
        return False
    if not h:
        return False
    _user32.ShowWindow(h, 9)  # SW_RESTORE: 最小化/隐藏均恢复显示
    _user32.SetForegroundWindow(h)
    return True


def focus_input(pid, hwnd=None):
    """点击 Kimi 输入框（窗口底部聊天输入区），确保焦点落在输入区。

    Kimi 桌面版输入框位于主窗口底部居中，取 宽*0.4 / 高*0.8 的启发式位置，
    通过 DLL CLICK（SetCursorPos + 鼠标点击）将焦点移入输入框。
    pid 为已注入的渲染进程；主窗口自动从进程树取。返回 {"success", "input_pos"}。
    """
    if not hwnd:
        main_pid = (process_tree().get("main") or {}).get("pid")
        mw = find_main_window(main_pid)
        if not mw:
            return {"success": False, "error": "找不到 Kimi 主窗口"}
        hwnd = mw["hwnd"]
    try:
        h = int(hwnd, 16) if isinstance(hwnd, str) else int(hwnd)
    except (TypeError, ValueError):
        return {"success": False, "error": f"无效 hwnd: {hwnd}"}
    if not h:
        return {"success": False, "error": "hwnd 为空"}
    r = wintypes.RECT()
    if not _user32.GetWindowRect(h, ctypes.byref(r)):
        return {"success": False, "error": "GetWindowRect 失败"}
    x = r.left + int((r.right - r.left) * 0.4)
    y = r.top + int((r.bottom - r.top) * 0.8)
    resp = _pipe_send(pid, f"CLICK {x} {y}")
    resp["input_pos"] = {"x": x, "y": y}
    return resp


# ---------------------------------------------------------------- 注入器
def inject(pid, dll_path=None):
    """CreateRemoteThread + LoadLibraryA 注入 x64 DLL 到目标进程"""
    dll_path = dll_path or HOOK_DLL
    if not os.path.exists(dll_path):
        return {"success": False, "error": f"kimi_hook.dll 不存在: {dll_path}"}
    if not is_windows():
        return {"success": False, "error": "注入仅支持 Windows 桌面端"}
    dll_path = os.path.abspath(dll_path)

    k32 = ctypes.windll.kernel32
    k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    k32.OpenProcess.restype = wintypes.HANDLE
    k32.VirtualAllocEx.argtypes = [wintypes.HANDLE, wintypes.LPVOID, ctypes.c_size_t,
                                   wintypes.DWORD, wintypes.DWORD]
    k32.VirtualAllocEx.restype = wintypes.LPVOID
    k32.WriteProcessMemory.argtypes = [wintypes.HANDLE, wintypes.LPVOID,
                                       wintypes.LPVOID, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    k32.CreateRemoteThread.argtypes = [wintypes.HANDLE, wintypes.LPVOID, ctypes.c_size_t,
                                       wintypes.LPVOID, wintypes.LPVOID, wintypes.DWORD,
                                       ctypes.POINTER(wintypes.DWORD)]
    k32.CreateRemoteThread.restype = wintypes.HANDLE
    k32.GetProcAddress.argtypes = [wintypes.HMODULE, wintypes.LPCSTR]
    k32.GetProcAddress.restype = wintypes.LPVOID
    k32.GetModuleHandleW.argtypes = [wintypes.LPCWSTR]
    k32.GetModuleHandleW.restype = wintypes.HMODULE
    k32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    k32.CloseHandle.argtypes = [wintypes.HANDLE]
    k32.VirtualFreeEx.argtypes = [wintypes.HANDLE, wintypes.LPVOID, ctypes.c_size_t, wintypes.DWORD]

    PROCESS_ALL_ACCESS = 0x1F0FFF
    MEM_COMMIT = 0x1000
    MEM_RESERVE = 0x2000
    MEM_RELEASE = 0x8000
    PAGE_READWRITE = 0x04
    INFINITE = 0xFFFFFFFF

    h = k32.OpenProcess(PROCESS_ALL_ACCESS, False, pid)
    if not h:
        return {"success": False, "error": f"OpenProcess({pid}) 失败, err={ctypes.get_last_error()}"}
    try:
        path_buf = dll_path.encode("utf-16-le") + b"\x00\x00"
        mem = k32.VirtualAllocEx(h, None, len(path_buf), MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE)
        if not mem:
            return {"success": False, "error": "VirtualAllocEx 失败"}
        written = ctypes.c_size_t()
        if not k32.WriteProcessMemory(h, mem, path_buf, len(path_buf), ctypes.byref(written)):
            return {"success": False, "error": "WriteProcessMemory 失败"}
        loadlib = k32.GetProcAddress(k32.GetModuleHandleW("kernel32.dll"), b"LoadLibraryW")
        if not loadlib:
            return {"success": False, "error": "GetProcAddress(LoadLibraryW) 失败"}
        tid = wintypes.DWORD()
        th = k32.CreateRemoteThread(h, None, 0, loadlib, mem, 0, ctypes.byref(tid))
        if not th:
            return {"success": False, "error": "CreateRemoteThread 失败"}
        k32.WaitForSingleObject(th, 10000)
        k32.CloseHandle(th)
        k32.VirtualFreeEx(h, mem, 0, MEM_RELEASE)
        return {"success": True, "pid": pid, "dll": dll_path, "tid": tid.value}
    finally:
        k32.CloseHandle(h)


def is_dll_loaded(pid, dll_name="kimi_hook.dll"):
    """检查目标进程是否已加载 kimi_hook.dll"""
    out = _ps(f"(Get-Process -Id {pid} -ErrorAction SilentlyContinue).Modules | "
              f"Where-Object {{ $_.ModuleName -eq '{dll_name}' }} | Measure-Object | Select-Object -ExpandProperty Count")
    return out.strip() not in ("", "0")


def unload(pid, dll_name="kimi_hook.dll"):
    """远程卸载已注入的 DLL（FreeLibrary），用于替换新版本"""
    k32 = ctypes.windll.kernel32
    PROCESS_ALL_ACCESS = 0x1F0FFF

    def _remote_call(start_addr, param):
        tid = wintypes.DWORD()
        th = k32.CreateRemoteThread(h, None, 0, start_addr, param, 0, ctypes.byref(tid))
        if not th:
            return None
        k32.WaitForSingleObject(th, 8000)
        code = wintypes.DWORD()
        k32.GetExitCodeThread(th, ctypes.byref(code))
        k32.CloseHandle(th)
        return code.value

    h = k32.OpenProcess(PROCESS_ALL_ACCESS, False, pid)
    if not h:
        return {"success": False, "error": f"OpenProcess({pid}) 失败"}
    try:
        k32.GetProcAddress.argtypes = [wintypes.HMODULE, wintypes.LPCSTR]
        k32.GetProcAddress.restype = wintypes.LPVOID
        k32.CreateRemoteThread.argtypes = [wintypes.HANDLE, wintypes.LPVOID, ctypes.c_size_t,
                                           wintypes.LPVOID, wintypes.LPVOID, wintypes.DWORD,
                                           ctypes.POINTER(wintypes.DWORD)]
        k32.CreateRemoteThread.restype = wintypes.HANDLE
        k32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        k32.GetExitCodeThread.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        k32.CloseHandle.argtypes = [wintypes.HANDLE]
        k32.VirtualAllocEx.argtypes = [wintypes.HANDLE, wintypes.LPVOID, ctypes.c_size_t,
                                       wintypes.DWORD, wintypes.DWORD]
        k32.VirtualAllocEx.restype = wintypes.LPVOID
        k32.WriteProcessMemory.argtypes = [wintypes.HANDLE, wintypes.LPVOID,
                                           wintypes.LPVOID, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
        k32.VirtualFreeEx.argtypes = [wintypes.HANDLE, wintypes.LPVOID, ctypes.c_size_t, wintypes.DWORD]

        k32.GetModuleHandleW.argtypes = [wintypes.LPCWSTR]
        k32.GetModuleHandleW.restype = ctypes.c_void_p

        getmod = k32.GetProcAddress(k32.GetModuleHandleW("kernel32.dll"), b"GetModuleHandleW")
        freelib = k32.GetProcAddress(k32.GetModuleHandleW("kernel32.dll"), b"FreeLibrary")
        if not getmod or not freelib:
            return {"success": False, "error": "无法获取 kernel32 函数地址"}

        # 1) 远程调用 GetModuleHandleW 拿模块句柄
        name_buf = (dll_name + "\x00").encode("utf-16-le")
        mem = k32.VirtualAllocEx(h, None, len(name_buf), 0x1000 | 0x2000, 0x04)
        if not mem:
            return {"success": False, "error": "VirtualAllocEx 失败"}
        written = ctypes.c_size_t()
        k32.WriteProcessMemory(h, mem, name_buf, len(name_buf), ctypes.byref(written))
        mod = _remote_call(getmod, mem)
        k32.VirtualFreeEx(h, mem, 0, 0x8000)
        if not mod or mod == 0:
            return {"success": False, "error": f"{dll_name} 未加载(句柄=0)"}

        # 2) 远程调用 FreeLibrary
        _remote_call(freelib, ctypes.c_void_p(mod))
        time.sleep(0.5)
        return {"success": True, "pid": pid, "unloaded": not is_dll_loaded(pid)}
    finally:
        k32.CloseHandle(h)


# ---------------------------------------------------------------- 管道客户端
def _pipe_send(pid, command, timeout=15):
    """向注入 DLL 的命名管道发送文本命令（如 PING/ENUM/TYPE xxx），返回解析后的 dict"""
    name = PIPE_PREFIX + str(pid)
    try:
        handle = ctypes.windll.kernel32.CreateFileW(
            name, 0xC0000000, 0, None, 3, 0, None)
        if handle == -1 or handle == 0xFFFFFFFFFFFFFFFF:
            return {"success": False, "error": "无法连接管道(可能未注入)"}
        data = command.encode("utf-8") + b"\x00"
        written = ctypes.c_ulong()
        ctypes.windll.kernel32.WriteFile(handle, data, len(data), ctypes.byref(written), None)
        # 读响应（前4字节长度 + JSON）
        buf = ctypes.create_string_buffer(65536)
        read = ctypes.c_ulong()
        ctypes.windll.kernel32.ReadFile(handle, buf, 65536, ctypes.byref(read), None)
        ctypes.windll.kernel32.CloseHandle(handle)
        resp = buf.raw[:read.value].decode("utf-8", "ignore").rstrip("\x00")
        try:
            return json.loads(resp)
        except Exception:
            return {"success": False, "error": f"管道响应解析失败: {resp[:200]}"}
    except Exception as e:
        return {"success": False, "error": f"管道通信异常: {e}"}


# ---------------------------------------------------------------- 顶层 API
def agent_status():
    """总体状态：进程树 + 注入状态"""
    tree = process_tree()
    result = {"kimi_running": tree["running"], "main": tree["main"], "renderer": tree["renderer"]}
    if tree["renderer"]:
        pid = tree["renderer"][0]["pid"]
        result["injected"] = is_dll_loaded(pid)
        result["inject_pid"] = pid
    else:
        result["injected"] = False
        result["inject_pid"] = None
    return result


def cmd_enum(pid):
    """枚举指定进程的窗口组件"""
    nodes = enum_window_tree(pid=pid)
    return {"success": True, "pid": pid, "count": len(nodes), "windows": nodes[:400]}


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "status":
        print(json.dumps(agent_status(), ensure_ascii=False, indent=2))
    elif len(sys.argv) > 2 and sys.argv[1] == "enum":
        print(json.dumps(cmd_enum(int(sys.argv[2])), ensure_ascii=False, indent=2)[:4000])
    else:
        print(json.dumps(process_tree(), ensure_ascii=False, indent=2)[:3000])
