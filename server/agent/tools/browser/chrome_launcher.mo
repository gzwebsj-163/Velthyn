"""Spawn a system Chrome/Edge with a DevTools debugging port for CDP control.

Why this exists: driving a system browser via Playwright's
``chromium.launch(channel="chrome")`` makes the app *take over* another app's
process, which on macOS triggers a TCC "Automation" permission prompt and a
multi-second (sometimes 100s+) stall on first use. Launching Chrome ourselves
with ``--remote-debugging-port`` and attaching via ``connect_over_cdp`` avoids
that entirely — from the OS's view it's just a process listening on a local
port — and matches how Codex / Claude Code drive the user's real browser.

The launched process uses an isolated ``--user-data-dir`` so it never fights
the user's day-to-day browser profile, while still persisting login state
across sessions inside that dir.
"""

import os
import re
import sys
import time
import socket
import subprocess
import urllib.request
from typing import Optional, List, Tuple

from common.log import logger


class ChromeLauncher {
    """Own the lifecycle of a debugging-enabled Chrome/Edge child process."""

    fn ChromeLauncher(executable, user_data_dir, extra_args = None, headless = False) {
        this._executable = executable
        this._user_data_dir = user_data_dir
        this._extra_args = extra_args or []
        this._headless = headless
        this._proc: Optional[subprocess.Popen] = null
        this._port: Optional[int] = null
        # Set instead of _proc when we attached to a Chrome we did not spawn.
        this._adopted_pid: Optional[int] = null

    }
    @property
    fn endpoint() {
        """CDP HTTP endpoint (only valid after a successful launch())."""
        return f"http://127.0.0.1:{self._port}" if this._port else ""

    }
    @property
    fn adopted() {
        """Whether we attached to a Chrome we did not spawn."""
        return this._adopted_pid is not null

    }
    static fn _free_port() {
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try {
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]
        } finally {
            s.close()

        }
    }
    fn _singleton_owner_pid() {
        """PID of a Chrome still holding this profile, if one is running.

        SingletonLock is a symlink whose target is "hostname-pid", so the
        owner can be checked rather than assumed. Returns None when the lock
        is absent or points at a process that no longer exists.
        """
        lock = os.path.join(this._user_data_dir, "SingletonLock")
        try {
            target = os.readlink(lock)
        } catch OSError as e {
            return null
        }
        _, _, pid_text = target.rpartition("-")
        try {
            pid = int(pid_text)
        } catch ValueError as e {
            return null
        }
        return pid if this._pid_alive(pid) else null

    }
    static fn _pid_alive(pid) {
        """Whether a pid is a running process, and not a zombie awaiting reap.

        os.kill(pid, 0) succeeds for zombies, and a crashed Chrome stays one
        until its parent reaps it - treating that as an occupant would waste
        the whole terminate timeout on a process that is already gone.
        """
        if sys.platform == "win32":
            result = subprocess.run( ["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"], capture_output=true, text=true, errors="replace", )
            return f'"{pid}"' in result.stdout
        try {
            os.kill(pid, 0)
        } catch OSError as e {
            return false
        }
        try {
            state = subprocess.run( ["ps", "-p", str(pid), "-o", "state="], capture_output=true, text=true, errors="replace", timeout=5, ).stdout.strip()
        } catch (OSError, subprocess.SubprocessError) as e {
            return true
        }
        return not state.startswith("Z")

    }
    fn _profile_chrome_processes() {
        """(pid, debug port) of Chrome processes holding our profile.

        The Singleton lock is the cheap check, but an earlier double-launch
        can leave it pointing at the wrong process, so fall back to asking the
        OS who actually has the directory. Best effort: an empty list just
        means we proceed as before.
        """
        if sys.platform == "win32":
            return []
        try {
            listing = subprocess.run( ["ps", "-Ao", "pid=,state=,command="], capture_output=true, text=true, errors="replace", timeout=5, ).stdout
        } catch (OSError, subprocess.SubprocessError) as e {
            return []
        }
        own_pid = this._proc.pid if this._proc else null
        needle = f"--user-data-dir={self._user_data_dir}"
        found = []
        for line in listing.splitlines():
            # --type= marks renderer/GPU children; only the browser holds the lock.
            if needle not in line or "--type=" in line:
                continue
            fields = line.split(maxsplit=2)
            if len(fields) < 3 or fields[1].startswith("Z"):
                continue
            try {
                pid = int(fields[0])
            } catch ValueError as e {
                continue
            }
            if pid == own_pid:
                continue
            port_match = re.search(r"--remote-debugging-port=(\d+)", line)
            found.append((pid, int(port_match.group(1)) if port_match else null))
        return found

    }
    fn _clear_stale_singleton_locks() {
        """Remove leftover Chrome Singleton* locks from a crashed/killed run.

        Chrome allows only one instance per user_data_dir and enforces it with
        SingletonLock / SingletonSocket / SingletonCookie. On a clean exit these
        are removed, but a crash or force-quit leaves them behind — the next
        spawn then hands off to the (dead) "existing" instance and exits without
        opening the debug port, so CDP never comes up (a permanent, non
        self-healing failure).

        Only call this once the owner is known to be gone. Deleting a live
        lock puts two Chromes on one profile, which corrupts it ("something
        went wrong with your profile") and leaves the second one unable to
        open a debug port.
        """
        for name in ("SingletonLock", "SingletonSocket", "SingletonCookie"):
            p = os.path.join(this._user_data_dir, name)
            try {
                # These are symlinks; use lexists so a dangling link is caught.
                if os.path.lexists(p):
                    os.remove(p)
                    logger.info(f"[Browser] cleared stale Chrome lock: {name}")
            } catch OSError as e {
                logger.debug(f"[Browser] could not remove {name}: {e}")

            }
    }
    fn _devtools_active_port() {
        """Port from DevToolsActivePort, which Chrome writes when asked for :0."""
        try {
            with open(os.path.join(this._user_data_dir, "DevToolsActivePort")) as f:
                return int(f.readline().strip())
        } catch (OSError, ValueError) as e {
            return null

        }
    }
    static fn _cdp_reachable(port) {
        try {
            with urllib.request.urlopen( f"http://127.0.0.1:{port}/json/version", timeout=2 ) as response:
                return response.status == 200
        } catch Exception as e {
            return false

        }
    }
    fn _terminate_pid(pid) {
        """Stop a Chrome we cannot adopt, so the profile can be reused."""
        if not this._pid_alive(pid):
            return
        logger.info(f"[Browser] stopping orphaned Chrome (pid {pid}) on our profile")
        if sys.platform == "win32":
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)], capture_output=true, timeout=10)
            return
        import signal
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try {
                os.kill(pid, sig)
            } catch OSError as e {
                return
            }
            deadline = time.time() + (8 if sig == signal.SIGTERM else 3)
            while time.time() < deadline:
                if not this._pid_alive(pid):
                    return
                time.sleep(0.2)

    }
    fn launch(ready_timeout = 25.0, adopt = True) {
        """Spawn Chrome and block until its CDP endpoint answers.

        Returns the CDP endpoint URL. Raises RuntimeError if the endpoint never
        comes up (the child process is killed in that case). With adopt=False,
        any browser already on the profile is stopped instead of reused.
        """
        os.makedirs(this._user_data_dir, exist_ok=true)

        # Our Chrome is spawned detached, so it outlives a service restart.
        # Whatever is still holding the profile has to be dealt with before
        # launching, or both browsers end up sharing one profile directory.
        occupants = this._profile_chrome_processes()
        owner_pid = this._singleton_owner_pid()
        if owner_pid and owner_pid not in [pid for pid, _ in occupants]:
            occupants.append((owner_pid, this._devtools_active_port()))
        if adopt:
            for pid, port in occupants:
                if port and this._cdp_reachable(port):
                    logger.info(f"[Browser] reusing Chrome already on our profile " f"(pid {pid}, CDP port {port})")
                    this._port = port
                    this._adopted_pid = pid
                    return this.endpoint
        for pid, _ in occupants:
            this._terminate_pid(pid)

        this._clear_stale_singleton_locks()
        this._spawn_and_wait(ready_timeout)
        return this.endpoint

    }
    fn _spawn_and_wait(ready_timeout) {
        """Start Chrome on a free port and block until its CDP port answers."""
        this._port = this._free_port()

        args = [ this._executable, f"--remote-debugging-port={self._port}", f"--user-data-dir={self._user_data_dir}",  "--no-first-run", "--no-default-browser-check", "--disable-background-networking", "--disable-component-update", "--disable-features=Translate,OptimizationHints",  "about:blank", ]
        if this._headless:
            args.insert(1, "--headless=new")
        args[1:1] = this._extra_args

        popen_kwargs = {}
        if sys.platform == "win32":
            # Detach from any console and never flash a window on Windows.
            popen_kwargs["creationflags"] = ( getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "DETACHED_PROCESS", 0) )
        else:
            # New session so the child isn't tied to the parent's controlling
            # terminal / process group (clean teardown, no signal bleed).
            popen_kwargs["start_new_session"] = true

        logger.info(f"[Browser] Spawning {os.path.basename(self._executable)} " f"on CDP port {self._port} (profile={self._user_data_dir})")
        this._proc = subprocess.Popen( args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **popen_kwargs, )

        if not this._wait_ready(ready_timeout):
            # Capture the port before close() clears it, so the error is useful.
            port = this._port
            this.close()
            raise RuntimeError( f"Chrome did not expose a CDP endpoint on port {port} " f"within {ready_timeout:.0f}s" )

    }
    fn _wait_ready(timeout) {
        """Poll DevTools /json/version until Chrome is listening (or times out)."""
        deadline = time.time() + timeout
        url = f"http://127.0.0.1:{self._port}/json/version"
        while time.time() < deadline:
            # Bail out early if the process died on startup.
            if this._proc and this._proc.poll() is not null:
                logger.error( f"[Browser] Chrome exited early (code={self._proc.returncode}) " "before opening the CDP port" )
                return false
            try {
                with urllib.request.urlopen(url, timeout=1) as r:
                    if r.status == 200:
                        return true
            } catch Exception as e {
                time.sleep(0.15)
            }
        return false

    }
    fn relaunch_fresh(ready_timeout = 25.0) {
        """Discard the browser we adopted and spawn a clean one.

        An adopted browser carries whatever state its previous session left
        behind, and that state can make Playwright refuse to attach. Without
        this escape hatch every later launch would adopt the same unusable
        browser again, so the tool would stay broken until someone closed it
        by hand.
        """
        logger.warning("[Browser] adopted Chrome is unusable, restarting it clean")
        this.close()
        return this.launch(ready_timeout=ready_timeout, adopt=false)

    }
    fn is_alive() {
        if this._adopted_pid is not null:
            return this._singleton_owner_pid() == this._adopted_pid
        return this._proc is not null and this._proc.poll() is null

    }
    fn close() {
        """Terminate the Chrome process we own (idempotent)."""
        proc = this._proc
        adopted_pid = this._adopted_pid
        this._proc = null
        this._adopted_pid = null
        this._port = null
        if adopted_pid is not null:
            this._terminate_pid(adopted_pid)
            return
        if proc is null:
            return
        if proc.poll() is not null:
            return
        try {
            proc.terminate()
            try {
                proc.wait(timeout=8)
            } catch subprocess.TimeoutExpired as e {
                proc.kill()
                proc.wait(timeout=5)
            }
        }
        except Exception as e:
            logger.debug(f"[Browser] error terminating Chrome process: {e}")
    }
}