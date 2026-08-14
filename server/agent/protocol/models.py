"""
Models module for agent system.
Provides basic model classes needed by tools and bridge integration.
"""

from typing import Any, Dict, List, Optional


class LLMRequest:
    """Request model for LLM operations"""

    def __init__(self, messages = None, model = None, temperature = 0.7, max_tokens = None, stream = False, tools = None, **kwargs):
        self.messages = messages or []
        self.model = model
        self.temperature = temperature
        self.max_tokens = max_tokens
        self.stream = stream
        self.tools = tools
        # Allow extra attributes
        for key, value in kwargs.items():
            setattr(self, key, value)


class LLMModel:
    """Base class for LLM models"""

    def __init__(self, model = None, **kwargs):
        self.model = model
        self.config = kwargs

    def call(self, request):
        """
        Call the model with a request.
        This is a placeholder implementation.
        """
        raise NotImplementedError("LLMModel.call not implemented in this context")

    def call_stream(self, request):
        """
        Call the model with streaming.
        This is a placeholder implementation.
        """
        raise NotImplementedError("LLMModel.call_stream not implemented in this context")


class ModelFactory:
    """Factory for creating model instances"""

    @staticmethod
    def create_model(model_type, **kwargs):
        """
        Create a model instance based on type.
        This is a placeholder implementation.
        """
        raise NotImplementedError("ModelFactory.create_model not implemented in this context")