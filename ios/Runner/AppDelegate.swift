import Flutter
import UIKit
import WebKit

// ── Cookie 读取通道（iOS 微信扫码登录）──
// 直接从 WKWebsiteDataStore 读取登录会话 Cookie，解决 iOS 上
// flutter_inappwebview CookieManager / document.cookie 抓不到会话 Cookie 的问题
// （移植自 smart_eye_stock 的 iOS 微信扫码登录成功版）

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 与 smart_eye_stock 一致：直接在 FlutterViewController 的 messenger 上注册
    // Cookie 通道（比 implicit engine 的 registrar(forPlugin:) 更可靠，iOS 已验证）
    if let controller = window?.rootViewController as? FlutterViewController {
      setupCookieChannel(controller)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  private func setupCookieChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "com.cashcarry/cookies",
      binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { (call, result) in
      guard call.method == "getCookies",
            let args = call.arguments as? [String: Any],
            let urlStr = args["url"] as? String,
            let url = URL(string: urlStr),
            let host = url.host else {
        result(FlutterMethodNotImplemented)
        return
      }
      let cookieStore = WKWebsiteDataStore.default().httpCookieStore
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
    }
  }
}
