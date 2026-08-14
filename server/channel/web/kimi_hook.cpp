// ============================================================
//  kimi_hook.dll - Kimi 渲染进程自动化代理 (x64)
// ============================================================
//  注入方式: CreateRemoteThread + LoadLibraryW (由 kimi_agent.py 驱动)
//  功能: 在目标进程内建立命名管道服务器 \\.\pipe\kimi_agent_<pid>
//        接收命令实现: 组件枚举 / 文本输入(SendInput) / 按键 /
//        鼠标点击 / 剪贴板读写 / 窗口聚焦
//  编译: clang++ -shared -O2 -std=c++17 -o kimi_hook.dll kimi_hook.cpp
//         (LLVM MinGW / mingw-w64 均可用)
// ============================================================
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <string>
#include <vector>
#include <sstream>
#include <algorithm>
#include <cstring>
#include <cstdio>
#include <gdiplus.h>

#ifndef PW_RENDERFULLCONTENT
#define PW_RENDERFULLCONTENT 0x00000002
#endif

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "kernel32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "gdi32.lib")

using namespace Gdiplus;

static volatile LONG g_initialized = 0;
static DWORD g_host_pid = 0;
static wchar_t g_pipe_name[128];

// ---------------------------------------------------------- UTF-8 工具
static std::wstring utf8_to_wide(const std::string &s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    if (n <= 0) return L"";
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
    return w;
}

static std::string wide_to_utf8(const std::wstring &w) {
    if (w.empty()) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    if (n <= 0) return "";
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

// JSON 字符串转义（反斜杠/引号/控制字符）
static std::string json_escape(const std::string &s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char ch : s) {
        switch (ch) {
            case '\\': out += "\\\\"; break;
            case '"': out += "\\\""; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default: out += ch;
        }
    }
    return out;
}

// ---------------------------------------------------------- 组件枚举
struct Node {
    HWND hwnd; std::wstring cls, txt; DWORD pid; bool vis; RECT r;
};
static std::vector<Node> g_nodes;
static DWORD g_filter_pid = 0;  // 0 = 全部

static BOOL CALLBACK win_walker(HWND h, LPARAM lp) {
    auto *vec = reinterpret_cast<std::vector<Node> *>(lp);
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (g_filter_pid == 0 || pid == g_filter_pid) {
        Node n;
        n.hwnd = h; n.pid = pid;
        n.vis = IsWindowVisible(h) != 0;
        wchar_t buf[512];
        int len = GetClassNameW(h, buf, 512);
        n.cls = (len > 0) ? std::wstring(buf, len) : L"";
        len = GetWindowTextW(h, buf, 512);
        n.txt = (len > 0) ? std::wstring(buf, len) : L"";
        GetWindowRect(h, &n.r);
        vec->push_back(n);
    }
    return TRUE;
}

static std::string enum_windows_tree(DWORD filter_pid = 0) {
    g_filter_pid = filter_pid;
    g_nodes.clear();
    std::vector<Node> tops;
    EnumWindows(win_walker, reinterpret_cast<LPARAM>(&tops));
    g_nodes = tops;
    for (auto &t : tops) {
        size_t before = g_nodes.size();
        EnumChildWindows(t.hwnd, win_walker, reinterpret_cast<LPARAM>(&g_nodes));
        size_t after = g_nodes.size();
        for (size_t i = before; i < after; ++i)
            EnumChildWindows(g_nodes[i].hwnd, win_walker, reinterpret_cast<LPARAM>(&g_nodes));
    }

    // 去重
    std::sort(g_nodes.begin(), g_nodes.end(), [](const Node &a, const Node &b) {
        return (size_t)a.hwnd < (size_t)b.hwnd;
    });
    g_nodes.erase(std::unique(g_nodes.begin(), g_nodes.end(),
                            [](const Node &a, const Node &b) { return a.hwnd == b.hwnd; }),
                g_nodes.end());

    std::ostringstream os;
    os << "[";
    bool first = true;
    int count = 0;
    for (auto &n : g_nodes) {
        if (n.cls == L"IME" || n.cls == L"MSCTFIME UI") continue;  // 过滤输入法窗口
        if (!first) os << ",";
        first = false;
        char hwnd_s[32], pid_s[32];
        sprintf_s(hwnd_s, "0x%llX", (unsigned long long)n.hwnd);
        sprintf_s(pid_s, "%lu", n.pid);
        os << "{\"hwnd\":\"" << hwnd_s << "\",\"pid\":" << pid_s
           << ",\"class\":\"" << json_escape(wide_to_utf8(n.cls)) << "\""
           << ",\"text\":\"" << json_escape(wide_to_utf8(n.txt)) << "\""
           << ",\"visible\":" << (n.vis ? "true" : "false")
           << ",\"rect\":[" << n.r.left << "," << n.r.top << "," << n.r.right << "," << n.r.bottom << "]}";
        count++;
    }
    os << "]";
    return "{\"success\":true,\"count\":" + std::to_string(count) + ",\"windows\":" + os.str() + "}";
}

