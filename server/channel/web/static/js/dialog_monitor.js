// ========================================
// 监听对话系统 - 注入到 chat.html
// 支持跨页面通信（BroadcastChannel）
// ========================================

(function() {
    'use strict';

    // 使用服务器端消息队列进行跨源通信（基于当前页面源，支持远程部署）
    const API_BASE = window.location.origin + '/api/monitor';

    // 监听器状态
    let commandPollInterval = null;

    // 启动命令轮询
    function startCommandPolling() {
        if (commandPollInterval) return;

        commandPollInterval = setInterval(async () => {
            try {
                const response = await fetch(`${API_BASE}/command`);
                if (response.ok) {
                    const data = await response.json();
                    if (data && data.action) {
                        if (data.action === 'start') {
                            window.dialogMonitor.start();
                        } else if (data.action === 'stop') {
                            window.dialogMonitor.stop();
                        } else if (data.action === 'clear') {
                            window.dialogMonitor.clear();
                        }
                    }
                }
            } catch (e) {
                // 静默失败，避免控制台刷屏
            }
        }, 1000); // 每秒轮询一次
    }

    // 停止命令轮询
    function stopCommandPolling() {
        if (commandPollInterval) {
            clearInterval(commandPollInterval);
            commandPollInterval = null;
        }
    }

    // 全局监听器
    window.dialogMonitor = {
        active: false,
        dialogs: [],
        maxDialogs: 1000,
        subscribers: [],

        // 启动监听
        start: function() {
            this.active = true;
            this.log('✅ 监听系统已启动');

            // 通知其他页面
            this.broadcast({ type: 'system', action: 'start', message: '监听已启动' });
            this.notifySubscribers({ type: 'system', message: '监听已启动' });
        },

        // 停止监听
        stop: function() {
            this.active = false;
            this.log('⏹️ 监听系统已停止');

            // 通知其他页面
            this.broadcast({ type: 'system', action: 'stop', message: '监听已停止' });
            this.notifySubscribers({ type: 'system', message: '监听已停止' });
        },

        // 拦截对话
        intercept: async function(dialog) {
            if (!this.active) return;

            // 添加分析
            dialog.analysis = this.analyzeDialog(dialog);

            // 保存
            this.dialogs.push(dialog);
            if (this.dialogs.length > this.maxDialogs) {
                this.dialogs = this.dialogs.slice(-this.maxDialogs);
            }

            // 通知订阅者
            this.notifySubscribers(dialog);

            this.log(`💬 拦截对话: ${dialog.body.prompt.substring(0, 30)}...`);

            // 广播到其他页面（异步）
            await this.broadcast(dialog);

            // 推送到 SyntaxCheckHook
            this.pushToSyntaxCheckHook(dialog);
        },

        // 广播消息到其他页面（通过服务器端消息队列）
        broadcast: async function(data) {
            try {
                const response = await fetch(`${API_BASE}/message`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        source: 'mocode-dialog-monitor',
                        data: data
                    })
                });

                if (response.ok) {
                    this.log('📤 已广播消息到服务器');
                } else {
                    this.log(`❌ 广播失败: HTTP ${response.status}`);
                }
            } catch (e) {
                this.log(`❌ 广播失败: ${e.message}`);
            }
        },

        // 推送到 SyntaxCheckHook 钩子
        pushToSyntaxCheckHook: function(dialog) {
            if (window.SyntaxCheckHook) {
                try {
                    // 只提取核心信息推送到钩子
                    const coreData = {
                        id: dialog.id,
                        timestamp: dialog.timestamp,
                        prompt: dialog.body.prompt,        // 问题
                        context: dialog.body.context,      // 上下文
                        analysis: dialog.analysis          // 分析结果
                    };
                    
                    window.SyntaxCheckHook(coreData);
                } catch (e) {
                    console.error('[SyntaxCheckHook] 执行失败:', e);
                }
            } else {
                // 创建默认钩子（只在首次运行时创建）
                window.SyntaxCheckHook = function(data) {
                    console.log('=== 对话已拦截 ===');
                    console.log('上下文:', data.context);
                    console.log('问题:', data.prompt);
                    console.log('分析:', data.analysis);
                    console.log('==================');
                };
                
                // 再次推送
                const coreData = {
                    id: dialog.id,
                    timestamp: dialog.timestamp,
                    prompt: dialog.body.prompt,
                    context: dialog.body.context,
                    analysis: dialog.analysis
                };
                window.SyntaxCheckHook(coreData);
            }
        },

        // 分析对话
        analyzeDialog: function(dialog) {
            const prompt = dialog.body.prompt || '';

            return {
                semantic: this.analyzeSemantic(prompt),
                intent: this.analyzeIntent(prompt),
                keywords: this.extractKeywords(prompt),
                timestamp: new Date().toISOString()
            };
        },

        // 语义分析
        analyzeSemantic: function(prompt) {
            const features = [];

            if (/[\u4e00-\u9fff]/.test(prompt)) features.push('中文');
            else features.push('英文');

            if (prompt.includes('?') || prompt.includes('？')) features.push('疑问');
            if (/如何|怎么|怎样|how to/i.test(prompt)) features.push('指导');
            if (/是什么|什么是|what is/i.test(prompt)) features.push('定义');

            const len = prompt.length;
            if (len < 20) features.push('简短');
            else if (len < 100) features.push('中等');
            else features.push('详细');

            return features.join(' | ');
        },

        // 意图识别
        analyzeIntent: function(prompt) {
            const intents = {
                '查询': ['查询', '搜索', '查找', 'query', 'search', 'find'],
                '创建': ['创建', '生成', '制作', 'create', 'generate', 'make'],
                '修改': ['修改', '编辑', '更新', 'modify', 'edit', 'update'],
                '删除': ['删除', '移除', '清除', 'delete', 'remove', 'clear'],
                '分析': ['分析', '解析', '理解', 'analyze', 'parse'],
                '帮助': ['帮助', '协助', '支持', 'help', 'assist']
            };

            const detected = [];
            const lower = prompt.toLowerCase();

            for (const [intent, keywords] of Object.entries(intents)) {
                if (keywords.some(kw => lower.includes(kw))) {
                    detected.push(intent);
                }
            }

            return detected.length > 0 ? detected.join('、') : '通用对话';
        },

        // 关键词提取
        extractKeywords: function(prompt) {
            const chinese = prompt.match(/[\u4e00-\u9fff]{2,}/g) || [];
            const english = prompt.match(/\b[A-Za-z]{3,}\b/gi) || [];
            return [...new Set([...chinese, ...english])].slice(0, 8);
        },

        // 订阅
        subscribe: function(callback) {
            this.subscribers.push(callback);
        },

        // 通知订阅者
        notifySubscribers: function(data) {
            this.subscribers.forEach(cb => {
                try {
                    cb(data);
                } catch (e) {
                    console.error('订阅者回调错误:', e);
                }
            });
        },

        // 日志
        log: function(message) {
            console.log(`[对话监听] ${message}`);
        },

        // 获取历史
        getHistory: function(limit) {
            return this.dialogs.slice(-limit || 100);
        },

        // 清空
        clear: function() {
            this.dialogs = [];
            this.log('🗑️ 已清空历史');
        }
    };

    // 拦截原始发送函数
    const originalFetch = window.fetch;
    window.fetch = async function(url, options) {
        // 检查是否是对话消息
        const urlString = url.toString();
        const isMessageRequest = urlString.includes('/message') && options && options.method === 'POST';

        if (isMessageRequest && window.dialogMonitor.active) {
            try {
                const body = JSON.parse(options.body);
                const messageText = body.message || body.text || body.content || body.prompt;

                if (messageText) {
                    // 立即拦截并推送到 SyntaxCheckHook
                    const dialogData = {
                        id: Date.now(),
                        type: 'chat',
                        method: 'POST',
                        url: urlString,
                        timestamp: new Date().toISOString(),
                        body: {
                            prompt: messageText,
                            context: body.session_id,  // 上下文（session_id）
                            stream: body.stream
                        }
                    };

                    // 调用拦截函数
                    await window.dialogMonitor.intercept(dialogData);
                }
            } catch (e) {
                console.error('[对话监听] 拦截失败:', e);
            }
        }

        return originalFetch.apply(this, arguments);
    };

    // 页面加载完成后自动显示监听状态
    window.addEventListener('load', function() {
        console.log('💬 对话监听系统已注入');
        console.log('📡 跨页面通信已启用（BroadcastChannel）');
        console.log('使用 window.dialogMonitor.start() 启动监听');
        console.log('使用 window.dialogMonitor.stop() 停止监听');
        console.log('使用 window.dialogMonitor.getHistory() 获取历史');
    });

})();