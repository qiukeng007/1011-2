import Flutter
import UIKit
import WebKit

// ── Cookie 读取通道（iOS 微信扫码登录）──
// 直接从 WKWebsiteDataStore 读取登录会话 Cookie，解决 iOS 上
// flutter_inappwebview CookieManager / document.cookie 抓不到会话 Cookie 的问题
// （移植自 smart_eye_stock 的 iOS 微信扫码登录成功版：用 FlutterPlugin 协议注册，
// 保证通道在 Scene 生命周期下也必定生效）
class CookieChannelPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.cashcarry/cookies",
      binaryMessenger: registrar.messenger())
    let instance = CookieChannelPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let urlStr = args["url"] as? String,
          let url = URL(string: urlStr),
          let host = url.host else {
      result(FlutterMethodNotImplemented)
      return
    }
    let cookieStore = WKWebsiteDataStore.default().httpCookieStore
    if call.method == "getCookies" {
      cookieStore.getAllCookies { cookies in
        let matching = cookies.filter { cookie in
          let cd = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
          return host == cd || host.hasSuffix("." + cd) || cd.hasSuffix("." + host)
        }
        let cookieStr = matching
          .filter { !$0.value.isEmpty }
          .map { "\($0.name)=\($0.value)" }
          .joined(separator: "; ")
        result(cookieStr)
      }
    } else if call.method == "clearCookies" {
      cookieStore.getAllCookies { cookies in
        let matching = cookies.filter { cookie in
          let cd = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
          return host == cd || host.hasSuffix("." + cd) || cd.hasSuffix("." + host)
        }
        let group = DispatchGroup()
        for cookie in matching {
          group.enter()
          cookieStore.delete(cookie) { group.leave() }
        }
        group.notify(queue: .main) { result(true) }
      }
    } else {
      result(FlutterMethodNotImplemented)
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Scene 生命周期下 window 可能尚未创建，这里尝试直接注册（可能为空，不影响）
    if let controller = window?.rootViewController as? FlutterViewController {
      setupCookieChannel(controller)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // 与 smart_eye_stock 的 AudioChannelPlugin 一致：用插件注册表注册，
    // 通道绑定到 implicit engine 的 messenger，Scene 场景下也可靠
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CookieChannelPlugin") {
      CookieChannelPlugin.register(with: registrar)
    }
  }

  private func setupCookieChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "com.cashcarry/cookies",
      binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { (call, result) in
      guard let args = call.arguments as? [String: Any],
            let urlStr = args["url"] as? String,
            let url = URL(string: urlStr),
            let host = url.host else {
        result(FlutterMethodNotImplemented)
        return
      }
      let cookieStore = WKWebsiteDataStore.default().httpCookieStore
      if call.method == "getCookies" {
        cookieStore.getAllCookies { cookies in
          let matching = cookies.filter { cookie in
            let cd = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == cd || host.hasSuffix("." + cd) || cd.hasSuffix("." + host)
          }
          let cookieStr = matching
            .filter { !$0.value.isEmpty }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
          result(cookieStr)
        }
      } else if call.method == "clearCookies" {
        cookieStore.getAllCookies { cookies in
          let matching = cookies.filter { cookie in
            let cd = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == cd || host.hasSuffix("." + cd) || cd.hasSuffix("." + host)
          }
          let group = DispatchGroup()
          for cookie in matching {
            group.enter()
            cookieStore.delete(cookie) { group.leave() }
          }
          group.notify(queue: .main) { result(true) }
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