// ---------------------------------------------------------- 剪贴板
static std::string clipboard_get_text() {
    if (!OpenClipboard(nullptr)) return "{\"success\":false,\"error\":\"OpenClipboard failed\"}";
    std::string result;
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (h) {
        const wchar_t *p = static_cast<const wchar_t *>(GlobalLock(h));
        if (p) {
            result = wide_to_utf8(p);
            GlobalUnlock(h);
        }
    }
    CloseClipboard();
    return "{\"success\":true,\"text\":\"" + result + "\"}";
}

static std::string clipboard_set_text(const std::string &text) {
    if (!OpenClipboard(nullptr)) return "{\"success\":false,\"error\":\"OpenClipboard failed\"}";
    EmptyClipboard();
    std::wstring w = utf8_to_wide(text);
    size_t bytes = (w.size() + 1) * sizeof(wchar_t);
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!h) { CloseClipboard(); return "{\"success\":false,\"error\":\"GlobalAlloc failed\"}"; }
    void *dst = GlobalLock(h);
    if (!dst) { GlobalFree(h); CloseClipboard(); return "{\"success\":false,\"error\":\"GlobalLock failed\"}"; }
    memcpy(dst, w.c_str(), bytes);
    GlobalUnlock(h);
    if (!SetClipboardData(CF_UNICODETEXT, h)) { GlobalFree(h); CloseClipboard(); return "{\"success\":false,\"error\":\"SetClipboardData failed\"}"; }
    CloseClipboard();
    return "{\"success\":true}";
}

// ---------------------------------------------------------- GDI+ 工具
struct GdiPlusGuard {
    ULONG_PTR token = 0;
    GdiPlusGuard() {
        GdiplusStartupInput si;
        GdiplusStartup(&token, &si, nullptr);
    }
    ~GdiPlusGuard() { if (token) GdiplusShutdown(token); }
};

static int get_encoder_clsid(const wchar_t *mime, CLSID *clsid) {
    UINT num = 0, size = 0;
    GetImageEncodersSize(&num, &size);
    if (size == 0) return -1;
    ImageCodecInfo *info = (ImageCodecInfo *)malloc(size);
    if (!info) return -1;
    GetImageEncoders(num, size, info);
    for (UINT i = 0; i < num; i++) {
        if (wcscmp(info[i].MimeType, mime) == 0) {
            *clsid = info[i].Clsid;
            free(info);
            return 0;
        }
    }
    free(info);
    return -1;
}

