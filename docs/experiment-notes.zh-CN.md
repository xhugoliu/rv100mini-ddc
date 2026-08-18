# RV100mini DDC/CI 实验记录

记录日期：2026-08-17  
测试主机：Apple Silicon Mac（Apple M4，macOS 26.6.1）  
目标：在不安装 BetterDisplay 等完整 GUI 应用的前提下，通过轻量命令和全局快捷键切换显示器输入源。

## 1. 显示器识别信息

| 项目 | 结果 |
| --- | --- |
| 型号 | RV100mini |
| 品牌 | Rich Vision / 未来视野 |
| 代工/关联厂商 | 深圳盛色科技（SANC） |
| 面板物理分辨率 | 3840 × 2160（4K） |
| macOS 当前逻辑分辨率 | 2560 × 1440 @ 60 Hz |
| macOS 内部渲染分辨率 | 5120 × 2880，再缩放输出至 4K |
| EDID 厂商 ID | RVM |
| 产品 ID | `0x2441`（十进制 9281） |
| EDID UUID | `4ACD4124-0000-0000-1A21-010380351E78` |
| 接口 | HDMI 2.0、DisplayPort 1.4、USB-C（65 W PD） |
| 本次 Mac 连接 | HDMI；IORegistry 显示传输链路为 `DP -> HDMI` |

`system_profiler` 显示的 `5120 × 2880` 不是面板为 5K，而是 macOS 的 HiDPI 内部渲染尺寸。IORegistry 中的最大输出宽高为 `3840 × 2160`。

## 2. 已确认的 DDC 能力

### 亮度

- VCP 功能码：`0x10`
- 写入亮度值 `50` 后，显示器明显变暗。
- 随后已恢复为 `100`。
- BetterDisplay 过去也能控制该显示器的硬件亮度。

结论：显示器支持 DDC/CI 写入，macOS 到显示器的底层 DDC 通道可用。

示例命令：

```sh
ASDDC setvcp --noverify 0x10 50
ASDDC setvcp --noverify 0x10 100
```

### 输入源

输入源使用 VCP 功能码 `0x60`。RV100mini 没有采用其 capabilities 字符串宣称的标准 MCCS 映射，而是使用了私有值。

| 输入源 | 十进制值 | 十六进制值 | 状态 |
| --- | ---: | ---: | --- |
| HDMI | `5` | `0x05` | 已确认；HDMI 为当前输入时可读回 `5` |
| DisplayPort | `6` | `0x06` | 推测；尚无带 DP 输出的设备，未验证 |
| USB-C | `7` | `0x07` | 已确认；接入有效 USB-C 信号后可成功切换 |

发现私有映射的过程：

1. `monitor-input -c RV100mini` 在 HDMI 输入下读到当前值为 `5`。
2. 显示器 capabilities 字符串却只报告 `DP1`、`DP2`、`Hdmi1`，对应标准值 `15`、`16`、`17`，与实际值矛盾。
3. USB-C 接入有效设备后写入原始值 `7`，显示器成功切到 USB-C。
4. 因三个物理接口很可能采用连续私有值，暂推测 DP 为 `6`，但必须用有效 DP 信号验证。

## 3. 输入切换测试记录

### 无有效 DP/USB-C 信号时

以下值均曾写入 VCP `0x60`，屏幕未发生可见切换：

```text
0x0F, 0x10, 0x1B, 0x12, 0x13, 0x0B, 0x00,
0x01, 0x03, 0x05, 0x06, 0x14, 0x15, 0x1C
```

这批结果不能证明值无效，因为当时 DP 和 USB-C 都没有有效信号。显示器可能拒绝无信号输入，或者立即自动返回 HDMI。其中 `0x05` 后来已确认就是 HDMI，写入后画面不变属于正常现象。

标准候选值也未能切换：

| 标准名称 | 值 | 结果 |
| --- | ---: | --- |
| DisplayPort 1 | `0x0F` | 无可见变化 |
| DisplayPort 2 | `0x10` | 无可见变化 |
| HDMI 1 | `0x11` | 未被识别为本机 HDMI 映射 |
| HDMI 2 | `0x12` | 无可见变化 |
| USB-C | `0x1B` | 无可见变化 |

