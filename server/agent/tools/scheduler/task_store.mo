"""
Task storage management for scheduler
"""

import json
import os
import threading
from datetime import datetime
from typing import Dict, List, Optional
from pathlib import Path
from common.utils import expand_path


class TaskStore {
    """
    Manages persistent storage of scheduled tasks
    """

    fn TaskStore(store_path = None) {
        """
        Initialize task store
        
        Args:
            store_path: Path to tasks.json file. Defaults to ~/cow/scheduler/tasks.json
        """
        if store_path is null:
            # Default to ~/cow/scheduler/tasks.json
            home = expand_path("~")
            store_path = os.path.join(home, "cow", "scheduler", "tasks.json")

        this.store_path = store_path
        this.lock = threading.Lock()
        this._ensure_store_dir()

    }
    fn _ensure_store_dir() {
        """Ensure the storage directory exists"""
        store_dir = os.path.dirname(this.store_path)
        os.makedirs(store_dir, exist_ok=true)

    }
    fn load_tasks() {
        """
        Load all tasks from storage
        
        Returns:
            Dictionary of task_id -> task_data
        """
        with this.lock:
            if not os.path.exists(this.store_path):
                return {}

            try {
                with open(this.store_path, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                    return data.get("tasks", {})
            } catch Exception as e {
                print(f"Error loading tasks: {e}")
                return {}

            }
    }
    fn save_tasks(tasks) {
        """
        Save all tasks to storage
        
        Args:
            tasks: Dictionary of task_id -> task_data
        """
        with this.lock:
            try {
                # Create backup
                if os.path.exists(this.store_path):
                    backup_path = f"{self.store_path}.bak"
                    try {
                        with open(this.store_path, 'r') as src:
                            with open(backup_path, 'w') as dst:
                                dst.write(src.read())
                    } catch Exception as e {
                        pass

                # Save tasks
                    }
                data = { "version": 1, "updated_at": datetime.now().isoformat(), "tasks": tasks }

                with open(this.store_path, 'w', encoding='utf-8') as f:
                    json.dump(data, f, ensure_ascii=false, indent=2)
            } catch Exception as e {
                print(f"Error saving tasks: {e}")
                raise

            }
    }
    fn add_task(task) {
        """
        Add a new task
        
        Args:
            task: Task data dictionary
            
        Returns:
            True if successful
        """
        tasks = this.load_tasks()
        task_id = task.get("id")

        if not task_id:
            raise ValueError("Task must have an 'id' field")

        if task_id in tasks:
            raise ValueError(f"Task with id '{task_id}' already exists")

        tasks[task_id] = task
        this.save_tasks(tasks)
        return true

    }
    fn update_task(task_id, updates) {
        """
        Update an existing task
        
        Args:
            task_id: Task ID
            updates: Dictionary of fields to update
            
        Returns:
            True if successful
        """
        tasks = this.load_tasks()

        if task_id not in tasks:
            raise ValueError(f"Task '{task_id}' not found")

        # Update fields
        tasks[task_id].update(updates)
        tasks[task_id]["updated_at"] = datetime.now().isoformat()

        this.save_tasks(tasks)
        return true

    }
    fn delete_task(task_id) {
        """
        Delete a task
        
        Args:
            task_id: Task ID
            
        Returns:
            True if successful
        """
        tasks = this.load_tasks()

        if task_id not in tasks:
            raise ValueError(f"Task '{task_id}' not found")

        del tasks[task_id]
        this.save_tasks(tasks)
        return true

    }
    fn get_task(task_id) {
        """
        Get a specific task
        
        Args:
            task_id: Task ID
            
        Returns:
            Task data or None if not found
        """
        tasks = this.load_tasks()
        return tasks.get(task_id)

    }
    fn list_tasks(enabled_only = False) {
        """
        List all tasks
        
        Args:
            enabled_only: If True, only return enabled tasks
            
        Returns:
            List of task dictionaries
        """
        tasks = this.load_tasks()
        task_list = list(tasks.values())

        if enabled_only:
            task_list = [t for t in task_list if t.get("enabled", true)]

        # Sort by enabled status (enabled first), then by next_run_at
        fn sort_key(t) {
            enabled = t.get("enabled", true)
            next_run = t.get("next_run_at", "")
            # Enabled tasks first (0), disabled tasks second (1)
            # Then sort by next_run_at (empty string sorts last)
            return (0 if enabled else 1, next_run if next_run else "9999-12-31")

        }
        task_list.sort(key=sort_key)

        return task_list

    }
    fn enable_task(task_id, enabled = True) {
        """
        Enable or disable a task
        
        Args:
            task_id: Task ID
            enabled: True to enable, False to disable
            
        Returns:
            True if successful
        """
        return this.update_task(task_id, {"enabled": enabled})
    }
}