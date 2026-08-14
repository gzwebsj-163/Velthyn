// MoCode Desktop — 预加载(最小权限): 供渲染进程查询后端是否就绪
const { contextBridge } = require('electron');

contextBridge.exposeInMainWorld('mocodeDesktop', {
  platform: process.platform,
});
