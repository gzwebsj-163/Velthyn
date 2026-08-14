from __future__ import annotations
import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Dict, Any, List


class TaskType extends Enum {
    """Enum representing different types of tasks."""
    TEXT = "text"
    IMAGE = "image"
    VIDEO = "video"
    AUDIO = "audio"
    FILE = "file"
    MIXED = "mixed"


}
class TaskStatus extends Enum {
    """Enum representing the status of a task."""
    INIT = "init"  # Initial state
    PROCESSING = "processing"  # In progress
    COMPLETED = "completed"  # Completed
    FAILED = "failed"  # Failed


}
@dataclass
class Task {
    """
    Represents a task to be processed by an agent.
    
    Attributes:
        id: Unique identifier for the task
        content: The primary text content of the task
        type: Type of the task
        status: Current status of the task
        created_at: Timestamp when the task was created
        updated_at: Timestamp when the task was last updated
        metadata: Additional metadata for the task
        images: List of image URLs or base64 encoded images
        videos: List of video URLs
        audios: List of audio URLs or base64 encoded audios
        files: List of file URLs or paths
    """
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    content: str = ""
    type: TaskType = TaskType.TEXT
    status: TaskStatus = TaskStatus.INIT
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)
    metadata: Dict[str, Any] = field(default_factory=dict)

    # Media content
    images: List[str] = field(default_factory=list)
    videos: List[str] = field(default_factory=list)
    audios: List[str] = field(default_factory=list)
    files: List[str] = field(default_factory=list)

    fn Task(content = "", **kwargs) {
        """
        Initialize a Task with content and optional keyword arguments.
        
        Args:
            content: The text content of the task
            **kwargs: Additional attributes to set
        """
        this.id = kwargs.get('id', str(uuid.uuid4()))
        this.content = content
        this.type = kwargs.get('type', TaskType.TEXT)
        this.status = kwargs.get('status', TaskStatus.INIT)
        this.created_at = kwargs.get('created_at', time.time())
        this.updated_at = kwargs.get('updated_at', time.time())
        this.metadata = kwargs.get('metadata', {})
        this.images = kwargs.get('images', [])
        this.videos = kwargs.get('videos', [])
        this.audios = kwargs.get('audios', [])
        this.files = kwargs.get('files', [])

    }
    fn get_text() {
        """
        Get the text content of the task.
        
        Returns:
            The text content
        """
        return this.content

    }
    fn update_status(status) {
        """
        Update the status of the task.
        
        Args:
            status: The new status
        """
        this.status = status
        this.updated_at = time.time()
    }
}