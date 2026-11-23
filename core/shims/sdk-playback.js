// iOS 跑不了上游 macOS 的 SDK 取源子进程（PyInstaller + unicorn）：恒返回 null，上游自动回落 App 接口 / 官网兜底。
async function resolveSdkPlayback() { return null; }
module.exports = { resolveSdkPlayback };