// CLIPSETIMG <path> —— 加载图片并写入剪贴板(CF_DIB)，供 Ctrl+V 粘贴
static std::string clipboard_set_image(const std::string &path) {
    GdiPlusGuard g;
    Bitmap bmp(utf8_to_wide(path).c_str());
    if (bmp.GetLastStatus() != Ok)
        return "{\"success\":false,\"error\":\"cannot load image: " + json_escape(path) + "\"}";
    HBITMAP hbmp = nullptr;
    if (bmp.GetHBITMAP(Color(255, 255, 255), &hbmp) != Ok || !hbmp)
        return "{\"success\":false,\"error\":\"GetHBITMAP failed\"}";
    BITMAP bm;
    GetObject(hbmp, sizeof(bm), &bm);
    HDC hdc = GetDC(nullptr);
    if (!hdc) { DeleteObject(hbmp); return "{\"success\":false,\"error\":\"GetDC failed\"}"; }
    BITMAPINFOHEADER bih;
    ZeroMemory(&bih, sizeof(bih));
    bih.biSize = sizeof(BITMAPINFOHEADER);
    bih.biWidth = bm.bmWidth;
    bih.biHeight = bm.bmHeight;
    bih.biPlanes = 1;
    bih.biBitCount = 32;
    bih.biCompression = BI_RGB;
    DWORD bytes = (DWORD)bm.bmWidth * 4 * bm.bmHeight;
    DWORD total = sizeof(BITMAPINFOHEADER) + bytes;
    HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, total);
    if (!hMem) { ReleaseDC(nullptr, hdc); DeleteObject(hbmp); return "{\"success\":false,\"error\":\"GlobalAlloc failed\"}"; }
    BITMAPINFOHEADER *pBih = (BITMAPINFOHEADER *)GlobalLock(hMem);
    *pBih = bih;
    char *pBits = (char *)pBih + sizeof(BITMAPINFOHEADER);
    if (GetDIBits(hdc, hbmp, 0, bm.bmHeight, pBits, (BITMAPINFO *)pBih, DIB_RGB_COLORS) == 0) {
        GlobalUnlock(hMem); GlobalFree(hMem); ReleaseDC(nullptr, hdc); DeleteObject(hbmp);
        return "{\"success\":false,\"error\":\"GetDIBits failed\"}";
    }
    GlobalUnlock(hMem);
    ReleaseDC(nullptr, hdc);
    DeleteObject(hbmp);
    if (!OpenClipboard(nullptr)) { GlobalFree(hMem); return "{\"success\":false,\"error\":\"OpenClipboard failed\"}"; }
    EmptyClipboard();
    if (!SetClipboardData(CF_DIB, hMem)) { GlobalFree(hMem); CloseClipboard(); return "{\"success\":false,\"error\":\"SetClipboardData failed\"}"; }
    CloseClipboard();
    return "{\"success\":true,\"w\":" + std::to_string(bm.bmWidth) + ",\"h\":" + std::to_string(bm.bmHeight) + "}";
}

// CLIPFILE <path1>[;<path2>...] —— 复制文件到剪贴板(CF_HDROP)，供 Ctrl+V 上传
static std::string clipboard_set_files(const std::string &arg) {
    std::vector<std::wstring> paths;
    std::string cur;
    for (char ch : arg) {
        if (ch == ';') { if (!cur.empty()) { paths.push_back(utf8_to_wide(cur)); cur.clear(); } }
        else cur += ch;
    }
    if (!cur.empty()) paths.push_back(utf8_to_wide(cur));
    if (paths.empty()) return "{\"success\":false,\"error\":\"no files\"}";
    size_t total = sizeof(DROPFILES);
    for (auto &p : paths) total += (p.size() + 1) * sizeof(wchar_t);
    total += sizeof(wchar_t);
    HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, total);
    if (!hMem) return "{\"success\":false,\"error\":\"GlobalAlloc failed\"}";
    DROPFILES *df = (DROPFILES *)GlobalLock(hMem);
    df->pFiles = sizeof(DROPFILES);
    df->fWide = TRUE;
    wchar_t *dst = (wchar_t *)((char *)df + sizeof(DROPFILES));
    for (auto &p : paths) {
        wcscpy_s(dst, p.size() + 1, p.c_str());
        dst += p.size() + 1;
    }
    *dst = L'\0';
    GlobalUnlock(hMem);
    if (!OpenClipboard(nullptr)) { GlobalFree(hMem); return "{\"success\":false,\"error\":\"OpenClipboard failed\"}"; }
    EmptyClipboard();
    if (!SetClipboardData(CF_HDROP, hMem)) { GlobalFree(hMem); CloseClipboard(); return "{\"success\":false,\"error\":\"SetClipboardData failed\"}"; }
    CloseClipboard();
    return "{\"success\":true,\"files\":" + std::to_string(paths.size()) + "}";
}

