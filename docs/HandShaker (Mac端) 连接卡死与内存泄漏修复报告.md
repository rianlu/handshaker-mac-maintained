# 📝 HandShaker (Mac端) 连接卡死与内存泄漏修复报告

## 🐛 故障现象
* **环境：** macOS 15 (Apple Silicon 芯片，通过 Rosetta 2 运行)
* **症状：** HandShaker Mac 端启动正常。当通过 USB 连接 Android 手机后，初步握手成功，能短暂显示手机内的照片、视频和文件夹。但约几十秒后，Mac 端突然彻底卡死（鼠标转彩球），并在“活动监视器”中观察到该进程内存占用持续无限制飙升（直至 OOM 崩溃或拖死整个系统）。
* **特征：** 即使连接一台没有照片的低版本 Android 手机，该卡死和内存飙升现象依然 100% 稳定复现。

## 🔍 排查过程

### 1. 排除底层 ADB 与 I/O 兼容性问题
最初怀疑是 macOS 底层 USB 驱动栈变更导致 HandShaker 内置的老旧 `adb` 进程死锁，或是网络 I/O 轮询陷入非阻塞死循环。但由于软件能成功读取出目录结构，且低版本安卓也会触发，排除了单纯的通信挂起。

### 2. 进程采样 (Sample) 抓取调用栈
为了获取实锤证据，在 HandShaker 刚开始内存飙升准备卡死时，通过 Mac 自带的“活动监视器”对其进行**进程采样 (Sample)**。
抓取到的主线程（Main Thread）调用栈成为了破案的关键：

```text
// 核心调用栈节选
-[SFPhotoSyncConfigViewController init]
  -[NSBundle(NSNibLoading) loadNibNamed:owner:topLevelObjects:] 
    _decodeObjectBinary 
      objc_exception_rethrow  <-- 致命点1：UI 反序列化抛出异常！
        ... (进入异常捕获逻辑)
          backtrace_symbols   <-- 致命点2：尝试解析崩溃堆栈
            (in Rosetta JIT)  <-- 致命点3：Rosetta 动态转译器介入
              __CFStringAppendFormatCore <-- 致命点4：无限拼接字符串，内存撑爆
```

## 🕵️‍♂️ 根因分析 (Root Cause)

经过对采样报告的分析，还原了完整的崩溃链条：

1. **导火索 (废弃组件引发异常)：** 手机连接成功后，软件试图弹出一个名为 `SFPhotoSyncConfigView`（照片自动同步提示）的窗口。但该界面的旧版 `.nib` 文件中包含了在现代 macOS 中被废弃或不符合安全解码规范的组件，导致 `NSKeyedUnarchiver` 拒绝解码并抛出异常（Exception）。
2. **核爆 (Rosetta 转译器引发内存泄漏)：** HandShaker 内部署了全局崩溃捕获器。它拦截了该 UI 异常，并试图通过 `backtrace_symbols` 打印出崩溃堆栈。
3. 然而，在 Apple Silicon 芯片的 Rosetta 2 (x86-64 转译) 环境下，频繁解析底层崩溃符号导致了极其严重的性能问题。程序陷入了极其耗时的符号解析循环，并在循环中疯狂调用 `__CFStringAppendFormatCore` 分配字符串对象。
4. **结果：** 短短几十秒内，海量的字符串垃圾对象吃光了 Mac 的所有内存，导致主线程彻底阻塞卡死。

## 🛠 逆向修复方案 (二进制打补丁)

既然根本原因是“弹窗 UI 加载失败”引发的连环车祸，且核心传输功能并未损坏，最优雅的修复方案是：**修改二进制汇编指令，直接在代码逻辑层面“阉割”掉这个弹窗。**

### 修复步骤：
1. **定位目标函数：**
   使用 **Hopper Disassembler** 载入 `HandShaker` 二进制可执行文件。
   导航至主线程调用栈暴露的触发点：`-[SFPhotoSyncConfigViewController init]` （偏移地址 `0x394af`）。

2. **分析伪代码与汇编逻辑：**
   该方法在调用 `[super init]` 后，会判断实例是否为空，若不为空，则开始执行创建 NSView、加载炸弹组件等一系列作死操作。
   汇编指令如下：
   ```assembly
   0x1000394df  call  imp___stubs__objc_msgSendSuper2  ; [super init]
   0x1000394e4  mov   r15, rax                         ; 实例存入 r15
   0x1000394e7  test  r15, r15                         ; 检查是否为空
   0x1000394ea  je    loc_10003967c                    ; 如果为空，跳到末尾结束 (条件跳转)
   ; ... 下方为导致崩溃的 UI 加载代码 ...
   ```

3. **实施外科手术 (Patch)：**
   选中 `0x1000394ea` 处的 `je` (Jump if Equal) 指令，修改为 **`jmp`** (无条件跳转)。
   *原指令：`je loc_10003967c`*
   *新指令：`jmp loc_10003967c`*
   **逻辑变更：** 欺骗 CPU，使其在执行完 `[super init]` 后，强行飞跃过所有 UI 加载代码，直接返回。

4. **重打包与签名：**
   在 Hopper 中选择 `Produce New Executable` 覆盖原文件。
   打开 macOS 终端，执行本地重签名以绕过 Gatekeeper：
   ```bash
   sudo codesign --force --deep --sign - /Applications/HandShaker.app
   ```

## ✅ 验证与总结
重新运行修改后的 HandShaker 并连接手机：
* 内存占用保持在正常水平（几十 MB 左右），不再飙升。
* 软件不再转彩球卡死，文件管理、图片和视频预览功能完全恢复正常。
* **副作用：** 原本的“照片同步”提示窗口变成了一个只有标题栏的空壳（因为内容控制器已被跳过），点击关闭即可，完全不影响核心功能使用。

本次修复成功挽救了一款在现代 macOS 上被判“死刑”的优秀经典软件。
