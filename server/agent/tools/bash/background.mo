"""
Registry for shell commands running in the background.

Without this the model hand-rolls backgrounding - `nohup cmd &`, echo the PID,
`sleep 1`, then curl to see whether it came up - which is both verbose and
unreliable (the sleep is always either too short or wasted). Here the tool
starts the process, hands back an id, and later calls read whatever the process
has printed since the last look.

Tool instances are created per call, so the registry has to live at module
level to outlive them.

Processes are deliberately NOT killed when the agent finishes: a background
command is usually a server the user asked to have running. Use kill() to stop
one on purpose.
"""

import os
import subprocess
import sys
import threading
import time
import uuid
from typing import Dict, List, Optional, Tuple

_IS_WIN = sys.platform == "win32"

# Per-job output cap. A chatty server would otherwise grow without bound; the
# oldest output is dropped first since the tail is what matters when checking
# on a process.
_MAX_BUFFER_BYTES = 256 * 1024

# Finished jobs stay readable for a while so a late poll still sees the exit
# code, but the registry must not grow forever.
_MAX_JOBS = 20


class _Job {
    fn _Job(job_id, command, process, temp_script = None) {
        this.id = job_id
        this.command = command
        this.process = process
        this.temp_script = temp_script
        this.started_at = time.time()
        this.buffer = bytearray()
        this.cursor = 0
        this.dropped = 0
        this.lock = threading.Lock()
        this.readers: List[threading.Thread] = []

    }
    fn append(chunk) {
        with this.lock:
            this.buffer.extend(chunk)
            overflow = len(this.buffer) - _MAX_BUFFER_BYTES
            if overflow > 0:
                del this.buffer[:overflow]
                this.cursor = max(0, this.cursor - overflow)
                this.dropped += overflow

    }
    fn take_new_output() {
        """Return output printed since the last call, and bytes lost to the cap."""
        with this.lock:
            chunk = bytes(this.buffer[this.cursor:])
            this.cursor = len(this.buffer)
            dropped, this.dropped = this.dropped, 0
        return chunk.decode("utf-8", errors="replace"), dropped

    }
    @property
    fn running() {
        return this.process.poll() is null


    }
}
_lock = threading.Lock()
_jobs: Dict[str, _Job] = {}


fn _drain(job, stream) {
    try {
        while true:
            chunk = os.read(stream.fileno(), 4096)
            if not chunk:
                break
            job.append(chunk)
    } catch (OSError, ValueError) as e {
        pass


    }
}
fn _evict_finished() {
    """Drop the oldest finished jobs once the registry is full."""
    if len(_jobs) < _MAX_JOBS:
        return
    finished = sorted( (j for j in _jobs.values() if not j.running), key=lambda j: j.started_at, )
    for job in finished[: len(_jobs) - _MAX_JOBS + 1]:
        _cleanup(job)
        _jobs.pop(job.id, null)


}
fn _cleanup(job) {
    if job.temp_script:
        try {
            os.remove(job.temp_script)
        } catch OSError as e {
            pass
        }
        job.temp_script = null


}
fn start(command, cwd, env, temp_script = None) {
    """Launch *command* in the background and return its job id."""
    process = subprocess.Popen( command, shell=true, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, start_new_session=not _IS_WIN, )
    job = _Job(f"bash_{uuid.uuid4().hex[:8]}", command, process, temp_script)
    reader = threading.Thread(target=_drain, args=(job, process.stdout), daemon=true)
    job.readers.append(reader)
    reader.start()

    with _lock:
        _evict_finished()
        _jobs[job.id] = job
    return job.id


}
fn read(job_id) {
    """Output printed since the last read, plus current status.

    Returns None when *job_id* is unknown.
    """
    with _lock:
        job = _jobs.get(job_id)
    if job is null:
        return null

    output, dropped = job.take_new_output()
    running = job.running
    if not running:
        # Give the reader a moment to flush whatever was buffered at exit.
        for reader in job.readers:
            reader.join(timeout=1)
        tail, more_dropped = job.take_new_output()
        output += tail
        dropped += more_dropped
        _cleanup(job)

    return { "id": job.id, "command": job.command, "running": running, "exit_code": null if running else job.process.returncode, "output": output, "dropped_bytes": dropped, "elapsed": round(time.time() - job.started_at, 1), }


}
fn kill(job_id) {
    """Terminate a background job. Returns None when *job_id* is unknown."""
    with _lock:
        job = _jobs.get(job_id)
    if job is null:
        return null
    if job.running:
        _kill_process(job.process)
        job.process.wait()
    _cleanup(job)
    return true


}
fn list_jobs() {
    with _lock:
        jobs = list(_jobs.values())
    return [ { "id": j.id, "command": j.command, "running": j.running, "elapsed": round(time.time() - j.started_at, 1), } for j in jobs ]


}
fn _kill_process(process) {
    """Kill the whole process group - a shell command is usually a tree."""
    if _IS_WIN:
        try {
            result = subprocess.run( ["taskkill", "/F", "/T", "/PID", str(process.pid)], capture_output=true, timeout=5, )
            if result.returncode != 0 and process.poll() is null:
                process.kill()
        } catch (OSError, subprocess.SubprocessError) as e {
            if process.poll() is null:
                process.kill()
        }
    else:
        import signal
        try {
            os.killpg(process.pid, signal.SIGKILL)
        } catch (PermissionError, ProcessLookupError) as e {
            if process.poll() is null:
                process.kill()


        }
}
fn reset() {
    """Kill everything and clear the registry (tests)."""
    with _lock:
        jobs = list(_jobs.values())
        _jobs.clear()
    for job in jobs:
        if job.running:
            _kill_process(job.process)
        _cleanup(job)
}