// SHOT <path> [hwnd-hex] —— 截取窗口(或全屏)保存 PNG
static std::string cmd_shot(const std::string &arg) {
    std::istringstream ss(arg);
    std::string path;
    ss >> path;
    if (path.empty()) return "{\"success\":false,\"error\":\"missing path\"}";
    unsigned long long h = 0;
    std::string hex;
    ss >> hex;
    if (!hex.empty()) {
        std::istringstream hs(hex);
        hs >> std::hex >> h;
    }
    HWND target = h ? (HWND)h : nullptr;
    int x = 0, y = 0, w = GetSystemMetrics(SM_CXSCREEN), hh = GetSystemMetrics(SM_CYSCREEN);
    if (target) {
        if (IsIconic(target)) ShowWindow(target, SW_RESTORE);
        RECT rc;
        GetWindowRect(target, &rc);
        x = rc.left; y = rc.top; w = rc.right - rc.left; hh = rc.bottom - rc.top;
        if (w <= 0 || hh <= 0) { w = GetSystemMetrics(SM_CXSCREEN); hh = GetSystemMetrics(SM_CYSCREEN); x = 0; y = 0; }
    }
    HDC screen = GetDC(nullptr);
    if (!screen) return "{\"success\":false,\"error\":\"GetDC failed\"}";
    HDC mem = CreateCompatibleDC(screen);
    HBITMAP bmp = CreateCompatibleBitmap(screen, w, hh);
    HGDIOBJ old = SelectObject(mem, bmp);
    if (target) {
        PrintWindow(target, mem, PW_RENDERFULLCONTENT);
    } else {
        BitBlt(mem, 0, 0, w, hh, screen, x, y, SRCCOPY);
    }
    SelectObject(mem, old);
    DeleteDC(mem);
    ReleaseDC(nullptr, screen);
    GdiPlusGuard g;
    Bitmap bm(bmp, nullptr);
    CLSID png;
    if (get_encoder_clsid(L"image/png", &png) < 0) { DeleteObject(bmp); return "{\"success\":false,\"error\":\"no png encoder\"}"; }
    Status st = bm.Save(utf8_to_wide(path).c_str(), &png, nullptr);
    DeleteObject(bmp);
    if (st != Ok) return "{\"success\":false,\"error\":\"save png failed\"}";
    return "{\"success\":true,\"path\":\"" + json_escape(path) + "\",\"w\":" + std::to_string(w) + ",\"h\":" + std::to_string(hh) + "}";
}

// ---------------------------------------------------------- SendInput
static void send_key(WORD vk, bool ctrl = false, bool alt = false, bool shift = false, bool down = true) {
    INPUT in[4];
    ZeroMemory(in, sizeof(in));
    int n = 0;
    auto add = [&](WORD v, DWORD flags, WORD wscan = 0) {
        in[n].type = INPUT_KEYBOARD;
        in[n].ki.wVk = v;
        in[n].ki.wScan = wscan;
        in[n].ki.dwFlags = flags;
        n++;
    };
    if (ctrl) add(VK_CONTROL, 0);
    if (alt) add(VK_MENU, 0);
    if (shift) add(VK_SHIFT, 0);
    if (down) add(vk, 0); else add(vk, KEYEVENTF_KEYUP);
    if (ctrl) add(VK_CONTROL, KEYEVENTF_KEYUP);
    if (alt) add(VK_MENU, KEYEVENTF_KEYUP);
    if (shift) add(VK_SHIFT, KEYEVENTF_KEYUP);
    SendInput((UINT)n, in, sizeof(INPUT));
}

static std::string cmd_key(const std::string &arg) {
    std::istringstream ss(arg);
    long vk = 0; std::string mods;
    ss >> vk >> mods;
    bool ctrl = mods.find('c') != std::string::npos;
    bool alt = mods.find('a') != std::string::npos;
    bool shift = mods.find('s') != std::string::npos;
    send_key((WORD)vk, ctrl, alt, shift, true);
    send_key((WORD)vk, ctrl, alt, shift, false);
    return "{\"success\":true}";
}