### USB-C 有有效信号后

```sh
monitor-input RV100mini=7
```

结果：成功从 HDMI 切到 USB-C。

### 仅插入未连接设备的 DP 线

显示器端插入 DP 线，但线材另一端没有连接任何输出设备。随后写入推测值 `6`：

```text
10:39:35 写入 DP 候选值 6
10:39:41 读回当前输入值 5
```

结果：显示器仍停留在 HDMI，当前输入源仍可正常读回为 `5`。空 DP 线没有设备提供有效视频信号或热插拔状态，因此该测试既没有确认也没有否定 `DP=6`。

### 从非当前输入端口切回测试

执行了如下定时逻辑：

```sh
monitor-input RV100mini=7
sleep 10
monitor-input RV100mini=5
```

实际时间：

```text
10:30:33 发送 USB-C 值 7
10:30:43 从原 HDMI 主机发送 HDMI 值 5
10:30:46 尝试读取当前输入源
```

结果：

- 第一步成功切到 USB-C。
- 后台进程在 10 秒后确实继续执行了写入 `5` 的命令。
- 显示器没有自动切回 HDMI。
- HDMI 主机此时读取 DDC 返回 `invalid DDC/CI length`。
- 最终需要使用显示器物理按键手动切回 HDMI。

结论：RV100mini 很可能只接受来自当前活动输入端口的 DDC 命令；也可能是 macOS 在 HDMI 失活后撤销或破坏了对应的 DDC/IOAVService 通道。显示器是不是主机的唯一屏幕不影响后台命令继续运行，只影响用户能否看到该主机画面。

## 4. 对实际快捷键方案的影响

单台主机无法可靠完成完整往返：

```text
HDMI Mac --写入 7--> 切到 USB-C：成功
HDMI Mac --写入 5--> 从 USB-C 拉回 HDMI：失败
```

可行方案是在每个信号源主机上分别安装轻量工具：

- HDMI 主机负责写入 `7`，把显示器切给 USB-C 主机。
- USB-C 主机负责写入 `5`，把显示器切回 HDMI 主机。
- 未来两端都是 MacBook 时，可以在两台 Mac 上安装同一个命令行工具和快捷键守护进程。
- 当前 USB-C 设备是同事的 Windows 电脑，因此本轮不在该设备安装软件。

如果希望任何一端都能随时“拉回”显示器，而显示器又关闭非当前端口的 DDC，则只能考虑独立于视频端口的控制方式，例如硬件切换器、KVM，或继续使用物理按键。

## 5. 调研过的开源项目

### monitor-input-rs

- 仓库：<https://github.com/kojiishi/monitor-input-rs>
- 许可证：Apache-2.0
- 本次测试版本：提交 `d9c084fabd9eb72633fada24f6059a95cc279b86`
- 支持 macOS、Windows 和 Linux。
- Apple Silicon 下通过 `ddc-hi` 和 `ddc-macos` 使用 IOAVService。
- 本次测试中能够读到 HDMI 的真实原始值 `5`，也能使用原始值 `7` 切到 USB-C。
- Release 二进制约 3.3 MB，已经足够轻量，适合作为新项目的底层实现或参考代码。

常用命令：

```sh
# 读取显示器和当前输入源
monitor-input -c RV100mini

# 切到 HDMI
monitor-input RV100mini=5

# 切到推测的 DP
monitor-input RV100mini=6

# 切到 USB-C
monitor-input RV100mini=7
```

### AppleSiliconDDC

- 仓库：<https://github.com/waydabber/AppleSiliconDDC>
- 许可证：MIT
- 本次测试版本：提交 `97af3818b9803e51412fb50cac1506db1d73b5bf`
- 是 BetterDisplay 作者公开的 Apple Silicon DDC 底层库。
- 能检测 RV100mini，写亮度成功。
- 对该显示器读取 VCP `0x60` 和 capabilities 不稳定。
- 写输入源值可以触发 HDMI → USB-C，但切走后同样不能从失活的 HDMI 通道切回。

