// ========================================
// 监听对话系统 - 注入到 chat.html
// ========================================

(function() {
    'use strict';
    
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
            this.notifySubscribers({ type: 'system', message: '监听已启动' });
        },
        
        // 停止监听
        stop: function() {
            this.active = false;
            this.log('⏹️ 监听系统已停止');
            this.notifySubscribers({ type: 'system', message: '监听已停止' });
        },
        
        // 拦截对话
        intercept: function(dialog) {
            if (!this.active) return;
            
            // 添加分析
            dialog.analysis = this.analyzeDialog(dialog);
            
            // 保存
            this.dialogs.push(dialog);
            if (this.dialogs.length > this.maxDialogs) {
                this.dialogs = this.dialogs.slice(-this.maxDialogs);
            }
            
            // 通知
            this.notifySubscribers(dialog);
            this.log(`💬 拦截对话: ${dialog.body.prompt.substring(0, 30)}...`);
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
    window.fetch = function(url, options) {
        // 检查是否是对话消息
        if (url === '/message' && options && options.method === 'POST') {
            try {
                const body = JSON.parse(options.body);
                if (body.message && window.dialogMonitor.active) {
                    window.dialogMonitor.intercept({
                        id: Date.now(),
                        type: 'chat',
                        method: 'POST',
                        url: url,
                        timestamp: new Date().toISOString(),
                        body: {
                            prompt: body.message,
                            session_id: body.session_id,
                            stream: body.stream
                        },
                        headers: options.headers || {}
                    });
                }
            } catch (e) {
                // 解析失败，忽略
            }
        }
        
        return originalFetch.apply(this, arguments);
    };
    
    // 页面加载完成后自动显示监听状态
    window.addEventListener('load', function() {
        console.log('💬 对话监听系统已注入');
        console.log('使用 window.dialogMonitor.start() 启动监听');
        console.log('使用 window.dialogMonitor.stop() 停止监听');
        console.log('使用 window.dialogMonitor.getHistory() 获取历史');
    });
    
})();