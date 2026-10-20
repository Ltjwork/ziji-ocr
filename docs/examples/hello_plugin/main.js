// hello 示例插件主脚本：注册一个功能入口就完事。
// 入口出现在编辑器「全书操作」菜单里（requiresProject: true 时），
// 或任意页面可开（requiresProject: false）。
'use strict';

(async function activate() {
  await ziji.invoke('ui.registerEntries', {
    entries: [{
      id: 'main',
      title: '你好，字迹',
      subtitle: '插件示例：书库概览',
      icon: 'lightbulb',
      page: 'page.html',
      requiresProject: false,
    }],
  });
  await ziji.invoke('app.setStatus', { text: '示例插件就绪' });
})();