### BetterDisplay

- 公开仓库：<https://github.com/waydabber/BetterDisplay>
- BetterDisplay 主应用并非完整开源；公开仓库主要用于发布、问题跟踪和部分配套代码。
- 过去已实测可控制 RV100mini 的硬件亮度。
- GitHub 上发现一个 RV100mini 相关 issue，但内容是 macOS 上的亮度 OSD，并非输入源切换：<https://github.com/waydabber/BetterDisplay/issues/5563>

### 厂商软件

- SANC 官方下载页：<http://www.ccclcd.com/service/downloads>
- 官方 Windows “盛色屏管家”只列出若干其他型号，未发现 RV100mini/M2441 版本。
- 静态检查过 D76 版 SancClient：Qt/C++ 程序，调用 Windows `dxva2.dll` 的 `GetVCPFeatureAndVCPFeatureReply` 和 `SetVCPFeature`，本质仍是标准 DDC/CI。
- 未发现 RV100mini 专用协议或可直接复用的型号映射。

截至本次调研，没有找到专门针对 RV100mini、Rich Vision/未来视野或该 EDID 的开源输入切换项目。

## 6. 当前本地原型

路径：本仓库根目录。

原型特性：

- Swift 原生命令行程序，Release 二进制约 197 KB。
- 使用 AppleSiliconDDC 发送 VCP `0x60`。
- 使用 Carbon `RegisterEventHotKey` 注册全局快捷键，不需要辅助功能权限。
- 支持 LaunchAgent 登录自启。
- 当前示例配置已改为 RV100mini 私有映射：
  - `Control-Option-1` → HDMI `5`
  - `Control-Option-2` → DP `6`（待验证）
  - `Control-Option-3` → USB-C `7`
- 尚未安装到系统，也没有启用登录自启。

注意：该 Swift 原型的底层 AppleSiliconDDC 可靠性不如 `monitor-input-rs`。若继续开发，优先考虑直接复用或移植 `ddc-macos` 的传输实现，而不是继续扩展当前传输层。

## 7. 后续项目建议

如果创建专门针对 RV100mini 的开源项目，建议最小范围如下：

1. 默认提供型号映射 `HDMI=5`、`DP=6`、`USB-C=7`，并明确标记 DP 尚待验证。
2. 同时允许用户传入任意原始十进制或十六进制 VCP 值，避免绑定单一固件。
3. 复用 `monitor-input-rs`、`ddc-hi` 或 `ddc-macos`，减少重新实现 DDC 数据包和平台枚举逻辑。
4. macOS 端用 Carbon 全局快捷键，避免菜单栏常驻 UI 和辅助功能权限。
5. Windows 端可复用 `monitor-input-rs`，或直接调用 High-Level Monitor Configuration API / `dxva2.dll`。
6. 日志必须区分“命令写入成功”和“显示器已实际切换”；仅凭底层 API 返回成功不能证明画面已经切换。
7. 文档明确说明端口限制：切走后原主机可能无法通过失活端口把显示器拉回。
8. 有可用 DP 设备后，先在 DP 为当前画面时读取 VCP `0x60`，确认是否为 `6`，再写入默认映射。

## 8. 下一轮建议测试步骤

准备两台 Mac 和有效 HDMI、USB-C 连接后：

1. 在 HDMI Mac 执行 `monitor-input RV100mini=7`，确认切到 USB-C。
2. 在 USB-C Mac 执行 `monitor-input -c RV100mini`，确认读到当前值 `7`。
3. 在 USB-C Mac 执行 `monitor-input RV100mini=5`，确认切回 HDMI。
4. 分别在两台 Mac 设置单向全局快捷键。
5. 重复往返至少 20 次，记录失败率、最短命令间隔和睡眠唤醒后的行为。
6. 找到带 DP 输出的设备后，物理切到 DP，再读取当前 VCP `0x60`，验证值 `6`。
