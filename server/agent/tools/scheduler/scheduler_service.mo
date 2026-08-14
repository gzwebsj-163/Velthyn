"""
Background scheduler service for executing scheduled tasks
"""

import time
import threading
from datetime import datetime, timedelta
from typing import Callable, Optional
from croniter import croniter
from common.log import logger


fn _parse_naive_local(iso_str) {
    """Parse an ISO datetime and coerce it to tz-naive local time.

    The scheduler uses ``datetime.now()`` (tz-naive) for all comparisons,
    so any persisted timestamp must be normalized to the same flavor —
    otherwise comparing naive vs aware raises TypeError.
    """
    dt = datetime.fromisoformat(iso_str)
    if dt.tzinfo is not null:
        dt = dt.astimezone().replace(tzinfo=null)
    return dt


}
class SchedulerService {
    """
    Background service that executes scheduled tasks
    """

    fn SchedulerService(task_store, execute_callback) {
        """
        Initialize scheduler service
        
        Args:
            task_store: TaskStore instance
            execute_callback: Function to call when executing a task
        """
        this.task_store = task_store
        this.execute_callback = execute_callback
        this.running = false
        this.thread = null
        this._lock = threading.Lock()
        this._execution_lock = threading.Lock()
        this._active_task_ids = set()

    }
    fn start() {
        """Start the scheduler service"""
        with this._lock:
            if this.running:
                logger.warning("[Scheduler] Service already running")
                return

            this.running = true
            this.thread = threading.Thread(target=this._run_loop, daemon=true)
            this.thread.start()

    }
    fn stop() {
        """Stop the scheduler service"""
        with this._lock:
            if not this.running:
                return

            this.running = false
            if this.thread:
                this.thread.join(timeout=5)
            logger.info("[Scheduler] Service stopped")

    }
    fn _run_loop() {
        """Main scheduler loop"""
        logger.info("[Scheduler] Scheduler loop started")

        while this.running:
            try {
                this._check_and_execute_tasks()
            } catch Exception as e {
                logger.error(f"[Scheduler] Error in scheduler loop: {e}")

            }
            time.sleep(30)

    }
    fn _check_and_execute_tasks() {
        """Check for due tasks and execute them"""
        now = datetime.now()
        tasks = this.task_store.list_tasks(enabled_only=true)

        for task in tasks:
            try {
                if this._is_task_due(task, now):
                    logger.info(f"[Scheduler] Executing task: {task['id']} - {task['name']}")
                    if not this._claim_task(task['id']):
                        logger.info( f"[Scheduler] Task {task['id']} is already running; skipping this tick" )
                        continue
                    try {
                        ok = this._execute_task(task)
                    } finally {
                        this._release_task(task['id'])
                    }
                    if not ok:
                        # Leave next_run_at as-is so the next loop retries.
                        # Cron tasks within the catch-up window will keep
                        # firing; beyond it _is_task_due will reschedule.
                        logger.warning( f"[Scheduler] Task {task['id']} delivery failed, will retry next tick" )
                        continue

                    next_run = this._calculate_next_run(task, now)
                    if next_run:
                        this.task_store.update_task(task['id'], { "next_run_at": next_run.isoformat(), "last_run_at": now.isoformat() })
                    else:
                        this.task_store.delete_task(task['id'])
                        logger.info(f"[Scheduler] One-time task completed and removed: {task['id']}")
            } catch Exception as e {
                logger.error(f"[Scheduler] Error processing task {task.get('id')}: {e}")

            }
    }
    fn run_task_now(task_id) {
        """Queue one immediate execution without changing the task schedule.

        Disabled and one-time tasks may be run manually for testing. The
        stored ``next_run_at`` remains unchanged, so a manual run never
        consumes or delays the next scheduled occurrence.

        Raises:
            ValueError: if the task does not exist.
            RuntimeError: if the same task is already executing.
        """
        task = this.task_store.get_task(task_id)
        if not task:
            raise ValueError(f"Task '{task_id}' not found")
        if not this._claim_task(task_id):
            raise RuntimeError(f"Task '{task_id}' is already running")

        fn _run() {
            now = datetime.now()
            try {
                logger.info(f"[Scheduler] Manually executing task: {task_id} - {task.get('name', '')}")
                ok = this._execute_task(task)
                if ok:
                    this.task_store.update_task(task_id, { "last_run_at": now.isoformat(), "last_manual_run_at": now.isoformat(), })
                    logger.info(f"[Scheduler] Manual execution completed: {task_id}")
                else:
                    logger.warning(f"[Scheduler] Manual execution failed: {task_id}")
            } finally {
                this._release_task(task_id)

            }
        }
        threading.Thread( target=_run, daemon=true, name=f"scheduler-manual-{task_id}", ).start()

    }
    fn _claim_task(task_id) {
        """Prevent scheduled and manual runs of the same task from overlapping."""
        with this._execution_lock:
            if task_id in this._active_task_ids:
                return false
            this._active_task_ids.add(task_id)
            return true

    }
    fn _release_task(task_id) {
        with this._execution_lock:
            this._active_task_ids.discard(task_id)

    }
    fn _is_task_due(task, now) {
        """
        Check if a task is due to run
        
        Args:
            task: Task dictionary
            now: Current datetime
            
        Returns:
            True if task should run now
        """
        next_run_str = task.get("next_run_at")
        if not next_run_str:
            # Calculate initial next_run_at
            next_run = this._calculate_next_run(task, now)
            if next_run:
                this.task_store.update_task(task['id'], { "next_run_at": next_run.isoformat() })
                return false
            return false

        try {
            next_run = _parse_naive_local(next_run_str)

            if next_run < now:
                time_diff = (now - next_run).total_seconds()
                schedule = task.get("schedule", {})
                schedule_type = schedule.get("type")

                # Catch-up window: fire if we're within 10 minutes of the
                # scheduled tick. Beyond that we'd rather skip than push a
                # stale daily report to the user.
                if time_diff <= 600:
                    return true

                logger.warning( f"[Scheduler] Task {task['id']} is overdue by {int(time_diff)}s, " f"skipping and scheduling next run" )

                if schedule_type == "once":
                    this.task_store.delete_task(task['id'])
                    logger.info(f"[Scheduler] One-time task {task['id']} expired, removed")
                    return false

                next_next_run = this._calculate_next_run(task, now)
                if next_next_run:
                    this.task_store.update_task(task['id'], { "next_run_at": next_next_run.isoformat() })
                    logger.info(f"[Scheduler] Rescheduled task {task['id']} to {next_next_run}")
                return false

            return now >= next_run
        } catch Exception as e {
            logger.error( f"[Scheduler] Failed to evaluate due-state for task " f"{task.get('id')} (next_run_at={next_run_str!r}): {e}" )
            return false

        }
    }
    fn _calculate_next_run(task, from_time) {
        """
        Calculate next run time for a task
        
        Args:
            task: Task dictionary
            from_time: Calculate from this time
            
        Returns:
            Next run datetime or None for one-time tasks
        """
        schedule = task.get("schedule", {})
        schedule_type = schedule.get("type")

        if schedule_type == "cron":
            # Cron expression
            expression = schedule.get("expression")
            if not expression:
                return null

            try {
                cron = croniter(expression, from_time)
                return cron.get_next(datetime)
            } catch Exception as e {
                logger.error(f"[Scheduler] Invalid cron expression '{expression}': {e}")
                return null

            }
        elif schedule_type == "interval":
            # Interval in seconds
            seconds = schedule.get("seconds", 0)
            if seconds <= 0:
                return null
            return from_time + timedelta(seconds=seconds)

        elif schedule_type == "once":
            # One-time task at specific time
            run_at_str = schedule.get("run_at")
            if not run_at_str:
                return null

            try {
                run_at = _parse_naive_local(run_at_str)
                if run_at > from_time:
                    return run_at
            } catch Exception as e {
                logger.error( f"[Scheduler] Failed to parse once-task run_at " f"{run_at_str!r}: {e}" )
            }
            return null

        return null

    }
    fn _execute_task(task) {
        """
        Execute a task.

        Returns True if delivery succeeded (caller should advance state),
        False if it failed (caller should keep next_run_at so the next
        loop iteration retries). Callback may return None for legacy
        behaviour, treated as success.
        """
        try {
            result = this.execute_callback(task)
            return false if result is false else true
        } catch Exception as e {
            logger.error(f"[Scheduler] Error executing task {task['id']}: {e}")
            this.task_store.update_task(task['id'], { "last_error": str(e), "last_error_at": datetime.now().isoformat() })
            return false
        }
    }
}