# 运动校园去广（iOS版）

> 基于 ClashMi 的校园跑 App 去广告配置文件，专为 iOS 设备设计。

## 项目简介

本项目提供一份 ClashMi 配置文件（`.yaml`），用于在 iOS 设备上拦截各类 App 弹窗广告和推送通知，核心目标是为「运动世界校园」等校园跑 App 去除强制广告弹窗，同时覆盖美团、微博、京东、淘宝、快手等常见广告源。

配置文件采用纯规则拦截模式（`REJECT`），不经过任何第三方代理服务器，所有流量直连或丢弃，隐私安全可控。

## 功能特性

- **校园跑广告拦截**：拦截穿山甲 SDK、天幕广告、AdMobile 等校园跑 App 常用广告渠道
- **红果短剧广告拦截**：拦截快手广告联盟（`gifshow.com`）相关域名
- **美团广告/推送/追踪拦截**：全面覆盖美团系广告、推送通知、数据追踪域名
- **多平台广告拦截**：覆盖微博、京东、淘宝、快手、广点通、百度、腾讯等主流广告网络
- **推送 SDK 拦截**：屏蔽个推、极光、友盟等推送服务 SDK
- **白名单保护**：校园跑核心服务器、支付宝、支付宝小程序等关键域名设为直连（`DIRECT`），确保 App 正常运行

## 拦截规则总览

| 分类 | 拦截域名/规则 |
|------|--------------|
| 白名单（直连） | `iydsj.com`、`zztfly.com`、`alipay.com`、`qianwen.com`、`cmpassport.com`、`alicdn.com`、`bytescm.com`、`zijieapi.com`、`quark.cn`、`e.qq.com` |
| 穿山甲广告 SDK | `pangolin-sdk-toutiao.com` 系列、`volces.com` 系列等 |
| 快手广告联盟 | `gifshow.com`、`yximgs.com` |
| 运动世界校园广告 | `tianmu.mobi`、`admobile.top` |
| 微博广告 | `sax.sina.com.cn`、`saxs.sina.com.cn`、`ad.weibo.com` |
| 美团广告/推送/追踪 | `meituan.com` 全系列、`meituanwaimai.com`、`push.meituan.com`、`ad.meituan.com` 等 24 条规则 |
| 京东广告 | `dsp-x.jd.com`、`janapi.jd.com` |
| 淘宝广告 | `guide-acs.m.taobao.com` |
| 快手广告 | `open.e.kuaishou.cn`、`e.kuaishou.com`、`kwad.com` |
| 广点通 | `gdt.qq.com`、`pgdt.gtimg.cn`、`ugdtimg.com` |
| 推送 SDK | `getui.com`、`gepush.com`、`igexin.com`、`umeng.com`、`umengcloud.com` |
| 通用广告 | 百度系、腾讯系、Google 广告系列、AppLovin、Mintegral、Unity Ads、InMobi、Chartboost 等 |

## 使用方法

### 1. 下载配置文件

点击页面右上角 **Code** 按钮 → **Download ZIP**，解压后获取 `运动校园去广（iOS版）.yaml` 文件。

### 2. 导入 ClashMi

1. 打开 **ClashMi** App
2. 点击右上角 **`+`** 号（添加配置）
3. 选择 **"文件导入"**
4. 选择下载的配置文件中 `运动校园去广（iOS版）.yaml`
5. 点击保存并应用

### 3. 开启 TUN 模式

1. 进入 ClashMi 主界面
2. 开启 **TUN** 模式
3. 策略选择切换为 **DIRECT** 或你需要的策略

### 4. 测试效果

重启校园跑 App，观察是否还有广告弹窗。如有遗漏，欢迎提交 Issue。

## 配置说明

```
mixed-port: 7890          # 代理端口
allow-lan: false          # 禁止局域网访问（安全起见）
mode: rule                # 规则模式
log-level: info           # 日志级别

dns:
  enable: true            # 开启 DNS 解析
  ipv6: false             # 关闭 IPv6
  default-nameserver: [223.5.5.5, 119.29.29.29]  # 阿里DNS + 腾讯DNS
  nameserver: [https://dns.alidns.com/dns-query, https://doh.pub/dns-query]  # DoH 加密 DNS
  enhanced-mode: fake-ip  # Fake-IP 模式，提升解析速度
```

## 安全说明

- 本配置文件**不包含任何代理节点**，所有规则仅为 `DIRECT`（直连）或 `REJECT`（拦截）
- 配置文件仅在你本地设备生效，不会上传任何数据
- 建议定期审查「设置 → 通用 → VPN 与设备管理」，确认无陌生描述文件

## 免责声明

本工具仅供个人学习研究使用，请遵守当地法律法规。使用者需自行承担使用风险。

## 更新日志

- **v12**：全面扩充美团广告/推送/追踪域名拦截规则（24 条）
- **v11**：新增 `gifshow.com`、`yximgs.com` 快手广告联盟拦截
- **v1**：初始版本，覆盖穿山甲、天幕、微博、京东、淘宝、快手、广点通、推送 SDK 等广告源

## 许可证

MIT License