static std::string cmd_type(const std::string &text) {
    // 用剪贴板 + Ctrl+V 粘贴, 支持中文
    clipboard_set_text(text);
    send_key('V', true, false, false, true);
    send_key('V', true, false, false, false);
    Sleep(80);
    return "{\"success\":true}";
}

static std::string cmd_click(const std::string &arg) {
    long x = 0, y = 0, double_click = 0;
    std::istringstream ss(arg);
    ss >> x >> y >> double_click;
    SetCursorPos((int)x, (int)y);
    INPUT m[3];
    ZeroMemory(m, sizeof(m));
    auto press = [&](int i, DWORD flags) {
        m[i].type = INPUT_MOUSE;
        m[i].mi.dwFlags = flags;
    };
    if (double_click) {
        press(0, MOUSEEVENTF_LEFTDOWN); press(1, MOUSEEVENTF_LEFTUP);
        press(2, MOUSEEVENTF_LEFTDOWN);
        SendInput(3, m, sizeof(INPUT));
        ZeroMemory(m, sizeof(m));
        press(0, MOUSEEVENTF_LEFTUP);
        SendInput(1, m, sizeof(INPUT));
    } else {
        press(0, MOUSEEVENTF_LEFTDOWN); press(1, MOUSEEVENTF_LEFTUP);
        SendInput(2, m, sizeof(INPUT));
    }
    return "{\"success\":true}";
}

