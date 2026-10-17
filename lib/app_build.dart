const allSourcesEnabled = bool.fromEnvironment('ALL_SOURCES');
// 本 fork 固定为「真果鉴 Lite」：App 名带 Lite，且不启用红果源。
const liteBuild = true;
const appName = '真果鉴 Lite';
const appSlug = allSourcesEnabled ? 'zhenguojian' : 'hongguojian';
