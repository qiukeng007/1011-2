import Flutter
import UIKit
import WebKit

// ── Cookie 读取通道（iOS 微信扫码登录）──
// 直接从 WKWebsiteDataStore 读取登录会话 Cookie，解决 iOS 上
// flutter_inappwebview CookieManager / document.cookie 抓不到会话 Cookie 的问题
// （移植自 smart_eye_stock 的 iOS 微信扫码登录成功版）
class CookieChannelPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.cashcarry/cookies",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(CookieChannelPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CookieChannelPlugin") {
      CookieChannelPlugin.register(with: registrar)
    }
  }
}