static std::string cmd_focus(const std::string &arg) {
    unsigned long long h = 0;
    std::istringstream ss(arg);
    ss >> std::hex >> h;
    if (!h) return "{\"success\":false,\"error\":\"bad hwnd\"}";
    HWND w = (HWND)h;
    if (IsIconic(w)) ShowWindow(w, SW_RESTORE);
    // 解锁前台锁定：模拟一次 ALT 键（让系统认为有用户输入）
    INPUT alt[2];
    ZeroMemory(alt, sizeof(alt));
    alt[0].type = INPUT_KEYBOARD;
    alt[0].ki.wVk = VK_MENU;
    alt[1].type = INPUT_KEYBOARD;
    alt[1].ki.wVk = VK_MENU;
    alt[1].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(2, alt, sizeof(INPUT));
    Sleep(30);
    // 置前台
    HWND fg = GetForegroundWindow();
    DWORD fg_tid = fg ? GetWindowThreadProcessId(fg, nullptr) : 0;
    DWORD cur_tid = GetCurrentThreadId();
    if (fg_tid && fg_tid != cur_tid) {
        AttachThreadInput(cur_tid, fg_tid, TRUE);
        BringWindowToTop(w);
        SetForegroundWindow(w);
        AttachThreadInput(cur_tid, fg_tid, FALSE);
    } else {
        BringWindowToTop(w);
        SetForegroundWindow(w);
    }
    // 再提到 Z 序最顶层
    SetWindowPos(w, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    SetWindowPos(w, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
    SetActiveWindow(w);
    SetFocus(w);
    Sleep(100);
    return "{\"success\":true,\"fg\":" +
           std::to_string((unsigned long long)(GetForegroundWindow() == w)) + "}";
}

static std::string cmd_hotkey(const std::string &arg) {
    // hotkey <vk>  -> 执行 Ctrl+<vk>
    long vk = 0;
    std::istringstream ss(arg);
    ss >> vk;
    send_key((WORD)vk, true, false, false, true);
    send_key((WORD)vk, true, false, false, false);
    return "{\"success\":true}";
}

// ---------------------------------------------------------- 命令分发
static std::string handle_command(const std::string &raw_in) {
    // 去掉末尾 NUL / 空白
    std::string raw = raw_in;
    while (!raw.empty() && (raw.back() == '\0' || raw.back() == '\n' || raw.back() == '\r' || raw.back() == ' '))
        raw.pop_back();

    size_t sp = raw.find(' ');
    std::string cmd = (sp == std::string::npos) ? raw : raw.substr(0, sp);
    std::string arg = (sp == std::string::npos) ? "" : raw.substr(sp + 1);

    if (cmd == "PING") return "{\"success\":true,\"pid\":" + std::to_string(GetCurrentProcessId()) + ",\"msg\":\"kimi_hook alive\"}";
    if (cmd == "ENUM") {
        // ENUM 或 ENUM <pid>
        DWORD fp = 0;
        if (!arg.empty()) {
            try { fp = (DWORD)std::stoul(arg); } catch (...) {}
        }
        return enum_windows_tree(fp);
    }
    if (cmd == "TYPE") return cmd_type(arg);
    if (cmd == "KEY") return cmd_key(arg);
    if (cmd == "HOTKEY") return cmd_hotkey(arg);
    if (cmd == "CLICK") return cmd_click(arg);
    if (cmd == "FOCUS") return cmd_focus(arg);
    if (cmd == "CLIPGET") return clipboard_get_text();
    if (cmd == "CLIPSET") return clipboard_set_text(arg);
    if (cmd == "CLIPSETIMG") return clipboard_set_image(arg);
    if (cmd == "CLIPFILE") return clipboard_set_files(arg);
    if (cmd == "SHOT") return cmd_shot(arg);
    if (cmd == "EXIT") return "{\"success\":true,\"bye\":true}";
    return "{\"success\":false,\"error\":\"unknown cmd: " + cmd + "\"}";
}

// ---------------------------------------------------------- 管道服务器
static DWORD WINAPI pipe_server_thread(LPVOID) {
    g_host_pid = GetCurrentProcessId();
    swprintf_s(g_pipe_name, L"%ls%lu", L"\\\\.\\pipe\\kimi_agent_", g_host_pid);
    // 清理遗留同名管道
    while (true) {
        HANDLE h = CreateFileW(g_pipe_name, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                               OPEN_EXISTING, 0, nullptr);
        if (h != INVALID_HANDLE_VALUE) {
            CloseHandle(h);
            // 已存在, 说明上一个实例还活着 -> 直接返回不再起管道?
            // 若管道存在但无人连接, 我们会 ConnectNamedPipe 失败。这里简单退出重试循环
            break;
        }
        break;
    }
    while (true) {
        HANDLE h = CreateNamedPipeW(
            g_pipe_name,
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
            PIPE_UNLIMITED_INSTANCES, 65536, 65536, 5000, nullptr);
        if (h == INVALID_HANDLE_VALUE) {
            Sleep(1000);
            continue;
        }
        BOOL ok = ConnectNamedPipe(h, nullptr);
        if (!ok && GetLastError() != ERROR_PIPE_CONNECTED) {
            CloseHandle(h);
            continue;
        }
        // 读命令
        char buf[65536];
        DWORD read = 0;
        BOOL got = ReadFile(h, buf, sizeof(buf) - 1, &read, nullptr);
        if (got && read > 0) {
            buf[read] = '\0';
            std::string resp = handle_command(std::string(buf, read));
            // 剪掉可能含换行的尾部
            std::string out = resp + "\0";
            DWORD written = 0;
            WriteFile(h, out.c_str(), (DWORD)out.size(), &written, nullptr);
            FlushFileBuffers(h);
        }
        CloseHandle(h);
    }
    return 0;
}

// ---------------------------------------------------------- DllMain
BOOL WINAPI DllMain(HINSTANCE hInst, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hInst);
        if (InterlockedCompareExchange(&g_initialized, 1, 0) == 0) {
            HANDLE th = CreateThread(nullptr, 0, pipe_server_thread, nullptr, 0, nullptr);
            if (th) CloseHandle(th);
        }
    } else if (reason == DLL_PROCESS_DETACH) {
        // 什么都不做(避免死锁)
    }
    return TRUE;
}

// mingw 需要导出 DllMain 相关符号
extern "C" __declspec(dllexport) DWORD WINAPI KimiAgentPing(void) {
    return GetCurrentProcessId();
}
