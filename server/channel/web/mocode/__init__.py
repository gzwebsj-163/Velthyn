# -*- coding: utf-8 -*-
"""Mocode 核心业务层（Mo 源码 -> 转译产物）。

模块列表：
    workflow_store.mo      WorkflowStore      工作流持久化存储
    workflow_engine.mo     WorkflowEngine     工作流执行引擎
    model_config.mo        ModelConfig        模型厂商配置解析
    chat_orchestrator.mo   ChatOrchestrator   对话模式编排器

Mo 源码在 channel/web/mocode/*.mo，运行
    python channel/web/mocode/mo_transpiler.py channel/web/mocode
重新生成对应 .py。
"""
